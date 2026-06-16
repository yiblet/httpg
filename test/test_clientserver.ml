(* Integration tests for the HTTP/1.x Client + Transport, a ported subset of
   go/src/net/http/clientserver_test.go and client_test.go.

   Each test starts a real loopback Server on an ephemeral port via
   [Server.listen_and_serve_started] and drives it with the httpg [Client]. The
   whole run is bounded by a timeout (Test_harness.with_env) so a hang fails
   rather than blocks. *)

open Httpg

(* Unwrap a happy-path client result, failing the test on a transport/redirect
   error. *)
let ok_resp = function
  | Ok resp -> resp
  | Error e -> Alcotest.failf "client: %s" (Client.error_to_string e)

let read_body b =
  match Body.read_all b with
  | Ok s -> s
  | Error e -> Alcotest.failf "body: %s" (Body.error_to_string e)

(* Start a server with [handler], run [client ~net ~sw ~clock ~port] against it,
   stop it. The accept loop runs in a fiber under the env switch. *)
let with_server handler client =
  Test_harness.with_env (fun ~net ~clock ~sw ->
      let srv, port, serve_loop =
        Server.listen_and_serve_started ~net ~clock ~sw ~addr:"127.0.0.1"
          ~port:0 handler
      in
      Eio.Fiber.fork ~sw serve_loop;
      Fun.protect
        (fun () -> client ~net ~sw ~clock ~port)
        ~finally:(fun () -> Server.close srv))

(* ---- handlers ---- *)

let hello_handler =
 fun ~sw:_ _r -> Response.create () |> Response.with_body_string "hello"

(* Echo the request body back in the response. *)
let echo_handler =
 fun ~sw:_ r ->
  Response.create () |> Response.with_body_string (read_body r.Request.body)

(* ---- Clientserver.get_roundtrip ---- *)
(* Server returns 200 + "hello"; Client.get reads status 200 and body "hello". *)
let get_roundtrip () =
  let client ~net ~sw ~clock ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    let resp = ok_resp (Client.get ~sw (Client.create ~net ~clock ()) url) in
    ( Httpg_base.Status.to_int resp.Response.status,
      read_body resp.Response.body )
  in
  let status, body = with_server hello_handler client in
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body" "hello" body

(* ---- Clientserver.post_body ---- *)
let post_body () =
  let payload = "the quick brown fox" in
  let client ~net ~sw ~clock ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/echo" port in
    let resp =
      ok_resp
        (Client.post ~sw
           (Client.create ~net ~clock ())
           url ~content_type:"text/plain" (Body.of_string payload))
    in
    ( Httpg_base.Status.to_int resp.Response.status,
      read_body resp.Response.body )
  in
  let status, body = with_server echo_handler client in
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "echoed body" payload body

