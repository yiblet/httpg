(* End-to-end ALPN integration tests: a httpg Server over real loopback TLS
   advertising ["h2"; "http/1.1"] is driven by the httpg Client / Transport. The
   roundtrip case performs a GET and a POST over a single multiplexed h2
   connection (asserting status 200 + body and that the h2 path was actually
   used); a second case proves the HTTP/1.1 fallback. Bounded so a hang fails. *)

open Httpg

(* A handler: GET -> 200 "hello, h2"; POST /echo echoes the request body. Works
   identically over h2 and http/1.1. *)
let test_handler =
  Server.handler_func
    (fun (w : Server.response_writer) (r : Body.t Request.t) ->
      match (r.Request.meth, Uri.path r.Request.url) with
      | "POST", "/echo" -> w.Server.write (Body.read_all r.Request.body)
      | _, _ -> w.Server.write "hello, h2")

(* Start a TLS server on an ephemeral port advertising [alpn], run [body] with
   the bound port, then close the server. Bounded. *)
let with_tls_server ?(handler = test_handler) ~alpn body =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 30. @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let certificates = Net.test_server_certificate () in
  let srv, port, serve_loop =
    Server.listen_and_serve_tls_started ~net ~clock ~certificates ~alpn ~sw
      ~addr:"127.0.0.1" ~port:0 handler
  in
  Eio.Fiber.fork ~sw serve_loop;
  Fun.protect
    ~finally:(fun () -> Server.close srv)
    (fun () -> body ~net ~clock ~sw port)

(* TLS server advertises ["h2"; "http/1.1"]; the httpg Client (https) negotiates
   h2 and performs GET + POST on one multiplexed connection. *)
let test_clientserver_roundtrip () =
  let gc, gb, pc, pb, h2_count =
    with_tls_server ~alpn:[ "h2"; "http/1.1" ] (fun ~net ~clock ~sw port ->
        let transport = Transport.create ~net ~clock ~insecure:true () in
        let client = Client.create ~net ~clock ~transport () in
        let base = Printf.sprintf "https://127.0.0.1:%d" port in
        (* GET *)
        let get_resp = Client.get ~sw client (base ^ "/hello") in
        let get_body = Body.read_all get_resp.Response.body in
        (* POST, reusing the same h2 connection from the pool. *)
        let post_resp =
          Client.post ~sw client (base ^ "/echo") ~content_type:"text/plain"
            (Body.String "ping-pong")
        in
        let post_body = Body.read_all post_resp.Response.body in
        ( (Httpg_base.Status.to_int get_resp.Response.status_code),
          get_body,
          (Httpg_base.Status.to_int post_resp.Response.status_code),
          post_body,
          Transport.h2_round_trip_count transport ))
  in
  Alcotest.(check int) "GET status 200" 200 gc;
  Alcotest.(check string) "GET body" "hello, h2" gb;
  Alcotest.(check int) "POST status 200" 200 pc;
  Alcotest.(check string) "POST echoed body" "ping-pong" pb;
  (* Both round trips negotiated h2 on one multiplexed connection. *)
  Alcotest.(check int) "two h2 round trips" 2 h2_count

(* The server advertises only ["http/1.1"], so the httpg Client over TLS is
   served by the HTTP/1.x path and still gets 200 + body (no h2 used). *)
let test_http11_fallback () =
  let code, body, h2_count =
    with_tls_server ~alpn:[ "http/1.1" ] (fun ~net ~clock ~sw port ->
        let transport = Transport.create ~net ~clock ~insecure:true () in
        let client = Client.create ~net ~clock ~transport () in
        let base = Printf.sprintf "https://127.0.0.1:%d" port in
        let resp = Client.get ~sw client (base ^ "/hello") in
        let body = Body.read_all resp.Response.body in
        ( (Httpg_base.Status.to_int resp.Response.status_code),
          body,
          Transport.h2_round_trip_count transport ))
  in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check string) "body" "hello, h2" body;
  Alcotest.(check int) "no h2 round trips (fell back to http/1.1)" 0 h2_count

(* F032 regression: N concurrent fibers issuing GET/POSTs over the public
   Client/Transport multiplex onto ONE pooled h2 conn and all complete cleanly
   (no Stream_aborted). Proves both fixes: the client awaits an open stream slot,
   and concurrent cold-start dials share a single conn (dials = 1). *)
