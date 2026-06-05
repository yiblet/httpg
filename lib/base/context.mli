(* Port of the deadline/cancellation subset of go/src/context/context.go
   (the [context] package), backed by Lwt.

   Context Values (Go's WithValue / Value / keys) are intentionally OUT of
   scope: net/http uses them only for the ServerContextKey / LocalAddrContextKey
   conveniences, which this port forgoes (the local address is on
   {!Request.remote_addr}; a handler needing the server can close over it). Only
   the deadline + cancellation machinery is ported. *)

type t
(** An opaque context (Go's [context.Context]), carrying a deadline and/or
    cancellation state. *)

exception Canceled
(** Go's [context.Canceled]: the cause when a context is cancelled for a reason
    other than a passed deadline. *)

exception Deadline_exceeded
(** Go's [context.DeadlineExceeded]: the cause when a context's deadline (or
    timeout) is reached. *)

val background : t
(** Go's [context.Background]: the never-cancelled, no-deadline root. Its
    {!done_} never resolves. *)

val todo : t
(** Go's [context.TODO]: semantically identical to {!background} here. *)

val with_cancel : t -> t * (exn -> unit)
(** [with_cancel parent] is Go's [WithCancel]: a child cancelled when [parent]
    is, plus a cancel function. The cancel function takes the cancellation cause
    exception (Go's [WithCancelCause] shape); pass {!Canceled} for the plain
    [WithCancel] behavior. Cancelling is idempotent (first cause wins). *)

val with_timeout : t -> float -> t * (exn -> unit)
(** [with_timeout parent secs] is Go's [WithTimeout]: a child cancelled with
    {!Deadline_exceeded} after [secs] seconds (or when [parent] is cancelled, or
    when the returned cancel function is called). The cancel function takes the
    cause exception; calling it stops the timer to avoid a leak. *)

val with_deadline : t -> float -> t * (exn -> unit)
(** [with_deadline parent epoch] is Go's [WithDeadline]: a child cancelled with
    {!Deadline_exceeded} at the absolute Unix-epoch-seconds [epoch] (tightened
    to [parent]'s deadline when [parent]'s is earlier). Same cancel-function
    contract as {!with_timeout}. *)

val done_ : t -> unit Lwt.t
(** Go's [Context.Done]: a promise that resolves when the context is cancelled
    or its deadline passes. For {!background}/{!todo} it never resolves. *)

val err : t -> exn option
(** Go's [Context.Err]/[context.Cause]: [None] until the context is cancelled,
    then [Some] of the cancelling exception ({!Canceled} or
    {!Deadline_exceeded}). *)

val deadline : t -> float option
(** Go's [Context.Deadline]: the deadline as Unix-epoch seconds, or [None]. *)
