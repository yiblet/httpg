(* Port of the HTTP/1.x subset of go/src/net/http/server.go: Handler /
   HandlerFunc, ResponseWriter, the per-connection serve loop, Server /
   ListenAndServe, ServeMux dispatch, and the NotFound / Error / Redirect /
   RedirectHandler helpers. HTTP/2-over-TLS is dispatched by ALPN (the h2 branch
   hands off to the HTTP/2 server via a translation shim, Go's http2.go);
   hijacking and graceful-shutdown niceties are out of scope. *)

type handler = sw:Eio.Switch.t -> Request.t -> Response.t
(** An axum-style handler: a function mapping a request to a fully-built
    response. Departs from Go's [ServeHTTP(ResponseWriter, *Request)] — the
    handler returns an immutable {!Response.t} that the serve loop flushes;
    streaming is expressed by a {!Body.Stream} body the runtime drives.

    [~sw] is the request switch: a {!Body.Stream} body is pulled by the serve
    loop {e after} the handler returns, so a handler streaming from an opened
    resource (the file server's file handle) must open it under [~sw], which is
    released once the response has been sent. Most handlers ignore [~sw]. *)

val error : string -> Httpg_base.Status.t -> Response.t
(** Go's [Error]: a plain-text [text/plain; nosniff] response with status [code]
    carrying the message. *)

val not_found : Request.t -> Response.t
(** Go's [NotFound]: a 404 "404 page not found" response. *)

val not_found_handler : unit -> handler
(** Go's [NotFoundHandler]. *)

val redirect : Request.t -> string -> Httpg_base.Status.t -> Response.t
(** Go's [Redirect]: a redirect response to [url] (which may be relative to the
    request path) with status [code]. *)

val redirect_handler : string -> Httpg_base.Status.t -> handler
(** Go's [RedirectHandler]. *)

(* ---- ServeMux ---- *)

type serve_mux
(** Go's [ServeMux]: an HTTP request multiplexer backed by the routing tree. *)

val new_serve_mux : unit -> serve_mux
(** Go's [NewServeMux]. *)

(** A handleable registration error: an invalid or conflicting pattern (Go's
    [register] error). Carries Go's message text. *)
type error = Register of string

val error_to_string : error -> string
(** Render an {!type-error} as its Go message text. *)

val handle : serve_mux -> string -> handler -> (unit, error) result
(** Go's [ServeMux.Handle]: register [handler] for [pattern]. Returns
    [Error (Register _)] on an invalid or conflicting pattern. *)

val serve_mux_serve_http :
  serve_mux -> sw:Eio.Switch.t -> Request.t -> Response.t
(** Go's [ServeMux.ServeHTTP]: dispatch a request to the matching handler. *)

val serve_mux_handler : serve_mux -> handler
(** A {!serve_mux} viewed as a {!handler}. *)

(* ---- Server ---- *)

type t
(** Go's [Server]: an address, a handler, the duration knobs, and the per-domain
    accept [Switch]es used to shut the accept loops (and in-flight connection
    fibers) down. *)

exception Shutdown
(** Sentinel used by {!close} to cancel the accept switches; swallowed by
    {!serve} (the shared accept loop, also used by the TLS entry points) so a
    clean shutdown returns normally. *)

val create :
  net:_ Eio.Net.t ->
  ?clock:_ Eio.Time.clock ->
  ?domain_mgr:_ Eio.Domain_manager.t ->
  ?addr:string ->
  ?port:int ->
  ?read_timeout:float ->
  ?read_header_timeout:float ->
  ?write_timeout:float ->
  ?idle_timeout:float ->
  ?max_header_bytes:int ->
  handler ->
  t
(** [create ~net ?clock ?domain_mgr ?addr ?port handler] builds a server bound
    to [addr]:[port], capturing the [net] capability (and optional [clock] for
    the duration knobs) so the serve entry points don't re-thread them.

    [?domain_mgr] (Eio.Stdenv.domain_mgr) enables the multicore accept pool: the
    serve entry points pre-spawn one accept loop per domain (default
    [Domain.recommended_domain_count ()], overridable with [?domains]), all
    accepting the same listening socket, for genuine parallelism across OS
    cores. Without it (or with [?domains:1]) serving stays single-domain.

    The four optional duration knobs are Go's [Server.ReadTimeout],
    [ReadHeaderTimeout], [WriteTimeout] and [IdleTimeout], in seconds, each
    defaulting to [0.] = "no timeout". As in Go, [read_header_timeout] and
    [idle_timeout] fall back to [read_timeout] when left at [0.]. The timeouts
    are enforced only when a [?clock] was captured here; they are implemented as
    [Eio.Time] deadlines (Go uses socket [SetReadDeadline]/[SetWriteDeadline]).

    [max_header_bytes] is Go's [Server.MaxHeaderBytes]: the request line +
    header block is bounded cumulatively against [max_header_bytes + 4096]
    bytes; a request exceeding it is answered [431] and the connection closed.
    Defaults to [DefaultMaxHeaderBytes = 1 lsl 20] (1 MB). *)

val close : t -> unit
(** Minimal [Server.Close]: cancel all per-domain accept switches, which stops
    accepting and cancels every in-flight connection fiber across all domains,
    then close the listener. Safe to call from any domain. *)

val shutdown : t -> unit
(** Go's [Server.Shutdown]: gracefully stop. Closes the listener (refuses new
    connections) and signals live connections to drain rather than cancelling
    them — HTTP/2 conns send a GOAWAY (NO_ERROR) with the last processed stream
    id, finish their in-flight streams, then linger briefly before closing; new
    streams after the GOAWAY are refused. Unlike {!close} it does not abort
    in-flight work. Safe to call from any domain. *)

val serve : ?domains:int -> t -> _ Eio.Net.listening_socket -> unit
(** [serve ?domains srv listen_sock] is Go's [Server.Serve]: accept connections
    on [listen_sock] and handle each in its own Eio fiber until {!close} is
    called. Each connection runs the per-request keep-alive loop; per-connection
    errors are recovered so one bad connection never tears down its accept loop
    (Go's [conn.serve]). The [clock] captured at {!create} (if any) drives the
    duration-knob deadlines.

    When a [?domain_mgr] was captured at {!create}, [?domains] accept loops (one
    per domain, default [Domain.recommended_domain_count ()]) are pre-spawned on
    the shared [listen_sock] for true multicore parallelism. [?domains:1], or no
    captured [domain_mgr], gives the legacy single-domain accept loop. *)

val listen_and_serve :
  ?read_timeout:float ->
  ?read_header_timeout:float ->
  ?write_timeout:float ->
  ?idle_timeout:float ->
  ?max_header_bytes:int ->
  net:_ Eio.Net.t ->
  ?clock:_ Eio.Time.clock ->
  ?domain_mgr:_ Eio.Domain_manager.t ->
  ?domains:int ->
  addr:string ->
  port:int ->
  handler ->
  unit
(** Go's [ListenAndServe]: bind [addr]:[port] (under an internal switch) and
    serve [handler] until the listener is torn down. Pass [?domain_mgr] (with an
    optional [?domains] count) to serve across OS cores; see {!serve}. The four
    duration knobs and [max_header_bytes] are forwarded to {!create}. *)

val listen_and_serve_started :
  ?read_timeout:float ->
  ?read_header_timeout:float ->
  ?write_timeout:float ->
  ?idle_timeout:float ->
  ?max_header_bytes:int ->
  net:_ Eio.Net.t ->
  ?clock:_ Eio.Time.clock ->
  ?domain_mgr:_ Eio.Domain_manager.t ->
  ?domains:int ->
  sw:Eio.Switch.t ->
  addr:string ->
  port:int ->
  handler ->
  t * int * (unit -> unit)
(** Like {!listen_and_serve} but binds the listener under the caller's [sw]
    first and returns the running [Server.t], the bound port (useful when
    [port = 0] selects an ephemeral port) and a thunk that runs the accept pool
    — so tests can read the port, fork the accept thunk, connect and {!close}.
    The four duration knobs and [max_header_bytes] are forwarded to {!create};
    [?domain_mgr]/[?domains] enable the multicore accept pool (see {!serve}). *)

(* ---- HTTP/2 over TLS (ALPN dispatch) ---- *)

val default_alpn_protocols : string list
(** The default ALPN protocols advertised by the TLS server:
    [["h2"; "http/1.1"]] (Go's [http2.NextProtoTLS] + ["http/1.1"]). *)

val listen_and_serve_tls :
  ?read_timeout:float ->
  ?read_header_timeout:float ->
  ?write_timeout:float ->
  ?idle_timeout:float ->
  ?max_header_bytes:int ->
  net:_ Eio.Net.t ->
  ?clock:_ Eio.Time.clock ->
  ?domain_mgr:_ Eio.Domain_manager.t ->
  ?domains:int ->
  certificates:Tls.Config.certchain ->
  ?alpn:string list ->
  addr:string ->
  port:int ->
  handler ->
  unit
(** Go's [ListenAndServeTLS]: bind [addr]:[port] with server-side TLS carrying
    [certificates] and advertising the ALPN protocols [alpn] (default
    {!default_alpn_protocols}), then serve [handler] over each accepted
    connection. When the negotiated ALPN protocol is ["h2"] the connection is
    served by {!Httpg_http2.H2_server} (via the public h1<->h2 translation shim,
    Go's http2.go); otherwise the HTTP/1.x serve loop runs over the TLS
    channels. The four duration knobs and [max_header_bytes] are forwarded to
    {!create} (Go keeps these on the single [Server] struct shared by
    [ListenAndServe] and [ListenAndServeTLS]). *)

val listen_and_serve_tls_started :
  ?read_timeout:float ->
  ?read_header_timeout:float ->
  ?write_timeout:float ->
  ?idle_timeout:float ->
  ?max_header_bytes:int ->
  net:_ Eio.Net.t ->
  ?clock:_ Eio.Time.clock ->
  ?domain_mgr:_ Eio.Domain_manager.t ->
  ?domains:int ->
  certificates:Tls.Config.certchain ->
  ?alpn:string list ->
  sw:Eio.Switch.t ->
  addr:string ->
  port:int ->
  handler ->
  t * int * (unit -> unit)
(** Like {!listen_and_serve_tls} but binds the listener under [sw] first and
    returns the running [Server.t], the bound port (useful with an ephemeral
    [port = 0]) and the accept-loop thunk — so tests can connect over TLS and
    {!close}. The four duration knobs and [max_header_bytes] are forwarded to
    {!create}. *)