let test_concurrent_multiplexing_one_conn () =
  let n = 16 in
  let handler =
    Server.handler_func
      (fun (w : Server.response_writer) (r : Body.t Request.t) ->
        let _ = Body.read_all r.Request.body in
        let path = Uri.path r.Request.url in
        w.Server.write
          ((if r.Request.meth = "POST" then "post:" else "get:") ^ path))
  in
  let dials, h2_count, results =
    with_tls_server ~handler ~alpn:[ "h2"; "http/1.1" ]
      (fun ~net ~clock ~sw port ->
        let transport = Transport.create ~net ~clock ~insecure:true () in
        let client = Client.create ~net ~clock ~transport () in
        let base = Printf.sprintf "https://127.0.0.1:%d" port in
        let do_rt i =
          let path = Printf.sprintf "/p%d" i in
          let resp =
            if i mod 3 = 0 then
              Client.post ~sw client (base ^ path) ~content_type:"text/plain"
                (Body.String "ping")
            else Client.get ~sw client (base ^ path)
          in
          ((Httpg_base.Status.to_int resp.Response.status_code), Body.read_all resp.Response.body, i)
        in
        let results = Eio.Fiber.List.map do_rt (List.init n (fun i -> i + 1)) in
        ( Transport.dial_count transport,
          Transport.h2_round_trip_count transport,
          results ))
  in
  List.iter
    (fun (code, body, i) ->
      Alcotest.(check int) (Printf.sprintf "s%d status" i) 200 code;
      let want =
        (if i mod 3 = 0 then "post:/p" else "get:/p") ^ string_of_int i
      in
      Alcotest.(check string) (Printf.sprintf "s%d body" i) want body)
    results;
  Alcotest.(check int) "all multiplexed on one conn" 1 dials;
  Alcotest.(check int) "h2 round trips" n h2_count

(* F027: a pooled h2 conn that races into closed/closing when reused must be
   evicted and the (untouched) request replayed on a fresh dial — a transparent
   success, not an escaping exception. We seed a pooled conn with a first GET,
   then a one-shot fault hook closes that pooled conn just before the second GET
   reuses it, forcing the Conn_unusable race; the retry must re-dial (dials goes
   1 -> 2) and return 200. The hook self-clears, so the retry can't re-trigger
   it (no infinite retry). *)
let test_h2_dead_pooled_conn_redials_and_retries () =
  let code, body, dials, fired =
    with_tls_server ~alpn:[ "h2"; "http/1.1" ] (fun ~net ~clock ~sw port ->
        let transport = Transport.create ~net ~clock ~insecure:true () in
        let client = Client.create ~net ~clock ~transport () in
        let base = Printf.sprintf "https://127.0.0.1:%d" port in
        (* 1) prime the pool with a live h2 conn. *)
        let r1 = Client.get ~sw client (base ^ "/a") in
        let _ = Body.read_all r1.Response.body in
        let d1 = Transport.dial_count transport in
        (* 2) one-shot: close the pooled conn in place right before reuse, so
           round_trip sees closing -> Conn_unusable -> evict + retry. *)
        let fired = ref 0 in
        Transport.set_before_h2_round_trip transport (fun () ->
            incr fired;
            Transport.set_before_h2_round_trip transport (fun () -> ());
            Transport.close_pooled_h2_conn transport ~host:"127.0.0.1" ~port);
        let r2 = Client.get ~sw client (base ^ "/b") in
        let b2 = Body.read_all r2.Response.body in
        ( (Httpg_base.Status.to_int r2.Response.status_code),
          b2,
          (d1, Transport.dial_count transport),
          !fired ))
  in
  let d1, d2 = dials in
  Alcotest.(check int) "retry returned 200" 200 code;
  Alcotest.(check string) "retry returned the body" "hello, h2" body;
  Alcotest.(check int) "fault hook fired exactly once" 1 fired;
  Alcotest.(check int) "first request dialed once" 1 d1;
  (* the retry re-dialed a fresh conn (no escaping exception). *)
  Alcotest.(check int) "retry re-dialed a fresh conn" 2 d2

(* ---- F035: the h2 pool dials a second conn per authority when saturated ----

   To force saturation deterministically the test server advertises a tiny
   SETTINGS_MAX_CONCURRENT_STREAMS, which the public {!Server} doesn't expose, so
   we run {!Httpg_http2.H2_server.serve} directly over a TLS+ALPN accept loop with
   an inline {!Httpg_http2.Api.handler}. The handler blocks at a barrier until
   [n] requests have arrived concurrently, then releases them — so with capacity
   [< n] the client cannot serialize them onto one conn and must scale out. *)
module H2_server = Httpg_http2.H2_server
module H2_api = Httpg_http2.Api

(* A TLS server advertising "h2" with [max_concurrent_streams], serving each
   accepted h2 connection with [handler] (an Api.handler). Returns the bound
   port to [body]; bounded. *)
