(* Integration tests for Httpg_http2.H2_transport: connect an H2_transport
   client_conn to H2_server.serve (Ticket 8) over a real loopback TCP socket
   pair, performing GET / POST / concurrent round trips. Ported subset of
   go/src/net/http/internal/http2/transport_test.go (TestTransport / GET, POST,
   concurrent streams). Bounded by a timeout so a hang fails. *)

open Httpg_http2
module F = H2_frame

let mk_request ~meth ~path ?(body = Api.Body.Empty) () : Api.client_request =
  let content_length =
    match body with
    | Api.Body.String s -> Int64.of_int (String.length s)
    | _ -> 0L
  in
  {
    Api.creq_meth = Httpg_base.Method.of_string meth;
    creq_url = Uri.of_string ("https://example.com" ^ path);
    creq_header = Api.Header.create ();
    creq_trailer = Api.Header.create ();
    creq_body = body;
    creq_host = "";
    creq_content_length = content_length;
    creq_close = false;
  }

(* Run [client cc] against an H2_server.serve over a real loopback socket pair,
   bounded. The server runs [handler]. *)
let run ~handler client = H2_test_util.with_h2_server ~handler client

(* round_trip now returns a typed result; for the happy-path tests unwrap it,
   failing the test on any Error arm. *)
let rt ?sw cc req =
  match H2_transport.round_trip ?sw cc req with
  | Ok r -> r
  | Error e -> Alcotest.failf "h2: %s" (H2_transport.error_to_string e)

(* ---- TestTransport: simple GET, 200 + "hello" body ---- *)
let test_get () =
  let handler (rw : H2_server.response_writer) (_req : Api.server_request) =
    rw.rw_write "hello";
    rw.rw_flush ()
  in
  let client cc =
    let req = mk_request ~meth:"GET" ~path:"/" () in
    let resp = rt cc req in
    let body = Api.Body.read_all resp.cres_body in
    (Httpg_base.Status.to_int resp.cres_status_code, body)
  in
  let code, body = run ~handler client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check string) "body hello" "hello" body

(* ---- TestTransport POST echo ---- *)
let test_post_echo () =
  let handler (rw : H2_server.response_writer) (req : Api.server_request) =
    let body = Api.Body.read_all req.sreq_body in
    rw.rw_write body;
    rw.rw_flush ()
  in
  let client cc =
    let req =
      mk_request ~meth:"POST" ~path:"/echo" ~body:(Api.Body.String "ping") ()
    in
    let resp = rt cc req in
    let body = Api.Body.read_all resp.cres_body in
    (Httpg_base.Status.to_int resp.cres_status_code, body)
  in
  let code, body = run ~handler client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check string) "echo ping" "ping" body

(* ---- TestTransport two concurrent round trips on one ClientConn ---- *)
let test_concurrent () =
  let handler (rw : H2_server.response_writer) (req : Api.server_request) =
    let path = Uri.path req.sreq_url in
    rw.rw_write ("ok:" ^ path);
    rw.rw_flush ()
  in
  let client cc =
    let do_rt path =
      let req = mk_request ~meth:"GET" ~path () in
      let resp = rt cc req in
      let body = Api.Body.read_all resp.cres_body in
      (Httpg_base.Status.to_int resp.cres_status_code, body)
    in
    Eio.Fiber.pair (fun () -> do_rt "/a") (fun () -> do_rt "/b")
  in
  let (c1, b1), (c2, b2) = run ~handler client in
  Alcotest.(check int) "s1 status" 200 c1;
  Alcotest.(check int) "s2 status" 200 c2;
  Alcotest.(check string) "s1 body" "ok:/a" b1;
  Alcotest.(check string) "s2 body" "ok:/b" b2

