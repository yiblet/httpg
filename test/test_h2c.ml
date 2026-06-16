(* End-to-end h2c (HTTP/2 cleartext, prior knowledge) integration tests.

   There is no Go source file: Go's net/http has no h2c (it lives in
   golang.org/x/net/http2/h2c, outside the vendored spec), so this is a
   deliberate deviation. Fidelity here means matching the RFC 9113 §3.3
   prior-knowledge shape: a {b plaintext} listener declared h2c via
   [Server.listen_and_serve_started ~force_h2:true] hands each connection
   straight to the HTTP/2 server (which reads the client preface itself), and the
   client opts in via [Client.get ~force_h2:true] over an ["http"] URL — no TLS,
   no ALPN, no [Upgrade:].

   The roundtrip case performs a GET and a POST over a single multiplexed h2c
   connection and asserts status 200 + body, that the response proto is
   "HTTP/2.0", and that the h2 path (not an h1 fallback) was actually used.
   Bounded by a timeout so a stuck connection fails the test instead of hanging. *)

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

(* A handler: GET -> 200 "hello, h2c"; POST /echo echoes the request body. *)
let test_handler =
 fun ~sw:_ (r : Request.t) ->
  let body =
    match (r.Request.meth, Uri.path r.Request.url) with
    | Httpg_base.Method.Post, "/echo" -> read_body r.Request.body
    | _, _ -> "hello, h2c"
  in
  Response.create () |> Response.with_body_string body

(* Start a plaintext h2c server on an ephemeral port, run [body] with the bound
   port, then close the server. Bounded. *)
let with_h2c_server ?(handler = test_handler) body =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 30. @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let srv, port, serve_loop =
    Server.listen_and_serve_started ~net ~clock ~force_h2:true ~sw
      ~addr:"127.0.0.1" ~port:0 handler
  in
  Eio.Fiber.fork ~sw serve_loop;
  Fun.protect
    ~finally:(fun () -> Server.close srv)
    (fun () -> body ~net ~clock ~sw port)

(* The httpg Client over a cleartext ["http"] URL with [~force_h2:true] speaks
   h2c via prior knowledge and performs GET + POST on one multiplexed conn. *)
let test_h2c_roundtrip () =
  let gc, gproto, gb, pc, pb, h2_count =
    with_h2c_server (fun ~net ~clock ~sw port ->
        let transport = Transport.create ~net ~clock () in
        let client = Client.create ~net ~clock ~transport () in
        let base = Printf.sprintf "http://127.0.0.1:%d" port in
        (* GET *)
        let get_resp =
          ok_resp (Client.get ~force_h2:true ~sw client (base ^ "/hello"))
        in
        let get_body = read_body get_resp.Response.body in
        (* POST, reusing the same h2c connection from the pool. *)
        let post_resp =
          ok_resp
            (Client.post ~force_h2:true ~sw client (base ^ "/echo")
               ~content_type:"text/plain" (Body.of_string "ping-pong"))
        in
        let post_body = read_body post_resp.Response.body in
        ( Httpg_base.Status.to_int get_resp.Response.status,
          get_resp.Response.proto,
          get_body,
          Httpg_base.Status.to_int post_resp.Response.status,
          post_body,
          Transport.h2_round_trip_count transport ))
  in
  Alcotest.(check int) "GET status 200" 200 gc;
  Alcotest.(check string)
    "GET proto is HTTP/2.0" "HTTP/2.0"
    (Httpg_base.Protocol.to_string gproto);
  Alcotest.(check string) "GET body" "hello, h2c" gb;
  Alcotest.(check int) "POST status 200" 200 pc;
  Alcotest.(check string) "POST echoed body" "ping-pong" pb;
  (* Both round trips were genuinely h2c (not an h1 fallback) on one conn. *)
  Alcotest.(check int) "two h2 round trips" 2 h2_count

let tests = [ Alcotest.test_case "h2c_roundtrip" `Slow test_h2c_roundtrip ]
