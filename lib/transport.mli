(* Port of the HTTP/1.x subset of go/src/net/http/transport.go: the Transport
   and its idle-connection pool. There is no first-class [RoundTripper]
   interface type here -- the project uses {!round_trip} directly as the
   round-tripper -- but {!t} is the [Transport] and {!round_trip} is
   [Transport.RoundTrip]. *)

val default_user_agent : string
(** The default User-Agent advertised by {!round_trip} when the request carries
    none. Go uses ["Go-http-client/1.1"] ([request.go]'s [defaultUserAgent]);
    this port advertises ["httpg-client/1.1"] so the wire string is not
    mistaken for the Go runtime's. *)

type t
(** A [Transport]: an idle-connection pool keyed by scheme/host/port (Go's
    [idleConn map[connectMethodKey][]*persistConn], modeled as a [Hashtbl] from
    a ["scheme|host:port"] cache key to a list of idle connections) plus a
    keep-alive toggle. *)

val create :
  ?insecure:bool ->
  ?authenticator:X509.Authenticator.t ->
  ?max_response_header_bytes:int ->
  unit ->
  t
(** [create ?insecure ?authenticator ?max_response_header_bytes ()] is Go's
    [&Transport{}]: a fresh transport with an empty pool and keep-alives
    enabled.

    The TLS verification policy for https dials (reduced from Go's
    [Transport.TLSClientConfig]) is secure by default — the server certificate
    is verified against the system trust store and its name matched. Override:
    [?authenticator] supplies an explicit [X509.Authenticator.t] (highest
    precedence); [?insecure:true] disables verification entirely (Go's
    [InsecureSkipVerify], suitable only for self-signed/loopback test servers).
    See {!Net.connect_alpn}.

    [?max_response_header_bytes] bounds the response status line + header block
    the client reads, so a hostile/buggy server cannot OOM the client before any
    handler runs (Go's [Transport.MaxResponseHeaderBytes],
    transport.go:275-280). Defaults to [10 lsl 20] (Go's
    [DefaultMaxResponseHeaderBytes], transport.go:337-340). On overflow the
    round trip fails with a modeled error derived from
    {!Io.Response_header_too_large}. The response body is separately bounded by
    streaming {!Transfer}, so this covers the head only. *)

val round_trip :
  ?context:Context.t ->
  ?force_h2:bool ->
  t ->
  Body.t Request.t ->
  Body.t Response.t Lwt.t
(** [round_trip t req] is Go's [Transport.RoundTrip] (HTTP/1.x path): pick
    scheme/host/port from [req.url] (TLS when the scheme is ["https"]), reuse an
    idle pooled connection or dial a fresh one via {!Net.connect}, send the
    request with {!Io.write_request} and read the response with
    {!Io.read_response}. Sets the default Host and User-Agent headers when the
    request lacks them.

    {b The response body streams and gates connection reuse.} The returned
    [resp.body] is a {!Body.Stream} pulling bytes lazily from the connection; it
    is not pre-buffered. Reusability (keep-alives enabled, neither request nor
    response asked to close) is decided up front, and a one-shot release action
    is wrapped onto the body's EOF (Go's [bodyEOFSignal] over
    [waitForBodyRead]): the connection is returned to the idle pool
    {b only after the caller consumes the body to EOF} ({!Body.read_all} or
    {!Body.drain} — the analogue of [resp.Body.Close]); if it is not reusable,
    or if the read fails, the connection is closed instead. A caller that never
    drains the body simply forgoes reuse. A failure on a recycled idle
    connection triggers one fresh-dial retry.

    {b Cancellation covers the body read.} Each body chunk read races [req]'s
    context ([?context], or a client timeout composed onto it): if the context
    fires mid-stream the read aborts with the context cause and the connection
    is closed (never pooled) — Go aborting an in-flight body read on
    [<-ctx.Done()].

    {b HTTP/2:} for an ["https"] request (or when [?force_h2] is set) the dial
    advertises ALPN [["h2"; "http/1.1"]] via {!Net.connect_alpn}; if the peer
    negotiates ["h2"] the request is multiplexed over a pooled
    [H2_transport.client_conn] (keyed by authority, parallel to the HTTP/1.x
    idle pool), otherwise the HTTP/1.x path runs over the dialed channels.
    Plaintext ["http"] always uses HTTP/1.x. [?force_h2] (default [false])
    advertises only ["h2"] — an escape hatch for tests.

    The optional [?context] (Go's per-request [context.Context]) is an
    ergonomics layer: when supplied it is applied to [req] before the round
    trip, so the deadline/cancellation race uses it; when omitted the request's
    existing context is used (defaulting to {!Context.background}). *)

val conn_key : scheme:string -> host:string -> port:int -> string
(** The cache key for a scheme/host/port (Go's [connectMethodKey.String]:
    ["scheme|host:port"]). Exposed for tests/inspection. *)

val dial_count : t -> int
(** Total number of connections this transport has dialed. Go has no exact
    analogue; exposed so the keep-alive-reuse test can assert that a second
    request did not open a second connection. *)

val idle_count : t -> string -> int
(** Number of idle connections currently pooled under [key]. *)

val h2_round_trip_count : t -> int
(** Total number of requests this transport has served over HTTP/2. Go has no
    exact analogue; exposed so the ALPN end-to-end test can assert that the [h2]
    path was actually taken. *)

val default_transport : t
(** The process-wide default transport (Go's [DefaultTransport]). *)
