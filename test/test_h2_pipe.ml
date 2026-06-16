(* Ported from go/src/net/http/internal/http2/pipe_test.go.
   The pipe's blocking Read is now a direct (fiber-blocking) call. To assert a
   Read "stays blocked" we fork it into a promise, yield the scheduler a few
   times, and check the promise is still unresolved (the direct-style analogue
   of polling a sleeping promise); a later write or close resolves it. Each test runs
   under an Eio switch bounded by a timeout so a genuine hang fails the suite. *)

module Pipe = Httpg_http2.H2_pipe
module DB = Httpg_http2.H2_databuffer

exception Err_a
exception Err_b
exception Test_error

(* Run [fn ~sw] under Eio_main + a switch, bounded so a hang surfaces. *)
let run fn =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 10. @@ fun () -> Eio.Switch.run fn

(* a pipe with a fresh backing buffer (Go's `p.b = new(bytes.Buffer)`). *)
let new_pipe () =
  let p = Pipe.create () in
  Pipe.set_buffer p (DB.create ());
  p

(* Yield enough that any runnable fiber would have made progress; used to give a
   forked Read the chance to run (and block) before we assert it is blocked. *)
let settle () =
  for _ = 1 to 5 do
    Eio.Fiber.yield ()
  done

(* io.ReadAll: drain the pipe until the close error is raised. *)
let read_all (p : Pipe.t) : string * exn =
  let buf = Buffer.create 16 in
  let rec loop () =
    match Pipe.read p 4096 with
    | s ->
        Buffer.add_string buf s;
        loop ()
    | exception e -> (Buffer.contents buf, e)
  in
  loop ()

(* TestPipeClose: first CloseWithError wins; Read returns that error. *)
let test_pipe_close () =
  run @@ fun _sw ->
  let p = new_pipe () in
  Pipe.close_with_error p Err_a;
  Pipe.close_with_error p Err_b;
  match Pipe.read p 1 with
  | _ -> Alcotest.fail "expected error"
  | exception e -> Alcotest.(check bool) "err = a" true (e == Err_a)

(* TestPipeDoneChan *)
let test_pipe_done_chan () =
  run @@ fun _sw ->
  let p = new_pipe () in
  let done_ = Pipe.done_ p in
  settle ();
  Alcotest.(check bool) "done too soon" false (Eio.Promise.is_resolved done_);
  Pipe.close_with_error p Test_error;
  Eio.Promise.await done_

(* TestPipeDoneChan_ErrFirst: error before Done(). *)
let test_pipe_done_chan_err_first () =
  run @@ fun _sw ->
  let p = new_pipe () in
  Pipe.close_with_error p Test_error;
  Eio.Promise.await (Pipe.done_ p)

(* TestPipeDoneChan_Break *)
let test_pipe_done_chan_break () =
  run @@ fun _sw ->
  let p = new_pipe () in
  let done_ = Pipe.done_ p in
  settle ();
  Alcotest.(check bool) "done too soon" false (Eio.Promise.is_resolved done_);
  Pipe.break_with_error p Test_error;
  Eio.Promise.await done_

(* TestPipeDoneChan_Break_ErrFirst *)
let test_pipe_done_chan_break_err_first () =
  run @@ fun _sw ->
  let p = new_pipe () in
  Pipe.break_with_error p Test_error;
  Eio.Promise.await (Pipe.done_ p)

(* TestPipeCloseWithError: read all buffered data, then the error; buffer
   empties; subsequent Write/Read fail. *)
let test_pipe_close_with_error () =
  run @@ fun _sw ->
  let p = new_pipe () in
  let body = "foo" in
  ignore (Pipe.write p body);
  Pipe.close_with_error p Test_error;
  let all, err = read_all p in
  Alcotest.(check string) "read bytes" body all;
  Alcotest.(check bool) "err = test error" true (err == Test_error);
  Alcotest.(check int) "0 unread bytes" 0 (Pipe.len p);
  (match Pipe.write p "abc" with
  | Ok _ -> Alcotest.fail "write after close should fail"
  | Error Pipe.Closed -> ()
  | Error Pipe.Uninitialized -> Alcotest.fail "wrong write error");
  match Pipe.read p 1 with
  | _ -> Alcotest.fail "read after close should fail"
  | exception _ -> Alcotest.(check int) "0 unread bytes" 0 (Pipe.len p)

(* TestPipeBreakWithError: break discards buffered data; Read returns the error
   immediately; unread count preserved; Write fails. *)
let test_pipe_break_with_error () =
  run @@ fun _sw ->
  let p = new_pipe () in
  ignore (Pipe.write p "foo");
  Pipe.break_with_error p Test_error;
  let all, err = read_all p in
  Alcotest.(check string) "read bytes empty" "" all;
  Alcotest.(check bool) "err = test error" true (err == Test_error);
  Alcotest.(check int) "3 unread bytes" 3 (Pipe.len p);
  (match Pipe.write p "abc" with
  | Ok _ -> Alcotest.fail "write after break should fail"
  | Error Pipe.Closed -> ()
  | Error Pipe.Uninitialized -> Alcotest.fail "wrong write error");
  Alcotest.(check int) "3 unread bytes" 3 (Pipe.len p)

(* A blocked Read is unblocked by a later Write. *)
let test_blocked_read_unblocked_by_write () =
  run @@ fun sw ->
  let p = new_pipe () in
  let r = Eio.Fiber.fork_promise ~sw (fun () -> Pipe.read p 16) in
  settle ();
  Alcotest.(check bool) "read is blocked" false (Eio.Promise.is_resolved r);
  ignore (Pipe.write p "hello");
  Alcotest.(check string) "woken read" "hello" (Eio.Promise.await_exn r)

(* A blocked Read is unblocked by CloseWithError (returning the error after
   draining). *)
let test_blocked_read_unblocked_by_close () =
  run @@ fun sw ->
  let p = new_pipe () in
  let r = Eio.Fiber.fork_promise ~sw (fun () -> Pipe.read p 16) in
  settle ();
  Alcotest.(check bool) "read is blocked" false (Eio.Promise.is_resolved r);
  Pipe.close_with_error p Test_error;
  match Eio.Promise.await r with
  | Ok _ -> Alcotest.fail "expected close error"
  | Error e -> Alcotest.(check bool) "err = test error" true (e == Test_error)

let tests =
  [
    ("pipe_close", `Quick, test_pipe_close);
    ("pipe_done_chan", `Quick, test_pipe_done_chan);
    ("pipe_done_chan_err_first", `Quick, test_pipe_done_chan_err_first);
    ("pipe_done_chan_break", `Quick, test_pipe_done_chan_break);
    ( "pipe_done_chan_break_err_first",
      `Quick,
      test_pipe_done_chan_break_err_first );
    ("pipe_close_with_error", `Quick, test_pipe_close_with_error);
    ("pipe_break_with_error", `Quick, test_pipe_break_with_error);
    ( "blocked_read_unblocked_by_write",
      `Quick,
      test_blocked_read_unblocked_by_write );
    ( "blocked_read_unblocked_by_close",
      `Quick,
      test_blocked_read_unblocked_by_close );
  ]
