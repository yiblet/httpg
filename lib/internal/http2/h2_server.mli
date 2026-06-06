(* Port of the HTTP/2 subset of go/src/net/http/internal/http2/server.go: the
   [serverConn] frame-read/serve loop, the [stream] state machine, flow
   control, and the response-writing path. Composes {!H2}, {!H2_error},
   {!H2_frame}, {!Hpack}, {!H2_flow}, {!H2_pipe}, {!H2_databuffer},
   {!H2_write}, {!H2_writesched}, {!Header}, {!Request}, {!Body}, {!Uri},
   {!Context}.

   To avoid a module cycle with the HTTP/1.x {!Server} (which will call this
   module in a later ticket), [H2_server] defines its own {!response_writer}
   and {!handler} types — structurally identical to {!Server}'s — rather than
   depending on {!Server}.

   Go's goroutine + channel concurrency is mapped onto Lwt fibers:
   - The [serve] goroutine + its [select] over [readFrameCh]/[wantWriteFrameCh]/
     [wroteFrameCh]/[bodyReadCh]/[serveMsgCh] becomes one serve fiber draining a
     single {!Lwt_stream} of {e events}; that fiber exclusively owns all the
     [serverConn]/[stream] mutable state and is the sole writer of the output
     channel (mirroring "the serve goroutine never blocks; only handlers do").
   - The [readFrames] goroutine becomes a reader fiber that posts [Read_frame]/
     [Read_error] events.
   - Each handler runs in its own fiber ([Lwt.async]); it posts write requests
     ([wantWriteFrameCh]), body-read notes ([bodyReadCh]) and a done message
     ([handlerDoneMsg]) as events, and blocks on an {!Lwt_condition} for the
     frame-write result (mirroring [writeDataFromHandler]'s [done] channel).
   - Go's per-stream request {!H2_pipe} feeds the streaming {!Body}; DATA frames
     write into it and a blocked handler read awaits the pipe's condition. *)

type response_writer = Api.response_writer
(** Go's [ResponseWriter] / [Handler], defined in {!Api} (Go's api.go) so the
    HTTP/2 stack does not name the public Request/Response types; the public
    [Server] shim adapts them to [Server.response_writer] / a [Request.t]
    handler. *)

type handler = Api.handler

val serve :
  ?max_concurrent_streams:int ->
  ?max_header_bytes:int ->
  Lwt_io.input_channel ->
  Lwt_io.output_channel ->
  handler:handler ->
  unit Lwt.t
(** [serve ic oc ~handler] serves a single HTTP/2 connection over the duplex
    channel pair [(ic, oc)] (already past TLS/ALPN): it reads and validates the
    client preface, sends the server's initial SETTINGS, ACKs the client's
    SETTINGS, then runs the frame-read/serve loop until the connection ends
    (clean EOF, GOAWAY drain, or a fatal error). Each fully-received request is
    dispatched to [handler] in its own fiber. Mirrors Go's [serverConn.serve].
    Server push, RFC 9218 priority and 100-continue auto-send are out of scope
    (see the module's execution record). Resolves when the connection is done.

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
