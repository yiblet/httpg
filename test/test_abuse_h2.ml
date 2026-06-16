(* HTTP/2 abuse-hardening tests, driven over a real loopback socket pair with a
   raw H2 framer + Hpack encoder against H2_server.serve.

   Cases: too_many_early_resets (CVE-2023-44487), advertises_max_header_list_size,
   rejects_header_list_bomb, huffman_string_cap, rejects_duplicate_settings,
   accepts_distinct_settings, h2_flow_control_overflow_goaway,
   h2_max_concurrent_streams_refused. *)

module F = Httpg_http2.H2_frame
module S = Httpg_http2.H2_server
module H2 = Httpg_http2.H2
module Hpack = Httpg_http2.Hpack
module H2_error = Httpg_http2.H2_error
module Api = Httpg_http2.Api

(* The frame writers thread their build invariant as [(unit, H2_error.t) result]
   (ticket 013); these raw-client helpers use valid values, so unwrap [Ok]. *)
let ok : (unit, H2_error.t) result -> unit = function
  | Ok () -> ()
  | Error _ -> failwith "test: unexpected h2 frame-build invariant"

(* Run [client r w] against [S.serve ?max_concurrent_streams ?max_header_bytes
   handler] over a loopback socket pair (shared harness). The server fiber is
   cancelled once the client returns. *)
let with_h2_conn = H2_test_util.with_h2_raw

let h2_encode_block (fields : (string * string) list) =
  let enc = Hpack.new_encoder () in
  let buf = Buffer.create 64 in
  Hpack.set_writer enc (fun s -> Buffer.add_string buf s);
  List.iter
    (fun (name, value) ->
      Hpack.write_field enc { Hpack.name; value; sensitive = false })
    fields;
  Buffer.contents buf

let h2_request_block path =
  h2_encode_block
    [
      (":method", "GET");
      (":path", path);
      (":scheme", "https");
      (":authority", "example.com");
    ]

let h2_open oc ~stream_id =
  ok
    (F.write_headers oc ~stream_id ~end_stream:true ~end_headers:true
       (h2_request_block "/"))

let client_handshake oc =
  Eio.Buf_write.string oc H2.client_preface;
  ok (F.write_settings oc []);
  Eio.Buf_write.flush oc

(* Read frames until a GOAWAY is seen; return its error code. *)
let rec read_until_goaway ic =
  match F.read_frame ic with
  | Ok (F.GoAway (_, gf)) -> gf.error_code
  | Ok _ -> read_until_goaway ic
  | Error _ -> failwith "test: unexpected h2 frame-build invariant"

