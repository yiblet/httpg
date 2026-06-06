(* Port of the HTTP/2 subset of go/src/net/http/internal/http2/server.go: the
   [serverConn] frame-read/serve loop, the [stream] state machine, flow
   control, and the response-writing path. Composes {!H2}, {!H2_error},
   {!H2_frame}, {!Hpack}, {!H2_flow}, {!H2_pipe}, {!H2_databuffer},
   {!H2_write}, {!H2_writesched}, {!Api}.

   To avoid a module cycle with the HTTP/1.x {!Server} (which calls this module
   via the ALPN shim), [H2_server] uses the {!Api} (Go's api.go)
   {!response_writer}/{!handler} types rather than depending on {!Server}.

   Go's goroutine + channel concurrency is mapped onto Eio fibers under one
   [Eio.Switch] per connection:
   - The [serve] goroutine + its [select] over [readFrameCh]/[wantWriteFrameCh]/
     [wroteFrameCh]/[bodyReadCh]/[serveMsgCh] becomes one serve fiber draining a
     single [Eio.Stream] of {e events}; that fiber exclusively owns all the
     [serverConn]/[stream] mutable state and is the sole writer of the output
     [Eio.Buf_write.t].
   - The [readFrames] goroutine becomes a reader fiber ([Fiber.fork ~sw]) that
     posts [Read_frame]/[Read_meta]/[Read_error] events.
   - Each handler runs in its own fiber ([Fiber.fork ~sw]); it posts write
     requests, body-read notes and a done message as events, and blocks on a
     per-request reply mailbox raced ([Eio.Fiber.first]) against the
     [done_serving] condition (mirroring [writeDataFromHandler]'s [done] chan).
   - Releasing the connection switch cancels the reader and any in-flight
     handler fibers (Go's [doneServing] broadcast). *)

type response_writer = Api.response_writer
(** Go's [ResponseWriter] / [Handler], defined in {!Api} (Go's api.go) so the
    HTTP/2 stack does not name the public Request/Response types; the public
    [Server] shim adapts them to [Server.response_writer] / a [Request.t]
    handler. *)

type handler = Api.handler

val serve :
  ?max_concurrent_streams:int ->
  ?max_header_bytes:int ->
  ?clock:_ Eio.Time.clock ->
  ?idle_timeout:float ->
  ?read_timeout:float ->
  ?graceful:unit Eio.Promise.t ->
  Eio.Buf_read.t ->
  Eio.Buf_write.t ->
  handler:handler ->
  unit
(** [serve r w ~handler] serves a single HTTP/2 connection over the buffered
    duplex pair [(r, w)] (already past TLS/ALPN): it reads and validates the
    client preface, sends the server's initial SETTINGS, ACKs the client's
    SETTINGS, then runs the frame-read/serve loop until the connection ends
    (clean EOF, GOAWAY drain, or a fatal error). Each fully-received request is
    dispatched to [handler] in its own fiber. Mirrors Go's [serverConn.serve].
    It owns an internal [Eio.Switch]; on return the reader and all handler
    fibers are cancelled, the request pipes broken, and any blocked handler
    write unblocked. Server push, RFC 9218 priority and 100-continue auto-send
    are out of scope (see the module's execution record).

    Shutdown / timeouts (Go's [serverConn] [serveMsgCh] timers, gated on
    [clock]; with no [clock] every timer is inert, matching Go's zero-duration
    knobs):
    - [graceful], once resolved, starts a graceful shutdown (Go's
      [startGracefulShutdown]): GOAWAY with NO_ERROR and the last processed
      stream id, then keep serving until all in-flight streams complete, then
      linger [goAwayTimeout] (~1s) before closing. New streams after the GOAWAY
      are refused. This is distinct from a {e forced} close (cancelling the conn
      switch), which tears down in-flight streams immediately.
    - [idle_timeout] (Go's [IdleTimeout]; 0. = off): once no streams are open,
      arms a graceful GOAWAY after the idle period.
    - [read_timeout] (Go's [ReadTimeout]/[SendPingTimeout] shape; 0. = off):
      closes the connection if no frame is read within the period; reset on
      every received frame.
    - The first-SETTINGS ([firstSettingsTimeout], 2s) and preface
      ([prefaceTimeout], 10s) handshake timers close a peer that never completes
      the HTTP/2 handshake.

    [max_concurrent_streams] is the advertised SETTINGS_MAX_CONCURRENT_STREAMS
    (default {!default_max_concurrent_streams}). [max_header_bytes] is the
    advertised SETTINGS_MAX_HEADER_LIST_SIZE and the HPACK decode budget
    (incoming HEADERS/CONTINUATION blocks exceeding it are rejected as a
    connection [ProtocolError]); a non-positive value falls back to the default
    {!H2.default_max_header_bytes} ([1 lsl 20]), mirroring Go's
    [serverConn.maxHeaderListSize] (server.go:499-505,:778). *)

val default_max_concurrent_streams : int
(** The default advertised SETTINGS_MAX_CONCURRENT_STREAMS. Mirrors Go's
    [defaultMaxStreams] (250). *)
