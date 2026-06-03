(* Port of the HTTP/1.x subset of go/src/net/http/transport.go: the Transport
   and its idle-connection pool. There is no first-class [RoundTripper]
   interface type here -- the project uses {!round_trip} directly as the
   round-tripper -- but {!t} is the [Transport] and {!round_trip} is
   [Transport.RoundTrip]. *)

(** The default User-Agent advertised by {!round_trip} when the request carries
    none. Go uses ["Go-http-client/1.1"] ([request.go]'s [defaultUserAgent]);
    this port advertises ["gohttp-client/1.1"] so the wire string is not
    mistaken for the Go runtime's. *)
val default_user_agent : string

(** A [Transport]: an idle-connection pool keyed by scheme/host/port (Go's
    [idleConn map[connectMethodKey][]*persistConn], modeled as a [Hashtbl] from
    a ["scheme|host:port"] cache key to a list of idle connections) plus a
    keep-alive toggle. *)
type t

(** Go's [&Transport{}]: a fresh transport with an empty pool and keep-alives
    enabled. *)
val create : unit -> t

(** [round_trip t req] is Go's [Transport.RoundTrip] (HTTP/1.x path): pick
    scheme/host/port from [req.url] (TLS when the scheme is ["https"]), reuse an
    idle pooled connection or dial a fresh one via {!Net.connect}, send the
    request with {!Io.write_request} and read the response with
    {!Io.read_response}. Sets the default Host and User-Agent headers when the
    request lacks them. On a keep-alive-eligible response (keep-alives enabled,
    neither request nor response asked to close) the connection is returned to
    the pool; otherwise it is closed. A failure on a recycled idle connection
    triggers one fresh-dial retry.

    The optional [?context] (Go's per-request [context.Context]) is an
    ergonomics layer: when supplied it is applied to [req] before the round
    trip, so the deadline/cancellation race uses it; when omitted the request's
    existing context is used (defaulting to {!Context.background}). *)
val round_trip :
  ?context:Context.t -> t -> Body.t Request.t -> Body.t Response.t Lwt.t

(** The cache key for a scheme/host/port (Go's [connectMethodKey.String]:
    ["scheme|host:port"]). Exposed for tests/inspection. *)
val conn_key : scheme:string -> host:string -> port:int -> string

(** Total number of connections this transport has dialed. Go has no exact
    analogue; exposed so the keep-alive-reuse test can assert that a second
    request did not open a second connection. *)
val dial_count : t -> int

(** Number of idle connections currently pooled under [key]. *)
val idle_count : t -> string -> int

(** The process-wide default transport (Go's [DefaultTransport]). *)
val default_transport : t
