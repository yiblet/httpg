(* Integration tests for Httpg_http2.H2_server: drive a raw HTTP/2 client (the
   Framer + Hpack encoder) over a loopback socket pair against H2_server.serve,
   asserting response HEADERS/DATA. Ported subset of
   go/src/net/http/internal/http2/server_test.go (TestServer / GET, POST echo,
   concurrent streams). Bounded so a hang fails. *)

open Httpg_http2
module F = H2_frame
module S = H2_server

(* Client-side helper: send preface + an (empty) SETTINGS frame. *)
let client_handshake oc =
  Eio.Buf_write.string oc H2.client_preface;
  F.write_settings oc [];
  Eio.Buf_write.flush oc

(* Encode a header field list into a single HPACK block. *)
let encode_block (fields : (string * string) list) =
  let enc = Hpack.new_encoder () in
  let buf = Buffer.create 64 in
  Hpack.set_writer enc (fun s -> Buffer.add_string buf s);
  List.iter
    (fun (name, value) ->
      Hpack.write_field enc { name; value; sensitive = false })
    fields;
  Buffer.contents buf

(* Send a request HEADERS frame. *)
let client_headers oc ~stream_id ?(end_stream = true) fields =
  let block = encode_block fields in
  F.write_headers oc ~stream_id ~end_stream ~end_headers:true block

(* A collected frame. For HEADERS we eagerly decode the block (the server sends
   END_HEADERS in a single frame in these tests) using the connection-wide
   decoder so the shared HPACK dynamic table stays in sync across streams. *)
type collected = { frame : F.frame; headers : (string * string) list option }

(* Read frames from the server until the predicate is satisfied. A single
   [dec] decodes every HEADERS block (HPACK is stateful across the conn). *)
let rec collect_frames ic (dec : Hpack.decoder) acc ~until =
  let f =
    match F.read_frame ic with
    | Ok f -> f
    | Error e -> raise (H2_error.to_exception e)
  in
  let headers =
    match f with
    | F.Headers (_, hf) ->
        let fields = ref [] in
        Hpack.set_emit_func dec (fun (hf : Hpack.header_field) ->
            fields := (hf.name, hf.value) :: !fields);
        ignore (Hpack.write dec hf.header_frag);
        Hpack.close dec;
        Some (List.rev !fields)
    | _ -> None
  in
  let acc = { frame = f; headers } :: acc in
  if until (List.rev acc) then List.rev acc
  else collect_frames ic dec acc ~until

let status_of_frames frames =
  List.fold_left
    (fun acc c ->
      match c.headers with
      | Some fields -> (
          match List.assoc_opt ":status" fields with
          | Some s -> Some s
          | None -> acc)
      | None -> acc)
    None frames

let data_of_frames frames =
  List.fold_left
    (fun acc c ->
      match c.frame with F.Data (_, df) -> acc ^ df.data | _ -> acc)
    "" frames

(* Has the server signalled END_STREAM on a HEADERS or DATA frame for [sid]? *)
let saw_end_stream sid frames =
  List.exists
    (fun c ->
      match c.frame with
      | F.Headers (fh, hf) -> fh.stream_id = sid && hf.end_stream
      | F.Data (fh, df) -> fh.stream_id = sid && df.end_stream
      | F.RST_stream (fh, _) -> fh.stream_id = sid
      | _ -> false)
    frames

(* Run [client] against [serve handler] over a real loopback socket pair,
   bounded. The client collects its frames and returns; the server fiber is then
   cancelled by the shared harness. *)
let run ~handler client = H2_test_util.with_h2_raw ~handler client

(* ---- TestServer: simple GET, 200 + "hello" body ---- *)
let test_get () =
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.rw_write "hello";
    rw.rw_flush ()
  in
  let client ic oc =
    client_handshake oc;
    client_headers oc ~stream_id:1
      [
        (":method", "GET");
        (":path", "/");
        (":scheme", "https");
        (":authority", "example.com");
      ];
    Eio.Buf_write.flush oc;
    let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
    collect_frames ic dec [] ~until:(saw_end_stream 1)
  in
  let frames = run ~handler client in
  Alcotest.(check (option string))
    "status 200" (Some "200") (status_of_frames frames);
  Alcotest.(check string) "body hello" "hello" (data_of_frames frames)

