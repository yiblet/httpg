(* End-to-end ALPN integration tests (H2 Ticket 10): a httpg Server over real
   loopback TLS advertising ["h2"; "http/1.1"] is driven by the httpg Client /
   Transport. The Success Criterion [clientserver_roundtrip] performs a GET and a
   POST over a single multiplexed h2 connection (asserting status 200 + body and
   that the h2 path was actually used); a second case proves the HTTP/1.1
   fallback. All bounded by Net.with_timeout so a hang fails. *)

open Httpg

let ( let* ) = Lwt.bind

(* A ServeMux-style handler: GET /hello -> 200 "hello, h2"; POST /echo echoes the
   request body. Works identically over h2 and http/1.1. *)
let test_handler =
  Server.handler_func
    (fun (w : Server.response_writer) (r : Body.t Request.t) ->
      match (r.Request.meth, Uri.path r.Request.url) with
      | "POST", "/echo" ->
          let* body = Body.read_all r.Request.body in
          w.Server.write body
      | _, _ -> w.Server.write "hello, h2")

(* Start a TLS server on an ephemeral port advertising [alpn], run [body] with
   the bound port, then close the server. Bounded. *)
let with_tls_server ~alpn body =
  Lwt_main.run
    (Net.with_timeout 30.
       (let certificates = Net.test_server_certificate () in
        let* srv, port, serve_loop =
          Server.listen_and_serve_tls_started ~certificates ~alpn
            ~addr:"127.0.0.1" ~port:0 test_handler
        in
        Lwt.async (fun () ->
            Lwt.catch (fun () -> serve_loop) (fun _ -> Lwt.return_unit));
        Lwt.finalize (fun () -> body port) (fun () -> Server.close srv)))

(* ---- Success Criterion: H2.clientserver_roundtrip ---- *)
(* TLS server advertises ["h2"; "http/1.1"]; the httpg Client (https) negotiates
   h2 and performs GET + POST on one multiplexed connection. *)
let test_clientserver_roundtrip () =
  with_tls_server ~alpn:[ "h2"; "http/1.1" ] (fun port ->
      let transport = Transport.create ~insecure:true () in
      let client = Client.create ~transport () in
      let base = Printf.sprintf "https://127.0.0.1:%d" port in
      (* GET *)
      let* get_resp = Client.get client (base ^ "/hello") in
      let* get_body = Body.read_all get_resp.Response.body in
      (* POST, reusing the same h2 connection from the pool. *)
      let* post_resp =
        Client.post client (base ^ "/echo") ~content_type:"text/plain"
          (Body.String "ping-pong")
      in
      let* post_body = Body.read_all post_resp.Response.body in
      let h2_count = Transport.h2_round_trip_count transport in
      Lwt.return
        ( get_resp.Response.status_code,
          get_body,
          post_resp.Response.status_code,
          post_body,
          h2_count ))
  |> fun (gc, gb, pc, pb, h2_count) ->
  Alcotest.(check int) "GET status 200" 200 gc;
  Alcotest.(check string) "GET body" "hello, h2" gb;
  Alcotest.(check int) "POST status 200" 200 pc;
  Alcotest.(check string) "POST echoed body" "ping-pong" pb;
  (* Both round trips negotiated h2 on one multiplexed connection. *)
  Alcotest.(check int) "two h2 round trips" 2 h2_count

(* ---- Fallback: client/server only http/1.1 ---- *)
(* The server advertises only ["http/1.1"], so the httpg Client over TLS is
   served by the HTTP/1.x path and still gets 200 + body (no h2 used). *)
let test_http11_fallback () =
  with_tls_server ~alpn:[ "http/1.1" ] (fun port ->
      let transport = Transport.create ~insecure:true () in
      let client = Client.create ~transport () in
      let base = Printf.sprintf "https://127.0.0.1:%d" port in
      let* resp = Client.get client (base ^ "/hello") in
      let* body = Body.read_all resp.Response.body in
      Lwt.return
        ( resp.Response.status_code,
          body,
          Transport.h2_round_trip_count transport ))
  |> fun (code, body, h2_count) ->
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check string) "body" "hello, h2" body;
  Alcotest.(check int) "no h2 round trips (fell back to http/1.1)" 0 h2_count

let tests =
  [
    Alcotest.test_case "clientserver_roundtrip" `Quick
      test_clientserver_roundtrip;
    Alcotest.test_case "http11_fallback" `Quick test_http11_fallback;
  ]
