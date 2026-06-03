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

(** Go's [ResponseWriter], modeled as a record of operations (identical shape to
    {!Server.response_writer}). [header ()] is the mutable header map the handler
    fills before headers are flushed; [write_header code] sets the status
    (implicit 200 on first [write]); [write data] appends body bytes. [flush]
    forces the buffered headers/body onto the wire (Go's [Flush]). *)
type response_writer = {
  header : unit -> Header.t;
  write_header : int -> unit;
  write : string -> unit Lwt.t;
  flush : unit -> unit Lwt.t;
}

(** Go's [Handler]: [ServeHTTP(ResponseWriter, *Request)]. *)
type handler = response_writer -> Body.t Request.t -> unit Lwt.t

(** [serve ic oc ~handler] serves a single HTTP/2 connection over the duplex
    channel pair [(ic, oc)] (already past TLS/ALPN): it reads and validates the
    client preface, sends the server's initial SETTINGS, ACKs the client's
    SETTINGS, then runs the frame-read/serve loop until the connection ends
    (clean EOF, GOAWAY drain, or a fatal error). Each fully-received request is
    dispatched to [handler] in its own fiber. Mirrors Go's [serverConn.serve].
    Server push, RFC 9218 priority and 100-continue auto-send are out of scope
    (see the module's execution record). Resolves when the connection is done.

    [max_concurrent_streams] is the advertised SETTINGS_MAX_CONCURRENT_STREAMS
    (default {!default_max_concurrent_streams}). *)
val serve :
  ?max_concurrent_streams:int ->
  Lwt_io.input_channel ->
  Lwt_io.output_channel ->
  handler:handler ->
  unit Lwt.t

(** The default advertised SETTINGS_MAX_CONCURRENT_STREAMS. Mirrors Go's
    [defaultMaxStreams] (250). *)
val default_max_concurrent_streams : int