(* ---- F032 regression: N concurrent streams must respect the server's
   MAX_CONCURRENT_STREAMS and all complete cleanly (no Stream_aborted). With the
   server advertising a small limit (4) and N=16 fibers fanned out on one conn,
   the client must queue for an open slot (Go's awaitOpenSlotForStreamLocked)
   rather than open all 16 at once and have the overflow RST'd. Looped to be
   convincing without being slow/flaky. *)
let test_many_concurrent_respects_max () =
  let n = 16 and iters = 30 and server_max = 4 in
  let handler (rw : H2_server.response_writer) (req : Api.server_request) =
    let path = Uri.path req.sreq_url in
    rw.rw_write ("ok:" ^ path);
    rw.rw_flush ()
  in
  for _ = 1 to iters do
    let client cc =
      let do_rt i =
        let path = Printf.sprintf "/p%d" i in
        let resp = rt cc (mk_request ~meth:"GET" ~path ()) in
        ( Httpg_base.Status.to_int resp.cres_status_code,
          Api.Body.read_all resp.cres_body )
      in
      Eio.Fiber.List.map do_rt (List.init n (fun i -> i + 1))
    in
    let results =
      H2_test_util.with_h2_server ~max_concurrent_streams:server_max ~handler
        client
    in
    List.iteri
      (fun idx (code, body) ->
        let i = idx + 1 in
        Alcotest.(check int) (Printf.sprintf "s%d status" i) 200 code;
        Alcotest.(check string)
          (Printf.sprintf "s%d body" i)
          (Printf.sprintf "ok:/p%d" i)
          body)
      results
  done

(* ---- F026: caller abandons the response body early (undrained) ----
   The server replies immediately WITHOUT reading the (large, flow-controlled)
   request body, so the client's body-writer fiber parks in await_flow_control.
   The caller takes the response and returns WITHOUT draining the body, inside a
   per-request [~sw] scope. On scope release cleanup_write_request must abort the
   writer and forget the stream — so across many such requests on ONE conn the
   stream table never grows (no lingering writer/stream). *)
let test_early_return_undrained_no_leak () =
  let iters = 50 in
  let handler (rw : H2_server.response_writer) (_req : Api.server_request) =
    (* respond at once; never touch the request body. *)
    rw.rw_write "ok";
    rw.rw_flush ()
  in
  let client cc =
    let big =
      String.make (1 lsl 20) 'x'
      (* 1 MiB > a stream window *)
    in
    for _ = 1 to iters do
      (* a streaming request body the writer cannot finish before we leave. *)
      Eio.Switch.run @@ fun sw ->
      let req =
        {
          (mk_request ~meth:"POST" ~path:"/early" ()) with
          Api.creq_body =
            Api.Body.of_stream (fun () ->
                Some big (* endless: the writer can never reach END_STREAM *));
          (* nonzero so has_body holds and the writer fiber actually forks. *)
          creq_content_length = Int64.of_int (1 lsl 30);
        }
      in
      let resp = rt ~sw cc req in
      Alcotest.(check int)
        "status 200" 200
        (Httpg_base.Status.to_int resp.cres_status_code);
      (* return WITHOUT reading resp.cres_body; leaving [sw] runs cleanup. *)
      ()
    done;
    (* after all scopes released, the table must be empty (no lingering streams);
       a missing teardown would accumulate one entry (+ a parked writer) each
       iteration. *)
    H2_transport.live_stream_count cc
  in
  let live = run ~handler client in
  Alcotest.(check int) "no lingering streams" 0 live

(* ---- F026/F020: cancelling a request scope aborts its stream + writer ----
   The server never responds; the client awaits the response under a [~sw] that
   we cancel. The cancel must abort the stream (round_trip raises) and leave no
   lingering stream. *)
let test_cancel_aborts_stream () =
  let handler (_rw : H2_server.response_writer) (_req : Api.server_request) =
    (* never reply; park so the client must cancel to make progress. *)
    Eio.Fiber.await_cancel ()
  in
  let client cc =
    let aborted =
      try
        Eio.Switch.run (fun sw ->
            (* cancel this scope shortly after issuing the request. *)
            Eio.Fiber.fork ~sw (fun () -> Eio.Switch.fail sw Exit);
            let req = mk_request ~meth:"GET" ~path:"/hang" () in
            let _ = H2_transport.round_trip ~sw cc req in
            false)
      with _ -> true
    in
    (aborted, H2_transport.live_stream_count cc)
  in
  let aborted, live = run ~handler client in
  Alcotest.(check bool) "round trip aborted" true aborted;
  Alcotest.(check int) "no lingering stream after cancel" 0 live

(* ---- F034: slot accounting (reserve / free-after-body-read) ----
   Distinguishes Go's accounting from the old "free on peer END_STREAM". With the
   server advertising MAX_CONCURRENT_STREAMS=1:
   (a) reserve_new_request bumps current_request_count even before any stream id
       is assigned, and a round_trip consumes the reservation;
   (b) a response whose body is held UNDRAINED keeps its slot — a concurrent
       round_trip must block until the first body is read to EOF, then proceeds.
   Under the OLD behaviour (slot freed at peer END_STREAM) the second round_trip
   would open immediately while the first body was still buffered. *)
let test_slot_accounting_free_after_body () =
  let handler (rw : H2_server.response_writer) (req : Api.server_request) =
    let path = Uri.path req.sreq_url in
    rw.rw_write ("ok:" ^ path);
    rw.rw_flush ()
  in
  let client cc =
    (* (a) a reservation counts against the limit before any stream exists. *)
    Alcotest.(check int)
      "count 0 initially" 0
      (H2_transport.current_request_count cc);
    Alcotest.(check bool)
      "reserve succeeds" true
      (H2_transport.reserve_new_request cc);
    Alcotest.(check int)
      "reservation counts" 1
      (H2_transport.current_request_count cc);
    (* with one slot reserved and max=1, a second reservation is refused. *)
    Alcotest.(check bool)
      "second reserve refused" false
      (H2_transport.reserve_new_request cc);
    (* (b) round_trip 1 consumes the reservation, opens the stream, returns a
       streaming response we deliberately leave UNDRAINED. *)
    let resp1 = rt cc (mk_request ~meth:"GET" ~path:"/a" ()) in
    Alcotest.(check int)
      "status1 200" 200
      (Httpg_base.Status.to_int resp1.cres_status_code);
    (* pull the body chunk(s) WITHOUT reading EOF — this forces the read loop to
       have processed the DATA+END_STREAM frame (peer half-close), so the stream
       is half-closed but, under the new accounting, its slot is held until the
       body is read to EOF (the final [next ()] returning None). *)
    let next1 =
      match resp1.cres_body with
      | Api.Body.Stream f -> f
      | _ -> Alcotest.fail "expected a streaming body"
    in
    let buf1 = Buffer.create 16 in
    let rec read_data () =
      if Buffer.contents buf1 = "ok:/a" then ()
      else
        match next1 () with
        | Some s ->
            Buffer.add_string buf1 s;
            read_data ()
        | None -> ()
    in
    read_data ();
    Alcotest.(check string) "body1 data received" "ok:/a" (Buffer.contents buf1);
    (* peer END_STREAM is processed but body not yet at EOF: the slot is still
       held (would be 0 under the old "free on peer END_STREAM"). *)
    Alcotest.(check int)
      "undrained body holds slot" 1
      (H2_transport.current_request_count cc);
    (* a concurrent round_trip must block on the slot until we read resp1 to EOF. *)
    let started2 = ref false and done2 = ref false in
    let b2 = ref "" and c2 = ref 0 in
    Eio.Fiber.both
      (fun () ->
        started2 := true;
        let resp2 = rt cc (mk_request ~meth:"GET" ~path:"/b" ()) in
        c2 := Httpg_base.Status.to_int resp2.cres_status_code;
        b2 := Api.Body.read_all resp2.cres_body;
        done2 := true)
      (fun () ->
        (* let fiber 2 reach (and park in) await_open_slot. *)
        for _ = 1 to 10 do
          Eio.Fiber.yield ()
        done;
        Alcotest.(check bool)
          "fiber2 parked, not done" true (!started2 && not !done2);
        Alcotest.(check int)
          "still one slot (rt2 waiting)" 1
          (H2_transport.current_request_count cc);
        (* reading resp1 to EOF frees the slot -> rt2 unblocks. *)
        match next1 () with
        | None -> ()
        | Some _ -> Alcotest.fail "expected EOF");
    Alcotest.(check bool) "rt2 completed after drain" true !done2;
    Alcotest.(check int) "status2 200" 200 !c2;
    Alcotest.(check string) "body2" "ok:/b" !b2;
    (* both exchanges fully read -> no slots held. *)
    Alcotest.(check int)
      "count 0 after both drained" 0
      (H2_transport.current_request_count cc);
    Alcotest.(check int)
      "no lingering streams" 0
      (H2_transport.live_stream_count cc)
  in
  H2_test_util.with_h2_server ~max_concurrent_streams:1 ~handler client

(* ---- F027: a closed/closing conn yields the distinguishable Conn_unusable
   (Go's errClientConnUnusable), since round_trip wrote nothing — the signal the
   transport pool uses to evict + retry on a fresh dial. Now surfaced as the
   [Error Conn_unusable] arm of the typed result. *)
let test_closed_conn_unusable () =
  let handler (rw : H2_server.response_writer) (_req : Api.server_request) =
    rw.rw_write "ok";
    rw.rw_flush ()
  in
  let client cc =
    H2_transport.close cc;
    (* closed before any write -> Error Conn_unusable, not Conn_closed/other. *)
    let outcome =
      match
        H2_transport.round_trip cc (mk_request ~meth:"GET" ~path:"/" ())
      with
      | Ok _ -> `Ok
      | Error H2_transport.Conn_unusable -> `Unusable
      | Error _ -> `Other
    in
    (outcome, H2_transport.live_stream_count cc)
  in
  let outcome, live = run ~handler client in
  Alcotest.(check bool)
    "round_trip on closed conn -> Error Conn_unusable" true (outcome = `Unusable);
  (* nothing was written, so no stream entry was ever created. *)
  Alcotest.(check int) "no stream created" 0 live

(* ---- A response missing the [:status] pseudo-header is a framing violation:
   round_trip surfaces it as the [Error (Malformed_response _)] arm rather than
   an exception. Driven by a hand-rolled raw H2 server (self-contained loopback,
   not the shared S.serve harness) that completes the handshake and then replies
   to the request HEADERS with a HEADERS frame carrying NO [:status]. *)
let encode_block (fields : (string * string) list) =
  let enc = Hpack.new_encoder () in
  let buf = Buffer.create 64 in
  Hpack.set_writer enc (fun s -> Buffer.add_string buf s);
  List.iter
    (fun (name, value) ->
      Hpack.write_field enc { name; value; sensitive = false })
    fields;
  Buffer.contents buf

(* Minimal raw server: read the client preface + initial SETTINGS, send our
   SETTINGS (so new_client_conn returns) + an ACK, then for the first request
   HEADERS reply with a malformed (no :status) HEADERS frame and park. *)
let malformed_raw_server r w =
  let preface = Eio.Buf_read.take H2.client_preface_len r in
  if preface <> H2.client_preface then failwith "bad preface";
  F.write_settings w [];
  Eio.Buf_write.flush w;
  let stream_id = ref 0 in
  (try
     while !stream_id = 0 do
       match F.read_frame r with
       | Ok (F.Settings (fh, _)) ->
           if fh.flags land 0x1 = 0 then (
             F.write_settings_ack w;
             Eio.Buf_write.flush w)
       | Ok (F.Headers (fh, _)) -> stream_id := fh.stream_id
       | Ok _ -> ()
       | Error _ -> failwith "frame error"
     done
   with End_of_file -> ());
  if !stream_id <> 0 then (
    (* HEADERS with END_HEADERS|END_STREAM but no :status pseudo-header. *)
    let block = encode_block [ ("content-type", "text/plain") ] in
    F.write_headers w ~stream_id:!stream_id ~end_stream:true ~end_headers:true
      block;
    Eio.Buf_write.flush w);
  Eio.Fiber.await_cancel ()

let test_malformed_response_missing_status () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 15. @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let lsock = Httpg.Net.listen ~sw net "127.0.0.1" 0 in
  let port = Httpg.Net.bound_port lsock in
  Eio.Fiber.first
    (fun () ->
      let flow =
        match Httpg.Net.connect ~sw net ~host:"127.0.0.1" ~port with
        | Ok x -> x
        | Error e -> failwith ("net: " ^ Httpg.Net.error_to_string e)
      in
      Httpg.Net.with_connection flow (fun r w ->
          Eio.Switch.run @@ fun cc_sw ->
          let cc = H2_transport.new_client_conn ~sw:cc_sw r w in
          (match
             H2_transport.round_trip cc (mk_request ~meth:"GET" ~path:"/" ())
           with
          | Ok _ -> Alcotest.fail "expected Error Malformed_response"
          | Error (H2_transport.Malformed_response _) -> ()
          | Error e ->
              Alcotest.failf "expected Malformed_response, got %s"
                (H2_transport.error_to_string e));
          try H2_transport.close cc with _ -> ()))
    (fun () ->
      (try
         let flow, _peer = Httpg.Net.accept ~sw lsock in
         Httpg.Net.with_connection flow malformed_raw_server
       with _ -> ());
      Eio.Fiber.await_cancel ())

let tests =
  [
    Alcotest.test_case "get" `Quick test_get;
    Alcotest.test_case "closed_conn_unusable" `Quick test_closed_conn_unusable;
    Alcotest.test_case "malformed_response_missing_status" `Quick
      test_malformed_response_missing_status;
    Alcotest.test_case "post_echo" `Quick test_post_echo;
    Alcotest.test_case "concurrent" `Quick test_concurrent;
    (* Stress/leak tests with high iteration counts: slow, gated by HTTPG_SLOW. *)
    Alcotest.test_case "many_concurrent_respects_max" `Slow
      test_many_concurrent_respects_max;
    Alcotest.test_case "early_return_undrained_no_leak" `Slow
      test_early_return_undrained_no_leak;
    Alcotest.test_case "cancel_aborts_stream" `Quick test_cancel_aborts_stream;
    Alcotest.test_case "slot_accounting_free_after_body" `Slow
      test_slot_accounting_free_after_body;
  ]
