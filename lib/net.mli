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

exception Tls_error of string
(** A TLS handshake / authentication / protocol failure (untrusted or expired
    certificate, protocol violation, connection closed mid-handshake), carrying
    the underlying [Tls.Engine.string_of_failure] text. Handleable: it mirrors
    Go's [tls.Conn.Handshake] returning an [error] propagated through [dialConn]
    -> [RoundTrip] (transport.go:1803-1819) rather than a panic, so a caller of
    the TLS client entry points / {!Transport.round_trip} can branch on it (e.g.
    an untrusted self-signed server without [?insecure]). Distinct from the bare
    [Failure] kept for genuine usage bugs (write-before-handshake, bad config).
*)

exception Dial_error of string
(** A dial failure -- DNS resolution turning up no address for the host (the
    common case), carrying the offending [host:port]. Handleable: it mirrors
    Go's [Dial] returning an [error] (a [*net.DNSError] "no such host" for the
    resolver case) that [Transport.dialConn] propagates through [RoundTrip],
    rather than a panic, so a caller of the client entry points below /
    {!Transport.round_trip} can branch on it (e.g. a request to a nonexistent
    host). Raised by {!connect}/{!connect_tls}/{!connect_alpn} (and {!listen})
    when the address cannot be resolved. Distinct from the bare [Failure] kept
    for genuine usage/config bugs. *)

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
  'tag Eio.Net.listening_socket_ty Eio.Resource.t
(** [listen ?backlog ~sw net host port] resolves [host]/[port], binds a TCP
    socket with [SO_REUSEADDR] and listens. [host] is used as given (e.g.
    ["0.0.0.0"] or ["127.0.0.1"]); [port = 0] selects an ephemeral port,
    recoverable with {!bound_port}. [backlog] defaults to 128 (Go's [net.Listen]
    default). The socket is closed when [sw] finishes. *)

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
  'tag Eio.Net.stream_socket_ty Eio.Resource.t
(** [connect ~sw net ~host ~port] resolves and connects a client TCP socket
    (closed when [sw] finishes). Use {!with_connection} to obtain buffered
    channels, or {!connect_tls}/{!connect_alpn} which dial and wrap in one step.
    Raises {!Dial_error} if [host]/[port] cannot be resolved. *)

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
  'a
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

    Raises {!Dial_error} if [host]/[port] cannot be resolved, {!Tls_error} on a
    TLS handshake/verification failure, and [Failure] only for a setup bug (an
    invalid TLS config, or the OS trust store failing to load). *)

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
  'a
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
  'tag tls_server
(** [listen_tls ?backlog ~sw ~certificates ~alpn net host port] is {!listen}
    plus a server-side TLS configuration carrying [certificates] (one cert chain
    \+ key) and advertising the ALPN protocols [alpn] in descending preference
    (e.g. [["h2"; "http/1.1"]]; [[]] disables ALPN). During the handshake the
    server selects the first advertised protocol the client also offers. Raises
    [Failure] if the resulting TLS server config is invalid (a setup bug). *)

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
    a slow handshake never stalls the accept loop. *)

(** {1 Address helpers} *)

val bound_port : _ Eio.Net.listening_socket -> int
(** [bound_port sock] is the locally bound TCP port of a listening socket (handy
    for ephemeral [listen]ers bound on port 0). Raises [Failure] if [sock] is
    not bound to a TCP address. *)

val sockaddr_to_string : Eio.Net.Sockaddr.stream -> string
(** [sockaddr_to_string sa] renders [sa] as Go's [host:port] form (used for
    [Request.remote_addr]). IPv6 hosts are bracketed: [[::1]:port]. *)

(** {1 Timeout} *)

val with_timeout : _ Eio.Time.clock -> float -> (unit -> 'a) -> 'a
(** [with_timeout clock secs fn] runs [fn ()] but raises [Eio.Time.Timeout] if
    it has not completed within [secs] seconds (wraps
    [Eio.Time.with_timeout_exn]). *)

(** {1 TLS verification authenticators} *)

val null_authenticator : X509.Authenticator.t
(** A null [X509] authenticator that accepts any peer certificate without
    verification: the explicit, documented {e insecure} opt-out (Go's
    [tls.Config.InsecureSkipVerify = true]), selected by [?insecure:true]. NOT
    used by default. *)

val default_authenticator : unit -> X509.Authenticator.t
(** [default_authenticator ()] builds the SECURE default [X509] authenticator
    from the OS trust store via [ca-certs] (it also checks expiry and, at
    handshake time with a [host], the certificate name). This is what the TLS
    client entry points use unless overridden, mirroring Go's [http.Client]
    verifying against the system roots. Raises [Failure] if the trust store
    cannot be loaded. *)
