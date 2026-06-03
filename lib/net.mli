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

(** [connect ~host ~port ?tls ?authenticator ?insecure ()] resolves
    [host]/[port], connects a client TCP socket, and returns buffered [Lwt_io]
    channels. When [tls] is [true] (default [false]) the connection is upgraded
    with [tls-lwt].

    {b TLS verification (secure by default).} The TLS client verifies the server
    certificate chain against the operating-system trust store and matches the
    [host] name (SNI is also derived from [host]), mirroring Go's [http.Client],
    which verifies unless [InsecureSkipVerify] is set. Override with:
    - [?authenticator] — use this [X509.Authenticator.t] (highest precedence);
    - [?insecure:true] — use {!null_authenticator} (no verification at all), the
      analogue of Go's [InsecureSkipVerify = true].
    When neither is given the secure {!default_authenticator} is used. Note that
    verifying against an IP literal [host] (no valid hostname) legitimately
    fails name matching; such callers must opt out via [?insecure]. *)
val connect :
  host:string ->
  port:int ->
  ?tls:bool ->
  ?authenticator:X509.Authenticator.t ->
  ?insecure:bool ->
  unit ->
  (Lwt_io.input_channel * Lwt_io.output_channel) Lwt.t

(** [connect_alpn ~host ~port ?tls ?alpn ?authenticator ?insecure ()] is like
    {!connect} but additionally advertises the ALPN protocols [alpn] (in
    descending order of preference, e.g. [["h2"; "http/1.1"]]) when [tls] is
    [true], and returns the negotiated protocol as the third element (the
    analogue of Go's [tls.ConnectionState.NegotiatedProtocol]). For a non-TLS
    connection, or when no ALPN protocol was agreed, the negotiated protocol is
    [None]. The [?authenticator]/[?insecure] verification policy is identical to
    {!connect}: secure (system-trust) by default. *)
val connect_alpn :
  host:string ->
  port:int ->
  ?tls:bool ->
  ?alpn:string list ->
  ?authenticator:X509.Authenticator.t ->
  ?insecure:bool ->
  unit ->
  (Lwt_io.input_channel * Lwt_io.output_channel * string option) Lwt.t

(** {1 Server-side TLS + ALPN} *)

(** [ensure_rng ()] seeds the [mirage-crypto] RNG (idempotently). It MUST run
    before any TLS handshake or X509 key generation. The TLS entry points below
    and {!connect_alpn} call it themselves; it is exposed for callers that mint
    keys directly. Go's [crypto/rand] needs no analogue; this is OCaml-stack
    bookkeeping. *)
val ensure_rng : unit -> unit

(** [test_server_certificate ()] mints a fresh self-signed RSA-2048 certificate
    + key at runtime (no files on disk), CN=localhost with SubjectAltName
    DNS=localhost, valid for ~ten years — the OCaml-stack analogue of Go's
    [net/http/internal/testcert]. Intended for tests/loopback servers; since the
    matching client uses {!null_authenticator}, the cert only satisfies the
    handshake's server-certificate step (no real trust). *)
val test_server_certificate : unit -> Tls.Config.certchain

(** A listening TLS server: a bound/listening socket plus the negotiated TLS
    [server] configuration (certificate + advertised ALPN protocols). *)
type tls_server

(** [listen_tls ?backlog ~certificates ~alpn host port] is {!listen} plus a
    server-side TLS configuration carrying [certificates] (a single cert chain +
    key) and advertising the ALPN protocols [alpn] in descending order of
    preference (e.g. [["h2"; "http/1.1"]]; [[]] disables ALPN). During the
    handshake the server selects the first advertised protocol the client also
    offers (per the [tls] library's selection rule). *)
val listen_tls :
  ?backlog:int ->
  certificates:Tls.Config.certchain ->
  alpn:string list ->
  string ->
  int ->
  tls_server Lwt.t

(** [tls_listen_fd s] is the underlying listening socket of [s] (handy for
    {!bound_port} on an ephemeral [listen_tls ... 0] server). *)
val tls_listen_fd : tls_server -> Lwt_unix.file_descr

(** [accept_tls s] accepts one connection on [s], performs the server-side TLS
    handshake, and returns buffered [Lwt_io] channels over the TLS session, the
    negotiated ALPN protocol ([None] if none was agreed), and the peer address. *)
val accept_tls :
  tls_server ->
  (Lwt_io.input_channel * Lwt_io.output_channel * string option * Unix.sockaddr)
  Lwt.t

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
    verification. Exposed as the explicit, documented {e insecure} opt-out (the
    analogue of Go's [tls.Config.InsecureSkipVerify = true]); selected by
    [connect ?insecure:true]. NOT used by default. *)
val null_authenticator : X509.Authenticator.t

(** [default_authenticator ()] builds the SECURE default [X509] authenticator
    from the operating-system trust store via [ca-certs] (it also checks expiry
    and, at handshake time with a [host], the certificate name). This is what
    {!connect}/{!connect_alpn} use unless overridden, mirroring Go's
    [http.Client] verifying against the system roots. Raises [Failure] if the
    trust store cannot be loaded. *)
val default_authenticator : unit -> X509.Authenticator.t
