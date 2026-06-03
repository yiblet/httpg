(* Ticket 3 (streaming client response bodies, HTTP/1.x): the Client/Transport
   return a streaming [Response.body] whose EOF/drain action governs connection
   reuse (Go's [persistConn]/[bodyEOFSignal] returning the connection to the
   idle pool only after [waitForBodyRead]), and a [?context] firing mid-body
   aborts the in-flight read and closes the connection.

   These tests start a real loopback server on an ephemeral port via
   [Server.listen_and_serve_started] and drive it with the gohttp [Client]:

   - client_body_streamed (Success Criterion): a handler streams many flushed
     chunks; the client obtains a [Body.Stream] whose first chunk is readable
     while the handler is still suspended mid-body (i.e. NOT pre-materialized),
     and draining yields the full payload.
   - reuse_after_drain: two sequential [Client.get]s on one client; after the
     first response body is drained the second request reuses the pooled
     connection (asserted via the transport dial counter staying at 1).
   - cancel_mid_body: a [?context] with a short timeout against a body that
     streams one chunk then stalls aborts with the context error.

   Bounded by [Net.with_timeout] so a hang fails rather than blocks. *)

open Gohttp
open Lwt.Infix

(* Start a server with [handler], run [client ~port] against it, stop it. *)
let with_server ?(timeout = 10.0) handler client =
  let run () =
    Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize (fun () -> client ~port) (fun () -> Server.close srv)
  in
  Lwt_main.run (Net.with_timeout timeout (run ()))

(* Pull one chunk from a [Body.Stream], failing the test otherwise. *)
let next_chunk = function
  | Body.Stream next -> next ()
  | Body.Empty -> Lwt.return_none
  | Body.String _ -> Alcotest.fail "expected a streaming body, got a String"

(* ---- Stream.client_body_streamed (SUCCESS CRITERION) ---- *)
(* The handler flushes a first chunk, then blocks on [released] which the test
   resolves ONLY after it has read that early chunk from the response body —
   proving the body is not pre-materialized (the client sees a chunk before the
   handler finishes). After release the handler streams the remaining chunks;
   draining the body yields the full concatenation. *)
let client_body_streamed () =
  let released, release = Lwt.wait () in
  let n_more = 200 in
  let more_chunk = String.make 1024 'x' in
  let handler =
    Server.handler_func (fun w _r ->
        w.Server.write "FIRST" >>= fun () ->
        w.Server.flush () >>= fun () ->
        released >>= fun () ->
        let rec loop i =
          if i = 0 then Lwt.return_unit
          else w.Server.write more_chunk >>= fun () -> loop (i - 1)
        in
        loop n_more)
  in
  let client ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    Client.get Client.default_client url >>= fun resp ->
    (* Read the first chunk BEFORE releasing the (still-suspended) handler.
       This must resolve while the handler is blocked on [released], so the
       body cannot have been fully buffered. *)
    next_chunk resp.Response.body >>= fun first ->
    let handler_done_early = Lwt.state released <> Lwt.Sleep in
    (* Now let the handler stream the rest, then drain the whole body. *)
    Lwt.wakeup_later release ();
    Body.read_all resp.Response.body >>= fun rest ->
    Lwt.return (first, handler_done_early, rest)
  in
  let first, handler_done_early, rest = with_server handler client in
  Alcotest.(check bool) "first chunk readable" true (first <> None && first <> Some "");
  Alcotest.(check bool) "first chunk arrived before handler completed"
    false handler_done_early;
  let first_s = match first with Some s -> s | None -> "" in
  let full = first_s ^ rest in
  let expected = "FIRST" ^ String.concat "" (List.init n_more (fun _ -> more_chunk)) in
  Alcotest.(check int) "full body length" (String.length expected) (String.length full);
  Alcotest.(check string) "full body content" expected full

(* ---- Stream.reuse_after_drain ---- *)
(* Two sequential GETs on one client; after draining the first response body
   the connection returns to the idle pool, so the second request reuses it and
   the transport dial count stays at 1. *)
let reuse_after_drain () =
  let transport = Transport.create () in
  let c = Client.create ~transport () in
  let handler = Server.handler_func (fun w _r -> w.Server.write "hello") in
  let client ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    Client.get c url >>= fun resp1 ->
    (* Drain (not read_all) the first body to release the connection. *)
    Body.drain resp1.Response.body >>= fun () ->
    let dials_after_1 = Transport.dial_count transport in
    let idle_after_1 =
      Transport.idle_count transport
        (Transport.conn_key ~scheme:"http" ~host:"127.0.0.1" ~port)
    in
    Client.get c url >>= fun resp2 ->
    Body.read_all resp2.Response.body >>= fun b2 ->
    let dials_after_2 = Transport.dial_count transport in
    Lwt.return (dials_after_1, idle_after_1, b2, dials_after_2)
  in
  let dials_after_1, idle_after_1, b2, dials_after_2 = with_server handler client in
  Alcotest.(check int) "first request dialed once" 1 dials_after_1;
  Alcotest.(check int) "connection pooled after drain" 1 idle_after_1;
  Alcotest.(check string) "resp2 body" "hello" b2;
  Alcotest.(check int) "second request reused the connection (no new dial)" 1
    dials_after_2

(* ---- Stream.cancel_mid_body ---- *)
(* The handler streams one chunk, flushes, then stalls long past the context
   deadline. The client reads the first chunk fine, but the next body read
   races the (now-expired) context and fails with the context error. *)
let cancel_mid_body () =
  let handler =
    Server.handler_func (fun w _r ->
        w.Server.write "early" >>= fun () ->
        w.Server.flush () >>= fun () ->
        Lwt_unix.sleep 5.0 >>= fun () ->
        w.Server.write "late")
  in
  let client ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    let ctx, _cancel = Context.with_timeout Context.background 0.3 in
    Client.get ~context:ctx Client.default_client url >>= fun resp ->
    (* First chunk is readable. *)
    next_chunk resp.Response.body >>= fun first ->
    (* The next read stalls on the server, so the context deadline fires and
       aborts the in-flight body read. *)
    Lwt.catch
      (fun () ->
        Body.read_all resp.Response.body >>= fun _ -> Lwt.return (first, `No_error))
      (function
        | Context.Deadline_exceeded -> Lwt.return (first, `Deadline)
        | e -> Lwt.return (first, `Other (Printexc.to_string e)))
  in
  let first, outcome = with_server handler client in
  Alcotest.(check bool) "first chunk readable" true (first <> None && first <> Some "");
  match outcome with
  | `Deadline -> ()
  | `No_error -> Alcotest.fail "expected Deadline_exceeded mid-body, got full body"
  | `Other s -> Alcotest.failf "expected Deadline_exceeded mid-body, got %s" s

let tests =
  [
    Alcotest.test_case "client_body_streamed" `Quick client_body_streamed;
    Alcotest.test_case "reuse_after_drain" `Quick reuse_after_drain;
    Alcotest.test_case "cancel_mid_body" `Quick cancel_mid_body;
  ]
