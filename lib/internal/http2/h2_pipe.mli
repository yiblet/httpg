(* Port of go/src/net/http/internal/http2/pipe.go *)

exception Closed_pipe_write
(** Raised by {!write} on a closed/broken pipe. Mirrors Go's
    [errClosedPipeWrite] ("write on closed buffer"). *)

exception Uninitialized_pipe_write
(** Raised by {!write} when the buffer was never initialized via {!set_buffer}.
    Mirrors Go's [errUninitializedPipeWrite]. *)

val closed_pipe_write_msg : string
val uninitialized_pipe_write_msg : string

type t
(** A fiber-safe Reader/Writer pair backed by an internal {!H2_databuffer.t},
    with error/close propagation. Mirrors Go's [pipe]; a blocked {!read} awaits
    an [Lwt_condition] that {!write}/{!close_with_error}/{!break_with_error}
    broadcast (replacing Go's [sync.Cond]). *)

val create : unit -> t
(** A fresh pipe with no buffer set. Mirrors Go's zero-valued [pipe]. *)

val set_buffer : t -> H2_databuffer.t -> unit
(** [set_buffer p b] installs the backing buffer. No effect if [p] is already
    closed/broken. Mirrors [pipe.setBuffer]. *)

val len : t -> int
(** [len p] is the number of unread bytes (the recorded [unread] count once done
    reading). Mirrors [pipe.Len]. *)

val read : t -> int -> string Lwt.t
(** [read p max] resolves with up to [max] bytes once data is available. If the
    pipe is empty it waits until a {!write}, {!close_with_error} or
    {!break_with_error} occurs. On close-with-error, buffered data is returned
    first and the error is raised only once drained; on break, the error is
    raised immediately. Mirrors [pipe.Read]. *)

val write : t -> string -> int
(** [write p d] appends [d] and wakes a waiting reader, returning the count
    written. Raises {!Closed_pipe_write} if closed/broken, or
    {!Uninitialized_pipe_write} if no buffer was set. Mirrors [pipe.Write]. *)

val close_with_error : t -> exn -> unit
(** [close_with_error p err] causes the next {!read} (waking a blocked reader)
    to raise [err] after all buffered data has been read. Mirrors
    [pipe.CloseWithError]. *)

val break_with_error : t -> exn -> unit
(** [break_with_error p err] causes the next {!read} to raise [err] immediately,
    discarding unread data (recorded in {!len}). Mirrors [pipe.BreakWithError].
*)

val close_with_error_and_code : t -> exn -> (unit -> unit) -> unit
(** [close_with_error_and_code p err fn] is like {!close_with_error} but runs
    [fn] in the reader before raising the error. Mirrors
    [pipe.closeWithErrorAndCode]. *)

val err : t -> exn option
(** [err p] is the error first set by {!break_with_error} or
    {!close_with_error}. Mirrors [pipe.Err]. *)

val done_ : t -> unit Lwt.t
(** [done_ p] is a promise resolved when the pipe is closed/broken with an
    error. Mirrors [pipe.Done]. *)
