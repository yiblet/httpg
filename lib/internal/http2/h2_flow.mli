(* Port of go/src/net/http/internal/http2/flow.go *)

val max_window : int
(** Maximum flow-control window size, 2^31-1 (RFC 7540 Section 6.9.1). *)

type inflow = { mutable avail : int32; mutable unsent : int32 }
(** [inflow] accounts for an inbound flow control window. It tracks both the
    latest window sent to the peer ([avail], used for enforcement) and the
    accumulated unsent window ([unsent]). Mirrors Go's [inflow]. *)

val create_inflow : unit -> inflow
(** A zero-valued [inflow] (Go's [var f inflow]). *)

val inflow_init : inflow -> int32 -> unit
(** [inflow_init f n] sets the initial window. Mirrors [inflow.init]. *)

val inflow_add : inflow -> int -> (int32, H2_error.err_code) result
(** [inflow_add f n] adds [n] bytes to the window, returning the number of bytes
    to send in a WINDOW_UPDATE frame (0 when buffered) as [Ok]. Mirrors
    [inflow.add]. Raises [Invalid_argument] on a negative update (Go panics — a
    programming bug). Returns [Error H2_error.FlowControlError] if the window
    would exceed 2^31-1 (Go panics there too, but we surface a modeled
    connection error so the serve loop converts it to a [FLOW_CONTROL_ERROR]
    GOAWAY rather than crashing the connection fiber). *)

val inflow_take : inflow -> int -> bool
(** [inflow_take f n] attempts to take [n] (an unsigned 32-bit count) from the
    peer's flow control window, reporting whether capacity was available.
    Mirrors [inflow.take]. *)

val take_inflows : inflow -> inflow -> int -> bool
(** [take_inflows f1 f2 n] attempts to take [n] from both inflows, reporting
    whether both had capacity. Mirrors Go's [takeInflows]. *)

type outflow = { mutable n : int32; mutable conn : outflow option }
(** [outflow] is the outbound flow control window's size. Kept both on a conn
    and per-stream. Mirrors Go's [outflow]. *)

val create_outflow : unit -> outflow
(** A zero-valued [outflow] (Go's [var f outflow]). *)

val set_conn_flow : outflow -> outflow -> unit
(** [set_conn_flow f cf] links [f] to the shared connection-level outflow [cf].
    Mirrors [outflow.setConnFlow]. *)

val available : outflow -> int32
(** [available f] is the number of bytes that may be sent, the min of the stream
    and (if linked) conn windows. Mirrors [outflow.available]. *)

val take : outflow -> int32 -> unit
(** [take f n] consumes [n] bytes from the window (and the linked conn window).
    Mirrors [outflow.take]. Raises [Invalid_argument] if [n > available f] (Go
    panics). *)

val add : outflow -> int32 -> bool
(** [add f n] adds [n] (positive or negative) to the window, returning [false]
    if the sum would exceed 2^31-1. Mirrors [outflow.add]. *)

module Private : sig
  (** Helpers exposed only for the ported white-box tests; not part of the
      public API. *)

  val inflow_min_refresh : int
  (** [inflow_min_refresh] is the minimum number of bytes we'll send for a flow
      control window update. Mirrors Go's [inflowMinRefresh] (4<<10). *)
end
