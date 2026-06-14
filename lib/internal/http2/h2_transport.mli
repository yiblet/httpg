(* Port of the client subset of go/src/net/http/internal/http2/transport.go:
   the HTTP/2 [ClientConn] (one multiplexed connection). The keep-alive pool
   keyed by authority lives in the public {!Httpg.Transport}. Composes {!H2},
   {!H2_error}, {!H2_frame}, {!Hpack}, {!H2_flow}, {!H2_pipe}, {!H2_databuffer},
   {!Api}.

   To avoid a module cycle with the HTTP/1.x {!Transport}/{!Client} (the ALPN
   shim, ticket 010), [H2_transport] works only over given [Eio.Buf_read]/
   [Eio.Buf_write] channels — it does not dial or depend on {!Transport}, and
   uses the decoupled {!Api} types rather than the public Request/Response.

   Go's goroutine + channel concurrency is mapped onto Eio fibers under one
   [Eio.Switch] per connection (passed to {!new_client_conn}):
   - The [ClientConn.readLoop] goroutine becomes a daemon {e read-loop fiber}
     forked into the conn switch; it reads frames, assembles
     HEADERS+CONTINUATION via {!H2_frame.read_meta_headers}, and dispatches to
     per-stream waiters, exclusively owning the connection's mutable state.
   - Go's per-stream [resc]/[peerClosed]/[abort] channels and conn-level
     [cc.cond] (flow / closed changes) collapse to a single [Eio.Condition.t]
     broadcast on every state change; waiters re-check their predicate after each
     wake (request fibers in {!round_trip} await the response or an abort).
   - Go's per-stream response [bufPipe] is the existing {!H2_pipe}, feeding the
     response {!Api.Body.Stream}; DATA frames write into it.
   - Go's [wmu] write mutex becomes an [Eio.Mutex.t] serializing all channel
     writes (HEADERS, DATA, WINDOW_UPDATE, PING ACK, SETTINGS ACK).
   - Releasing the conn switch (close / fatal error / GOAWAY) aborts in-flight
     request fibers via the abort condition; the daemon reader is cancelled. *)

exception Conn_unusable
(** Go's [errClientConnUnusable] (transport.go:530): the connection was already
    closed/closing before the request wrote anything to the wire. {!round_trip}
    now surfaces this as [Error Conn_unusable] (see {!error}); the exception is
    retained for the transport bridge, which re-raises it after deciding not to
    evict + replay. Because the request is untouched, the transport pool may
    evict the dead conn and replay it on a fresh dial (Go's
    [shouldRetryRequest]); any other failure means bytes may have been sent and
    must surface to the caller. *)

(** Handleable failures surfaced by {!round_trip} as an [Error] arm — the
    external boundary of the decoupled h2 client. They mirror Go's [(T, error)]
    for the round-trip path. Internal fiber control-flow and event-loop protocol
    transitions stay exceptional (see {!round_trip}). *)
