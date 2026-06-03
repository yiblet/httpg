(* Integration tests for the HTTP/1.x Client + Transport (Ticket 10), a ported
   subset of go/src/net/http/clientserver_test.go and client_test.go.

   Each test starts a real loopback Server (Ticket 9) on an ephemeral port via
   [Server.listen_and_serve_started] and drives it with the gohttp [Client]
   (Ticket 10) rather than a raw socket. The whole run is bounded by
   [Net.with_timeout] so a hang fails rather than blocks the suite. *)

open Gohttp
open Lwt.Infix

(* Start a server with [handler], run [client ~port] against it, stop it. *)
let with_server handler client =
  let run () =
    Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize (fun () -> client ~port) (fun () -> Server.close srv)
  in
  Lwt_main.run (Net.with_timeout 10. (run ()))

(* ---- handlers ---- *)

let hello_handler = Server.handler_func (fun w _r -> w.Server.write "hello")

(* Echo the request body back in the response. *)
let echo_handler =
  Server.handler_func (fun w r ->
      Body.read_all r.Request.body >>= fun s -> w.Server.write s)

(* ---- Clientserver.get_roundtrip (INTEGRATION SUCCESS CRITERION) ---- *)
(* Server returns 200 + "hello"; Client.get reads status 200 and body "hello". *)
let get_roundtrip () =
  let client ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    Client.get Client.default_client url >>= fun resp ->
    Body.read_all resp.Response.body >>= fun body ->
    Lwt.return (resp.Response.status_code, body)
  in
  let status, body = with_server hello_handler client in
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body" "hello" body

(* ---- Clientserver.post_body ---- *)
(* Server echoes the request body; client POSTs a body and reads it back. *)
let post_body () =
  let payload = "the quick brown fox" in
  let client ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/echo" port in
    Client.post Client.default_client url ~content_type:"text/plain"
      (Body.of_string payload)
    >>= fun resp ->
    Body.read_all resp.Response.body >>= fun body ->
    Lwt.return (resp.Response.status_code, body)
  in
  let status, body = with_server echo_handler client in
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "echoed body" payload body

(* ---- Transport.keepalive_reuse ---- *)
(* Two sequential requests to the same HTTP/1.1 server reuse one connection.
   Reuse is asserted via the transport's own dial counter: with keep-alive, the
   first request dials once and returns the connection to the idle pool; the
   second request pops that idle connection instead of dialing again, so the
   total dial count stays at 1. (Server-side accept counting is harder to
   observe deterministically because the kernel accepts eagerly; the
   transport-side dial count is the authoritative signal that no second
   connection was opened.) *)
let keepalive_reuse () =
  (* A dedicated transport so the dial count is isolated from other tests. *)
  let transport = Transport.create () in
  let c = Client.create ~transport () in
  let client ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    Client.get c url >>= fun resp1 ->
    Body.read_all resp1.Response.body >>= fun b1 ->
    (* The connection must now be idle for reuse. *)
    let dials_after_1 = Transport.dial_count transport in
    Client.get c url >>= fun resp2 ->
    Body.read_all resp2.Response.body >>= fun b2 ->
    let dials_after_2 = Transport.dial_count transport in
    Lwt.return (b1, b2, dials_after_1, dials_after_2)
  in
  let b1, b2, dials_after_1, dials_after_2 = with_server hello_handler client in
  Alcotest.(check string) "resp1 body" "hello" b1;
  Alcotest.(check string) "resp2 body" "hello" b2;
  Alcotest.(check int) "first request dialed once" 1 dials_after_1;
  Alcotest.(check int) "second request reused the connection (no new dial)" 1
    dials_after_2

let tests =
  [
    Alcotest.test_case "get_roundtrip" `Quick get_roundtrip;
    Alcotest.test_case "post_body" `Quick post_body;
    Alcotest.test_case "keepalive_reuse" `Quick keepalive_reuse;
  ]
