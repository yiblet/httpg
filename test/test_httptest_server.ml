(* Integration tests for the loopback [Httptest.Server], a ported subset of
   go/src/net/http/httptest/server_test.go and httptest_test.go.

   Each test starts an ephemeral loopback test server, drives it with the httpg
   [Client] returned by [Httptest.Server.client], and closes the server at the
   end. Bounded by Test_harness.with_env. *)

open Httpg
module Ts = Httptest.Server

(* Unwrap a happy-path client result, failing the test on a transport/redirect
   error. *)
let ok_resp = function
  | Ok resp -> resp
  | Error e -> Alcotest.failf "client: %s" (Client.error_to_string e)

let read_body b =
  match Body.read_all b with
  | Ok s -> s
  | Error e -> Alcotest.failf "body: %s" (Body.error_to_string e)

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
            let resp = ok_resp (Client.get ~sw c (Ts.url s ^ "/foo")) in
            ( Httpg_base.Status.to_int resp.Response.status,
              read_body resp.Response.body )))
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
            let resp = ok_resp (Client.get ~sw c (Ts.url s)) in
            ( Httpg_base.Status.to_int resp.Response.status,
              read_body resp.Response.body,
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
        let resp = ok_resp (Client.get ~sw c (Ts.url s)) in
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

(* ---- HttptestServer.in_memory_get ---- *)
(* The in-memory server uses the socketpair fakenet: no loopback, no port. The
   full HTTP/1 stack still round-trips client <-> server. *)
let in_memory_get () =
  let handler =
   fun ~sw:_ r ->
    Response.create () |> Response.with_body_string (Uri.path r.Request.url)
  in
  let status, body, url, port =
    Test_harness.with_env (fun ~net:_ ~clock ~sw ->
        let s = Ts.new_test_server ~sw ~clock handler in
        Fun.protect
          ~finally:(fun () -> Ts.close s)
          (fun () ->
            let c = Ts.client s in
            let resp = ok_resp (Client.get ~sw c (Ts.url s ^ "/echo")) in
            ( Httpg_base.Status.to_int resp.Response.status,
              read_body resp.Response.body,
              Ts.url s,
              Ts.port s )))
  in
  Alcotest.(check string)
    "url is example.com (no port)" "http://example.com" url;
  Alcotest.(check int) "no real port" 0 port;
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body is request path" "/echo" body

(* ---- HttptestServer.in_memory_tls_get ---- *)
(* TLS (and ALPN) over the in-memory connection. *)
let in_memory_tls_get () =
  let handler =
   fun ~sw:_ _r -> Response.with_body_string "hello" (Response.create ())
  in
  let status, body, url =
    Test_harness.with_env ~secs:15. (fun ~net:_ ~clock ~sw ->
        let s = Ts.new_test_tls_server ~sw ~clock handler in
        Fun.protect
          ~finally:(fun () -> Ts.close s)
          (fun () ->
            let c = Ts.client s in
            let resp = ok_resp (Client.get ~sw c (Ts.url s)) in
            ( Httpg_base.Status.to_int resp.Response.status,
              read_body resp.Response.body,
              Ts.url s )))
  in
  Alcotest.(check string) "url is https example.com" "https://example.com" url;
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body" "hello" body

(* ---- HttptestServer.in_memory_h2 ---- *)
(* The TLS in-memory server advertises ALPN h2+http/1.1 and the default https
   client offers the same, so the exchange runs over HTTP/2 -- proving the full
   h2 stack works over the in-memory connection (Go enables h2 on its fakenet
   test server). *)
let in_memory_h2 () =
  let handler =
   fun ~sw:_ _r -> Response.with_body_string "h2 ok" (Response.create ())
  in
  let proto, status, body =
    Test_harness.with_env ~secs:15. (fun ~net:_ ~clock ~sw ->
        let s = Ts.new_test_tls_server ~sw ~clock handler in
        Fun.protect
          ~finally:(fun () -> Ts.close s)
          (fun () ->
            let c = Ts.client s in
            let resp = ok_resp (Client.get ~sw c (Ts.url s)) in
            ( Httpg_base.Protocol.to_string resp.Response.proto,
              Httpg_base.Status.to_int resp.Response.status,
              read_body resp.Response.body )))
  in
  Alcotest.(check string) "negotiated HTTP/2 over in-memory" "HTTP/2.0" proto;
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body" "h2 ok" body

let tests =
  [
    Alcotest.test_case "server_get" `Quick server_get;
    Alcotest.test_case "server_tls" `Slow server_tls;
    Alcotest.test_case "server_close" `Quick server_close;
    Alcotest.test_case "in_memory_get" `Quick in_memory_get;
    Alcotest.test_case "in_memory_tls_get" `Slow in_memory_tls_get;
    Alcotest.test_case "in_memory_h2" `Slow in_memory_h2;
  ]
