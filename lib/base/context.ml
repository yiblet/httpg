(* Port of the deadline/cancellation subset of go/src/context/context.go.

   Mirrors Go's Context interface (Deadline / Done / Err) and the
   WithCancel / WithDeadline / WithTimeout constructors, backed by Lwt.

   Context Values (WithValue / Value / keys) are intentionally OUT of scope
   (Ticket 12 scope note): net/http uses them only for the
   ServerContextKey / LocalAddrContextKey conveniences, which this port
   forgoes. Only the deadline/cancellation machinery is ported.

   Go's cancellation cause (context.Cause, WithCancelCause) is modeled by
   carrying the cancelling exception: [Canceled] for an ordinary cancel and
   [Deadline_exceeded] when a timer fires. [err] returns that exception, which
   serves as both Go's Err() (the cancel reason) and Cause() (the underlying
   cause) here -- the two coincide because Values are out of scope. *)

(* Go's context.Canceled / context.DeadlineExceeded sentinel errors. *)
exception Canceled
exception Deadline_exceeded

type t = {
  (* Go's Done() channel, modeled as a memoized promise resolved (with unit)
     when the context is cancelled. For background/todo this promise is never
     resolved (Go returns a nil channel). *)
  done_p : unit Lwt.t;
  (* The resolver for [done_p]; [None] for the never-cancelled
     background/todo roots. *)
  wake : unit Lwt.u option;
  (* Go's Err()/Cause(): [None] until cancelled, then the cancelling
     exception. Set exactly once (first cause wins). *)
  mutable err_cell : exn option;
  (* Go's Deadline(): the deadline as Unix epoch seconds, if any. *)
  deadline_v : float option;
}

(* Go's Background(): never cancelled, no deadline. We use a never-resolving
   promise (no resolver retained) so [done_] never fires. *)
let background =
  let p, _ = Lwt.wait () in
  { done_p = p; wake = None; err_cell = None; deadline_v = None }

(* Go's TODO(): semantically identical to Background for our purposes. *)
let todo =
  let p, _ = Lwt.wait () in
  { done_p = p; wake = None; err_cell = None; deadline_v = None }

let done_ t = t.done_p
let err t = t.err_cell
let deadline t = t.deadline_v

(* Resolve [c]'s Done promise exactly once, recording [cause] as Err()/Cause()
   (Go's cancelCtx.cancel: first cause wins, the channel is closed once). *)
let do_cancel c (cause : exn) =
  match c.err_cell with
  | Some _ -> () (* already cancelled: first cause wins *)
  | None -> (
      c.err_cell <- Some cause;
      match c.wake with
      | Some u -> Lwt.wakeup_later u ()
      | None -> () (* unreachable for cancellable contexts *))

(* Build a fresh cancellable child whose Done promise also fires when [parent]'s
   Done fires (Go's propagateCancel: a child is cancelled when its parent is).
   [deadline_v] carries the effective deadline (parent's, possibly tightened). *)
let new_cancel_ctx (parent : t) ?(deadline_v = parent.deadline_v) () =
  let p, u = Lwt.wait () in
  let c = { done_p = p; wake = Some u; err_cell = None; deadline_v } in
  (* Chain to the parent: when the parent is cancelled, cancel the child with
     the parent's cause (Go propagates parent.Err()). This watcher is harmless
     for background/todo parents (their Done never resolves) and is dropped once
     the child is itself cancelled (its Done having resolved makes the bind a
     no-op on the already-resolved child). *)
  Lwt.async (fun () ->
      Lwt.bind parent.done_p (fun () ->
          let cause =
            match parent.err_cell with Some e -> e | None -> Canceled
          in
          do_cancel c cause;
          Lwt.return_unit));
  c

(* Go's WithCancel: returns a child and a cancel function. The cancel function
   takes the cause exception (Go's WithCancelCause shape); the plain
   WithCancel's cancel defaults to [Canceled] -- callers pass [Canceled]. *)
let with_cancel (parent : t) : t * (exn -> unit) =
  let c = new_cancel_ctx parent () in
  (c, fun cause -> do_cancel c cause)

(* Go's WithDeadline: arm a timer that cancels the child with Deadline_exceeded
   at the given Unix-epoch deadline. The deadline is tightened to the parent's
   if the parent's is earlier (Go does the same). Returns the child and a cancel
   function (cancelling early with [Canceled], cancelling the timer to avoid a
   leak). *)
let with_deadline (parent : t) (deadline_epoch : float) : t * (exn -> unit) =
  (* If the parent already has an earlier deadline, keep theirs. *)
  let effective =
    match parent.deadline_v with
    | Some pd when pd <= deadline_epoch -> pd
    | _ -> deadline_epoch
  in
  let c = new_cancel_ctx parent ~deadline_v:(Some effective) () in
  let delay = effective -. Unix.gettimeofday () in
  if delay <= 0. then
    (* Deadline already passed (Go cancels immediately). *)
    do_cancel c Deadline_exceeded
  else begin
    let timer = Lwt_unix.sleep delay in
    Lwt.async (fun () ->
        Lwt.bind timer (fun () ->
            do_cancel c Deadline_exceeded;
            Lwt.return_unit));
    (* Cancel the timer once the context is done by any route, to avoid leaking
       a pending sleep (Go's timerCtx.cancel stops the timer). *)
    Lwt.async (fun () ->
        Lwt.bind c.done_p (fun () ->
            Lwt.cancel timer;
            Lwt.return_unit))
  end;
  (c, fun cause -> do_cancel c cause)

(* Go's WithTimeout: WithDeadline(parent, now + timeout). [secs] in seconds. *)
let with_timeout (parent : t) (secs : float) : t * (exn -> unit) =
  with_deadline parent (Unix.gettimeofday () +. secs)
