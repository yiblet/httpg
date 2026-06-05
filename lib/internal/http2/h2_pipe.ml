(* Port of go/src/net/http/internal/http2/pipe.go *)

(* errClosedPipeWrite / errUninitializedPipeWrite mirror Go's package errors. *)
exception Closed_pipe_write
exception Uninitialized_pipe_write

let closed_pipe_write_msg = "write on closed buffer"
let uninitialized_pipe_write_msg = "write on uninitialized buffer"

(* pipe is a goroutine-safe (here: fiber-safe) Reader/Writer pair. It's like
   io.Pipe except there are no PipeReader/PipeWriter halves, and the underlying
   buffer is held internally. Go uses a sync.Cond to block Read; here a blocked
   Read awaits an Lwt_condition that Write/CloseWithError/BreakWithError
   broadcast. *)
type t = {
  cond : unit Lwt_condition.t; (* mirrors Go's sync.Cond *)
  mutable b : H2_databuffer.t option; (* None when done reading *)
  mutable unread : int; (* bytes unread when done *)
  mutable err : exn option; (* read error once empty; Some means closed *)
  mutable break_err : exn option;
      (* immediate read error (caller doesn't see rest of b) *)
  mutable donec : unit Lwt.t option; (* resolved on error *)
  mutable donec_wake : unit Lwt.u option;
  mutable read_fn : (unit -> unit) option;
      (* optional code to run before error *)
}

let create () =
  {
    cond = Lwt_condition.create ();
    b = None;
    unread = 0;
    err = None;
    break_err = None;
    donec = None;
    donec_wake = None;
    read_fn = None;
  }

(* setBuffer initializes the pipe buffer. It has no effect if the pipe is
   already closed. *)
let set_buffer p b = if p.err = None && p.break_err = None then p.b <- Some b
let len p = match p.b with None -> p.unread | Some b -> H2_databuffer.len b

(* Read waits until data is available and copies up to [max] bytes from the
   buffer, returning them as a string. On close-with-error, after all buffered
   data is drained, the error is raised; on break, the error is raised
   immediately. Mirrors pipe.Read. *)
let rec read p (max : int) : string Lwt.t =
  match p.break_err with
  | Some e -> Lwt.fail e
  | None -> (
      match p.b with
      | Some b when H2_databuffer.len b > 0 ->
          Lwt.return (H2_databuffer.read_string b max)
      | _ -> (
          match p.err with
          | Some e ->
              (match p.read_fn with
              | Some fn ->
                  fn () (* e.g. copy trailers *);
                  p.read_fn <- None (* not sticky like p.err *)
              | None -> ());
              p.b <- None;
              Lwt.fail e
          | None ->
              (* Wait for a Write / Close / Break to wake us. *)
              Lwt.bind (Lwt_condition.wait p.cond) (fun () -> read p max)))

(* Write copies bytes into the buffer and wakes a reader. It is an error to
   write more data than the buffer can hold. Returns the number written. *)
let write p (d : string) : int =
  Fun.protect
    ~finally:(fun () -> Lwt_condition.broadcast p.cond ())
    (fun () ->
      if p.err <> None || p.break_err <> None then raise Closed_pipe_write;
      (* setBuffer may never have been invoked, leaving the buffer
         uninitialized. *)
      match p.b with
      | None -> raise Uninitialized_pipe_write
      | Some b -> H2_databuffer.write_string b d)

(* requires nothing held; resolves donec if present and unresolved. *)
let close_done_locked p =
  match (p.donec, p.donec_wake) with
  | Some _, Some u ->
      p.donec_wake <- None;
      Lwt.wakeup_later u ()
  | _ -> ()

(* closeWithError into the given target. *)
let close_with_error_into ~is_break p (err : exn) (fn : (unit -> unit) option) =
  Fun.protect
    ~finally:(fun () -> Lwt_condition.broadcast p.cond ())
    (fun () ->
      let already = if is_break then p.break_err <> None else p.err <> None in
      if already then () (* Already been done. *)
      else begin
        p.read_fn <- fn;
        if is_break then begin
          (match p.b with
          | Some b -> p.unread <- p.unread + H2_databuffer.len b
          | None -> ());
          p.b <- None
        end;
        if is_break then p.break_err <- Some err else p.err <- Some err;
        close_done_locked p
      end)

(* CloseWithError causes the next Read (waking a blocked Read if needed) to
   return the provided err after all data has been read. The error must be
   non-nil. *)
let close_with_error p err = close_with_error_into ~is_break:false p err None

(* BreakWithError causes the next Read to return err immediately, without
   waiting for unread data. *)
let break_with_error p err = close_with_error_into ~is_break:true p err None

(* closeWithErrorAndCode: like CloseWithError but also sets code to run before
   returning the error. *)
let close_with_error_and_code p err fn =
  close_with_error_into ~is_break:false p err (Some fn)

(* Err returns the error (if any) first set by BreakWithError or
   CloseWithError. *)
let err p = match p.break_err with Some _ as e -> e | None -> p.err

(* Done returns a promise which resolves if and when this pipe is closed with
   CloseWithError (or BreakWithError). *)
let done_ p =
  match p.donec with
  | Some d -> d
  | None ->
      let d, u = Lwt.wait () in
      p.donec <- Some d;
      p.donec_wake <- Some u;
      if p.err <> None || p.break_err <> None then
        (* Already hit an error. *)
        close_done_locked p;
      d
