(* Tests for the Context module (Ticket 12): the deadline/cancellation port of
   go/src/context/context.go and its threading through Request / Transport /
   Client / Server.

   Networked cases start a real loopback Server on an ephemeral port and drive
   it with the gohttp Client; every run is bounded by [Net.with_timeout] so a
   hang fails the suite rather than blocking it. Unit cases exercise the
   Context primitives directly. *)

open Gohttp
open Lwt.Infix

let run p = Lwt_main.run (Net.with_timeout 10. p)

(* ---- unit cases (no network) ---- *)

(* with_timeout resolves done_ and sets err = Some Deadline_exceeded. *)
let unit_with_timeout () =
  run
    (let ctx, _cancel = Context.with_timeout Context.background 0.05 in
     Context.done_ ctx >>= fun () ->
     Alcotest.(check bool)
       "err is Deadline_exceeded" true
       (Context.err ctx = Some Context.Deadline_exceeded);
     Lwt.return_unit)

(* with_deadline (epoch already-near) fires with Deadline_exceeded. *)
let unit_with_deadline () =
  run
    (let ctx, _cancel =
       Context.with_deadline Context.background (Unix.gettimeofday () +. 0.05)
     in
     Context.done_ ctx >>= fun () ->
     Alcotest.(check bool) "deadline set" true (Context.deadline ctx <> None);
     Alcotest.(check bool)
       "err is Deadline_exceeded" true
       (Context.err ctx = Some Context.Deadline_exceeded);
     Lwt.return_unit)

(* with_cancel sets err = Some Canceled when cancelled. *)
let unit_with_cancel () =
  run
    (let ctx, cancel = Context.with_cancel Context.background in
     cancel Context.Canceled;
     Context.done_ ctx >>= fun () ->
     Alcotest.(check bool)
       "err is Canceled" true
       (Context.err ctx = Some Context.Canceled);
     Lwt.return_unit)