(* ---- Transport.keepalive_reuse ---- *)
(* Two sequential requests to one HTTP/1.1 server reuse one connection, asserted
   via the transport's dial counter. *)
let keepalive_reuse () =
  let client ~net ~sw ~clock ~port =
    let transport = Transport.create ~net ~clock () in
    let c = Client.create ~net ~clock ~transport () in
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    let resp1 = ok_resp (Client.get ~sw c url) in
    let b1 = read_body resp1.Response.body in
    let dials_after_1 = Transport.dial_count transport in
    let resp2 = ok_resp (Client.get ~sw c url) in
    let b2 = read_body resp2.Response.body in
    let dials_after_2 = Transport.dial_count transport in
    (b1, b2, dials_after_1, dials_after_2)
  in
  let b1, b2, dials_after_1, dials_after_2 = with_server hello_handler client in
  Alcotest.(check string) "resp1 body" "hello" b1;
  Alcotest.(check string) "resp2 body" "hello" b2;
  Alcotest.(check int) "first request dialed once" 1 dials_after_1;
  Alcotest.(check int)
    "second request reused the connection (no new dial)" 1 dials_after_2

(* ---- F006: TLS handshake failure is a typed, handleable boundary error ---- *)
(* A TLS server with the self-signed [test_server_certificate], reached by a
   Client WITHOUT [~insecure], must surface the TLS failure as the typed result
   [Error (Client.Round_trip (Transport.Net (Net.Tls _)))] (the analogue of Go's
   tls.Conn.Handshake error propagated through RoundTrip and Client.Do) -- a
   catchable typed value, not a raise. The [~insecure] client to the same server
   still succeeds (secure-default rejects, opt-out accepts). *)
let tls_handshake_failure_is_typed () =
  Test_harness.with_env (fun ~net ~clock ~sw ->
      let srv = Httptest.Server.new_tls_server ~net ~clock ~sw hello_handler in
      let url = Httptest.Server.url srv ^ "/" in
      Fun.protect
        ~finally:(fun () -> Httptest.Server.close srv)
        (fun () ->
          (* Secure default: untrusted self-signed cert -> typed Round_trip Tls
             error (asserts the Client.Round_trip arm). *)
          let secure = Client.create ~net ~clock () in
          (match Client.get ~sw secure url with
          | Error (Client.Round_trip (Transport.Net (Net.Tls _))) -> ()
          | Error e ->
              Alcotest.failf
                "expected Error (Round_trip (Net (Tls _))), got Error %s"
                (Client.error_to_string e)
          | Ok _ ->
              Alcotest.fail
                "expected Error (Round_trip (Net (Tls _))), got a response");
          (* Opt-out: ~insecure still completes the handshake and round trips. *)
          let insecure = Client.create ~net ~clock ~insecure:true () in
          let resp = ok_resp (Client.get ~sw insecure url) in
          ( Httpg_base.Status.to_int resp.Response.status,
            read_body resp.Response.body )))
  |> fun (code, body) ->
  Alcotest.(check int) "insecure status" 200 code;
  Alcotest.(check string) "insecure body" "hello" body

(* ---- Phase 3: Transport.round_trip returns a typed result at the boundary ---- *)

(* A request whose URL carries no Host is [Error No_host] (Go's errMissingHost),
   asserted directly at the Transport boundary (not via the raising Client). *)
let round_trip_no_host_is_error () =
  Test_harness.with_env (fun ~net ~clock ~sw ->
      let transport = Transport.create ~net ~clock () in
      Transport.run transport ~sw (fun () ->
          let req = Request.make "/path-only-no-host" in
          match Transport.round_trip transport req with
          | Error Transport.No_host -> ()
          | Error e ->
              Alcotest.failf "expected Error No_host, got Error %s"
                (Transport.error_to_string e)
          | Ok _ -> Alcotest.fail "expected Error No_host, got Ok"))

(* A TLS server with a self-signed cert, dialed WITHOUT [~insecure], is
   [Error (Net (Net.Tls _))] at the Transport boundary (Go's tls.Conn.Handshake
   error propagated through RoundTrip). *)
let round_trip_tls_failure_is_error () =
  Test_harness.with_env (fun ~net ~clock ~sw ->
      let srv = Httptest.Server.new_tls_server ~net ~clock ~sw hello_handler in
      let url = Httptest.Server.url srv ^ "/" in
      Fun.protect
        ~finally:(fun () -> Httptest.Server.close srv)
        (fun () ->
          let transport = Transport.create ~net ~clock () in
          Transport.run transport ~sw (fun () ->
              let req = Request.make url in
              match Transport.round_trip transport req with
              | Error (Transport.Net (Net.Tls _)) -> ()
              | Error e ->
                  Alcotest.failf "expected Error (Net (Tls _)), got Error %s"
                    (Transport.error_to_string e)
              | Ok _ -> Alcotest.fail "expected Error (Net (Tls _)), got Ok")))

let tests =
  [
    Alcotest.test_case "get_roundtrip" `Quick get_roundtrip;
    Alcotest.test_case "post_body" `Quick post_body;
    Alcotest.test_case "keepalive_reuse" `Quick keepalive_reuse;
    Alcotest.test_case "round_trip_no_host_is_error" `Quick
      round_trip_no_host_is_error;
    Alcotest.test_case "round_trip_tls_failure_is_error" `Slow
      round_trip_tls_failure_is_error;
    Alcotest.test_case "tls_handshake_failure_is_typed" `Slow
      tls_handshake_failure_is_typed;
  ]