(* ---- TestServer POST echo ---- *)
let test_post_echo () =
  let handler (rw : S.response_writer) (req : Api.server_request) =
    let body = Api.Body.read_all req.sreq_body in
    rw.rw_write body;
    rw.rw_flush ()
  in
  let client ic oc =
    client_handshake oc;
    client_headers oc ~stream_id:1 ~end_stream:false
      [
        (":method", "POST");
        (":path", "/echo");
        (":scheme", "https");
        (":authority", "example.com");
      ];
    F.write_data oc 1 true "ping";
    Eio.Buf_write.flush oc;
    let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
    collect_frames ic dec [] ~until:(saw_end_stream 1)
  in
  let frames = run ~handler client in
  Alcotest.(check (option string))
    "status 200" (Some "200") (status_of_frames frames);
  Alcotest.(check string) "echo ping" "ping" (data_of_frames frames)

(* ---- TestServer two concurrent streams (ids 1 and 3) ---- *)
let test_two_streams () =
  let handler (rw : S.response_writer) (req : Api.server_request) =
    (* echo the path so we can distinguish streams *)
    let path = Uri.path req.sreq_url in
    rw.rw_write ("ok:" ^ path);
    rw.rw_flush ()
  in
  let client ic oc =
    client_handshake oc;
    client_headers oc ~stream_id:1
      [
        (":method", "GET");
        (":path", "/a");
        (":scheme", "https");
        (":authority", "x");
      ];
    client_headers oc ~stream_id:3
      [
        (":method", "GET");
        (":path", "/b");
        (":scheme", "https");
        (":authority", "x");
      ];
    Eio.Buf_write.flush oc;
    let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
    (* collect until both stream 1 and stream 3 have ended *)
    collect_frames ic dec [] ~until:(fun fs ->
        saw_end_stream 1 fs && saw_end_stream 3 fs)
  in
  let frames = run ~handler client in
  (* Both streams should produce a HEADERS with :status 200 and a DATA body. *)
  let data_for sid =
    List.fold_left
      (fun acc c ->
        match c.frame with
        | F.Data (fh, df) when fh.stream_id = sid -> acc ^ df.data
        | _ -> acc)
      "" frames
  in
  let status_for sid =
    List.fold_left
      (fun acc c ->
        match c.frame with
        | F.Headers (fh, _) when fh.stream_id = sid -> (
            match c.headers with
            | Some fields -> (
                match List.assoc_opt ":status" fields with
                | Some s -> Some s
                | None -> acc)
            | None -> acc)
        | _ -> acc)
      None frames
  in
  Alcotest.(check (option string)) "s1 status" (Some "200") (status_for 1);
  Alcotest.(check (option string)) "s3 status" (Some "200") (status_for 3);
  Alcotest.(check string) "s1 body" "ok:/a" (data_for 1);
  Alcotest.(check string) "s3 body" "ok:/b" (data_for 3)

(* ---- A genuinely-handleable handler failure still becomes RST_STREAM ----
   The narrowed run_handler catch-all (F023) keeps Go's runHandler recover()
   behaviour for handleable failures (one panicking stream is reset, not the
   whole conn) while letting bug-class exceptions propagate. This checks the
   recovery half: a [Failure] from the handler resets the stream. *)
let saw_rst sid frames =
  List.exists
    (fun c ->
      match c.frame with
      | F.RST_stream (fh, _) -> fh.stream_id = sid
      | _ -> false)
    frames

let test_handler_failure_rst () =
  let handler (_rw : S.response_writer) (_req : Api.server_request) =
    failwith "handleable boom"
  in
  let client ic oc =
    client_handshake oc;
    client_headers oc ~stream_id:1
      [
        (":method", "GET");
        (":path", "/");
        (":scheme", "https");
        (":authority", "example.com");
      ];
    Eio.Buf_write.flush oc;
    let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
    collect_frames ic dec [] ~until:(fun fs ->
        saw_rst 1 fs || saw_end_stream 1 fs)
  in
  let frames = run ~handler client in
  Alcotest.(check bool) "stream 1 reset" true (saw_rst 1 frames)

