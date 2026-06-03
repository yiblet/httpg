(* Lwt socket + TLS substrate. This module has no direct 1:1 Go source
   counterpart: Go's [net/http] builds on the stdlib [net] package and
   [crypto/tls]. It provides only what the server (server.go) and client
   (transport.go) tickets need from those packages -- TCP listen/accept,
   client connect (with optional TLS), and [Lwt_io] channel wrapping (the
   [bufio] analogue used by [Io]). *)

(** [listen ?backlog host port] resolves [host]/[port], creates a TCP socket
    with [SO_REUSEADDR], binds, and listens. [host] is used as given (e.g.
    ["0.0.0.0"] or ["127.0.0.1"]). Binding [port = 0] selects an ephemeral
    port; recover it with {!local_addr}/{!bound_port}. [backlog] defaults to
    128 (Go's [net.Listen] default). *)
val listen : ?backlog:int -> string -> int -> Lwt_unix.file_descr Lwt.t

(** [accept fd] accepts one connection on listening socket [fd], returning the
    connected socket and the peer address. *)
val accept : Lwt_unix.file_descr -> (Lwt_unix.file_descr * Unix.sockaddr) Lwt.t

(** [channels_of_fd fd] wraps [fd] in buffered [Lwt_io] input/output channels
    (the [bufio.Reader]/[bufio.Writer] analogue used by [Io]). *)
val channels_of_fd :
  Lwt_unix.file_descr -> Lwt_io.input_channel * Lwt_io.output_channel

(** [connect ~host ~port ?tls ()] resolves [host]/[port], connects a client
    TCP socket, and returns buffered [Lwt_io] channels. When [tls] is [true]
    (default [false]) the connection is upgraded with [tls-lwt].

    {b TLS verification:} the TLS client uses a {e null authenticator} that
    accepts any server certificate without verification (see {!null_authenticator}).
    This is acceptable for the smoke-test substrate only; a production client
    must supply a real authenticator (e.g. [X509] system trust). *)
val connect :
  host:string ->
  port:int ->
  ?tls:bool ->
  unit ->
  (Lwt_io.input_channel * Lwt_io.output_channel) Lwt.t

(** [local_addr fd] is the socket's locally bound address. *)
val local_addr : Lwt_unix.file_descr -> Unix.sockaddr

(** [bound_port fd] is the locally bound TCP port (handy for ephemeral
    [listen]ers bound on port 0). Raises [Failure] if [fd] is not an
    [ADDR_INET] socket. *)
val bound_port : Lwt_unix.file_descr -> int

(** [sockaddr_to_string sa] renders [sa] as Go's [host:port] form (used for
    [Request.remote_addr]). IPv6 hosts are bracketed: [\[::1\]:port]. *)
val sockaddr_to_string : Unix.sockaddr -> string

(** [with_timeout secs t] is [t] but fails with [Lwt_unix.Timeout] if it has
    not completed within [secs] seconds (wraps {!Lwt_unix.with_timeout}). *)
val with_timeout : float -> 'a Lwt.t -> 'a Lwt.t

(** A null [X509] authenticator that accepts any peer certificate without
    verification. Documented and exposed so callers (and tests) can see the
    deliberate no-verification policy of the TLS client. *)
val null_authenticator : X509.Authenticator.t
