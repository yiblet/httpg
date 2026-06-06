(* Port of go/src/net/http/internal/http2/writesched.go (the [WriteScheduler]
   interface, [FrameWriteRequest], the [writeQueue] two-stage queue and the
   [writeQueuePool]) plus writesched_roundrobin.go (the round-robin scheduler
   that prioritizes control frames over a round-robin of the open streams).

   The RFC 9218 priority scheduler (writesched_priority_rfc9218.go) is a plan
   non-goal and is not ported.

   Composes {!H2_write} (the writer values) and {!H2_flow} (per-stream
   outbound flow control). *)

type stream = { id : int; flow : H2_flow.outflow; mutable max_frame_size : int }
(** Per-stream scheduling state, mirroring the fields of Go's [stream] that the
    scheduler reads via a [FrameWriteRequest]: the stream id, the outbound
    flow-control window ([stream.flow], an {!H2_flow.outflow}) and the
    connection's max frame size ([stream.sc.maxFrameSize]). Created by the
    caller (the server connection) and shared by reference. *)

val make_stream : ?max_frame_size:int -> int -> stream
(** [make_stream ?max_frame_size id] creates a {!type-stream} with a fresh
    zero-valued outflow and the given (default {!H2.initial_max_frame_size}) max
    frame size. *)

type frame_write_request = {
  write : H2_write.write_framer;
  stream : stream option;
}
(** A request to write a frame. Mirrors Go's [FrameWriteRequest]. [stream] is
    [None] for non-stream frames (PING, SETTINGS, …) and for RST_STREAM (which
    carries its own stream id in the writer). *)

val stream_id : frame_write_request -> int
(** [stream_id wr] is the id of the stream this frame writes to, or 0 for
    non-stream frames. RST_STREAM frames with no [stream] use the id carried in
    the writer. Mirrors Go's [FrameWriteRequest.StreamID]. *)

val is_control : frame_write_request -> bool
(** [is_control wr] reports whether [wr] is a control frame (no stream, i.e.
    non-stream frames and RST_STREAM). Mirrors Go's
    [FrameWriteRequest.isControl]. *)

val data_size : frame_write_request -> int
(** [data_size wr] is the number of flow-control bytes consumed by the whole
    frame, 0 for non-DATA. Mirrors Go's [FrameWriteRequest.DataSize]. *)

val consume :
  frame_write_request -> int -> frame_write_request * frame_write_request * int
(** [consume wr n] consumes [min(n, available)] bytes from [wr], where
    [available] is the stream's flow-control budget (and is further capped by
    the stream's max frame size). Returns:
    - [(_, _, 0)] if flow control prevents consuming anything;
    - [(wr, _, 1)] if the whole frame was consumed;
    - [(consumed, rest, 2)] if it was split — [consumed] carries the leading
      bytes, [rest] the remainder. The consumed bytes are deducted from the
      stream's flow window. Non-DATA frames are always consumed whole. Mirrors
      Go's [FrameWriteRequest.Consume]. *)

(* ---- the scheduler ---- *)

type t
(** The round-robin write scheduler. Mirrors Go's [roundRobinWriteScheduler]. *)

val create : unit -> t
(** [create ()] constructs a new round-robin scheduler. Mirrors Go's
    [newRoundRobinWriteScheduler]. *)

val open_stream : t -> int -> unit
(** [open_stream ws id] opens stream [id] in the scheduler, appending its queue
    to the end of the round-robin ring. Illegal for id 0 or an already-open
    stream (raises [Failure], mirroring Go's panic). Mirrors [OpenStream]. *)

val close_stream : t -> int -> unit
(** [close_stream ws id] closes stream [id], discarding its queued frames and
    removing it from the ring. A no-op if not open. Mirrors [CloseStream]. *)

val adjust_stream : t -> int -> unit
(** [adjust_stream ws id] adjusts a stream's priority. A no-op for the
    round-robin scheduler (it ignores priorities). Mirrors [AdjustStream]. *)

val push : t -> frame_write_request -> unit
(** [push ws wr] queues [wr]. Control frames go on the control queue; stream
    frames go on the stream's queue. A frame for a closed stream is pushed onto
    the control queue (and must not be a DATA frame — raises [Failure],
    mirroring Go's panic). Mirrors [Push]. *)

val pop : t -> frame_write_request option
(** [pop ws] dequeues the next frame to write, or [None] if nothing can be
    written now (e.g. all remaining frames are DATA blocked on flow control).
    Control and RST_STREAM frames are returned first; otherwise it round-robins
    across the open streams, advancing the ring head past the chosen stream.
    Mirrors [Pop]. *)
