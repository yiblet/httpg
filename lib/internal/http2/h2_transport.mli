(* Port of the client subset of go/src/net/http/internal/http2/transport.go and
   client_conn_pool.go: the HTTP/2 [ClientConn] (one multiplexed connection) and
   a minimal connection pool keyed by authority. Composes {!H2}, {!H2_error},
   {!H2_frame}, {!Hpack}, {!H2_flow}, {!H2_pipe}, {!H2_databuffer}, {!Header},
   {!Request}, {!Response}, {!Body}, {!Status}.

   To avoid a module cycle with the HTTP/1.x {!Transport}/{!Client} (which will
   call this module in a later ticket), [H2_transport] works only over given
   [Lwt_io] channels — it does not dial or depend on {!Transport}.

   Go's goroutine + channel concurrency is mapped onto Lwt fibers:
   - The [ClientConn.readLoop] goroutine becomes a single {e read-loop fiber}
     ({!new_client_conn} starts it) that reads frames, assembles
     HEADERS+CONTINUATION via {!H2_frame.read_meta_headers}, and dispatches each
     to per-stream waiters. It exclusively owns the connection's mutable state.
   - Go's [cc.cond] (broadcast on flow/closed changes) becomes an
     {!Lwt_condition}; a request body write blocked on flow control awaits it
     (mirroring [awaitFlowControl]).
   - Each per-stream [resc]/[respHeaderRecv]/[peerClosed]/[abort] channel becomes
     an {!Lwt_condition} (or a resolved promise) on the per-stream record.
   - Go's per-stream response [bufPipe] is the existing {!H2_pipe}, feeding the
     response {!Body.Stream}; DATA frames write into it.
   - Go's [wmu] write mutex becomes an {!Lwt_mutex} serializing all channel
     writes (HEADERS, DATA, WINDOW_UPDATE, PING ACK, RST_STREAM, …). *)

type client_conn
(** One HTTP/2 client connection, multiplexing concurrent streams. Mirrors Go's
    [ClientConn]. *)

val new_client_conn :
  Lwt_io.input_channel -> Lwt_io.output_channel -> client_conn Lwt.t
(** [new_client_conn ic oc] establishes a [ClientConn] over the duplex channel
    pair [(ic, oc)] (already past TLS/ALPN): it writes the client preface and an
    initial SETTINGS frame, reads (and ACKs) the server's SETTINGS, and starts
    the shared read-loop fiber. Resolves once the server's first SETTINGS frame
    has been seen (mirroring Go's [newClientConn] + waiting on
    [seenSettingsChan]). *)

val round_trip : client_conn -> Api.client_request -> Api.client_response Lwt.t
(** [round_trip cc req] performs one HTTP/2 request/response exchange on [cc],
    multiplexed with any other concurrent {!round_trip} calls on the same
    connection. It allocates the next odd stream id, encodes the request
    pseudo-headers ([:method]/[:path]/[:scheme]/[:authority]) and headers via
    HPACK, writes the HEADERS frame (and DATA frames for the request body,
    respecting flow control, with END_STREAM on the last), then awaits the
    response HEADERS and returns a {!Response.t} whose body is a {!Body.Stream}
    fed by DATA frames through a per-stream {!H2_pipe}. Mirrors Go's
    [ClientConn.roundTrip]/[clientStream.writeRequest] +
    [clientConnReadLoop.handleResponse]. *)

val close : client_conn -> unit Lwt.t
(** [close cc] marks the connection closed and aborts the read loop / pending
    streams. Mirrors Go's [ClientConn.Close]. *)

val is_closed : client_conn -> bool
(** [is_closed cc] is [true] once the connection has been closed (cleanly or by
    a reader error) or is shutting down — i.e. it can no longer take new
    requests. Mirrors the negation of Go's [canTakeNewRequest]; exposed so a
    transport pool can evict dead connections. *)

(* ---- minimal connection pool (client_conn_pool.go subset) ---- *)

type t
(** A transport: a connection pool keyed by authority string ([host:port]).
    Mirrors the subset of Go's [Transport]/[clientConnPool] needed here. *)

val create : unit -> t
(** A fresh transport with an empty pool. *)

val round_trip_pooled :
  t ->
  connect:(string -> (Lwt_io.input_channel * Lwt_io.output_channel) Lwt.t) ->
  Api.client_request ->
  Api.client_response Lwt.t
(** [round_trip_pooled t ~connect req] dispatches [req] over a pooled
    [client_conn] for the request's authority, dialing a new one via
    [connect authority] (returning a duplex channel pair) when the pool has no
    usable connection. Mirrors Go's [clientConnPool.GetClientConn] +
    [ClientConn.RoundTrip]. *)
