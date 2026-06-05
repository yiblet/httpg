(* Integration tests for the loopback [Httptest.Server] (Tier 1, Ticket 2), a
   ported subset of go/src/net/http/httptest/server_test.go and
   httptest_test.go.

   Each test starts an ephemeral loopback test server, drives it with the
   gohttp [Client] returned by [Httptest.Server.client], and closes the server
   at the end. The whole run is bounded by [Net.with_timeout] so a hang fails
   rather than blocks the suite. *)

open Gohttp
open Lwt.Infix
module Ts = Httptest.Server

(* ---- HttptestServer.server_get ---- *)
(* Go's TestServer: a handler writes the request path; [client] GET <url>/foo
   returns 200 and body "/foo". *)
let server_get () =
  let handler =
    Server.handler_func (fun w r -> w.Server.write (Uri.path r.Request.url))
  in
  let run () =
    Ts.new_server handler >>= fun s ->
    Lwt.finalize
      (fun () ->
        let c = Ts.client s in
        Client.get c (Ts.url s ^ "/foo") >>= fun resp ->
        Body.read_all resp.Response.body >>= fun body ->
        Lwt.return (resp.Response.status_code, body))
      (fun () -> Ts.close s)
  in
  let status, body = Lwt_main.run (Net.with_timeout 10. (run ())) in
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body is request path" "/foo" body

(* ---- HttptestServer.server_tls ---- *)
(* Go's testServerClient: NewTLSServer + its Client() round-trips over https,
   returning 200 + "hello" with no cert warning (the client trusts the
   self-signed cert via ~insecure). *)
let server_tls () =
  let handler = Server.handler_func (fun w _r -> w.Server.write "hello") in
  let run () =
    Ts.new_tls_server handler >>= fun s ->
    Lwt.finalize
      (fun () ->
        let c = Ts.client s in
        Client.get c (Ts.url s) >>= fun resp ->
        Body.read_all resp.Response.body >>= fun body ->
        Lwt.return (resp.Response.status_code, body, Ts.url s))
      (fun () -> Ts.close s)
  in
  let status, body, url = Lwt_main.run (Net.with_timeout 15. (run ())) in
  Alcotest.(check bool)
    "url is https" true
    (String.length url >= 8 && String.sub url 0 8 = "https://");
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body" "hello" body

(* ---- HttptestServer.server_close ---- *)
(* Go's testServerCloseClientConnections / Close semantics: after [close], a
   fresh connect to the (now unbound) port fails or times out rather than
   completing a request. We capture the port before closing, close the server,
   then attempt a fresh TCP connect: it must raise (connection refused) within
   the bound. *)
let server_close () =
  let handler = Server.handler_func (fun w _r -> w.Server.write "hi") in
  let run () =
    Ts.new_server handler >>= fun s ->
    let port = Ts.port s in
    (* Sanity: it serves before close. *)
    let c = Ts.client s in
    Client.get c (Ts.url s) >>= fun resp ->
    Body.drain resp.Response.body >>= fun _ ->
    Ts.close s >>= fun () ->
    (* A fresh connect to the now-closed port must fail (refused). *)
    Lwt.catch
      (fun () ->
        Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
        Lwt_io.close ic >>= fun () ->
        Lwt_io.close oc >>= fun () ->
        Lwt.return (resp.Response.status_code, false))
      (fun _ -> Lwt.return (resp.Response.status_code, true))
  in
  let pre_status, refused = Lwt_main.run (Net.with_timeout 10. (run ())) in
  Alcotest.(check int) "served 200 before close" 200 pre_status;
  Alcotest.(check bool) "connect refused after close" true refused

let tests =
  [
    Alcotest.test_case "server_get" `Quick server_get;
    Alcotest.test_case "server_tls" `Quick server_tls;
    Alcotest.test_case "server_close" `Quick server_close;
  ]