type error =
  | Conn_closed  (** Go's [errClientConnClosed]: the conn closed under us. *)
  | Conn_unusable
      (** Go's [errClientConnUnusable]: conn closed/closing before anything was
          written; the request is untouched and replayable on a fresh dial. *)
  | Got_goaway of H2_error.err_code
      (** Go's [errClientConnGotGoAway]: the server sent GOAWAY. *)
  | Malformed_response of string
      (** The response violated HTTP/2 framing (e.g. a missing/invalid [:status]
          pseudo-header). *)
  | Request_canceled
      (** Go's [errRequestCanceled]: the caller abandoned the request (early
          return / undrained response / cancelled scope) before a clean close.
      *)

val error_to_string : error -> string
(** Human-readable rendering of an {!error}, for logging / test failures. *)

val error_to_exn : error -> exn
(** [error_to_exn e] is the internal exception [e] was mapped from. The {!error}
    variants shadow the same-named exceptions in this signature, so a caller
    cannot name those exceptions directly; this is the supported way for the
    transport bridge to re-raise an {!error} (preserving the pre-result raising
    behavior of [Transport.round_trip] until it too converts). *)

val error_of_exn : exn -> error option
(** [error_of_exn e] is [Some] of the modeled boundary {!error} that the
    internal exception [e] represents, or [None] for anything that is NOT a
    modeled boundary failure (a bug / fiber-control unwind) and must be
    re-raised. The inverse of {!error_to_exn}; the {!error} variants shadow the
    same-named exceptions, so this is the supported way for the transport
    boundary to convert a re-raised h2 exception back into a typed {!error}. *)

type client_conn
(** One HTTP/2 client connection, multiplexing concurrent streams. Mirrors Go's
    [ClientConn]. *)

val new_client_conn :
  sw:Eio.Switch.t -> Eio.Buf_read.t -> Eio.Buf_write.t -> client_conn
(** [new_client_conn ~sw r w] establishes a [ClientConn] over the buffered
    duplex pair [(r, w)] (already past TLS/ALPN): it writes the client preface
    and an initial SETTINGS frame, reads (and ACKs) the server's SETTINGS, and
    forks the shared read-loop daemon fiber into [sw]. Returns once the server's
    first SETTINGS frame has been seen (mirroring Go's [newClientConn] + waiting
    on [seenSettingsChan]). The read loop and per-request body-writer fibers
    live under [sw]; cancelling it tears down the connection. *)

val round_trip :
  ?sw:Eio.Switch.t ->
  client_conn ->
  Api.client_request ->
  (Api.client_response, error) result
(** [round_trip ?sw cc req] performs one HTTP/2 request/response exchange on
    [cc], multiplexed with any other concurrent {!round_trip} calls on the same
    connection. It allocates the next odd stream id, encodes the request
    pseudo-headers ([:method]/[:path]/[:scheme]/[:authority]) and headers via
    HPACK, writes the HEADERS frame (and, for a request body, DATA frames in a
    forked fiber respecting flow control, with END_STREAM on the last), then
    awaits the response HEADERS and returns an {!Api.client_response} whose body
    is a [Body.Stream] fed by DATA frames through a per-stream {!H2_pipe}.
    Mirrors Go's [ClientConn.roundTrip]/[clientStream.writeRequest] +
    [clientConnReadLoop.handleResponse].

    [?sw] is the caller's per-request scope: the body-writer fiber forks into it
    (not the conn switch) and, on its release — caller returns / abandons the
    response body undrained / the scope is cancelled (a per-request deadline) —
    a [cleanupWriteRequest]-equivalent aborts a still-open stream and
    [forgetStreamID]-removes it, so no writer fiber or stream entry lingers past
    the caller's interest. Omitting [?sw] keeps the writer on the conn switch
    (teardown then only on stream close / conn close).

    Returns [Error] for the handleable failures of {!error}: a dead/unusable
    connection ([Conn_closed]/[Conn_unusable]), a server GOAWAY ([Got_goaway]),
    a framing violation in the response ([Malformed_response]), or an abandoned
    request ([Request_canceled]). When the failure arrives wrapped in the
    internal [Stream_aborted] fiber-unwind, the real cause it carries is
    unwrapped and mapped through the same arms. Everything else propagates as an
    exception unchanged — that is the residual floor of bugs and fiber-control:
    [H2_error.Connection_error]/[Stream_error] (event-loop protocol transitions
    driving on-wire GOAWAY/RST), [Eio.Cancel], asserts, [invalid_arg], and the
    {!H2_pipe}/{!H2_databuffer} guards. *)

val reserve_new_request : client_conn -> bool
(** [reserve_new_request cc] reserves a concurrency slot on [cc] (incrementing
    Go's [streamsReserved]) so a pooled connection can be handed out without
    overshooting [MAX_CONCURRENT_STREAMS]; the reservation is consumed by the
    next {!round_trip}. Returns [false] if [cc] cannot take a new request.
    Mirrors Go's [ClientConn.ReserveNewRequest] (transport.go:744). *)

val current_request_count : client_conn -> int
(** [current_request_count cc] is the number of concurrency slots in use:
    [len(streams) + streamsReserved + pendingResets]. Mirrors Go's
    [currentRequestCountLocked] (transport.go:885). Exposed for tests asserting
    the slot accounting (reserved/pending-reset slots count against the limit,
    and the slot frees only after the response body is fully read). *)

val close : client_conn -> unit
(** [close cc] marks the connection closed and aborts the read loop / pending
    streams. Mirrors Go's [ClientConn.Close]. *)

val live_stream_count : client_conn -> int
(** [live_stream_count cc] is the number of streams currently in [cc]'s table
    (Go's [len(cc.streams)]). Exposed for tests asserting that
    [cleanupWriteRequest]/[forgetStreamID] leave no entry lingering after a
    round trip completes or its caller scope is released. *)

val is_closed : client_conn -> bool
(** [is_closed cc] is [true] once the connection has been closed (cleanly or by
    a reader error) or is shutting down — i.e. it can no longer take new
    requests. Mirrors the negation of Go's [canTakeNewRequest]; exposed so a
    transport pool can evict dead connections. *)