(* A child of a cancelled parent is cancelled with the parent's cause. *)
let unit_child_cancels () =
  run
    (let parent, cancel_parent = Context.with_cancel Context.background in
     let child, _cancel_child = Context.with_cancel parent in
     cancel_parent Context.Canceled;
     Context.done_ child >>= fun () ->
     Alcotest.(check bool)
       "child err is Canceled" true
       (Context.err child = Some Context.Canceled);
     Lwt.return_unit)

(* background never resolves: still pending after a short sleep. *)
let unit_background_never () =
  run
    (let p = Context.done_ Context.background in
     Lwt_unix.sleep 0.1 >>= fun () ->
     Alcotest.(check bool)
       "background done_ still pending" true
       (Lwt.state p = Lwt.Sleep);
     Alcotest.(check bool)
       "background err is None" true
       (Context.err Context.background = None);
     Lwt.return_unit)

(* ---- networked cases ---- *)

let with_server handler client =
  let prog =
    Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize (fun () -> client ~port) (fun () -> Server.close srv)
  in
  run prog

(* Context.deadline_aborts: a handler that sleeps ~1s, a client with a ~0.2s
   timeout => Client.get fails with Deadline_exceeded (and does not hang). *)
let deadline_aborts () =
  let slow_handler =
    Server.handler_func (fun w _r ->
        Lwt_unix.sleep 1.0 >>= fun () -> w.Server.write "too late")
  in
  let client ~port =
    let c = Client.create ~timeout:0.2 () in
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    Lwt.catch
      (fun () -> Client.get c url >>= fun _ -> Lwt.return `No_error)
      (function
        | Context.Deadline_exceeded -> Lwt.return `Deadline
        | e -> Lwt.return (`Other (Printexc.to_string e)))
  in
  let outcome = with_server slow_handler client in
  match outcome with
  | `Deadline -> ()
  | `No_error -> Alcotest.fail "expected Deadline_exceeded, got a response"
  | `Other s -> Alcotest.failf "expected Deadline_exceeded, got %s" s

(* Context.cancel_aborts: start a round trip against a slow (never-responding
   within the window) server, cancel the request context shortly after =>
   the round trip fails with Canceled. *)
let cancel_aborts () =
  let slow_handler =
    Server.handler_func (fun w _r ->
        Lwt_unix.sleep 5.0 >>= fun () -> w.Server.write "too late")
  in
  let client ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    let req = Client.make_request Method.get url in
    let ctx, cancel = Context.with_cancel Context.background in
    let req = Request.with_context req ctx in
    (* Cancel shortly after the round trip is in flight. *)
    Lwt.async (fun () ->
        Lwt_unix.sleep 0.2 >>= fun () ->
        cancel Context.Canceled;
        Lwt.return_unit);
    Lwt.catch
      (fun () ->
        Transport.round_trip Transport.default_transport req >>= fun _ ->
        Lwt.return `No_error)
      (function
        | Context.Canceled -> Lwt.return `Canceled
        | e -> Lwt.return (`Other (Printexc.to_string e)))
  in
  let outcome = with_server slow_handler client in
  match outcome with
  | `Canceled -> ()
  | `No_error -> Alcotest.fail "expected Canceled, got a response"
  | `Other s -> Alcotest.failf "expected Canceled, got %s" s

(* Context.server_done_on_close: a handler captures its Request context; after
   it responds (and the connection is torn down) the captured Context.done_
   resolves. Bounded by the suite timeout. *)
let server_done_on_close () =
  let captured = ref None in
  let handler =
    Server.handler_func (fun w r ->
        captured := Some (Request.context r);
        w.Server.write "ok")
  in
  let client ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    Client.get Client.default_client url >>= fun resp ->
    Body.read_all resp.Response.body >>= fun body ->
    (* The handler has run; its context must resolve done_ (handler return
       and/or connection close cancel it). *)
    match !captured with
    | None -> Alcotest.fail "handler did not capture a context"
    | Some ctx ->
        Context.done_ ctx >>= fun () ->
        Lwt.return (resp.Response.status_code, body, Context.err ctx)
  in
  let status, body, err = with_server handler client in
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body" "ok" body;
  Alcotest.(check bool) "server ctx cancelled" true (err = Some Context.Canceled)

(* Context.optional_arg_timeout: the [?context] ergonomics arg on Client.get,
   exercised both ways against the same server in one run. With an explicit
   short-timeout context the call fails with Deadline_exceeded; with the arg
   omitted (and no client timeout) the call against a fast handler succeeds. *)
let optional_arg_timeout () =
  let handler =
    Server.handler_func (fun w r ->
        (* The slow path sleeps long enough to outlast the short context. *)
        if Uri.path r.Request.url = "/slow" then
          Lwt_unix.sleep 1.0 >>= fun () -> w.Server.write "too late"
        else w.Server.write "ok")
  in
  let client ~port =
    let c = Client.create () in
    (* With ~context: a 0.2s deadline against the slow handler => Deadline. *)
    let slow_url = Printf.sprintf "http://127.0.0.1:%d/slow" port in
    let ctx, _cancel = Context.with_timeout Context.background 0.2 in
    Lwt.catch
      (fun () ->
        Client.get ~context:ctx c slow_url >>= fun _ -> Lwt.return `No_error)
      (function
        | Context.Deadline_exceeded -> Lwt.return `Deadline
        | e -> Lwt.return (`Other (Printexc.to_string e)))
    >>= fun with_ctx ->
    (* Without ~context: the fast handler responds 200 OK. *)
    let fast_url = Printf.sprintf "http://127.0.0.1:%d/fast" port in
    Client.get c fast_url >>= fun resp ->
    Body.read_all resp.Response.body >>= fun body ->
    Lwt.return (with_ctx, resp.Response.status_code, body)
  in
  let with_ctx, status, body = with_server handler client in
  (match with_ctx with
  | `Deadline -> ()
  | `No_error ->
      Alcotest.fail "expected Deadline_exceeded with ~context, got a response"
  | `Other s ->
      Alcotest.failf "expected Deadline_exceeded with ~context, got %s" s);
  Alcotest.(check int) "no-context status 200" 200 status;
  Alcotest.(check string) "no-context body" "ok" body

let tests =
  [
    Alcotest.test_case "with_timeout" `Quick unit_with_timeout;
    Alcotest.test_case "with_deadline" `Quick unit_with_deadline;
    Alcotest.test_case "with_cancel" `Quick unit_with_cancel;
    Alcotest.test_case "child_cancels" `Quick unit_child_cancels;
    Alcotest.test_case "background_never" `Quick unit_background_never;
    Alcotest.test_case "deadline_aborts" `Quick deadline_aborts;
    Alcotest.test_case "cancel_aborts" `Quick cancel_aborts;
    Alcotest.test_case "server_done_on_close" `Quick server_done_on_close;
    Alcotest.test_case "optional_arg_timeout" `Quick optional_arg_timeout;
  ]
