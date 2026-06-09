(* Port of the HTTP/1.x subset of go/src/net/http/transport.go: the Transport
   and its idle-connection pool. There is no first-class [RoundTripper]
   interface type -- {!round_trip} is used directly as the round-tripper, and
   {!t} is the [Transport]. *)

val default_user_agent : string
(** The default User-Agent advertised by {!round_trip} when the request carries
    none. Go uses ["Go-http-client/1.1"]; this port advertises
    ["httpg-client/1.1"] so the wire string is not mistaken for Go's. *)

type t
(** A [Transport]: an idle-connection pool keyed by scheme/host/port (Go's
    [idleConn map[connectMethodKey][]*persistConn], a [Hashtbl] from a
    ["scheme|host:port"] cache key to a list of idle connections), plus a
    keep-alive toggle. Each pooled connection runs as its own fiber (Go's
    [persistConn]).

    {b Multi-domain contract.} Like Go's [http.Transport] used from many
    goroutines across OS threads, one [t] may be driven concurrently from N Eio
    domains. The pool is {b per-domain}: each domain that drives [t] keeps its
    own idle/h2 connections and owning switch (established by {!run}). A
    connection is only ever dialed, reused, and torn down on its owning domain,
    so its [Buf_read]/[Buf_write] never crosses a domain boundary — connections
    are not shared across domains (a domain dials its own). Each domain must
    therefore establish its own [run ~sw] scope before issuing round trips
    (typically inside [Eio.Domain_manager.run]). The domain→pool registry is the
    only cross-domain structure and is guarded by a [Stdlib.Mutex]; each
    per-domain pool is guarded by its own [Eio.Mutex] touched only by its owning
    domain's fibers.

    {b Why per-domain, not one shared pool (F038).} Go's [http.Transport] keeps
    a single process-wide pool: its netpoller hands a connection to whichever
    goroutine needs it, so N OS threads driving one authority can share fewer
    than N connections. We deliberately do NOT replicate that. A connection's
    Eio [Buf_read]/[Buf_write] (and, for h2, the [client_conn]'s condition-var
    waiters and stream-slot reservation) are domain-local and must never be
    touched from another domain — that is exactly the invariant F031 relies on.
    Sharing a connection across domains would therefore require a dispatch
    layer: route each round trip to the connection's {e owning} domain via a
    cross-domain [Eio.Stream], run it there, and
    {e proxy the streaming response body back} chunk-by-chunk over another
    bounded [Eio.Stream] (the body thunk pulls from the owning domain's bufio,
    so an off-domain consumer cannot call it directly), with cross-domain
    error/cancellation propagation and remote-EOF reuse gating. That machinery
    is heavy, concentrated on the most safety-critical code, and only pays off
    when one authority is hammered from many domains at once. The simplicity
    north star and F031's safety both favour the per-domain pool; the cost is
    that driving one authority from N domains may open up to N connections
    instead of sharing a smaller set. Full cross-domain sharing is tracked as a
    follow-up. *)

val create :
  net:_ Eio.Net.t ->
  ?clock:_ Eio.Time.clock ->
  ?insecure:bool ->
  ?authenticator:X509.Authenticator.t ->
  ?max_response_header_bytes:int ->
  unit ->
  t
(** [create ~net ?clock ?insecure ?authenticator ?max_response_header_bytes ()]
    is Go's [&Transport{}]: a fresh transport with an empty pool and keep-alives
    enabled. The [net] capability (and optional [clock] for timeouts) is
    captured here, so {!round_trip} and the client verbs don't re-thread them.

    The TLS verification policy for https dials is secure by default — the
    server certificate is verified against the system trust store and its name
    matched. [?authenticator] supplies an explicit one (highest precedence);
    [?insecure:true] disables verification (Go's [InsecureSkipVerify], for
    self-signed/loopback test servers). See {!Net.connect_alpn}.

    [?max_response_header_bytes] bounds the response status line + header block
    (Go's [Transport.MaxResponseHeaderBytes]); defaults to [10 lsl 20]. On
    overflow the round trip fails with a modeled error
    ({!Io.Response_header_too_large}). The body is separately bounded by
    streaming {!Transfer}. *)

val run : t -> sw:Eio.Switch.t -> (unit -> 'a) -> 'a
(** [run t ~sw fn] establishes the {b current domain's} pool with owning switch
    [sw] for the dynamic extent of [fn], then runs [fn ()].
    {b This is the transport's ownership model} (Go's [Transport] connection
    pool, replicated per OS thread driving it):

    - On the calling domain, all pooled connection fibers fork under [sw],
      {b not} under whichever per-request switch happened to call {!round_trip}.
      A pooled connection therefore survives across independent caller switches
      and a {!round_trip} wrapped in a transient [Eio.Switch.run] returns
      cleanly once its body is drained (no deadlock).
    - When [fn] returns, [sw] finishes and this domain's pool is torn down (idle
      connections closed, its registry entry removed).
    - Reentrant {b per domain}: if the current domain already has a pool (an
      outer [run], or a nested call on the same domain), [fn] runs under the
      existing pool and [sw] is ignored — so wrapping is idempotent and [run]s
      may nest.
    - {b Multi-domain:} N domains may each call [run] with their own switch
      (typically inside [Eio.Domain_manager.run]) and drive the same [t]
      concurrently; each gets an independent per-domain pool. A [Switch.t]
      belongs to the domain that created it, so a per-domain switch is
      mandatory, not optional.

    {!round_trip} (and {!Client.do_}, which calls [run] for you with the client
    session's switch) requires the current domain to have an established pool;
    calling {!round_trip} on a domain with no [run] raises [Invalid_argument].

    {b Top-level transport:} a freshly {!create}d transport has no switch until
    first used under a [run]. Establish it once at the top level — e.g. wrap the
    application body in [Transport.run t ~sw] (or use {!Client.do_}, which
    scopes it to the client's [sw]) — so its pool lives for that scope rather
    than dying with a transient per-request switch. *)

val clock : t -> float Eio.Time.clock_ty Eio.Resource.t option
(** The clock captured at {!create} (for {!Client} timeout composition). *)

val round_trip : ?force_h2:bool -> t -> Request.t -> Response.t
(** [round_trip t req] is Go's [Transport.RoundTrip] (HTTP/1.x path): pick
    scheme/host/port from [req.url] (TLS when the scheme is ["https"]), reuse an
    idle pooled connection or dial a fresh one via {!Net.connect_alpn} (using
    the captured [net]), send the request with {!Io.write_request} and read the
    response head with {!Io.read_response}. Sets the default Host and User-Agent
    when the request lacks them. Concurrent round trips on one transport are
    safe — both within a domain (the per-domain pool is mutex-guarded) and
    across domains (each domain has its own pool; see {!t} and {!run}). Pooled
    connection fibers run under the current domain's switch (see {!run}), so
    this may be called under a transient per-request [Eio.Switch.run]; it raises
    [Invalid_argument] if the current domain has no {!run} scope.

    {b Modeled, catchable failures.} A request whose URL has no Host raises
    {!Io.Protocol_error} ["http: no Host in request URL"] (Go's [errMissingHost],
    transport.go; the typed request-validation carrier shared with malformed
    request/header lines). A dial failure surfaces as {!Net.Dial_error} (e.g. an
    unresolvable host) and a TLS handshake/verification failure as
    {!Net.Tls_error} — both delivered to the caller rather than escaping as a
    bare [Failure].

    {b The response body streams and gates connection reuse.} The returned
    [resp.body] is a {!Body.Stream} pulling bytes lazily from the connection; it
    is not pre-buffered. Reusability (keep-alives enabled, neither request nor
    response asked to close) is decided up front; the connection returns to the
    idle pool {b only after the caller consumes the body to EOF}
    ({!Body.read_all} or {!Body.drain} — the analogue of [resp.Body.Close]). A
    caller that never drains forgoes reuse; a non-reusable or failed connection
    is closed. A failure on a recycled idle connection triggers one fresh-dial
    retry.

    Per-request deadlines/cancellation are expressed by the caller (e.g. a
    surrounding [Eio.Time.with_timeout] or transient switch) — Go's [?context]
    is dropped in this port.

    {b HTTP/2:} for an ["https"] request (or when [?force_h2] is set) the dial
    advertises ALPN [["h2"; "http/1.1"]]; if the peer negotiates ["h2"] the
    request is multiplexed over a pooled {!Httpg_http2.H2_transport.client_conn}
    keyed by authority ([host:port]) and [resp] carries proto ["HTTP/2.0"].
    Plaintext ["http"] always uses HTTP/1.x. *)

val conn_key : scheme:string -> host:string -> port:int -> string
(** The cache key for a scheme/host/port (Go's [connectMethodKey.String]:
    ["scheme|host:port"]). Exposed for tests/inspection. *)

val dial_count : t -> int
(** Total connections this transport has dialed, {b summed across all domains}.
    Exposed so the keep-alive test can assert a second request did not open a
    second connection. *)

val idle_count : t -> string -> int
(** Number of idle connections currently pooled under [key]
    {b on the calling domain} (idle conns are domain-local; a domain with no
    {!run} scope reports [0]). *)

val h2_round_trip_count : t -> int
(** Total requests served over HTTP/2, {b summed across all domains}. Exposed
    for the ALPN end-to-end test. *)

val set_before_h2_round_trip : t -> (unit -> unit) -> unit
(** Test-only (F027): install a callback fired on the pooled-h2 fast path just
    before a pooled conn is reused, to deterministically force the
    closed/closing race that surfaces as
    {!Httpg_http2.H2_transport.Conn_unusable} and triggers the
    evict-and-retry-on-a-fresh-dial path. *)

val close_pooled_h2_conn : t -> host:string -> port:int -> unit
(** Test-only (F027): close the pooled HTTP/2 connection(s) for [host:port] in
    place (leaving them in the pool), so the next reuse races into
    Conn_unusable. No-op if none is pooled. *)

val h2_conn_count : t -> host:string -> port:int -> int
(** Test-only (F035): number of HTTP/2 connections currently pooled for
    [host:port] {b on the calling domain}. Exposed so the saturation test can
    assert the pool scaled out to a second conn (Go's
    [clientConnPool.conns[addr]]). *)
