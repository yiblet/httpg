(* Eio socket + TLS substrate. No 1:1 Go source counterpart: Go's net/http
   builds on the stdlib [net] package and [crypto/tls]. It provides only what the
   server (server.go) and client (transport.go) tickets need from those packages
   -- TCP listen/accept, client connect (optionally TLS), buffered
   [Eio.Buf_read]/[Eio.Buf_write] wrapping (the bufio analogue used by [Io]), and
   a hand-driven [Tls.Engine] so [Io] is oblivious to TLS.

   {b Connection wrapping is callback-scoped.} Buffered writes need a background
   flusher fiber and TLS owns an engine + session; both must be torn down on every
   path. So the connect/accept-TLS entry points run a caller-supplied
   [fn r w] with the channels live and close everything on return (mirroring
   [Eio.Net.with_tcp_connect] / [Buf_write.with_flow]). *)

type error =
  | Dial of string
  | Tls of string
      (** A handleable failure of the client connect entry points below,
          mirroring Go's [Dial]/[tls.Conn.Handshake] returning an [error].
          [Dial] is a resolve/connect failure (Go's [*net.DNSError]); [Tls] is a
          TLS handshake/verification failure (Go's [tls.Conn.Handshake]). The
          inner resolve/handshake helpers thread this [result] directly; the
          public entry points return it without any boundary catch. Each variant
          carries Go's message text. *)

val error_to_string : error -> string
(** [error_to_string e] is the message text carried by [e] ([Dial s]/[Tls s] ->
    [s]). *)

val ensure_rng : unit -> unit
(** [ensure_rng ()] seeds the [mirage-crypto] RNG (idempotently). It MUST run
    before any TLS handshake or X509 key generation. The TLS entry points below
    call it themselves; it is exposed for callers that mint keys directly. Go's
    [crypto/rand] needs no analogue; this is OCaml-stack bookkeeping. *)

(** {1 Plain TCP} *)

val listen :
  ?backlog:int ->
  sw:Eio.Switch.t ->
  [> ([> `Generic ] as 'tag) Eio.Net.ty ] Eio.Resource.t ->
  string ->
  int ->
  ('tag Eio.Net.listening_socket_ty Eio.Resource.t, error) result
(** [listen ?backlog ~sw net host port] resolves [host]/[port], binds a TCP
    socket with [SO_REUSEADDR] and listens. [host] is used as given (e.g.
    ["0.0.0.0"] or ["127.0.0.1"]); [port = 0] selects an ephemeral port,
    recoverable with {!bound_port}. [backlog] defaults to 128 (Go's [net.Listen]
    default). The socket is closed when [sw] finishes. The socket is always
    bound to a TCP address, so {!bound_port} on it is always [Some].

    Returns [Error (Dial _)] if [host]/[port] cannot be resolved or bound (e.g.
    the port is already in use). *)

val accept :
  sw:Eio.Switch.t ->
  [> ([> `Generic ] as 'tag) Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  'tag Eio.Net.stream_socket_ty Eio.Resource.t * Eio.Net.Sockaddr.stream
(** [accept ~sw listen_sock] accepts one connection, returning the connected
    socket (closed when [sw] finishes) and the peer address. Does not block on
    any TLS handshake -- the server forks a per-connection fiber, then calls
    {!accept_tls} / {!with_connection} inside it. *)

val accept_fork :
  sw:Eio.Switch.t ->
  on_error:(exn -> unit) ->
  [> ([> `Generic ] as 'tag) Eio.Net.listening_socket_ty ] Eio.Resource.t ->
  [< 'tag Eio.Net.stream_socket_ty ] Eio.Net.connection_handler ->
  unit
(** [accept_fork ~sw ~on_error listen_sock fn] accepts one connection and runs
    [fn flow peer] in a fresh fiber attached to [sw]; the accepted socket is
    {b closed when [fn] returns} (Go's [go c.serve] + [defer c.close()]), so no
    fd outlives its connection. [on_error] handles a connection-handler
    exception without tearing down the accept loop (Go's per-conn recover). *)

val connect :
  sw:Eio.Switch.t ->
  [> ([> `Generic ] as 'tag) Eio.Net.ty ] Eio.Resource.t ->
  host:string ->
  port:int ->
  ('tag Eio.Net.stream_socket_ty Eio.Resource.t, error) result
(** [connect ~sw net ~host ~port] resolves and connects a client TCP socket
    (closed when [sw] finishes). Use {!with_connection} to obtain buffered
    channels, or {!connect_tls}/{!connect_alpn} which dial and wrap in one step.
    Returns [Error (Dial _)] if [host]/[port] cannot be resolved. *)

val with_connection :
  _ Eio.Net.stream_socket -> (Eio.Buf_read.t -> Eio.Buf_write.t -> 'a) -> 'a
(** [with_connection flow fn] wraps a plaintext stream socket in buffered
    [Eio.Buf_read]/[Eio.Buf_write] channels (the bufio analogue used by [Io])
    and runs [fn r w] with the writer's flusher fiber live, flushing/closing on
    return. *)

(** {1 Client TLS} *)

val connect_tls :
  sw:Eio.Switch.t ->
  [> [> `Generic ] Eio.Net.ty ] Eio.Resource.t ->
  host:string ->
  port:int ->
  ?tls:bool ->
  ?authenticator:X509.Authenticator.t ->
  ?insecure:bool ->
  (Eio.Buf_read.t -> Eio.Buf_write.t -> 'a) ->
  ('a, error) result
(** [connect_tls ~sw net ~host ~port ?tls ?authenticator ?insecure fn] dials
    [host]/[port] and runs [fn r w] with buffered channels. When [tls] is [true]
    (default [false]) the connection is upgraded by hand-driving [Tls.Engine].

    {b TLS verification (secure by default).} The client verifies the server
    certificate chain against the OS trust store and matches [host] (SNI is
    derived from [host]), mirroring Go's [http.Client]. Override with:
    - [?authenticator] -- use this [X509.Authenticator.t] (highest precedence);
    - [?insecure:true] -- {!null_authenticator} (no verification), the analogue
      of Go's [InsecureSkipVerify = true]. With neither,
      {!default_authenticator} is used. Verifying against an IP literal [host]
      legitimately fails name matching; such callers opt out via [?insecure].

    Returns [Error (Dial _)] if [host]/[port] cannot be resolved,
    [Error (Tls _)] on a TLS handshake/verification failure, and raises
    [Failure] only for a setup bug (an invalid TLS config, or the OS trust store
    failing to load). *)

val connect_alpn :
  sw:Eio.Switch.t ->
  [> [> `Generic ] Eio.Net.ty ] Eio.Resource.t ->
  host:string ->
  port:int ->
  ?tls:bool ->
  ?alpn:string list ->
  ?authenticator:X509.Authenticator.t ->
  ?insecure:bool ->
  (proto:string option -> Eio.Buf_read.t -> Eio.Buf_write.t -> 'a) ->
  ('a, error) result
(** [connect_alpn] is like {!connect_tls} but additionally advertises the ALPN
    protocols [alpn] (descending preference, e.g. [["h2"; "http/1.1"]]) when
    [tls] is [true], and passes the negotiated protocol as [~proto] to [fn]
    (Go's [tls.ConnectionState.NegotiatedProtocol]). [proto] is [None] for a
    plain connection or when no ALPN protocol was agreed. Verification policy is
    identical to {!connect_tls}. *)

(** {1 Server-side TLS + ALPN} *)

val test_server_certificate : unit -> Tls.Config.certchain
(** [test_server_certificate ()] mints a fresh self-signed RSA-2048 certificate
    \+ key at runtime (no files on disk), CN=localhost with SubjectAltName
    DNS=localhost, valid for a fixed wide window (epoch..~2070) that contains
    "now" -- the OCaml-stack analogue of Go's [net/http/internal/testcert]. For
    tests/loopback servers; since the matching client uses
    {!null_authenticator}, the cert only satisfies the handshake's
    server-certificate step (no real trust). Raises [Failure] if key/CSR
    generation or self-signing fails (a setup bug, not a peer condition). *)

type 'tag tls_server
(** A listening TLS server: a bound/listening socket plus the negotiated TLS
    [server] configuration (certificate + advertised ALPN protocols). *)

val listen_tls :
  ?backlog:int ->
  sw:Eio.Switch.t ->
  certificates:Tls.Config.certchain ->
  alpn:string list ->
  [> ([> `Generic ] as 'tag) Eio.Net.ty ] Eio.Resource.t ->
  string ->
  int ->
  ('tag tls_server, error) result
(** [listen_tls ?backlog ~sw ~certificates ~alpn net host port] is {!listen}
    plus a server-side TLS configuration carrying [certificates] (one cert chain
    \+ key) and advertising the ALPN protocols [alpn] in descending preference
    (e.g. [["h2"; "http/1.1"]]; [[]] disables ALPN). During the handshake the
    server selects the first advertised protocol the client also offers. Returns
    [Error (Tls _)] if the caller-supplied certificate/ALPN combination yields
    an invalid TLS server config. *)

val tls_listen_sock :
  'tag tls_server -> 'tag Eio.Net.listening_socket_ty Eio.Resource.t
(** [tls_listen_sock s] is the underlying listening socket of [s] (handy for
    {!bound_port} on an ephemeral [listen_tls ... 0] server, and for the server
    accept loop, which {!accept}s plain then handshakes via {!accept_tls}). *)

val accept_tls :
  _ tls_server ->
  _ Eio.Net.stream_socket ->
  (proto:string option -> Eio.Buf_read.t -> Eio.Buf_write.t -> 'a) ->
  'a
(** [accept_tls s flow fn] performs the server-side TLS handshake on the
    already-accepted connection [flow] and runs [fn ~proto r w] with buffered
    channels over the TLS session, [proto] being the negotiated ALPN protocol
    ([None] if none agreed). The connection is flushed and a [close_notify] is
    sent on return. [flow] is accepted by the caller's per-connection fiber, so
    a slow handshake never stalls the accept loop.

    This is a [result]-free per-connection contract: a server-side handshake
    failure raises an exception internal to [Net] (it never crosses the public
    surface as a typed value). The per-connection fiber is forked with an
    [on_error] (see {!accept_fork}) that swallows it, so one failed handshake
    never tears down the accept loop — there is no buffered channel to respond
    over, so the failure is simply dropped, as in Go. *)

(** {1 Address helpers} *)

val bound_port : _ Eio.Net.listening_socket -> int option
(** [bound_port sock] is [Some] the locally bound TCP port of a listening socket
    (handy for ephemeral [listen]ers bound on port 0), or [None] if [sock] is
    not bound to a TCP address (e.g. a Unix-domain socket). Total: it never
    raises. *)

val sockaddr_to_string : Eio.Net.Sockaddr.stream -> string
(** [sockaddr_to_string sa] renders [sa] as Go's [host:port] form (used for
    [Request.remote_addr]). IPv6 hosts are bracketed: [[::1]:port]. *)

(** {1 Timeout} *)

val with_timeout :
  _ Eio.Time.clock -> float -> (unit -> 'a) -> ('a, [> `Timeout ]) result
(** [with_timeout clock secs fn] runs [fn ()] and returns [Ok] its result, or
    [Error `Timeout] if it has not completed within [secs] seconds (wraps
    [Eio.Time.with_timeout]). *)

(** {1 TLS verification authenticators} *)

val null_authenticator : X509.Authenticator.t
(** A null [X509] authenticator that accepts any peer certificate without
    verification: the explicit, documented {e insecure} opt-out (Go's
    [tls.Config.InsecureSkipVerify = true]), selected by [?insecure:true]. NOT
    used by default. *)

val default_authenticator : unit -> (X509.Authenticator.t, error) result
(** [default_authenticator ()] builds the SECURE default [X509] authenticator
    from the OS trust store via [ca-certs] (it also checks expiry and, at
    handshake time with a [host], the certificate name). This is what the TLS
    client entry points use unless overridden, mirroring Go's [http.Client]
    verifying against the system roots. Returns [Error (Tls _)] if the system
    trust store cannot be loaded. *)
