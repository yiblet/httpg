(* Integration tests for the loopback [Httptest.Server], a ported subset of
   go/src/net/http/httptest/server_test.go and httptest_test.go.

   Each test starts an ephemeral loopback test server, drives it with the httpg
   [Client] returned by [Httptest.Server.client], and closes the server at the
   end. Bounded by Test_harness.with_env. *)

open Httpg
module Ts = Httptest.Server

(* ---- HttptestServer.server_get ---- *)
let server_get () =
  let handler =
   fun ~sw:_ r ->
    Response.create () |> Response.with_body_string (Uri.path r.Request.url)
  in
  let status, body =
    Test_harness.with_env (fun ~net ~clock ~sw ->
        let s = Ts.new_server ~net ~clock ~sw handler in
        Fun.protect
          ~finally:(fun () -> Ts.close s)
          (fun () ->
            let c = Ts.client s in
            let resp = Client.get ~sw c (Ts.url s ^ "/foo") in
            ( Httpg_base.Status.to_int resp.Response.status,
              Body.read_all resp.Response.body )))
  in
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body is request path" "/foo" body

(* ---- HttptestServer.server_tls ---- *)
let server_tls () =
  let handler =
   fun ~sw:_ _r -> Response.with_body_string "hello" (Response.create ())
  in
  let status, body, url =
    Test_harness.with_env ~secs:15. (fun ~net ~clock ~sw ->
        let s = Ts.new_tls_server ~net ~clock ~sw handler in
        Fun.protect
          ~finally:(fun () -> Ts.close s)
          (fun () ->
            let c = Ts.client s in
            let resp = Client.get ~sw c (Ts.url s) in
            ( Httpg_base.Status.to_int resp.Response.status,
              Body.read_all resp.Response.body,
              Ts.url s )))
  in
  Alcotest.(check bool)
    "url is https" true
    (String.length url >= 8 && String.sub url 0 8 = "https://");
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body" "hello" body

(* ---- HttptestServer.server_close ---- *)
(* After [close], a fresh connect to the (now-unbound) port must fail (refused).
   We serve once before close, capture the port, close, then connect afresh. *)
let server_close () =
  let handler =
   fun ~sw:_ _r -> Response.with_body_string "hi" (Response.create ())
  in
  let pre_status, refused =
    Test_harness.with_env (fun ~net ~clock ~sw ->
        let s = Ts.new_server ~net ~clock ~sw handler in
        let port = Ts.port s in
        let c = Ts.client s in
        let resp = Client.get ~sw c (Ts.url s) in
        ignore (Body.drain resp.Response.body);
        Ts.close s;
        (* a fresh connect to the closed port must fail (refused). *)
        let refused =
          try
            Eio.Switch.run (fun sw ->
                let _ = Net.connect ~sw net ~host:"127.0.0.1" ~port in
                false)
          with _ -> true
        in
        (Httpg_base.Status.to_int resp.Response.status, refused))
  in
  Alcotest.(check int) "served 200 before close" 200 pre_status;
  Alcotest.(check bool) "connect refused after close" true refused

let tests =
  [
    Alcotest.test_case "server_get" `Quick server_get;
    Alcotest.test_case "server_tls" `Quick server_tls;
    Alcotest.test_case "server_close" `Quick server_close;
  ]
