(* Port of the HTTP/1.x subset of go/src/net/http/server.go: Handler /
   HandlerFunc, ResponseWriter, the per-connection serve loop, Server /
   ListenAndServe, ServeMux dispatch, and the NotFound / Error / Redirect /
   RedirectHandler helpers. HTTP/2, hijacking, TLS-NPN and graceful-shutdown
   niceties are out of scope. *)

type response_writer = {
  header : unit -> Header.t;
  write_header : int -> unit;
  write : string -> unit Lwt.t;
  flush : unit -> unit Lwt.t;
}
(** Go's [ResponseWriter] interface, modeled as a record of operations.
    - [header ()] returns the mutable header map the handler writes to before
      the response headers are flushed (Go's [ResponseWriter.Header]).
    - [write_header code] sets the status code (Go's [WriteHeader]); the first
      [write] implicitly calls [write_header 200].
    - [write data] appends body bytes (Go's [ResponseWriter.Write]). Writes
      accumulate in a [bufferBeforeChunkingSize = 2048] byte buffer; the framing
      decision (Content-Length vs chunked) fires at first flush = the buffer
      exceeds 2048 bytes, the handler returns, or [flush] is called. A handler
      that finishes with <=2048 bytes buffered and no explicit Content-Length
      gets an exact Content-Length (Go's common case); otherwise the response is
      streamed chunked (HTTP/1.1) or close-delimited (HTTP/1.0).
    - [flush ()] forces the headers/framing decision and pushes buffered bytes
      to the client (Go's [http.Flusher.Flush]). *)

type handler = {
  serve_http : response_writer -> Body.t Request.t -> unit Lwt.t;
}
(** Go's [Handler] interface: [ServeHTTP(ResponseWriter, *Request)]. *)

val handler_func :
  (response_writer -> Body.t Request.t -> unit Lwt.t) -> handler
(** Go's [HandlerFunc]: adapt a function to a {!handler}. *)

val error : response_writer -> string -> int -> unit Lwt.t
(** Go's [Error]: reply with a plain-text error message and status [code],
    resetting Content-Type, deleting Content-Length and setting the nosniff
    option. *)

val not_found : response_writer -> Body.t Request.t -> unit Lwt.t
(** Go's [NotFound]: a 404 "404 page not found" reply. *)

val not_found_handler : unit -> handler
(** Go's [NotFoundHandler]. *)

val redirect :
  response_writer -> Body.t Request.t -> string -> int -> unit Lwt.t
(** Go's [Redirect]: reply with a redirect to [url] (which may be relative to
    the request path) using status [code]. *)

val redirect_handler : string -> int -> handler
(** Go's [RedirectHandler]. *)

(* ---- ServeMux ---- *)

type serve_mux
(** Go's [ServeMux]: an HTTP request multiplexer backed by the routing tree. *)

val new_serve_mux : unit -> serve_mux
(** Go's [NewServeMux]. *)

(** A handleable registration error: an invalid or conflicting pattern (Go's
    [register] error, which Go surfaces by panicking in [Handle] but returns
    from [registerErr]). Carries Go's message text. *)
type error = Register of string

val error_to_string : error -> string
(** Render an {!error} as its Go message text. *)

val handle : serve_mux -> string -> handler -> (unit, error) result
(** Go's [ServeMux.Handle]: register [handler] for [pattern]. Returns
    [Error (Register _)] on an invalid or conflicting pattern (a wiring-time
    programmer error; callers may [Result.get_ok] at setup). *)

val handle_func :
  serve_mux ->
  string ->
  (response_writer -> Body.t Request.t -> unit Lwt.t) ->
  (unit, error) result
(** Go's [ServeMux.HandleFunc]: register a handler function for [pattern].
    Returns [Error (Register _)] on an invalid or conflicting pattern. *)

val serve_mux_serve_http :
  serve_mux -> response_writer -> Body.t Request.t -> unit Lwt.t
(** Go's [ServeMux.ServeHTTP]: dispatch a request to the matching handler. *)

val serve_mux_handler : serve_mux -> handler
(** A {!serve_mux} viewed as a {!handler}. *)

(* ---- Server ---- *)

type t
(** Go's [Server]. The zero-ish value carries an address, a handler and an
    internal stop signal used to shut the accept loop down (for tests). *)

val create : ?addr:string -> ?port:int -> handler -> t
(** [create ?addr ?port handler] builds a server bound to [addr]:[port]. *)

val close : t -> unit Lwt.t
(** Minimal [Server.Close]: stop accepting and close the listening socket. *)

val serve : t -> Lwt_unix.file_descr -> unit Lwt.t
(** [serve srv fd] is Go's [Server.Serve]: accept connections on the listening
    socket [fd] and handle each in its own Lwt fiber until {!close} is called.
    Each connection runs the per-request keep-alive loop. *)

val listen_and_serve : addr:string -> port:int -> handler -> unit Lwt.t
(** Go's [ListenAndServe]: bind [addr]:[port] and serve [handler] until the
    process or the listener is torn down. *)

val listen_and_serve_started :
  addr:string -> port:int -> handler -> (t * int * unit Lwt.t) Lwt.t
(** Like {!listen_and_serve} but binds first and returns the running [Server.t],
    the bound port (useful when [port = 0] selects an ephemeral port) and the
    serve loop promise — so tests can connect and {!close}. *)

(* ---- HTTP/2 over TLS (ALPN dispatch) ---- *)

val default_alpn_protocols : string list
(** The default ALPN protocols advertised by {!listen_and_serve_tls}, in
    descending order of preference: [["h2"; "http/1.1"]] (Go's
    [http2.NextProtoTLS] + ["http/1.1"]). *)

val listen_and_serve_tls :
  certificates:Tls.Config.certchain ->
  ?alpn:string list ->
  addr:string ->
  port:int ->
  handler ->
  unit Lwt.t
(** Go's [ListenAndServeTLS]: bind [addr]:[port] with server-side TLS carrying
    [certificates] and advertising the ALPN protocols [alpn] (default
    {!default_alpn_protocols}), then serve [handler] over each accepted
    connection — dispatching to the HTTP/2 server connection
    ({!H2_server.serve}) when the negotiated ALPN protocol is ["h2"], and to the
    existing HTTP/1.x serve loop otherwise (incl. when no ALPN protocol was
    agreed). The same {!handler} serves both protocols (the h2 path adapts it
    via the {!H2_server} response_writer). *)

val listen_and_serve_tls_started :
  certificates:Tls.Config.certchain ->
  ?alpn:string list ->
  addr:string ->
  port:int ->
  handler ->
  (t * int * unit Lwt.t) Lwt.t
(** Like {!listen_and_serve_tls} but binds first and returns the running
    [Server.t], the bound port (useful with an ephemeral [port = 0]) and the
    serve loop promise — so tests can connect over TLS and {!close}. *)
