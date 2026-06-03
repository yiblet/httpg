(* Port of the HTTP/1.x subset of go/src/net/http/server.go: Handler /
   HandlerFunc, ResponseWriter, the per-connection serve loop, Server /
   ListenAndServe, ServeMux dispatch, and the NotFound / Error / Redirect /
   RedirectHandler helpers. HTTP/2, hijacking, TLS-NPN and graceful-shutdown
   niceties are out of scope. *)

(** Go's [ResponseWriter] interface, modeled as a record of operations.
    - [header ()] returns the mutable header map the handler writes to before
      the response headers are flushed (Go's [ResponseWriter.Header]).
    - [write_header code] sets the status code (Go's [WriteHeader]); the first
      [write] implicitly calls [write_header 200].
    - [write data] appends body bytes (Go's [ResponseWriter.Write]). The body
      is buffered until the handler returns, so an exact Content-Length can be
      emitted. *)
type response_writer = {
  header : unit -> Header.t;
  write_header : int -> unit;
  write : string -> unit Lwt.t;
}

(** Go's [Handler] interface: [ServeHTTP(ResponseWriter, *Request)]. *)
type handler = { serve_http : response_writer -> Body.t Request.t -> unit Lwt.t }

(** Go's [HandlerFunc]: adapt a function to a {!handler}. *)
val handler_func :
  (response_writer -> Body.t Request.t -> unit Lwt.t) -> handler

(** Go's [Error]: reply with a plain-text error message and status [code],
    resetting Content-Type, deleting Content-Length and setting the nosniff
    option. *)
val error : response_writer -> string -> int -> unit Lwt.t

(** Go's [NotFound]: a 404 "404 page not found" reply. *)
val not_found : response_writer -> Body.t Request.t -> unit Lwt.t

(** Go's [NotFoundHandler]. *)
val not_found_handler : unit -> handler

(** Go's [Redirect]: reply with a redirect to [url] (which may be relative to
    the request path) using status [code]. *)
val redirect : response_writer -> Body.t Request.t -> string -> int -> unit Lwt.t

(** Go's [RedirectHandler]. *)
val redirect_handler : string -> int -> handler

(* ---- ServeMux ---- *)

(** Go's [ServeMux]: an HTTP request multiplexer backed by the routing tree. *)
type serve_mux

(** Go's [NewServeMux]. *)
val new_serve_mux : unit -> serve_mux

(** Raised by {!handle}/{!handle_func} on an invalid or conflicting pattern
    (Go's [register] panic). *)
exception Register_error of string

(** Go's [ServeMux.Handle]: register [handler] for [pattern]. Raises
    {!Register_error} on an invalid or conflicting pattern. *)
val handle : serve_mux -> string -> handler -> unit

(** Go's [ServeMux.HandleFunc]: register a handler function for [pattern]. *)
val handle_func :
  serve_mux ->
  string ->
  (response_writer -> Body.t Request.t -> unit Lwt.t) ->
  unit

(** Go's [ServeMux.ServeHTTP]: dispatch a request to the matching handler. *)
val serve_mux_serve_http :
  serve_mux -> response_writer -> Body.t Request.t -> unit Lwt.t

(** A {!serve_mux} viewed as a {!handler}. *)
val serve_mux_handler : serve_mux -> handler

(* ---- Server ---- *)

(** Go's [Server]. The zero-ish value carries an address, a handler and an
    internal stop signal used to shut the accept loop down (for tests). *)
type t

(** [create ?addr ?port handler] builds a server bound to [addr]:[port]. *)
val create : ?addr:string -> ?port:int -> handler -> t

(** Minimal [Server.Close]: stop accepting and close the listening socket. *)
val close : t -> unit Lwt.t

(** [serve srv fd] is Go's [Server.Serve]: accept connections on the listening
    socket [fd] and handle each in its own Lwt fiber until {!close} is called.
    Each connection runs the per-request keep-alive loop. *)
val serve : t -> Lwt_unix.file_descr -> unit Lwt.t

(** Go's [ListenAndServe]: bind [addr]:[port] and serve [handler] until the
    process or the listener is torn down. *)
val listen_and_serve :
  addr:string -> port:int -> handler -> unit Lwt.t

(** Like {!listen_and_serve} but binds first and returns the running
    [Server.t], the bound port (useful when [port = 0] selects an ephemeral
    port) and the serve loop promise — so tests can connect and {!close}. *)
val listen_and_serve_started :
  addr:string ->
  port:int ->
  handler ->
  (t * int * unit Lwt.t) Lwt.t
