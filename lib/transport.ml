(* Port of the HTTP/1.x subset of go/src/net/http/transport.go: the
   RoundTripper interface analogue, the Transport (connection establishment via
   {!Net.connect}, request write via {!Io.write_request}, response read via
   {!Io.read_response}) and the idle-connection pool keyed by scheme/host/port
   (Go's [idleConn map[connectMethodKey][]*persistConn]).

   HTTP/2, proxies, the wantConn queue, connsPerHost limits, the async body
   read-ahead and the byte-counted persistConn read/write loops are out of
   scope; we keep one idle connection per cache key (a list, as Go does) and
   reuse the most-recently-returned one.

   The response body now {b streams} (Stream Ticket 1: {!Io.read_response}
   returns a [Body.Stream], not a materialized String). So a keep-alive-eligible
   connection is {b not} immediately free after {!round_trip} reads the response
   headers — it is still busy carrying the (unread) body. Mirroring Go's
   [persistConn.readLoop]/[bodyEOFSignal] (transport.go), {!round_trip} decides
   reusability up front (Go's [persistConn.alive]) then hands back a body wrapped
   with a {b one-shot EOF/close action}: when the body reaches EOF (or is
   drained), the connection is returned to the idle pool if reusable, else
   closed. If the caller never drains/closes the body, the connection is simply
   not reused (Go behaves the same until [resp.Body.Close]). A [?context] firing
   mid-body aborts the in-flight read and closes the connection rather than
   pooling it. *)

open Lwt.Infix

(* User-Agent default. Go uses "Go-http-client/1.1" (request.go
   [defaultUserAgent]); this port advertises its own UA so the wire string is
   not mistaken for the Go runtime's. Mirrors Go's "<name>/<http-version>"
   shape. *)
let default_user_agent = "gohttp-client/1.1"

(* A pooled, reusable connection: the buffered channels plus the underlying fd
   (so we can actually close it when the connection is not reusable). *)
type persist_conn = {
  ic : Lwt_io.input_channel;
  oc : Lwt_io.output_channel;
}

type t = {
  (* Go's idleConn map[connectMethodKey][]*persistConn: keyed by the
     scheme/host/port cache key, value is a stack of idle connections (most
     recently used at the end, as Go documents). *)
  idle_conn : (string, persist_conn list) Hashtbl.t;
  mutable disable_keep_alives : bool;
  (* Test hook: total number of connections this transport has dialed (Go has
     no exact analogue, but it lets the keep-alive-reuse test assert that a
     second request did NOT open a second connection). *)
  mutable dials : int;
  (* HTTP/2 connection pool (Go's [Transport.h2transport] / clientConnPool):
     keyed by authority ["host:port"], reused for multiplexed requests. *)
  h2_conns : (string, H2_transport.client_conn) Hashtbl.t;
  (* Test hook: how many requests this transport has served over h2. *)
  mutable h2_round_trips : int;
  (* TLS verification policy for https dials, reduced from Go's
     [Transport.TLSClientConfig]: when [insecure] is set the server certificate
     is not verified (Go's [InsecureSkipVerify]); an explicit [authenticator]
     overrides both. When neither is set, {!Net.connect_alpn} verifies against
     the system trust store (secure by default). *)
  insecure : bool;
  authenticator : X509.Authenticator.t option;
}

let create ?(insecure = false) ?authenticator () =
  {
    idle_conn = Hashtbl.create 8;
    disable_keep_alives = false;
    dials = 0;
    h2_conns = Hashtbl.create 8;
    h2_round_trips = 0;
    insecure;
    authenticator;
  }

(* Go's connectMethodKey.String(): "scheme|host:port" (no proxy here). *)
let conn_key ~scheme ~host ~port = Printf.sprintf "%s|%s:%d" scheme host port

(* Default scheme/host/port for a request URL, mirroring Go's
   transport.go connectMethodForRequest / Request URL handling. *)
let scheme_host_port (req : Body.t Request.t) =
  let url = req.Request.url in
  let scheme =
    match Uri.scheme url with Some s -> String.lowercase_ascii s | None -> "http"
  in
  let host =
    match Uri.host url with
    | Some h when h <> "" -> h
    | _ -> (
        (* Fall back to the Host header / request host. *)
        match req.Request.host with h when h <> "" -> h | _ -> "")
  in
  let port =
    match Uri.port url with
    | Some p -> p
    | None -> if scheme = "https" then 443 else 80
  in
  (scheme, host, port)

(* Pop an idle connection for [key], if any (Go's getIdleConn). *)
let get_idle_conn t key =
  match Hashtbl.find_opt t.idle_conn key with
  | Some (pc :: rest) ->
      Hashtbl.replace t.idle_conn key rest;
      Some pc
  | Some [] | None -> None

(* Return [pc] to the pool for reuse (Go's tryPutIdleConn). *)
let put_idle_conn t key pc =
  let existing = try Hashtbl.find t.idle_conn key with Not_found -> [] in
  Hashtbl.replace t.idle_conn key (existing @ [ pc ])

let close_conn pc =
  Lwt.catch (fun () -> Lwt_io.close pc.oc) (fun _ -> Lwt.return_unit)
  >>= fun () -> Lwt.catch (fun () -> Lwt_io.close pc.ic) (fun _ -> Lwt.return_unit)

(* The ALPN protocols advertised for an https dial (Go's
   [Transport.TLSClientConfig.NextProtos] with HTTP/2 enabled): h2 preferred,
   http/1.1 fallback. *)
let h2_alpn_protocols = [ "h2"; "http/1.1" ]

(* Dial a fresh connection, optionally advertising ALPN for an https dial.
   Returns the channels plus the negotiated ALPN protocol ([None] for plaintext
   or when no protocol was agreed). [force_h2] advertises only ["h2"]. *)
let dial_alpn t ~scheme ~host ~port ~force_h2 =
  t.dials <- t.dials + 1;
  let tls = scheme = "https" in
  let alpn =
    if force_h2 then Some [ "h2" ]
    else if tls then Some h2_alpn_protocols
    else None
  in
  Net.connect_alpn ~host ~port ~tls ?alpn ~insecure:t.insecure
    ?authenticator:t.authenticator ()
  >>= fun (ic, oc, negotiated) ->
  Lwt.return ({ ic; oc }, negotiated)

let dial t ~scheme ~host ~port =
  dial_alpn t ~scheme ~host ~port ~force_h2:false >>= fun (pc, _) ->
  Lwt.return pc

(* Decide whether a connection can be returned to the pool after this exchange,
   mirroring Go's persistConn.alive / shouldRetryRequest plumbing reduced to the
   HTTP/1.x keep-alive rules: not if keep-alives are disabled, not if the request
   asked to close, not if the response asked to close. *)
let reusable t (req : Body.t Request.t) (resp : Body.t Response.t) =
  (not t.disable_keep_alives)
  && (not req.Request.close)
  && not resp.Response.close

(* Set the default request headers Go's Transport/Request.write would supply:
   Host (from the URL/Host field) and a default User-Agent when the caller has
   not set one. *)
let set_default_headers (req : Body.t Request.t) ~host =
  if req.Request.host = "" then req.Request.host <- host;
  if Header.get req.Request.header "User-Agent" = "" then
    Header.set req.Request.header "User-Agent" default_user_agent

(* The authority key for the h2 connection pool: ["host:port"]. *)
let h2_authority ~host ~port = Printf.sprintf "%s:%d" host port

(* Whether a pooled h2 connection is still usable. *)
let h2_conn_usable cc = not (H2_transport.is_closed cc)

(* Get (or [None]) a usable pooled h2 connection for [authority]. *)
let get_h2_conn t authority =
  match Hashtbl.find_opt t.h2_conns authority with
  | Some cc when h2_conn_usable cc -> Some cc
  | Some _ ->
      Hashtbl.remove t.h2_conns authority;
      None
  | None -> None

(* The h2 request/response exchange over [cc], counted for the test hook. *)
let h2_round_trip t cc req =
  t.h2_round_trips <- t.h2_round_trips + 1;
  H2_transport.round_trip cc req

(* Go's Transport.RoundTrip. For https (or when [force_h2]) the dial advertises
   ALPN ["h2"; "http/1.1"]; if "h2" is negotiated the request is multiplexed
   over a pooled {!H2_transport.client_conn} (keyed by authority), otherwise the
   existing HTTP/1.x path runs over the dialed channels. Plaintext http always
   uses HTTP/1.x. The optional [?context] is an API ergonomics layer over Go's
   req.Context(): when supplied it is applied to the request before the round
   trip (so the [Context.done_ req.ctx] race below uses it); when omitted the
   request's existing [ctx] is used (defaulting to [Context.background]). *)
let round_trip ?context ?(force_h2 = false) t (req : Body.t Request.t) :
    Body.t Response.t Lwt.t =
  (match context with Some ctx -> req.Request.ctx <- ctx | None -> ());
  let scheme, host, port = scheme_host_port req in
  if host = "" then
    Lwt.fail (Io.Protocol_error "http: no Host in request URL")
  else begin
  let key = conn_key ~scheme ~host ~port in
  set_default_headers req ~host;
  let authority = h2_authority ~host ~port in
  let want_h2 = force_h2 || scheme = "https" in
  (* HTTP/2 fast path: reuse a pooled h2 connection for this authority. *)
  let h2_reuse () =
    match get_h2_conn t authority with
    | Some cc -> Some (h2_round_trip t cc req)
    | None -> None
  in
  (* Obtain a connection: reuse an idle one or dial a fresh one. *)
  let acquire () =
    match get_idle_conn t key with
    | Some pc -> Lwt.return (pc, true)
    | None -> dial t ~scheme ~host ~port >>= fun pc -> Lwt.return (pc, false)
  in
  (* Wrap the streaming [resp.body] so that reaching EOF (or being drained)
     runs a one-shot connection-release action: pool the connection if
     [reusable], else close it (Go's [bodyEOFSignal.fn] / [persistConn]
     returning to the pool only after [waitForBodyRead]). A [?context] firing
     mid-body aborts the in-flight read and closes the connection (NOT pooled),
     re-raising the context cause. The action runs at most once. *)
  let wrap_body_lifecycle pc (resp : Body.t Response.t) : Body.t =
    let reuse = reusable t req resp in
    let released = ref false in
    let release ~reuse_now =
      if !released then Lwt.return_unit
      else begin
        released := true;
        if reuse_now then (put_idle_conn t key pc; Lwt.return_unit)
        else close_conn pc
      end
    in
    match resp.Response.body with
    | (Body.Empty | Body.String _) as b ->
      (* No streaming body on the wire (e.g. HEAD / no-body status): the
         connection is immediately free. *)
      Lwt.async (fun () -> release ~reuse_now:reuse);
      b
    | Body.Stream inner ->
      let next () : string option Lwt.t =
        (* Race the inner read against the request context (Go aborts an
           in-flight body read on <-ctx.Done()). *)
        let ctx_p =
          Context.done_ req.Request.ctx >>= fun () ->
          let cause =
            match Context.err req.Request.ctx with
            | Some e -> e
            | None -> Context.Canceled
          in
          Lwt.fail cause
        in
        Lwt.try_bind
          (fun () -> Lwt.choose [ inner (); ctx_p ])
          (fun chunk ->
            Lwt.cancel ctx_p;
            match chunk with
            | Some _ -> Lwt.return chunk
            | None ->
              (* io.EOF: release the connection to the pool / close it. *)
              release ~reuse_now:reuse >>= fun () -> Lwt.return_none)
          (fun exn ->
            (* Context fired (or the read failed): close the connection
               unconditionally (never pool a torn-down/cancelled body). *)
            Lwt.cancel ctx_p;
            release ~reuse_now:false >>= fun () -> Lwt.fail exn)
      in
      Body.Stream next
  in
  let exchange pc =
    Io.write_request_exn pc.oc req >>= fun () ->
    Lwt_io.flush pc.oc >>= fun () ->
    Io.read_response_exn ~request:req pc.ic >>= fun resp ->
    resp.Response.body <- wrap_body_lifecycle pc resp;
    Lwt.return resp
  in
  (* Race the IO against the request context (Go aborts an in-flight round trip
     on <-ctx.Done() and returns context.Cause(ctx)). If the context fires
     first we raise its cause exception; [Lwt.choose] then leaves the IO branch
     pending, which we cancel and whose connection we close (the IO read would
     otherwise fail with EBADF and could mask the context cause). On normal IO
     completion the never-resolving context branch (for a background context) or
     resolved-after branch is cancelled, so the watcher does not leak. *)
  let exchange_with_ctx pc =
    let io_p = exchange pc in
    let ctx_p =
      Context.done_ req.Request.ctx >>= fun () ->
      let cause =
        match Context.err req.Request.ctx with
        | Some e -> e
        | None -> Context.Canceled
      in
      Lwt.fail cause
    in
    (* Lwt.choose resolves/rejects as soon as the first branch does, without
       cancelling the other. *)
    Lwt.try_bind
      (fun () -> Lwt.choose [ io_p; ctx_p ])
      (fun resp ->
        (* IO won. Stop watching the context. *)
        Lwt.cancel ctx_p;
        Lwt.return resp)
      (fun exn ->
        (* Either the context fired (cause exn) or the IO failed. In both cases
           cancel the still-pending sibling and close the connection so the fd
           is released; then re-raise. *)
        Lwt.cancel ctx_p;
        Lwt.cancel io_p;
        close_conn pc >>= fun () -> Lwt.fail exn)
  in
  let rec attempt ~allow_retry =
    acquire () >>= fun (pc, was_idle) ->
    Lwt.catch
      (fun () -> exchange_with_ctx pc)
      (fun exn ->
        (* A reused (idle) connection may have been closed by the server; on a
           failure with a recycled connection, dial fresh and retry once
           (Go's shouldRetryRequest for an idempotent re-dial). *)
        close_conn pc >>= fun () ->
        (* Do not retry when the context cancelled/expired (Go's
           shouldRetryRequest declines once the request context is done). *)
        let ctx_done = Context.err req.Request.ctx <> None in
        if was_idle && allow_retry && not ctx_done then attempt ~allow_retry:false
        else Lwt.fail exn)
  in
  (* When HTTP/2 is wanted, try a pooled h2 conn first; otherwise dial with
     ALPN and either establish an h2 ClientConn (negotiated "h2") or fall through
     to the HTTP/1.x path over the freshly-dialed channels (negotiated
     http/1.1 / none). Plaintext http skips all of this. *)
  if want_h2 then
    match h2_reuse () with
    | Some p -> p
    | None ->
        dial_alpn t ~scheme ~host ~port ~force_h2 >>= fun (pc, negotiated) ->
        if negotiated = Some "h2" then
          H2_transport.new_client_conn pc.ic pc.oc >>= fun cc ->
          Hashtbl.replace t.h2_conns authority cc;
          h2_round_trip t cc req
        else
          (* Reuse the dialed channels for the HTTP/1.x exchange. *)
          Lwt.catch
            (fun () -> exchange_with_ctx pc)
            (fun exn -> close_conn pc >>= fun () -> Lwt.fail exn)
  else attempt ~allow_retry:true
  end

(* Test/inspection hooks. *)
let dial_count t = t.dials
let h2_round_trip_count t = t.h2_round_trips
let idle_count t key = match Hashtbl.find_opt t.idle_conn key with
  | Some l -> List.length l
  | None -> 0
let conn_key = conn_key

let default_transport = create ()
