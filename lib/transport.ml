(* Port of the HTTP/1.x subset of go/src/net/http/transport.go: the
   RoundTripper interface analogue, the Transport (connection establishment via
   {!Net.connect}, request write via {!Io.write_request}, response read via
   {!Io.read_response}) and the idle-connection pool keyed by scheme/host/port
   (Go's [idleConn map[connectMethodKey][]*persistConn]).

   HTTP/2, proxies, the wantConn queue, connsPerHost limits, the async body
   read-ahead and the byte-counted persistConn read/write loops are out of
   scope; we keep one idle connection per cache key (a list, as Go does) and
   reuse the most-recently-returned one. Because {!Io} materializes response
   bodies fully in memory, a keep-alive-eligible connection can be returned to
   the pool as soon as {!round_trip} has read the response. *)

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
}

let create () =
  { idle_conn = Hashtbl.create 8; disable_keep_alives = false; dials = 0 }

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

let dial t ~scheme ~host ~port =
  t.dials <- t.dials + 1;
  let tls = scheme = "https" in
  Net.connect ~host ~port ~tls () >>= fun (ic, oc) -> Lwt.return { ic; oc }

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

(* Go's Transport.RoundTrip (HTTP/1.x path). The optional [?context] is an API
   ergonomics layer over Go's req.Context(): when supplied it is applied to the
   request before the round trip (so the [Context.done_ req.ctx] race below
   uses it); when omitted the request's existing [ctx] is used (defaulting to
   [Context.background]). *)
let round_trip ?context t (req : Body.t Request.t) : Body.t Response.t Lwt.t =
  (match context with Some ctx -> req.Request.ctx <- ctx | None -> ());
  let scheme, host, port = scheme_host_port req in
  if host = "" then
    Lwt.fail (Io.Protocol_error "http: no Host in request URL")
  else begin
  let key = conn_key ~scheme ~host ~port in
  set_default_headers req ~host;
  (* Obtain a connection: reuse an idle one or dial a fresh one. *)
  let acquire () =
    match get_idle_conn t key with
    | Some pc -> Lwt.return (pc, true)
    | None -> dial t ~scheme ~host ~port >>= fun pc -> Lwt.return (pc, false)
  in
  let exchange pc =
    (* Body is fully materialized by Io.read_response, so the connection is
       immediately free. Return it to the pool when reusable, else close. *)
    Io.write_request pc.oc req >>= fun () ->
    Lwt_io.flush pc.oc >>= fun () ->
    Io.read_response ~request:req pc.ic >>= fun resp ->
    (if reusable t req resp then (
       put_idle_conn t key pc;
       Lwt.return_unit)
     else close_conn pc)
    >>= fun () -> Lwt.return resp
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
  attempt ~allow_retry:true
  end

(* Test/inspection hooks. *)
let dial_count t = t.dials
let idle_count t key = match Hashtbl.find_opt t.idle_conn key with
  | Some l -> List.length l
  | None -> 0
let conn_key = conn_key

let default_transport = create ()