let too_many_early_resets () =
  (* adv_max_streams = 1, so the backlog cap is 4 * 1 = 4: the 6th queued
     handler trips ENHANCE_YOUR_CALM. *)
  let max_streams = 1 in
  (* A blocking handler: the first (un-reset) stream's handler parks on a
     never-resolved promise, keeping cur_handlers == adv_max_streams so every
     later stream's handler is queued rather than started. *)
  let block, _wake = Eio.Promise.create () in
  let started, started_u = Eio.Promise.create () in
  let woken = ref false in
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    if not !woken then begin
      woken := true;
      Eio.Promise.resolve started_u ()
    end;
    Eio.Promise.await block;
    rw.Api.rw_flush ()
  in
  let client c_ic oc =
    client_handshake oc;
    (* Stream 1: starts the (blocking) handler, then reset it so
       cur_client_streams drops back to 0 while the handler fiber keeps running
       (cur_handlers stays at adv_max_streams). *)
    h2_open oc ~stream_id:1;
    Eio.Buf_write.flush oc;
    Eio.Promise.await started;
    ok (F.write_rst_stream oc 1 H2_error.Cancel);
    Eio.Buf_write.flush oc;
    (* Flood: open then immediately reset a stream, repeatedly; each queued
       handler grows the backlog until it exceeds 4*adv_max_streams. *)
    let rec loop sid n =
      if n > 0 then begin
        h2_open oc ~stream_id:sid;
        ok (F.write_rst_stream oc sid H2_error.Cancel);
        Eio.Buf_write.flush oc;
        loop (sid + 2) (n - 1)
      end
    in
    loop 3 20;
    read_until_goaway c_ic
  in
  let code = with_h2_conn ~max_concurrent_streams:max_streams ~handler client in
  Alcotest.(check bool)
    "GOAWAY error code is ENHANCE_YOUR_CALM" true
    (code = H2_error.EnhanceYourCalm)

module Huff = Httpg_http2.Hpack_huffman

(* Read the server's first SETTINGS frame off the wire. *)
let rec read_first_settings ic =
  match F.read_frame ic with
  | Ok (F.Settings (_, sf)) -> sf
  | Ok _ -> read_first_settings ic
  | Error _ -> failwith "test: unexpected h2 frame-build invariant"

(* TestH2AdvertisesMaxHeaderListSize: the server's initial SETTINGS frame
   contains a MAX_HEADER_LIST_SIZE entry equal to the configured value. *)
let advertises_max_header_list_size () =
  let configured = 4096 in
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.Api.rw_flush ()
  in
  let client c_ic _oc =
    (* The server sends its initial SETTINGS before reading the preface. *)
    let sf = read_first_settings c_ic in
    let v =
      List.find_opt
        (fun (s : H2.setting) -> s.id = H2.Max_header_list_size)
        sf.settings
    in
    Option.map (fun (s : H2.setting) -> s.value) v
  in
  let value = with_h2_conn ~max_header_bytes:configured ~handler client in
  Alcotest.(check (option int32))
    "advertised MAX_HEADER_LIST_SIZE = configured value"
    (Some (Int32.of_int configured))
    value

(* TestH2RejectsHeaderListBomb: a HEADERS block whose decoded header list
   exceeds the configured size is a connection PROTOCOL_ERROR (GOAWAY). *)
let rejects_header_list_bomb () =
  let configured = 256 in
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.Api.rw_flush ()
  in
  let bomb_block =
    h2_encode_block
      [
        (":method", "GET");
        (":path", "/");
        (":scheme", "https");
        (":authority", "example.com");
        ("x-bomb", String.make 4096 'a');
      ]
  in
  let client c_ic oc =
    client_handshake oc;
    ok
      (F.write_headers oc ~stream_id:1 ~end_stream:true ~end_headers:true
         bomb_block);
    Eio.Buf_write.flush oc;
    read_until_goaway c_ic
  in
  let code = with_h2_conn ~max_header_bytes:configured ~handler client in
  Alcotest.(check bool)
    "GOAWAY error code is PROTOCOL_ERROR" true
    (code = H2_error.ProtocolError)

(* TestH2HuffmanStringCap: a Huffman-coded string whose DECODED length exceeds
   the decoder's per-string cap is rejected with String_too_long. Pure HPACK
   unit test (no IO). *)
let huffman_string_cap () =
  let cap = 64 in
  let decoded = String.make (cap + 8) 'a' in
  let huff = Huff.encode decoded in
  Alcotest.(check bool)
    "encoded wire string is within the per-string cap (so the encoded-length \
     check alone would pass)"
    true
    (String.length huff <= cap);
  let buf = Buffer.create 64 in
  (* Literal Header Field without Indexing, new name (RFC 7541 6.2.2). *)
  Buffer.add_char buf '\x00';
  Hpack.Private.append_var_int buf 7 1;
  Buffer.add_char buf 'x';
  let len_buf = Buffer.create 8 in
  Hpack.Private.append_var_int len_buf 7 (String.length huff);
  let len_bytes = Buffer.contents len_buf in
  let first = Char.code len_bytes.[0] lor 0x80 in
  Buffer.add_char buf (Char.chr first);
  Buffer.add_substring buf len_bytes 1 (String.length len_bytes - 1);
  Buffer.add_string buf huff;
  let block = Buffer.contents buf in
  let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
  Hpack.set_max_string_length dec cap;
  let result =
    match Hpack.write_result dec block with
    | Error e -> Error e
    | Ok _ -> Hpack.close_result dec
  in
  match result with
  | Error Httpg_http2.Hpack.String_too_long -> ()
  | Error e ->
      Alcotest.failf "expected String_too_long, got %s"
        (Httpg_http2.Hpack.error_to_string e)
  | Ok () -> Alcotest.fail "expected String_too_long, got Ok"

(* TestH2RejectsDuplicateSettings: a single SETTINGS frame carrying two entries
   for the same ID trips a PROTOCOL_ERROR GOAWAY. *)
let rejects_duplicate_settings () =
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.Api.rw_flush ()
  in
  let client c_ic oc =
    Eio.Buf_write.string oc H2.client_preface;
    (* One SETTINGS frame, two entries for the SAME id (duplicate). *)
    ok
      (F.write_settings oc
         [
           { H2.id = H2.Initial_window_size; value = 65535l };
           { H2.id = H2.Initial_window_size; value = 1024l };
         ]);
    Eio.Buf_write.flush oc;
    read_until_goaway c_ic
  in
  let code = with_h2_conn ~timeout:10. ~handler client in
  Alcotest.(check bool)
    "GOAWAY error code is PROTOCOL_ERROR" true
    (code = H2_error.ProtocolError)

(* TestH2AcceptsDistinctSettings: a single SETTINGS frame whose entries all have
   distinct IDs is accepted; a following GET is served normally (status 200). *)
let accepts_distinct_settings () =
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.Api.rw_write "ok";
    rw.Api.rw_flush ()
  in
  let client c_ic oc =
    Eio.Buf_write.string oc H2.client_preface;
    ok
      (F.write_settings oc
         [
           { H2.id = H2.Initial_window_size; value = 65535l };
           { H2.id = H2.Max_concurrent_streams; value = 100l };
           { H2.id = H2.Header_table_size; value = 4096l };
         ]);
    Eio.Buf_write.flush oc;
    h2_open oc ~stream_id:1;
    Eio.Buf_write.flush oc;
    let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
    let rec read_status () =
      match F.read_frame c_ic with
      | Ok (F.Headers (_, hf)) ->
          let fields = ref [] in
          Hpack.set_emit_func dec (fun (h : Hpack.header_field) ->
              fields := (h.name, h.value) :: !fields);
          (match Hpack.write_result dec hf.header_frag with
          | Ok _ -> ()
          | Error e ->
              Alcotest.failf "hpack decode: %s" (Hpack.error_to_string e));
          (match Hpack.close_result dec with
          | Ok () -> ()
          | Error e -> Alcotest.failf "hpack close: %s" (Hpack.error_to_string e));
          List.assoc_opt ":status" !fields
      | Ok (F.GoAway (_, gf)) ->
          Alcotest.failf "unexpected GOAWAY %s"
            (H2_error.Private.err_code_string gf.error_code)
      | Ok _ -> read_status ()
      | Error _ -> failwith "test: unexpected h2 frame-build invariant"
    in
    read_status ()
  in
  let status = with_h2_conn ~timeout:10. ~handler client in
  Alcotest.(check (option string))
    "distinct SETTINGS accepted; GET served 200" (Some "200") status

(* TestServer_Send_GoAway_After_Bogus_WindowUpdate: a connection-level
   WINDOW_UPDATE of 2^31-1 overflows the outbound window, surfacing a modeled
   FLOW_CONTROL_ERROR connection error (GOAWAY). *)
let h2_flow_control_overflow_goaway () =
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.Api.rw_flush ()
  in
  let max_window = (1 lsl 31) - 1 in
  let client c_ic oc =
    client_handshake oc;
    ok (F.write_window_update oc 0 max_window);
    Eio.Buf_write.flush oc;
    read_until_goaway c_ic
  in
  let code = with_h2_conn ~handler client in
  Alcotest.(check bool)
    "GOAWAY error code is FLOW_CONTROL_ERROR" true
    (code = H2_error.FlowControlError)

(* Read frames until an RST_STREAM is seen; return its (stream_id, code). *)
let rec read_until_rst ic =
  match F.read_frame ic with
  | Ok (F.RST_stream (fh, rf)) -> (fh.stream_id, rf.error_code)
  | Ok _ -> read_until_rst ic
  | Error _ -> failwith "test: unexpected h2 frame-build invariant"

(* TestH2MaxConcurrentStreamsRefused (regression): with adv_max_streams = 1, a
   second concurrent stream opened while the first is still active is refused
   with RST_STREAM REFUSED_STREAM. *)
let h2_max_concurrent_streams_refused () =
  let block, _wake = Eio.Promise.create () in
  let started, started_u = Eio.Promise.create () in
  let woken = ref false in
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    if not !woken then begin
      woken := true;
      Eio.Promise.resolve started_u ()
    end;
    Eio.Promise.await block;
    rw.Api.rw_flush ()
  in
  let client c_ic oc =
    client_handshake oc;
    (* Stream 1: kept open (no END_STREAM) so it counts as active. *)
    ok
      (F.write_headers oc ~stream_id:1 ~end_stream:false ~end_headers:true
         (h2_request_block "/"));
    Eio.Buf_write.flush oc;
    Eio.Promise.await started;
    (* Stream 3: over the limit -> RST_STREAM REFUSED_STREAM. *)
    h2_open oc ~stream_id:3;
    Eio.Buf_write.flush oc;
    read_until_rst c_ic
  in
  let sid, code = with_h2_conn ~max_concurrent_streams:1 ~handler client in
  Alcotest.(check int) "RST_STREAM is for stream 3" 3 sid;
  Alcotest.(check bool)
    "RST_STREAM code is REFUSED_STREAM" true
    (code = H2_error.RefusedStream)

let tests =
  [
    Alcotest.test_case "too_many_early_resets" `Quick too_many_early_resets;
    Alcotest.test_case "advertises_max_header_list_size" `Quick
      advertises_max_header_list_size;
    Alcotest.test_case "rejects_header_list_bomb" `Quick
      rejects_header_list_bomb;
    Alcotest.test_case "huffman_string_cap" `Quick huffman_string_cap;
    Alcotest.test_case "rejects_duplicate_settings" `Quick
      rejects_duplicate_settings;
    Alcotest.test_case "accepts_distinct_settings" `Quick
      accepts_distinct_settings;
    Alcotest.test_case "h2_flow_control_overflow_goaway" `Quick
      h2_flow_control_overflow_goaway;
    Alcotest.test_case "h2_max_concurrent_streams_refused" `Quick
      h2_max_concurrent_streams_refused;
  ]
