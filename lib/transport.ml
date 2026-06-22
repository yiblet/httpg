(* Port of the HTTP/1.x subset of go/src/net/http/transport.go: the
   RoundTripper analogue, the Transport (connection establishment via
   {!Net.connect_alpn}, request write via {!Io.write_request}, response read via
   {!Io.read_response}) and the idle-connection pool keyed by scheme/host/port
   (Go's [idleConn map[connectMethodKey][]*persistConn]).

   HTTP/2 over TLS (ALPN "h2") is multiplexed over a pooled
   {!Httpg_http2.H2_transport.client_conn} keyed by authority (the translation
   shim below, Go's http2.go: http2RoundTrip). Proxies, the wantConn queue,
   connsPerHost limits and the byte-counted read/write loops are out of scope; we
   keep a list of idle h1 connections per cache key and reuse the
   most-recently-returned one.

   {b Connection model.} Eio's [Net.connect_alpn] is callback-scoped: a
   connection lives only for the duration of [fn r w]. To keep a connection
   alive across requests for the pool we run each connection as its own fiber
   (Go's [persistConn] with its read/write loops) under the transport's switch:
   the fiber holds the channels open and serves requests handed to it over an
   [Eio.Stream], parking on the pool between requests. The response body
   {b streams}; the connection is returned to the idle pool only after the body
   reaches EOF / is drained (Go's [bodyEOFSignal] over [waitForBodyRead]). *)

let default_user_agent = "httpg-client/1.1"

module H2_transport = Httpg_http2.H2_transport
module Api = Httpg_http2.Api

(* The handleable failures of {!round_trip}, embedding the lower layers' typed
   errors (Go's RoundTrip returning an [error]). [No_host] is Go's
   [errMissingHost]. The whole flow threads typed [result]s: {!Net.connect_alpn},
   {!Io.write_request}/{!Io.read_response} and {!H2_transport.round_trip} all
   return [result], so {!round_trip} maps their [error] arms into these without a
   raise-and-catch boundary. *)
type error =
  | Net of Net.error
  | Io of Io.error
  | H2 of H2_transport.error
  | No_host

(* A pooled connection backed by a dedicated fiber. [submit] hands the fiber a
   request plus a one-shot [reply] stream; the fiber writes the request, reads
   the response head, replies, then parks until the response body is released
   (EOF/drained) before returning itself to the idle pool. [close] tears the
   connection down (cancels its switch). *)

(* The conn fiber replies with a typed transport [result] for handleable
   outcomes (Ok response / [Error (Io _)] from the framing). A genuinely
   unhandleable exception (Eio.Cancel, a programming bug, fiber teardown) is
   NOT swallowed into a result: it is carried verbatim as [Crashed] and
   re-raised by the awaiting fiber, preserving today's cancellation/teardown
   behavior. *)
type reply = Replied of (Response.t, error) result | Crashed of exn

type persist_conn = {
  submit : (Request.t * reply Eio.Stream.t) Eio.Stream.t;
  released : bool Eio.Stream.t;
      (* posted with the reuse verdict when the response body hits EOF *)
  mutable broken : bool;
  close : unit -> unit;
}

let error_to_string = function
  | Net e -> Net.error_to_string e
  | Io e -> Io.error_to_string e
  | H2 e -> H2_transport.error_to_string e
  | No_host -> "http: no Host in request URL"

(* Per-domain pool (Go's Transport connection pool, replicated per OS thread): a
   connection is only ever dialed, reused, and torn down on its OWNING domain,
   so its Buf_read/Buf_write never crosses a domain boundary. Eio switches and
   fibers are domain-local, hence the pool's [sw] is per-domain too. The pool's
   own [idle_conn]/[h2_conns]/[h2_dial_locks] are touched only by their owning
   domain's fibers, so they keep the fiber-level {!Eio.Mutex}.
   NB: per-domain (not one shared pool a la Go) is a deliberate F038 decision;
   the rationale + the dispatch/body-proxy machinery cross-domain sharing would
   need is documented on {!t} in transport.mli. *)
type domain_pool = {
  sw : Eio.Switch.t; (* this domain's owning switch, set by {!run} *)
  (* Go's idleConn map[connectMethodKey][]*persistConn: keyed by the
     scheme/host/port cache key, value a stack of idle connections (most
     recently used at the end). *)
  idle_conn : (string, persist_conn list) Hashtbl.t;
  (* Go's clientConnPool.conns map[string][]*ClientConn: a list of multiplexed
     h2 connections per authority, dialing an additional conn when all existing
     ones are saturated (client_conn_pool.go:24). *)
  h2_conns : (string, H2_transport.client_conn list) Hashtbl.t;
  (* Per-authority dial lock (Go's clientConnPool dialCall/singleflight). *)
  h2_dial_locks : (string, Eio.Mutex.t) Hashtbl.t;
  mutex : Eio.Mutex.t; (* guards this domain's pool tables; fiber-level *)
}

type t = {
  (* Eio capabilities captured at construction (cohttp_eio style), so per-call
     surfaces don't re-thread them. The switch is NOT captured (scoped/short-lived
     — per-domain, owned by {!run}). *)
  net : [ `Generic ] Eio.Net.ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
  (* Domain -> per-domain pool. The ONLY structure touched from multiple
     domains, so it is guarded by a cross-domain-safe {!Stdlib.Mutex} (NOT
     {!Eio.Mutex}, whose fiber-suspension wakeups are domain-local). Access is
     rare: first-use per domain + aggregated counters. *)
  registry : (int, domain_pool) Hashtbl.t;
  registry_mutex : Mutex.t;
  mutable disable_keep_alives : bool;
  (* Process-wide test hooks, summed across domains; atomic since dialed from
     any domain. *)
  dials : int Atomic.t;
  h2_round_trips : int Atomic.t;
  insecure : bool;
  authenticator : X509.Authenticator.t option;
  (* Go's [Transport.MaxResponseHeaderBytes] (transport.go:275-280): a limit on
     the response status line + header block, default
     [DefaultMaxResponseHeaderBytes] (10<<20). The body is separately bounded by
     streaming {!Transfer}. *)
  max_response_header_bytes : int;
  (* Test-only fault-injection hook (Go's testHooks): run on the pooled-h2 fast
     path just before reusing a conn, so a test can force the closed/closing race
     that yields Conn_unusable. No-op in production. *)
  mutable before_h2_round_trip : unit -> unit;
}

let default_max_response_header_bytes = 10 lsl 20

let create ~net ?clock ?(insecure = false) ?authenticator
    ?(max_response_header_bytes = default_max_response_header_bytes) () =
  {
    net :> [ `Generic ] Eio.Net.ty Eio.Resource.t;
    clock =
      Option.map (fun c -> (c :> float Eio.Time.clock_ty Eio.Resource.t)) clock;
    registry = Hashtbl.create 8;
    registry_mutex = Mutex.create ();
    disable_keep_alives = false;
    dials = Atomic.make 0;
    h2_round_trips = Atomic.make 0;
    insecure;
    authenticator;
    max_response_header_bytes;
    before_h2_round_trip = (fun () -> ());
  }

let self_domain () = (Domain.self () :> int)

let with_registry t fn =
  Mutex.lock t.registry_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.registry_mutex) fn

(* Establish the CURRENT domain's pool with owning switch [sw] for the scope of
   [fn] (Go's Transport pool, one per OS thread driving it). All pooled
   connection fibers on this domain fork under [sw], so they outlive any
   per-request caller switch (fixes F009 invalidation / F014 deadlock).
   Reentrant per domain: a [run] on a domain that already has a live pool (a
   nested [run], or a second top-level [run] under the same still-open [sw])
   reuses it — so keep-alive reuse holds across sequential round trips, and
   wrapping is idempotent. The pool's lifetime is tied to [sw]: it is torn down
   (idle conns closed, entry removed) when [sw] is released, NOT when [fn]
   returns. *)
let run t ~sw fn =
  let dom = self_domain () in
  with_registry t (fun () ->
      match Hashtbl.find_opt t.registry dom with
      | Some _ -> () (* this domain already has a live pool: reuse it *)
      | None ->
          let pool =
            {
              sw;
              idle_conn = Hashtbl.create 8;
              h2_conns = Hashtbl.create 8;
              h2_dial_locks = Hashtbl.create 8;
              mutex = Eio.Mutex.create ();
            }
          in
          Hashtbl.replace t.registry dom pool;
          (* Tear the entry down when [sw] is released, so the pool's lifetime
             matches the switch's (Go's Transport tied to a process context). *)
          Eio.Switch.on_release sw (fun () ->
              with_registry t (fun () -> Hashtbl.remove t.registry dom)));
  fn ()

(* This domain's pool (Go's per-thread view of the Transport). Raises if {!run}
   has not established one on the current domain — pooled conn fibers need a
   domain-local switch outliving the call. *)
let current_pool t =
  match
    with_registry t (fun () -> Hashtbl.find_opt t.registry (self_domain ()))
  with
  | Some p -> p
  | None ->
      invalid_arg
        "Transport: no owning switch on this domain; wrap calls in \
         Transport.run t ~sw (...)"

(* Go's connectMethodKey.String(): "scheme|host:port" (no proxy here). *)
let conn_key ~scheme ~host ~port = Printf.sprintf "%s|%s:%d" scheme host port

(* Default scheme/host/port for a request URL (Go's connectMethodForRequest). *)
let scheme_host_port (req : Request.t) =
  let url = req.Request.url in
  let scheme =
    match Uri.scheme url with
    | Some s -> String.lowercase_ascii s
    | None -> "http"
  in
  let host =
    match Uri.host url with
    | Some h when h <> "" -> h
    | _ -> Option.value ~default:"" req.Request.host
  in
  let port =
    match Uri.port url with
    | Some p -> p
    | None -> if scheme = "https" then 443 else 80
  in
  (scheme, host, port)

(* Pop an idle connection for [key] (Go's getIdleConn), skipping broken ones. *)
let rec get_idle_conn pool key =
  Eio.Mutex.use_rw ~protect:true pool.mutex (fun () ->
      match Hashtbl.find_opt pool.idle_conn key with
      | Some (pc :: rest) ->
          Hashtbl.replace pool.idle_conn key rest;
          Some pc
      | Some [] | None -> None)
  |> function
  | Some pc when pc.broken -> get_idle_conn pool key
  | other -> other

(* Return [pc] to the pool for reuse (Go's tryPutIdleConn). *)
let put_idle_conn pool key pc =
  Eio.Mutex.use_rw ~protect:true pool.mutex (fun () ->
      let existing =
        try Hashtbl.find pool.idle_conn key with Not_found -> []
      in
      Hashtbl.replace pool.idle_conn key (existing @ [ pc ]))

(* The ALPN protocols advertised for an https dial (Go's NextProtos): h2
   preferred, http/1.1 fallback. *)
let h2_alpn_protocols = [ "h2"; "http/1.1" ]

(* Reusability after an exchange (Go's persistConn.alive reduced to the HTTP/1.x
   keep-alive rules): not if keep-alives are disabled, the request asked to
   close, or the response asked to close. *)
let reusable t (req : Request.t) (resp : Response.t) =
  (not t.disable_keep_alives)
  && (not req.Request.close) && not resp.Response.close

(* Set the default request headers Go's Transport/Request.write supplies. *)
let set_default_headers (req : Request.t) ~host =
  if req.Request.host = None then req.Request.host <- Some host;
  match Header.get req.Request.header "User-Agent" with
  | None ->
      req.Request.header <-
        Header.set "User-Agent" default_user_agent req.Request.header
  | Some _ -> ()

(* Run one request/response exchange over the buffered channels [r]/[w]. The
   response body is wrapped so that reaching EOF (in the caller's fiber)
   {b synchronously} returns the connection to the idle pool when [reusable]
   (Go's bodyEOFSignal / tryPutIdleConn), then posts [released] so the
   connection fiber loops to its next request (or exits, closing the conn, when
   not reusable). Pooling synchronously at EOF — rather than handing off to the
   fiber — closes the timing gap where a follow-up round trip would miss the
   just-freed connection.

   Threads the framing layer's typed [result]: an {!Io.error} from the request
   write or response read maps to [Error (Io _)] (Go's persistConn write/read
   loop surfacing an [error]). *)
let exchange t pool key ~max_header_bytes ~released r w pc (req : Request.t) :
    (Response.t, error) result =
  match Io.write_request w req with
  | Error e -> Error (Io e)
  | Ok () -> (
      Eio.Buf_write.flush w;
      match Io.read_response ~request:req ~max_header_bytes r with
      | Error e -> Error (Io e)
      | Ok resp ->
          let reuse = reusable t req resp in
          (* Release the connection back to the pool exactly once: immediately
             when there is no body to drain ([content_length = Some 0L]), else
             when the streaming body reaches EOF. The flat [Body.t] no longer
             encodes "empty vs streaming" in its shape, so we decide from the
             framing-derived [content_length] (set by {!Io.read_response}). *)
          let released_once = ref false in
          let on_eof () =
            if not !released_once then begin
              released_once := true;
              if reuse && not pc.broken then put_idle_conn pool key pc;
              Eio.Stream.add released reuse
            end
          in
          (match resp.Response.content_length with
          | Some 0L -> on_eof ()
          | _ ->
              resp.Response.body <- Body.on_complete on_eof resp.Response.body);
          Ok resp)

(* The per-connection fiber (Go's persistConn loops). Holds the channels open,
   serves submitted requests, parks until the body is released, then loops if
   the exchange was reusable. Runs inside [Net.connect_alpn]'s callback so the
   connection is closed when this returns. *)
let conn_loop t pool key ~max_header_bytes pc r w =
  let rec loop () =
    let req, reply = Eio.Stream.take pc.submit in
    match
      exchange t pool key ~max_header_bytes ~released:pc.released r w pc req
    with
    | Ok resp -> (
        Eio.Stream.add reply (Replied (Ok resp));
        (* Wait for the caller to drain the body (Go's waitForBodyRead); the
           reuse verdict is decided in [exchange]'s on-EOF action. *)
        match Eio.Stream.take pc.released with
        | true -> loop ()
        | false -> () (* not reusable -> callback returns, conn closes *))
    | Error e ->
        (* Handleable framing failure: the conn wrote/read partially, so it is
           no longer reusable. Surface the typed error; don't loop. *)
        pc.broken <- true;
        Eio.Stream.add reply (Replied (Error e))
    | exception exn ->
        (* Unhandleable (Eio.Cancel, a programming bug, fiber teardown): carry
           it verbatim to the awaiting fiber, which re-raises it. Not swallowed
           into a result. *)
        pc.broken <- true;
        Eio.Stream.add reply (Crashed exn)
  in
  loop ()

(* A freshly dialed connection: either an HTTP/1.x persistent connection or an
   HTTP/2 multiplexed client_conn, decided by ALPN. *)
type dialed =
  | Dialed_h1 of persist_conn
  | Dialed_h2 of H2_transport.client_conn

(* What the dial daemon posts to the waiting round trip: a typed transport
   [result] (Ok dialed / [Error (Net _)] from {!Net.connect_alpn}) for handleable
   outcomes, or a verbatim unhandleable exception ([Dial_crashed]) the awaiting
   fiber re-raises. *)
type dial_outcome = Dialed of (dialed, error) result | Dial_crashed of exn

(* Dial a fresh connection and fork its serve fiber under the transport's owning
   switch (NOT the caller's per-request switch), so a pooled conn survives across
   independent round trips. Advertises ALPN for https; [force_h2] advertises only
   ["h2"]. If the peer negotiates "h2" an {!H2_transport.client_conn} is built
   over the channels; otherwise an HTTP/1.x persist_conn serve loop runs. Returns
   the dialed connection once the channels are live, or a typed [Error (Net _)]
   for a dial/handshake failure. *)
let dial t pool ~scheme ~host ~port ~key ~max_header_bytes ~force_h2 :
    (dialed, error) result =
  let sw = pool.sw in
  let net = t.net in
  Atomic.incr t.dials;
  let tls = scheme = "https" in
  let alpn =
    if force_h2 then [ "h2" ] else if tls then h2_alpn_protocols else []
  in
  (* The connection runs under its own child switch so [close] can tear it down
     independently of other pooled connections. *)
  let conn_sw = ref None in
  let result_box = Eio.Stream.create 1 in
  let pc =
    {
      submit = Eio.Stream.create 1;
      released = Eio.Stream.create 1;
      broken = false;
      close = (fun () -> match !conn_sw with Some f -> f () | None -> ());
    }
  in
  (* Daemon under the transport switch: an idle pooled conn parks forever on
     [submit] / an h2 read-loop parks on the socket, so they must not keep the
     owning [run] scope from finishing — the switch cancels them (closing the
     socket) once all real work is done. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try
         Eio.Switch.run @@ fun csw ->
         conn_sw := Some (fun () -> Eio.Switch.fail csw Exit);
         (* {!Net.connect_alpn} returns a typed result; thread it straight into
            [result_box]. A dial/handshake failure (Go's addTLS handshake error,
            transport.go:1803-1819) becomes [Error (Net _)] — modeled, no
            raise-and-catch bridge. *)
         match
           Net.connect_alpn ~sw:csw net ~host ~port ~tls ~alpn
             ~insecure:t.insecure ?authenticator:t.authenticator
             (fun ~proto r w ->
               (* Over cleartext there is no TLS handshake, so ALPN never runs and
                [proto] is [None]; [force_h2] then means h2c via prior knowledge
                (RFC 9113 §3.3) — speak HTTP/2 directly. Over TLS, ALPN decides. *)
               let want_h2 = proto = Some "h2" || (force_h2 && not tls) in
               if want_h2 then begin
                 let cc = H2_transport.new_client_conn ~sw:csw r w in
                 Eio.Stream.add result_box (Dialed (Ok (Dialed_h2 cc)));
                 (* Park: keep the channels/read-loop alive until the conn switch
                  is cancelled (close / pool teardown). *)
                 Eio.Fiber.await_cancel ()
               end
               else begin
                 Eio.Stream.add result_box (Dialed (Ok (Dialed_h1 pc)));
                 conn_loop t pool key ~max_header_bytes pc r w
               end)
         with
         | Ok () -> ()
         | Error (Net.Dial _ as e) | Error (Net.Tls _ as e) ->
             if Eio.Stream.length result_box = 0 then
               Eio.Stream.add result_box (Dialed (Error (Net e)))
       with exn -> (
         (* An unhandleable failure (Eio.Cancel, a bug, fiber teardown) is carried
           verbatim to the waiting round trip via [result_box] and re-raised
           below — not swallowed into a result. Tolerate a failing stream op
           during cancellation, where it re-raises. *)
         pc.broken <- true;
         if Eio.Stream.length result_box = 0 then
           try Eio.Stream.add result_box (Dial_crashed exn) with _ -> ()));
      `Stop_daemon);
  match Eio.Stream.take result_box with
  | Dialed d -> d
  | Dial_crashed exn -> raise exn

(* Submit [req] to a pooled connection fiber and await its response. Returns the
   conn fiber's typed [result]; an unhandleable [Crashed] exception is re-raised
   (Eio.Cancel / a bug / fiber teardown), never folded into a result. *)
let round_trip_over pc (req : Request.t) : (Response.t, error) result =
  let reply = Eio.Stream.create 1 in
  Eio.Stream.add pc.submit (req, reply);
  match Eio.Stream.take reply with Replied r -> r | Crashed exn -> raise exn

(* ---- net/http <-> http2 translation shim (Go's http2.go: http2RoundTrip) ----
   The HTTP/2 stack works in its own decoupled {!Api} types so it never names the
   public Request/Response/Body types; these convert across the boundary, and
   [Httpg_base.Status.to_string] is applied client-side (as Go does). *)

let api_body_of_body (b : Body.t) : Api.Body.t =
  (* [is_empty] forces one element but returns a re-readable body, so a stateful
     stream is not double-pulled. Outgoing request bodies are app-provided and do
     not carry mid-stream framing errors; a defensive [Error] is treated as EOF
     (the decoupled Api pull is [unit -> string option] and cannot carry one). *)
  let empty, b = Body.is_empty b in
  if empty then Api.Body.Empty
  else
    let pull = Body.to_stream b in
    Api.Body.Stream
      (fun () ->
        match pull () with
        | Some (Ok s) -> Some s
        | Some (Error _) | None -> None)

let body_of_api_body (b : Api.Body.t) : Body.t =
  match b with
  | Api.Body.Empty -> Body.empty
  | Api.Body.String s -> Body.of_string s
  | Api.Body.Stream f -> Body.of_stream f

(* The public Header is a persistent Map; the decoupled Api.header is a mutable
   Hashtbl. Convert at the shim boundary. *)
let api_header_of_header (h : Header.t) : Api.header =
  let t = Api.Header.create () in
  Header.iter (fun k vs -> List.iter (fun v -> Api.Header.add t k v) vs) h;
  t

let header_of_api_header (t : Api.header) : Header.t =
  List.fold_left
    (fun acc (k, vs) -> Header.set_values k vs acc)
    Header.empty (Api.Header.to_list t)

let client_request_of_request (req : Request.t) : Api.client_request =
  {
    creq_meth = req.Request.meth;
    creq_url = req.Request.url;
    creq_header = api_header_of_header req.Request.header;
    creq_trailer =
      (match req.Request.trailer with
      | Some t -> api_header_of_header t
      | None -> Api.Header.create ());
    creq_body = api_body_of_body req.Request.body;
    creq_host = Option.value ~default:"" req.Request.host;
    creq_content_length = Option.value ~default:(-1L) req.Request.content_length;
    creq_close = req.Request.close;
  }

let response_of_client_response (cr : Api.client_response) : Response.t =
  {
    Response.status = cr.cres_status_code;
    proto = Httpg_base.Protocol.Http20;
    header = header_of_api_header cr.cres_header;
    body = body_of_api_body cr.cres_body;
    content_length =
      (let n = cr.cres_content_length in
       if Int64.compare n 0L < 0 then None else Some n);
    transfer_encoding = [];
    close = false;
    uncompressed = cr.cres_uncompressed;
    trailer =
      (if Hashtbl.length cr.cres_trailer = 0 then None
       else Some (header_of_api_header cr.cres_trailer));
    request = None;
  }

(* The authority key for the h2 connection pool: ["host:port"]. *)
let h2_authority ~host ~port = Printf.sprintf "%s:%d" host port

(* The live conns for [authority], pruning closed ones (must hold [pool.mutex]).
   Empties the entry when none remain so a later miss re-dials. *)
let live_h2_conns_locked pool authority =
  match Hashtbl.find_opt pool.h2_conns authority with
  | None -> []
  | Some ccs ->
      let live = List.filter (fun cc -> not (H2_transport.is_closed cc)) ccs in
      if live = [] then Hashtbl.remove pool.h2_conns authority
      else Hashtbl.replace pool.h2_conns authority live;
      live

(* A usable pooled h2 conn for [authority]: the first that can reserve a stream
   slot, mirroring Go's getClientConn walk over conns[addr] +
   cc.ReserveNewRequest() (client_conn_pool.go:53-64). [None] => all saturated
   (or none pooled), so the caller dials an additional conn. The reservation
   counts against MAX_CONCURRENT_STREAMS and is consumed by the next round_trip,
   so concurrent pickers can't all land on the same nearly-full conn. *)
let get_h2_conn pool authority =
  Eio.Mutex.use_rw ~protect:true pool.mutex (fun () ->
      List.find_opt H2_transport.reserve_new_request
        (live_h2_conns_locked pool authority))

(* Append a freshly dialed conn to [authority]'s list (Go's addConnLocked,
   client_conn_pool.go:122). *)
let put_h2_conn pool authority cc =
  Eio.Mutex.use_rw ~protect:true pool.mutex (fun () ->
      let live = live_h2_conns_locked pool authority in
      Hashtbl.replace pool.h2_conns authority (live @ [ cc ]))

(* Drop a dead pooled conn from [authority]'s list (Go's markDead / removeConn
   guard); a no-op if a concurrent re-dial already pruned it. *)
let evict_h2_conn pool authority cc =
  Eio.Mutex.use_rw ~protect:true pool.mutex (fun () ->
      match Hashtbl.find_opt pool.h2_conns authority with
      | None -> ()
      | Some ccs -> (
          match List.filter (fun c -> not (c == cc)) ccs with
          | [] -> Hashtbl.remove pool.h2_conns authority
          | rest -> Hashtbl.replace pool.h2_conns authority rest))

(* The per-authority dial lock (Go's getStartDialLocked / dialCall). *)
let h2_dial_lock pool authority =
  Eio.Mutex.use_rw ~protect:true pool.mutex (fun () ->
      match Hashtbl.find_opt pool.h2_dial_locks authority with
      | Some m -> m
      | None ->
          let m = Eio.Mutex.create () in
          Hashtbl.replace pool.h2_dial_locks authority m;
          m)

(* The h2 request/response exchange over [cc], counted for the test hook. A
   Conn_unusable failure wrote nothing and is retried on a fresh dial, so it
   isn't counted as an exchange (the increment follows a started round trip).
   Threads {!H2_transport.round_trip}'s typed [result]; the [H2_transport.error]
   is kept as-is so the caller can branch on [Conn_unusable] before mapping the
   rest into [Error (H2 _)]. *)
let h2_round_trip t cc req : (Response.t, H2_transport.error) result =
  match H2_transport.round_trip cc (client_request_of_request req) with
  | Ok cr ->
      Atomic.incr t.h2_round_trips;
      Ok (response_of_client_response cr)
  | Error _ as e -> e

(* Go's Transport.RoundTrip. The [net] capability is captured in [t]; pooled
   connection fibers run under the transport's own switch ({!run}), not the
   caller's, so a round trip under a transient [Switch.run] returns cleanly after
   the body is drained. For https (or [force_h2]) the dial advertises ALPN
   ["h2";"http/1.1"]; if "h2" is negotiated the request is multiplexed over a
   pooled {!H2_transport.client_conn} keyed by authority, otherwise the HTTP/1.x
   path runs over the dialed channels. Plaintext http always uses HTTP/1.x. *)
let round_trip ?(force_h2 = false) t (req : Request.t) :
    (Response.t, error) result =
  let pool = current_pool t in
  let scheme, host, port = scheme_host_port req in
  (* Go's [errMissingHost] (transport.go): a request with no Host is invalid
     user input, surfaced as the typed [No_host] arm rather than a bare
     [Failure], so the caller can branch on it. *)
  if host = "" then Error No_host
  else
    let key = conn_key ~scheme ~host ~port in
    set_default_headers req ~host;
    let max_header_bytes = t.max_response_header_bytes in
    let authority = h2_authority ~host ~port in
    let want_h2 = force_h2 || scheme = "https" in
    (* Reuse an idle connection or dial a fresh one, retrying once on a fresh dial
     if a recycled connection turns out to be dead (Go's shouldRetryRequest).
     Everything operates on the current domain's [pool]. *)
    (* Every branch threads a typed [(Response.t, error) result]; the lower
       layers ({!dial}/{!round_trip_over}/{!h2_round_trip}) already return their
       own typed result, so there is no exception boundary to unwind. The
       [Conn_unusable] evict+retry-once and the dead-idle-conn retry stay inside
       [attempt]; a finally-failed retry returns its [Error] arm directly.
       Anything unhandleable (Eio.Cancel, bugs, fiber teardown) is re-raised by
       {!round_trip_over}/{!dial}, never folded into a result. *)
    let rec attempt ~allow_retry : (Response.t, error) result =
      (* HTTP/2 fast path: reuse a pooled multiplexed conn for this authority. A
       pooled conn can race into closed/closing between the usability check and
       round_trip; H2_transport returns Conn_unusable iff nothing was written, so
       the request is replayable. Evict + retry once on a fresh dial, mirroring
       the h1 idle-conn branch and Go's shouldRetryRequest (transport.go:845). *)
      match if want_h2 then get_h2_conn pool authority else None with
      | Some cc -> (
          t.before_h2_round_trip ();
          match h2_round_trip t cc req with
          | Ok resp -> Ok resp
          | Error H2_transport.Conn_unusable ->
              evict_h2_conn pool authority cc;
              if allow_retry then attempt ~allow_retry:false
              else Error (H2 H2_transport.Conn_unusable)
          | Error e -> Error (H2 e))
      | None -> (
          match get_idle_conn pool key with
          | Some pc -> (
              match round_trip_over pc req with
              | Ok resp -> Ok resp
              | Error e ->
                  (* A recycled connection that turned out to be dead/partial:
                   close it and retry once on a fresh dial (Go's
                   shouldRetryRequest); otherwise surface the typed error. *)
                  pc.close ();
                  if allow_retry then attempt ~allow_retry:false else Error e)
          | None -> (
              (* Serialize the dial per authority (Go's getStartDialLocked /
               dialCall singleflight): concurrent callers that all found every
               pooled conn saturated re-check under the lock and share a single
               new conn rather than each dialing one (thundering herd). A fresh
               h2 conn is added to the pool (Go's addConnLocked) {b inside} the
               lock, so the next lock holder's re-check sees it instead of
               dialing yet another. h1 dials don't pool a shared conn so they
               skip the lock. *)
              let dial_now () =
                dial t pool ~scheme ~host ~port ~key ~max_header_bytes ~force_h2
              in
              let dialed : (dialed, error) result =
                if want_h2 then
                  Eio.Mutex.use_rw ~protect:true (h2_dial_lock pool authority)
                    (fun () ->
                      (* Re-check: a slot may have freed on an existing conn, or a
                       concurrent dial added one. *)
                      match get_h2_conn pool authority with
                      | Some cc -> Ok (Dialed_h2 cc)
                      | None -> (
                          match dial_now () with
                          | Ok (Dialed_h2 cc) ->
                              put_h2_conn pool authority cc;
                              Ok (Dialed_h2 cc)
                          | Ok (Dialed_h1 _) as d -> d
                          | Error _ as e -> e))
                else dial_now ()
              in
              match dialed with
              | Error e -> Error e
              | Ok (Dialed_h2 cc) -> (
                  match h2_round_trip t cc req with
                  | Ok resp -> Ok resp
                  | Error e -> Error (H2 e))
              | Ok (Dialed_h1 pc) -> round_trip_over pc req))
    in
    attempt ~allow_retry:true

let clock t = t.clock

(* Test/inspection hooks. [dial_count]/[h2_round_trip_count] are process-wide,
   summed across all domains. [idle_count] is the CURRENT domain's pool only
   (idle conns are domain-local; a domain with no [run] has none). *)
let dial_count t = Atomic.get t.dials
let h2_round_trip_count t = Atomic.get t.h2_round_trips

let idle_count t key =
  match
    with_registry t (fun () -> Hashtbl.find_opt t.registry (self_domain ()))
  with
  | None -> 0
  | Some pool ->
      Eio.Mutex.use_ro pool.mutex (fun () ->
          match Hashtbl.find_opt pool.idle_conn key with
          | Some l -> List.length l
          | None -> 0)

let conn_key = conn_key

(* Test-only fault injection (F027): register a callback fired just before the
   pooled-h2 fast path reuses a conn, and close the pooled conn for an authority
   in place (left in the pool so the next reuse races into Conn_unusable). *)
let set_before_h2_round_trip t f = t.before_h2_round_trip <- f

let close_pooled_h2_conn t ~host ~port =
  let pool = current_pool t in
  let authority = h2_authority ~host ~port in
  let ccs =
    Eio.Mutex.use_ro pool.mutex (fun () ->
        Option.value ~default:[] (Hashtbl.find_opt pool.h2_conns authority))
  in
  List.iter H2_transport.close ccs

(* Test-only (F035): how many h2 conns are pooled for an authority right now. *)
let h2_conn_count t ~host ~port =
  match
    with_registry t (fun () -> Hashtbl.find_opt t.registry (self_domain ()))
  with
  | None -> 0
  | Some pool ->
      let authority = h2_authority ~host ~port in
      Eio.Mutex.use_ro pool.mutex (fun () ->
          match Hashtbl.find_opt pool.h2_conns authority with
          | Some l -> List.length l
          | None -> 0)