(* ---- F036: a bug-class exception in the read loop PROPAGATES ----
   The read-loop boundary catch forwards genuine framer/IO errors as a modeled
   [Read_error] (Go server.go:692-711), but routes the caught exn through
   [reraise_unhandleable] first so bug-class exns (here [Invalid_argument]) and
   [Cancelled] propagate rather than being silently repackaged as a connection
   read error. We drive [serve] over a source that yields a valid client preface
   then raises [Invalid_argument] on the next read (i.e. inside the read loop's
   first [read_frame]); [serve] must re-raise that exception, not return cleanly. *)
module Buggy_source = struct
  type t = { mutable remaining : string }

  let read_methods = []

  let single_read (t : t) (buf : Cstruct.t) : int =
    if t.remaining = "" then raise (Invalid_argument "read-loop bug")
    else begin
      let n = min (Cstruct.length buf) (String.length t.remaining) in
      Cstruct.blit_from_string t.remaining 0 buf 0 n;
      t.remaining <- String.sub t.remaining n (String.length t.remaining - n);
      n
    end
end

let test_read_loop_bug_propagates () =
  let handler (_rw : S.response_writer) (_req : Api.server_request) = () in
  let raised =
    Eio_main.run @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    Eio.Time.with_timeout_exn clock 15. @@ fun () ->
    let src_state = { Buggy_source.remaining = H2.client_preface } in
    let source =
      Eio.Resource.T (src_state, Eio.Flow.Pi.source (module Buggy_source))
    in
    let r = Eio.Buf_read.of_flow ~max_size:(1 lsl 20) source in
    let sink = Eio.Flow.buffer_sink (Buffer.create 256) in
    Eio.Buf_write.with_flow sink @@ fun w ->
    match S.serve r w ~handler with
    | () -> None
    | exception Invalid_argument _ -> Some `Bug
    | exception _ -> Some `Other
  in
  Alcotest.(check bool)
    "Invalid_argument propagates out of serve (not swallowed as Read_error)"
    true (raised = Some `Bug)

(* ---- F024: graceful GOAWAY drain + timeouts ----
   These exercise H2_server.serve's [?graceful]/[?clock]/[?idle_timeout]/
   [?read_timeout] params directly, so the test owns the clock, the graceful
   trigger and the timing. A local loopback harness (the shared with_h2_raw does
   not surface those params) runs the server and the client body concurrently,
   bounded by an outer timeout so a genuine hang fails. *)

module Net = Httpg.Net

(* Run [server_extra]-configured serve against [client r w]; both run under one
   switch, bounded. [client] returns its result; the server returns on its own
   (GOAWAY drain / timeout / EOF) — we do NOT cancel it, so we observe a real
   graceful close. *)
let with_serve ?clock ?idle_timeout ?read_timeout ?graceful ~handler client =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let real_clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn real_clock 15. @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let lsock = Net.listen ~sw net "127.0.0.1" 0 in
  let port = Net.bound_port lsock in
  let server_done, server_done_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      (try
         let flow, _peer = Net.accept ~sw lsock in
         Net.with_connection flow (fun r w ->
             S.serve ?clock ?idle_timeout ?read_timeout ?graceful r w ~handler)
       with _ -> ());
      Eio.Promise.resolve server_done_u ());
  let flow =
    match Net.connect ~sw net ~host:"127.0.0.1" ~port with
    | Ok x -> x
    | Error e -> Alcotest.failf "net: %s" (Net.error_to_string e)
  in
  let result = Net.with_connection flow (fun r w -> client ~server_done r w) in
  result

let saw_goaway code frames =
  List.exists
    (fun c ->
      match c.frame with F.GoAway (_, gf) -> gf.error_code = code | _ -> false)
    frames

(* Graceful stop: an in-flight stream COMPLETES (200 + body) after a GOAWAY
   NO_ERROR; the conn then closes (clean EOF) on its own. *)
let test_graceful_drains_inflight () =
  (* Handler blocks until the test releases it, so the stream is genuinely
     in-flight when graceful shutdown is triggered. *)
  let release, release_u = Eio.Promise.create () in
  let started, started_u = Eio.Promise.create () in
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    Eio.Promise.resolve started_u ();
    Eio.Promise.await release;
    rw.rw_write "done";
    rw.rw_flush ()
  in
  let graceful, graceful_u = Eio.Promise.create () in
  let client ~server_done:_ ic oc =
    client_handshake oc;
    client_headers oc ~stream_id:1
      [
        (":method", "GET");
        (":path", "/");
        (":scheme", "https");
        (":authority", "x");
      ];
    Eio.Buf_write.flush oc;
    (* Wait until the server has actually started processing stream 1 (the
       handler is running, blocked on [release]) before triggering graceful, so
       the GOAWAY's last-stream-id covers stream 1 and it is genuinely in-flight
       rather than racing the shutdown and being refused. *)
    Eio.Promise.await started;
    (* Trigger graceful shutdown while the handler is still blocked. *)
    Eio.Promise.resolve graceful_u ();
    let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
    (* First collect the GOAWAY (it precedes the response). *)
    let g = collect_frames ic dec [] ~until:(saw_goaway H2_error.NoError) in
    (* Now release the handler and collect the in-flight response. *)
    Eio.Promise.resolve release_u ();
    let resp = collect_frames ic dec [] ~until:(saw_end_stream 1) in
    g @ resp
  in
  let frames = with_serve ~graceful ~handler client in
  Alcotest.(check bool)
    "GOAWAY NO_ERROR sent" true
    (saw_goaway H2_error.NoError frames);
  Alcotest.(check (option string))
    "in-flight stream completed 200" (Some "200") (status_of_frames frames);
  Alcotest.(check string)
    "in-flight body delivered" "done" (data_of_frames frames)

(* After a graceful GOAWAY, a NEW stream (id > last processed) is refused: the
   server does not produce a 200 for it. *)
let test_graceful_refuses_new_stream () =
  let release, release_u = Eio.Promise.create () in
  let started1, started1_u = Eio.Promise.create () in
  let handler (rw : S.response_writer) (req : Api.server_request) =
    if Uri.path req.sreq_url = "/one" then Eio.Promise.resolve started1_u ();
    Eio.Promise.await release;
    rw.rw_write "ok";
    rw.rw_flush ()
  in
  let graceful, graceful_u = Eio.Promise.create () in
  let client ~server_done:_ ic oc =
    client_handshake oc;
    client_headers oc ~stream_id:1
      [
        (":method", "GET");
        (":path", "/one");
        (":scheme", "https");
        (":authority", "x");
      ];
    Eio.Buf_write.flush oc;
    Eio.Promise.await started1;
    (* Graceful shutdown; the GOAWAY's last-stream-id is 1. *)
    Eio.Promise.resolve graceful_u ();
    let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
    let _ = collect_frames ic dec [] ~until:(saw_goaway H2_error.NoError) in
    (* New stream 3 after the GOAWAY: must be refused (no 200 for /two). *)
    client_headers oc ~stream_id:3
      [
        (":method", "GET");
        (":path", "/two");
        (":scheme", "https");
        (":authority", "x");
      ];
    Eio.Buf_write.flush oc;
    Eio.Promise.resolve release_u ();
    (* Collect until stream 1 ends; stream 3 should never produce a response. *)
    collect_frames ic dec [] ~until:(saw_end_stream 1)
  in
  let frames = with_serve ~graceful ~handler client in
  let status_for sid =
    List.exists
      (fun c ->
        match c.frame with
        | F.Headers (fh, _) -> fh.stream_id = sid
        | _ -> false)
      frames
  in
  Alcotest.(check bool) "stream 1 answered" true (status_for 1);
  Alcotest.(check bool) "stream 3 refused (no HEADERS)" false (status_for 3)

(* read_timeout: a peer that completes the preface but then sends nothing has
   its connection closed once the read timer fires. We observe the close as the
   server fiber resolving [server_done]. *)
let test_read_timeout_closes_idle_peer () =
  let handler (_rw : S.response_writer) (_req : Api.server_request) = () in
  let closed =
    Eio_main.run @@ fun env ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    Eio.Time.with_timeout_exn clock 15. @@ fun () ->
    Eio.Switch.run @@ fun sw ->
    let lsock = Net.listen ~sw net "127.0.0.1" 0 in
    let port = Net.bound_port lsock in
    let server_done, server_done_u = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
        (try
           let flow, _peer = Net.accept ~sw lsock in
           Net.with_connection flow (fun r w ->
               S.serve ~clock ~read_timeout:0.3 r w ~handler)
         with _ -> ());
        Eio.Promise.resolve server_done_u ());
    let flow =
      match Net.connect ~sw net ~host:"127.0.0.1" ~port with
      | Ok x -> x
      | Error e -> Alcotest.failf "net: %s" (Net.error_to_string e)
    in
    Net.with_connection flow (fun _r w ->
        Eio.Buf_write.string w H2.client_preface;
        F.write_settings w [];
        Eio.Buf_write.flush w;
        (* Send nothing further; the read timer must fire and close the conn. *)
        Eio.Promise.await server_done;
        true)
  in
  Alcotest.(check bool) "read-idle peer closed by timer" true closed

(* idle_timeout: once a stream completes and the conn is idle, the idle timer
   fires a graceful GOAWAY (NO_ERROR), then the conn closes. *)
let test_idle_timeout_goaway () =
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.rw_write "hi";
    rw.rw_flush ()
  in
  let client ~server_done ic oc =
    client_handshake oc;
    client_headers oc ~stream_id:1
      [
        (":method", "GET");
        (":path", "/");
        (":scheme", "https");
        (":authority", "x");
      ];
    Eio.Buf_write.flush oc;
    let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
    (* After the response, the conn is idle; collect until the idle GOAWAY. *)
    let frames =
      collect_frames ic dec [] ~until:(saw_goaway H2_error.NoError)
    in
    Eio.Promise.await server_done;
    frames
  in
  let closed = ref false in
  let frames =
    Eio_main.run @@ fun env ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    Eio.Time.with_timeout_exn clock 15. @@ fun () ->
    Eio.Switch.run @@ fun sw ->
    let lsock = Net.listen ~sw net "127.0.0.1" 0 in
    let port = Net.bound_port lsock in
    let server_done, server_done_u = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
        (try
           let flow, _peer = Net.accept ~sw lsock in
           Net.with_connection flow (fun r w ->
               S.serve ~clock ~idle_timeout:0.3 r w ~handler)
         with _ -> ());
        closed := true;
        Eio.Promise.resolve server_done_u ());
    let flow =
      match Net.connect ~sw net ~host:"127.0.0.1" ~port with
      | Ok x -> x
      | Error e -> Alcotest.failf "net: %s" (Net.error_to_string e)
    in
    Net.with_connection flow (fun r w -> client ~server_done r w)
  in
  Alcotest.(check bool)
    "idle GOAWAY NO_ERROR" true
    (saw_goaway H2_error.NoError frames);
  Alcotest.(check bool) "conn closed after idle GOAWAY" true !closed

(* Forced close still works: cancelling the conn (the shared with_h2_raw harness
   cancels the server fiber once the client returns) tears the stream down. We
   reuse the simple GET to confirm forced teardown leaves no hang. *)
let test_forced_close_still_works () =
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.rw_write "x";
    rw.rw_flush ()
  in
  let client ic oc =
    client_handshake oc;
    client_headers oc ~stream_id:1
      [
        (":method", "GET");
        (":path", "/");
        (":scheme", "https");
        (":authority", "x");
      ];
    Eio.Buf_write.flush oc;
    let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
    collect_frames ic dec [] ~until:(saw_end_stream 1)
  in
  (* with_h2_raw cancels the server fiber when the client returns: forced close. *)
  let frames = run ~handler client in
  Alcotest.(check (option string))
    "forced-close path serves then tears down" (Some "200")
    (status_of_frames frames)

let tests =
  [
    Alcotest.test_case "get" `Quick test_get;
    Alcotest.test_case "post_echo" `Quick test_post_echo;
    Alcotest.test_case "two_streams" `Quick test_two_streams;
    Alcotest.test_case "handler_failure_rst" `Quick test_handler_failure_rst;
    Alcotest.test_case "read_loop_bug_propagates" `Quick
      test_read_loop_bug_propagates;
    Alcotest.test_case "graceful_drains_inflight" `Quick
      test_graceful_drains_inflight;
    Alcotest.test_case "graceful_refuses_new_stream" `Quick
      test_graceful_refuses_new_stream;
    (* Real-clock timeout waits: slow, gated by HTTPG_SLOW. *)
    Alcotest.test_case "read_timeout_closes_idle_peer" `Slow
      test_read_timeout_closes_idle_peer;
    Alcotest.test_case "idle_timeout_goaway" `Slow test_idle_timeout_goaway;
    Alcotest.test_case "forced_close_still_works" `Quick
      test_forced_close_still_works;
  ]