let with_tls_h2_server ~max_concurrent_streams ~handler body =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 30. @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let certificates = Net.test_server_certificate () in
  let tls_srv =
    Net.listen_tls ~sw ~certificates ~alpn:[ "h2"; "http/1.1" ] net "127.0.0.1"
      0
  in
  let listen_sock = Net.tls_listen_sock tls_srv in
  let port = Net.bound_port listen_sock in
  (* Accept loop + per-conn serve fibers run as DAEMONS under [srv_sw]: each conn
     handshakes via accept_tls then runs H2_server.serve with the small advertised
     limit. Because they are daemons, [body] returning lets [Switch.run srv_sw]
     finish (cancelling the lingering server loops) instead of blocking on them. *)
  let rec accept_loop srv_sw =
    let flow, _peer = Net.accept ~sw:srv_sw listen_sock in
    (* Serve each conn in a DAEMON fiber so tearing down [srv_sw] (after [body]
       returns) cancels lingering serve loops instead of blocking on them. *)
    Eio.Fiber.fork_daemon ~sw:srv_sw (fun () ->
        (try
           Net.accept_tls tls_srv flow (fun ~proto r w ->
               match proto with
               | Some "h2" ->
                   H2_server.serve ~max_concurrent_streams r w ~handler
               | _ -> ())
         with _ -> ());
        `Stop_daemon);
    accept_loop srv_sw
  in
  Eio.Switch.run @@ fun srv_sw ->
  Eio.Fiber.fork_daemon ~sw:srv_sw (fun () -> accept_loop srv_sw);
  body ~net ~clock ~sw port

(* A barrier handler over [n]: each request bumps an arrival counter, broadcasts,
   waits until all [n] have arrived, then replies "ok". Forces [n] concurrent
   in-flight streams so a small per-conn limit can't serialize them. *)
let barrier_handler n : H2_api.handler =
  let mutex = Eio.Mutex.create () in
  let cond = Eio.Condition.create () in
  let arrived = ref 0 in
  fun (w : H2_api.response_writer) (_r : H2_api.server_request) ->
    Eio.Mutex.use_rw ~protect:false mutex (fun () ->
        incr arrived;
        Eio.Condition.broadcast cond;
        while !arrived < n do
          Eio.Condition.await cond mutex
        done);
    w.H2_api.rw_write "ok";
    w.H2_api.rw_flush ()

(* With MAX_CONCURRENT_STREAMS = 1 and 3 concurrent requests, one conn can hold
   only one in-flight stream, so the barrier (all 3 must arrive together) can
   only be satisfied if the pool dials additional conns. Assert it scales out to
   3 conns / 3 dials and every request still completes 200 "ok"
   (client_conn_pool.go:51-85). *)
let test_h2_pool_scales_out_when_saturated () =
  let n = 3 in
  let dials, conns, results =
    with_tls_h2_server ~max_concurrent_streams:1 ~handler:(barrier_handler n)
      (fun ~net ~clock ~sw port ->
        let transport = Transport.create ~net ~clock ~insecure:true () in
        let client = Client.create ~net ~clock ~transport () in
        let base = Printf.sprintf "https://127.0.0.1:%d" port in
        let do_rt i =
          let resp = Client.get ~sw client (Printf.sprintf "%s/p%d" base i) in
          ((Httpg_base.Status.to_int resp.Response.status_code), Body.read_all resp.Response.body)
        in
        let results = Eio.Fiber.List.map do_rt (List.init n (fun i -> i + 1)) in
        ( Transport.dial_count transport,
          Transport.h2_conn_count transport ~host:"127.0.0.1" ~port,
          results ))
  in
  List.iteri
    (fun i (code, body) ->
      Alcotest.(check int) (Printf.sprintf "req %d status" i) 200 code;
      Alcotest.(check string) (Printf.sprintf "req %d body" i) "ok" body)
    results;
  (* All [n] were in flight at once; capacity 1/conn => one conn per request. *)
  Alcotest.(check int) "pool dialed a conn per saturated request" n dials;
  Alcotest.(check int) "pool holds n conns for the authority" n conns

(* Below saturation: a generous MAX_CONCURRENT_STREAMS lets all [n] concurrent
   requests multiplex onto ONE conn, so the pool must NOT dial extra conns. *)
let test_h2_pool_single_conn_below_saturation () =
  let n = 4 in
  let dials, conns, codes =
    with_tls_h2_server ~max_concurrent_streams:100 ~handler:(barrier_handler n)
      (fun ~net ~clock ~sw port ->
        let transport = Transport.create ~net ~clock ~insecure:true () in
        let client = Client.create ~net ~clock ~transport () in
        let base = Printf.sprintf "https://127.0.0.1:%d" port in
        let do_rt i =
          let resp = Client.get ~sw client (Printf.sprintf "%s/p%d" base i) in
          let _ = Body.read_all resp.Response.body in
          (Httpg_base.Status.to_int resp.Response.status_code)
        in
        let codes = Eio.Fiber.List.map do_rt (List.init n (fun i -> i + 1)) in
        ( Transport.dial_count transport,
          Transport.h2_conn_count transport ~host:"127.0.0.1" ~port,
          codes ))
  in
  List.iter (fun c -> Alcotest.(check int) "status" 200 c) codes;
  Alcotest.(check int) "one shared conn below saturation" 1 dials;
  Alcotest.(check int) "one pooled conn for the authority" 1 conns

let tests =
  [
    Alcotest.test_case "clientserver_roundtrip" `Quick
      test_clientserver_roundtrip;
    Alcotest.test_case "h2_pool_scales_out_when_saturated" `Quick
      test_h2_pool_scales_out_when_saturated;
    Alcotest.test_case "h2_pool_single_conn_below_saturation" `Quick
      test_h2_pool_single_conn_below_saturation;
    Alcotest.test_case "h2_dead_pooled_conn_redials_and_retries" `Quick
      test_h2_dead_pooled_conn_redials_and_retries;
    Alcotest.test_case "http11_fallback" `Quick test_http11_fallback;
    Alcotest.test_case "concurrent_multiplexing_one_conn" `Quick
      test_concurrent_multiplexing_one_conn;
  ]
