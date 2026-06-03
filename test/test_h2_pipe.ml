(* Ported from go/src/net/http/internal/http2/pipe_test.go.
   The pipe's blocking Read becomes an Lwt promise; we drive it with
   Lwt_main.run bounded by Net.with_timeout so a hang fails the suite rather
   than blocking. A blocked read is unblocked by a later write and by
   close/break-with-error. *)

module Pipe = Gohttp.H2_pipe
module DB = Gohttp.H2_databuffer
module Net = Gohttp.Net

exception Err_a
exception Err_b
exception Test_error

let run t = Lwt_main.run (Net.with_timeout 10. t)

(* a pipe with a fresh backing buffer (Go's `p.b = new(bytes.Buffer)`). *)
let new_pipe () =
  let p = Pipe.create () in
  Pipe.set_buffer p (DB.create ());
  p

(* io.ReadAll: drain the pipe until the close error is raised, returning the
   accumulated bytes and the terminating error. *)
let read_all (p : Pipe.t) : (string * exn) Lwt.t =
  let buf = Buffer.create 16 in
  let rec loop () =
    Lwt.catch
      (fun () -> Lwt.bind (Pipe.read p 4096) (fun s -> Buffer.add_string buf s; loop ()))
      (fun e -> Lwt.return (Buffer.contents buf, e))
  in
  loop ()

(* TestPipeClose: first CloseWithError wins; Read returns that error. *)
let test_pipe_close () =
  run
    (let p = new_pipe () in
     Pipe.close_with_error p Err_a;
     Pipe.close_with_error p Err_b;
     Lwt.catch
       (fun () -> Lwt.bind (Pipe.read p 1) (fun _ -> Alcotest.fail "expected error"))
       (fun e ->
         Alcotest.(check bool) "err = a" true (e == Err_a);
         Lwt.return_unit))

(* TestPipeDoneChan *)
let test_pipe_done_chan () =
  run
    (let p = new_pipe () in
     let done_ = Pipe.done_ p in
     Alcotest.(check bool) "done too soon" true (Lwt.is_sleeping done_);
     Pipe.close_with_error p Test_error;
     Lwt.bind done_ (fun () -> Lwt.return_unit))

(* TestPipeDoneChan_ErrFirst: error before Done(). *)
let test_pipe_done_chan_err_first () =
  run
    (let p = new_pipe () in
     Pipe.close_with_error p Test_error;
     let done_ = Pipe.done_ p in
     Lwt.bind done_ (fun () -> Lwt.return_unit))

(* TestPipeDoneChan_Break *)
let test_pipe_done_chan_break () =
  run
    (let p = new_pipe () in
     let done_ = Pipe.done_ p in
     Alcotest.(check bool) "done too soon" true (Lwt.is_sleeping done_);
     Pipe.break_with_error p Test_error;
     Lwt.bind done_ (fun () -> Lwt.return_unit))

(* TestPipeDoneChan_Break_ErrFirst *)
let test_pipe_done_chan_break_err_first () =
  run
    (let p = new_pipe () in
     Pipe.break_with_error p Test_error;
     let done_ = Pipe.done_ p in
     Lwt.bind done_ (fun () -> Lwt.return_unit))

(* TestPipeCloseWithError: read all buffered data, then the error; buffer
   empties; subsequent Write/Read fail. *)
let test_pipe_close_with_error () =
  run
    (let p = new_pipe () in
     let body = "foo" in
     ignore (Pipe.write p body);
     Pipe.close_with_error p Test_error;
     Lwt.bind (read_all p) (fun (all, err) ->
         Alcotest.(check string) "read bytes" body all;
         Alcotest.(check bool) "err = test error" true (err == Test_error);
         Alcotest.(check int) "0 unread bytes" 0 (Pipe.len p);
         (* Write should fail. *)
         (match Pipe.write p "abc" with
         | _ -> Alcotest.fail "write after close should fail"
         | exception Pipe.Closed_pipe_write -> ());
         (* Read should fail. *)
         Lwt.catch
           (fun () ->
             Lwt.bind (Pipe.read p 1) (fun _ ->
                 Alcotest.fail "read after close should fail"))
           (fun _ ->
             Alcotest.(check int) "0 unread bytes" 0 (Pipe.len p);
             Lwt.return_unit)))

(* TestPipeBreakWithError: break discards buffered data; Read returns the
   error immediately; unread count preserved; Write fails. *)
let test_pipe_break_with_error () =
  run
    (let p = new_pipe () in
     ignore (Pipe.write p "foo");
     Pipe.break_with_error p Test_error;
     Lwt.bind (read_all p) (fun (all, err) ->
         Alcotest.(check string) "read bytes empty" "" all;
         Alcotest.(check bool) "err = test error" true (err == Test_error);
         Alcotest.(check int) "3 unread bytes" 3 (Pipe.len p);
         (* Write should fail. *)
         (match Pipe.write p "abc" with
         | _ -> Alcotest.fail "write after break should fail"
         | exception Pipe.Closed_pipe_write -> ());
         Alcotest.(check int) "3 unread bytes" 3 (Pipe.len p);
         Lwt.return_unit))

(* A blocked Read is unblocked by a later Write. *)
let test_blocked_read_unblocked_by_write () =
  run
    (let p = new_pipe () in
     (* Start a read on an empty pipe; it must block (stay sleeping). *)
     let r = Pipe.read p 16 in
     Alcotest.(check bool) "read is blocked" true (Lwt.is_sleeping r);
     (* Later write wakes it. *)
     ignore (Pipe.write p "hello");
     Lwt.bind r (fun s ->
         Alcotest.(check string) "woken read" "hello" s;
         Lwt.return_unit))

(* A blocked Read is unblocked by CloseWithError (returning the error after
   draining). *)
let test_blocked_read_unblocked_by_close () =
  run
    (let p = new_pipe () in
     let r = Pipe.read p 16 in
     Alcotest.(check bool) "read is blocked" true (Lwt.is_sleeping r);
     Pipe.close_with_error p Test_error;
     Lwt.catch
       (fun () ->
         Lwt.bind r (fun _ -> Alcotest.fail "expected close error"))
       (fun e ->
         Alcotest.(check bool) "err = test error" true (e == Test_error);
         Lwt.return_unit))

let tests =
  [
    ("pipe_close", `Quick, test_pipe_close);
    ("pipe_done_chan", `Quick, test_pipe_done_chan);
    ("pipe_done_chan_err_first", `Quick, test_pipe_done_chan_err_first);
    ("pipe_done_chan_break", `Quick, test_pipe_done_chan_break);
    ("pipe_done_chan_break_err_first", `Quick, test_pipe_done_chan_break_err_first);
    ("pipe_close_with_error", `Quick, test_pipe_close_with_error);
    ("pipe_break_with_error", `Quick, test_pipe_break_with_error);
    ("blocked_read_unblocked_by_write", `Quick, test_blocked_read_unblocked_by_write);
    ("blocked_read_unblocked_by_close", `Quick, test_blocked_read_unblocked_by_close);
  ]
