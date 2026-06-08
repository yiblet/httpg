(* Ported from go/src/net/http/internal/http2/frame_test.go.
   Each test writes a frame with the writers (capturing the bytes) and reads it
   back through an in-memory Eio.Buf_read, asserting the parsed fields. Frame IO
   is synchronous, so no fibers/switch are needed for these round-trips. *)

module F = Httpg_http2.H2_frame
module H2 = Httpg_http2.H2
module H2_error = Httpg_http2.H2_error
module Hpack = Httpg_http2.Hpack

(* Capture the raw bytes a writer produces (for byte-exact encoding checks). *)
let capture (writer : Eio.Buf_write.t -> unit) : string =
  Test_harness.with_output_string writer

(* Run [writer] then [reader]: serialize the writer's bytes, then read them back
   through a fresh in-memory Buf_read. *)
let with_pipe (writer : Eio.Buf_write.t -> unit) (reader : Eio.Buf_read.t -> 'a)
    : 'a =
  reader (Test_harness.buf_read_of_string (capture writer))

(* read_frame returns [result]; unwrap [Ok], re-raising the boundary error via
   [H2_error.to_exception] so the [check_raises] error tests below keep asserting
   the exception identity (Frame_too_large / Connection_error / …). *)
let read_one ?max_size () r =
  match F.read_frame ?max_size r with
  | Ok f -> f
  | Error e -> raise (H2_error.to_exception e)

(* ---- frame type string ---- *)

let test_frame_type_string () =
  Alcotest.(check string) "DATA" "DATA" (H2.Private.frame_type_string H2.Data);
  Alcotest.(check string) "PING" "PING" (H2.Private.frame_type_string H2.Ping);
  Alcotest.(check string) "GOAWAY" "GOAWAY" (H2.Private.frame_type_string H2.Goaway)

(* ---- RST_STREAM (TestWriteRST) ---- *)

let test_write_rst () =
  let stream_id = (1 lsl 24) + (2 lsl 16) + (3 lsl 8) + 4 in
  let err =
    H2_error.err_code_of_int ((7 lsl 24) + (6 lsl 16) + (5 lsl 8) + 4)
  in
  let enc = capture (fun oc -> F.write_rst_stream oc stream_id err) in
  Alcotest.(check string)
    "rst enc" "\x00\x00\x04\x03\x00\x01\x02\x03\x04\x07\x06\x05\x04" enc;
  let f =
    with_pipe (fun oc -> F.write_rst_stream oc stream_id err) (read_one ())
  in
  match f with
  | F.RST_stream (fh, r) ->
      Alcotest.(check int) "type" 0x3 (H2.frame_type_to_int fh.typ);
      Alcotest.(check int) "len" 4 fh.length;
      Alcotest.(check int) "stream" 0x1020304 fh.stream_id;
      Alcotest.(check int)
        "code" 0x7060504
        (H2_error.err_code_to_int r.error_code)
  | _ -> Alcotest.fail "expected RST_stream"

(* ---- DATA (TestWriteData) ---- *)

let test_write_data () =
  let stream_id = (1 lsl 24) + (2 lsl 16) + (3 lsl 8) + 4 in
  let enc = capture (fun oc -> F.write_data oc stream_id true "ABC") in
  Alcotest.(check string)
    "data enc" "\x00\x00\x03\x00\x01\x01\x02\x03\x04ABC" enc;
  let f =
    with_pipe (fun oc -> F.write_data oc stream_id true "ABC") (read_one ())
  in
  match f with
  | F.Data (_, d) ->
      Alcotest.(check string) "data" "ABC" d.data;
      Alcotest.(check bool) "end_stream" true d.end_stream
  | _ -> Alcotest.fail "expected Data"

(* ---- DATA padded (TestWriteDataPadded) ---- *)

let test_write_data_padded () =
  (* unpadded *)
  let f = with_pipe (fun oc -> F.write_data oc 1 true "foo") (read_one ()) in
  (match f with
  | F.Data (fh, d) ->
      Alcotest.(check int) "u flags" H2.flag_end_stream fh.flags;
      Alcotest.(check int) "u len" 3 fh.length;
      Alcotest.(check string) "u data" "foo" d.data
  | _ -> Alcotest.fail "unpadded");
  (* padded bit set, no padding *)
  let f =
    with_pipe (fun oc -> F.write_data ~pad:"" oc 1 true "foo") (read_one ())
  in
  (match f with
  | F.Data (fh, d) ->
      Alcotest.(check int)
        "p0 flags"
        (H2.flag_end_stream lor H2.flag_padded)
        fh.flags;
      Alcotest.(check int) "p0 len" 4 fh.length;
      Alcotest.(check string) "p0 data" "foo" d.data
  | _ -> Alcotest.fail "padded empty");
  (* padded with 3 zero pad bytes *)
  let f =
    with_pipe
      (fun oc -> F.write_data ~pad:"\x00\x00\x00" oc 1 false "foo")
      (read_one ())
  in
  match f with
  | F.Data (fh, d) ->
      Alcotest.(check int) "p3 flags" H2.flag_padded fh.flags;
      Alcotest.(check int) "p3 len" 7 fh.length;
      Alcotest.(check string) "p3 data" "foo" d.data
  | _ -> Alcotest.fail "padded 3"

(* ---- HEADERS (TestWriteHeaders) ---- *)

let test_write_headers_basic () =
  let enc = capture (fun oc -> F.write_headers oc ~stream_id:42 "abc") in
  Alcotest.(check string)
    "h basic enc" "\x00\x00\x03\x01\x00\x00\x00\x00*abc" enc;
  let f =
    with_pipe (fun oc -> F.write_headers oc ~stream_id:42 "abc") (read_one ())
  in
  match f with
  | F.Headers (fh, h) ->
      Alcotest.(check int) "stream" 42 fh.stream_id;
      Alcotest.(check int) "len" 3 fh.length;
      Alcotest.(check string) "frag" "abc" h.header_frag;
      Alcotest.(check bool) "no prio" true (h.priority = None)
  | _ -> Alcotest.fail "headers basic"

let test_write_headers_end_flags () =
  let enc =
    capture (fun oc ->
        F.write_headers oc ~stream_id:42 ~end_stream:true ~end_headers:true
          "abc")
  in
  Alcotest.(check string)
    "h flags enc" "\x00\x00\x03\x01\x05\x00\x00\x00*abc" enc;
  let f =
    with_pipe
      (fun oc ->
        F.write_headers oc ~stream_id:42 ~end_stream:true ~end_headers:true
          "abc")
      (read_one ())
  in
  match f with
  | F.Headers (fh, h) ->
      Alcotest.(check int)
        "flags"
        (H2.flag_end_stream lor H2.flag_end_headers)
        fh.flags;
      Alcotest.(check bool) "end_stream" true h.end_stream;
      Alcotest.(check bool) "end_headers" true h.end_headers;
      Alcotest.(check string) "frag" "abc" h.header_frag
  | _ -> Alcotest.fail "headers flags"

let test_write_headers_padding () =
  let enc =
    capture (fun oc ->
        F.write_headers oc ~stream_id:42 ~end_stream:true ~end_headers:true
          ~pad_length:5 "abc")
  in
  Alcotest.(check string)
    "h pad enc" "\x00\x00\x09\x01\x0d\x00\x00\x00*\x05abc\x00\x00\x00\x00\x00"
    enc;
  let f =
    with_pipe
      (fun oc ->
        F.write_headers oc ~stream_id:42 ~end_stream:true ~end_headers:true
          ~pad_length:5 "abc")
      (read_one ())
  in
  match f with
  | F.Headers (fh, h) ->
      Alcotest.(check int) "len" (1 + 3 + 5) fh.length;
      Alcotest.(check string) "frag" "abc" h.header_frag
  | _ -> Alcotest.fail "headers pad"

let test_write_headers_priority () =
  let prio = { F.stream_dep = 15; exclusive = true; weight = 127 } in
  let enc =
    capture (fun oc ->
        F.write_headers oc ~stream_id:42 ~end_stream:true ~end_headers:true
          ~pad_length:2 ~priority:prio "abc")
  in
  Alcotest.(check string)
    "h prio enc"
    "\x00\x00\x0b\x01\x2d\x00\x00\x00*\x02\x80\x00\x00\x0f\x7fabc\x00\x00" enc;
  let f =
    with_pipe
      (fun oc ->
        F.write_headers oc ~stream_id:42 ~end_stream:true ~end_headers:true
          ~pad_length:2 ~priority:prio "abc")
      (read_one ())
  in
  match f with
  | F.Headers (_, h) -> (
      match h.priority with
      | Some p ->
          Alcotest.(check int) "dep" 15 p.stream_dep;
          Alcotest.(check bool) "excl" true p.exclusive;
          Alcotest.(check int) "weight" 127 p.weight;
          Alcotest.(check string) "frag" "abc" h.header_frag
      | None -> Alcotest.fail "expected priority")
  | _ -> Alcotest.fail "headers prio"

(* ---- CONTINUATION (TestWriteContinuation) ---- *)

let test_write_continuation () =
  let f =
    with_pipe (fun oc -> F.write_continuation oc 42 false "abc") (read_one ())
  in
  (match f with
  | F.Continuation (fh, c) ->
      Alcotest.(check int) "stream" 42 fh.stream_id;
      Alcotest.(check string) "frag" "abc" c.header_frag;
      Alcotest.(check bool) "not end" false c.end_headers
  | _ -> Alcotest.fail "continuation not-end");
  let f =
    with_pipe (fun oc -> F.write_continuation oc 42 true "def") (read_one ())
  in
  match f with
  | F.Continuation (_, c) ->
      Alcotest.(check string) "frag" "def" c.header_frag;
      Alcotest.(check bool) "end" true c.end_headers
  | _ -> Alcotest.fail "continuation end"

(* ---- PRIORITY (TestWritePriority) ---- *)

let test_write_priority () =
  let p = { F.stream_dep = 2; exclusive = false; weight = 127 } in
  let f = with_pipe (fun oc -> F.Private.write_priority oc 42 p) (read_one ()) in
  (match f with
  | F.Priority (fh, pf) ->
      Alcotest.(check int) "len" 5 fh.length;
      Alcotest.(check int) "dep" 2 pf.priority.stream_dep;
      Alcotest.(check bool) "excl" false pf.priority.exclusive;
      Alcotest.(check int) "weight" 127 pf.priority.weight
  | _ -> Alcotest.fail "priority");
  let p = { F.stream_dep = 3; exclusive = true; weight = 77 } in
  let f = with_pipe (fun oc -> F.Private.write_priority oc 42 p) (read_one ()) in
  match f with
  | F.Priority (_, pf) ->
      Alcotest.(check int) "dep" 3 pf.priority.stream_dep;
      Alcotest.(check bool) "excl" true pf.priority.exclusive;
      Alcotest.(check int) "weight" 77 pf.priority.weight
  | _ -> Alcotest.fail "priority excl"

let test_write_invalid_stream_dep () =
  Alcotest.check_raises "headers dep" F.Invalid_dep_stream_id (fun () ->
      ignore
        (capture (fun oc ->
             F.write_headers oc ~stream_id:42
               ~priority:
                 { F.stream_dep = 1 lsl 31; exclusive = false; weight = 0 }
               "")));
  Alcotest.check_raises "priority dep" F.Invalid_dep_stream_id (fun () ->
      ignore
        (capture (fun oc ->
             F.Private.write_priority oc 2
               { F.stream_dep = 1 lsl 31; exclusive = false; weight = 0 })))

(* ---- SETTINGS (TestWriteSettings) ---- *)

let test_write_settings () =
  let settings =
    [
      { H2.id = H2.Header_table_size; value = 2l };
      { H2.id = H2.Max_concurrent_streams; value = 4l };
    ]
  in
  let enc = capture (fun oc -> F.write_settings oc settings) in
  Alcotest.(check string)
    "settings enc"
    "\x00\x00\x0c\x04\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x02\x00\x03\x00\x00\x00\x04"
    enc;
  let f = with_pipe (fun oc -> F.write_settings oc settings) (read_one ()) in
  match f with
  | F.Settings (_, s) ->
      Alcotest.(check bool) "not ack" false s.ack;
      Alcotest.(check int) "num" 2 (List.length s.settings);
      let ids =
        List.map
          (fun (st : H2.setting) -> H2.setting_id_to_int st.id)
          s.settings
      in
      Alcotest.(check (list int)) "ids" [ 1; 3 ] ids;
      let vals =
        List.map (fun (st : H2.setting) -> Int32.to_int st.value) s.settings
      in
      Alcotest.(check (list int)) "vals" [ 2; 4 ] vals
  | _ -> Alcotest.fail "settings"

let test_write_settings_ack () =
  let enc = capture (fun oc -> F.write_settings_ack oc) in
  Alcotest.(check string) "ack enc" "\x00\x00\x00\x04\x01\x00\x00\x00\x00" enc;
  let f = with_pipe (fun oc -> F.write_settings_ack oc) (read_one ()) in
  match f with
  | F.Settings (_, s) -> Alcotest.(check bool) "ack" true s.ack
  | _ -> Alcotest.fail "settings ack"

(* ---- WINDOW_UPDATE (TestWriteWindowUpdate) ---- *)

let test_write_window_update () =
  let stream_id = (1 lsl 24) + (2 lsl 16) + (3 lsl 8) + 4 in
  let incr = (7 lsl 24) + (6 lsl 16) + (5 lsl 8) + 4 in
  let enc = capture (fun oc -> F.write_window_update oc stream_id incr) in
  Alcotest.(check string)
    "wu enc" "\x00\x00\x04\x08\x00\x01\x02\x03\x04\x07\x06\x05\x04" enc;
  let f =
    with_pipe (fun oc -> F.write_window_update oc stream_id incr) (read_one ())
  in
  match f with
  | F.Window_update (fh, w) ->
      Alcotest.(check int) "stream" 0x1020304 fh.stream_id;
      Alcotest.(check int) "incr" 0x7060504 w.increment
  | _ -> Alcotest.fail "window_update"

(* ---- PING (TestWritePing / Ack) ---- *)

let test_write_ping ack () =
  let data = "\x01\x02\x03\x04\x05\x06\x07\x08" in
  let want_flag = if ack then H2.flag_ack else 0 in
  let enc = capture (fun oc -> F.write_ping oc ack data) in
  let want_enc =
    "\x00\x00\x08\x06"
    ^ String.make 1 (Char.chr want_flag)
    ^ "\x00\x00\x00\x00" ^ data
  in
  Alcotest.(check string) "ping enc" want_enc enc;
  let f = with_pipe (fun oc -> F.write_ping oc ack data) (read_one ()) in
  match f with
  | F.Ping (fh, p) ->
      Alcotest.(check int) "flags" want_flag fh.flags;
      Alcotest.(check string) "data" data p.data;
      Alcotest.(check bool) "ack" ack p.ack
  | _ -> Alcotest.fail "ping"

(* ---- GOAWAY (TestWriteGoAway) ---- *)

let test_write_goaway () =
  let debug = "foo" in
  let code = H2_error.err_code_of_int 0x05060708 in
  let enc = capture (fun oc -> F.write_goaway oc 0x01020304 code debug) in
  Alcotest.(check string)
    "goaway enc"
    "\x00\x00\x0b\x07\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08foo"
    enc;
  let f =
    with_pipe (fun oc -> F.write_goaway oc 0x01020304 code debug) (read_one ())
  in
  match f with
  | F.GoAway (fh, g) ->
      Alcotest.(check int) "len" (4 + 4 + 3) fh.length;
      Alcotest.(check int) "last" 0x01020304 g.last_stream_id;
      Alcotest.(check int)
        "code" 0x05060708
        (H2_error.err_code_to_int g.error_code);
      Alcotest.(check string) "debug" "foo" g.debug_data
  | _ -> Alcotest.fail "goaway"

(* ---- PUSH_PROMISE (TestWritePushPromise) ---- *)

let test_write_push_promise () =
  let enc =
    capture (fun oc ->
        F.write_push_promise oc ~stream_id:42 ~promise_id:42 "abc")
  in
  Alcotest.(check string)
    "pp enc" "\x00\x00\x07\x05\x00\x00\x00\x00*\x00\x00\x00*abc" enc;
  let f =
    with_pipe
      (fun oc -> F.write_push_promise oc ~stream_id:42 ~promise_id:42 "abc")
      (read_one ())
  in
  match f with
  | F.Push_promise (fh, pp) ->
      Alcotest.(check int) "stream" 42 fh.stream_id;
      Alcotest.(check int) "promise" 42 pp.promise_id;
      Alcotest.(check string) "frag" "abc" pp.header_frag
  | _ -> Alcotest.fail "push_promise"

(* ---- frame header round-trip (TestReadWriteFrameHeader / ReadFrameHeader) ---- *)

let test_frame_header_codec () =
  let h =
    { F.length = 66051; typ = H2.Settings; flags = 5; stream_id = 101124105 }
  in
  let enc = F.Private.encode_frame_header h in
  Alcotest.(check string) "enc" "\x01\x02\x03\x04\x05\x06\x07\x08\x09" enc;
  let h2 = F.Private.decode_frame_header "\x01\x02\x03\x04\x05\x06\x07\x08\x09" in
  Alcotest.(check int) "len" 66051 h2.length;
  Alcotest.(check int) "type" 4 (H2.frame_type_to_int h2.typ);
  Alcotest.(check int) "flags" 5 h2.flags;
  Alcotest.(check int) "stream" 101124105 h2.stream_id;
  (* high bit masked *)
  let h3 = F.Private.decode_frame_header "\xff\xff\xff\xff\xff\xff\xff\xff\xff" in
  Alcotest.(check int) "masked stream" 2147483647 h3.stream_id

(* ---- oversize -> Frame_too_large (TestReadFrameHeaderFrameTooLarge) ---- *)

let test_oversize_frame () =
  (* Write a raw frame with declared length 5 but read with max_size 4. *)
  let writer oc = F.write_raw oc (H2.frame_type_to_int H2.Data) 0 1 "hello" in
  Alcotest.check_raises "too large" F.Frame_too_large (fun () ->
      ignore (with_pipe writer (read_one ~max_size:4 ())))

(* ---- bad stream id: DATA on stream 0 -> PROTOCOL_ERROR ---- *)

let test_bad_stream_id () =
  (* Raw DATA frame on stream 0 -> connection error PROTOCOL_ERROR. *)
  let writer oc = F.write_raw oc (H2.frame_type_to_int H2.Data) 0 0 "abc" in
  Alcotest.check_raises "data stream 0"
    (H2_error.Connection_error H2_error.ProtocolError) (fun () ->
      ignore (with_pipe writer (read_one ())));
  (* SETTINGS on a non-zero stream -> PROTOCOL_ERROR. *)
  let writer oc = F.write_raw oc (H2.frame_type_to_int H2.Settings) 0 1 "" in
  Alcotest.check_raises "settings stream 1"
    (H2_error.Connection_error H2_error.ProtocolError) (fun () ->
      ignore (with_pipe writer (read_one ())));
  (* SETTINGS not a multiple of 6 -> FRAME_SIZE_ERROR. *)
  let writer oc = F.write_raw oc (H2.frame_type_to_int H2.Settings) 0 0 "abc" in
  Alcotest.check_raises "settings size"
    (H2_error.Connection_error H2_error.FrameSizeError) (fun () ->
      ignore (with_pipe writer (read_one ())))

(* ---- result boundary: read_frame returns Error (Ticket 7) ---- *)

(* Read the raw [(frame, H2_error.t) result] without unwrapping. *)
let read_result ?max_size () r = F.read_frame ?max_size r

(* A frame whose declared length exceeds max_size -> Error Frame_too_large. *)
let test_read_oversize_frame_result () =
  let writer oc = F.write_raw oc (H2.frame_type_to_int H2.Data) 0 1 "hello" in
  match with_pipe writer (read_result ~max_size:4 ()) with
  | Error H2_error.Frame_too_large -> ()
  | Error e ->
      Alcotest.failf "expected Error Frame_too_large, got Error %s"
        (match e with
        | H2_error.Connection c -> "Connection " ^ H2_error.Private.err_code_string c
        | _ -> "<other>")
  | Ok _ -> Alcotest.fail "expected Error Frame_too_large, got Ok"

(* A frame with a bad stream id at the read boundary. NOTE (Go-fidelity): on the
   *read* path Go's parsers return a connection-level PROTOCOL_ERROR for a bad
   stream id (e.g. DATA on stream 0); [Invalid_stream_id] is a *write-side*
   error (errStreamID), not produced by the parsers. So this asserts the
   faithful read-boundary result [Error (Connection ProtocolError)] rather than
   the plan's literal [Error Invalid_stream_id] (which the read path never
   yields). *)
let test_read_bad_stream_id_result () =
  let writer oc = F.write_raw oc (H2.frame_type_to_int H2.Data) 0 0 "abc" in
  match with_pipe writer (read_result ()) with
  | Error (H2_error.Connection H2_error.ProtocolError) -> ()
  | Error _ -> Alcotest.fail "expected Error (Connection ProtocolError)"
  | Ok _ -> Alcotest.fail "expected Error (Connection ProtocolError), got Ok"

(* ---- CONTINUATION assembly via read_meta_headers (TestMetaFrameHeader) ---- *)

(* Encode a header list into one raw HPACK block with a throwaway encoder. *)
let encode_header_raw pairs =
  let enc = Hpack.new_encoder () in
  let fields =
    List.map
      (fun (n, v) -> { Hpack.name = n; value = v; sensitive = false })
      pairs
  in
  Hpack.Private.encode_to_string enc fields

let split_at s i = (String.sub s 0 i, String.sub s i (String.length s - i))

let read_meta ?(max_header_list_size = 16 lsl 20) writer =
  let r = Test_harness.buf_read_of_string (capture writer) in
  match F.read_frame r with
  | Ok (F.Headers (fh, h)) -> (
      let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
      match F.read_meta_headers ~max_header_list_size dec (fh, h) r with
      | Ok mf -> mf
      | Error e -> raise (H2_error.to_exception e))
  | Ok _ -> Alcotest.fail "expected HEADERS"
  | Error e -> raise (H2_error.to_exception e)

let field_pairs (mh : F.meta_headers_frame) =
  List.map (fun (f : Hpack.header_field) -> (f.name, f.value)) mh.fields

let test_meta_single () =
  let all = encode_header_raw [ (":method", "GET"); (":path", "/") ] in
  let mh =
    read_meta (fun oc -> F.write_headers oc ~stream_id:1 ~end_headers:true all)
  in
  Alcotest.(check (list (pair string string)))
    "single"
    [ (":method", "GET"); (":path", "/") ]
    (field_pairs mh);
  Alcotest.(check bool) "not truncated" false mh.truncated

let test_meta_with_continuation () =
  let all =
    encode_header_raw [ (":method", "GET"); (":path", "/"); ("foo", "bar") ]
  in
  let a, b = split_at all 1 in
  let mh =
    read_meta (fun oc ->
        F.write_headers oc ~stream_id:1 a;
        F.write_continuation oc 1 true b)
  in
  Alcotest.(check (list (pair string string)))
    "with continuation"
    [ (":method", "GET"); (":path", "/"); ("foo", "bar") ]
    (field_pairs mh)

let test_meta_two_continuation () =
  let all =
    encode_header_raw [ (":method", "GET"); (":path", "/"); ("foo", "bar") ]
  in
  let a, rest = split_at all 2 in
  let b, c = split_at rest 2 in
  let mh =
    read_meta (fun oc ->
        F.write_headers oc ~stream_id:1 a;
        F.write_continuation oc 1 false b;
        F.write_continuation oc 1 true c)
  in
  Alcotest.(check (list (pair string string)))
    "two continuation"
    [ (":method", "GET"); (":path", "/"); ("foo", "bar") ]
    (field_pairs mh)

let test_meta_truncated () =
  (* 100 "foo: bar" pairs plus method/path, max list size 512 -> truncated. *)
  let pairs =
    [ (":method", "GET"); (":path", "/") ]
    @ List.init 100 (fun _ -> ("foo", "bar"))
  in
  let all = encode_header_raw pairs in
  let a, b = split_at all 2 in
  let mh =
    read_meta ~max_header_list_size:512 (fun oc ->
        F.write_headers oc ~stream_id:1 a;
        F.write_continuation oc 1 true b)
  in
  Alcotest.(check bool) "truncated" true mh.truncated;
  (* method(:GET=~37) + path(:/=~36) then foo/bar pairs of size 38 each until
     remaining budget (512) is exhausted. We just assert it's a strict prefix. *)
  Alcotest.(check bool)
    "has method" true
    (List.exists (fun (n, _) -> n = ":method") (field_pairs mh));
  Alcotest.(check bool)
    "fewer than all" true
    (List.length mh.fields < List.length pairs)

let test_meta_pseudo_after_regular () =
  let all =
    encode_header_raw [ (":method", "GET"); ("foo", "bar"); (":path", "/") ]
  in
  Alcotest.check_raises "pseudo after regular"
    (H2_error.Stream_error (H2_error.stream_error 1 H2_error.ProtocolError))
    (fun () ->
      ignore
        (read_meta (fun oc ->
             F.write_headers oc ~stream_id:1 ~end_headers:true all)))

let test_meta_unknown_pseudo () =
  let all = encode_header_raw [ (":unknown", "foo"); ("foo", "bar") ] in
  Alcotest.check_raises "unknown pseudo"
    (H2_error.Stream_error (H2_error.stream_error 1 H2_error.ProtocolError))
    (fun () ->
      ignore
        (read_meta (fun oc ->
             F.write_headers oc ~stream_id:1 ~end_headers:true all)))

let test_meta_dup_pseudo () =
  let all = encode_header_raw [ (":method", "GET"); (":method", "POST") ] in
  Alcotest.check_raises "dup pseudo"
    (H2_error.Stream_error (H2_error.stream_error 1 H2_error.ProtocolError))
    (fun () ->
      ignore
        (read_meta (fun oc ->
             F.write_headers oc ~stream_id:1 ~end_headers:true all)))

let test_meta_invalid_field_name () =
  let all = encode_header_raw [ ("CapitalBad", "x") ] in
  Alcotest.check_raises "invalid name"
    (H2_error.Stream_error (H2_error.stream_error 1 H2_error.ProtocolError))
    (fun () ->
      ignore
        (read_meta (fun oc ->
             F.write_headers oc ~stream_id:1 ~end_headers:true all)))

let tests =
  [
    ("frame_type_string", `Quick, test_frame_type_string);
    ("write_rst (roundtrip)", `Quick, test_write_rst);
    ("write_data (roundtrip)", `Quick, test_write_data);
    ("write_data_padded (roundtrip)", `Quick, test_write_data_padded);
    ("write_headers_basic (roundtrip)", `Quick, test_write_headers_basic);
    ("write_headers_end_flags (roundtrip)", `Quick, test_write_headers_end_flags);
    ("write_headers_padding (roundtrip)", `Quick, test_write_headers_padding);
    ("write_headers_priority (roundtrip)", `Quick, test_write_headers_priority);
    ("write_continuation (roundtrip)", `Quick, test_write_continuation);
    ("write_priority (roundtrip)", `Quick, test_write_priority);
    ("write_invalid_stream_dep", `Quick, test_write_invalid_stream_dep);
    ("write_settings (roundtrip)", `Quick, test_write_settings);
    ("write_settings_ack (roundtrip)", `Quick, test_write_settings_ack);
    ("write_window_update (roundtrip)", `Quick, test_write_window_update);
    ("write_ping (roundtrip)", `Quick, test_write_ping false);
    ("write_ping_ack (roundtrip)", `Quick, test_write_ping true);
    ("write_goaway (roundtrip)", `Quick, test_write_goaway);
    ("write_push_promise (roundtrip)", `Quick, test_write_push_promise);
    ("frame_header_codec", `Quick, test_frame_header_codec);
    ("oversize_frame", `Quick, test_oversize_frame);
    ("bad_stream_id", `Quick, test_bad_stream_id);
    ("read_oversize_frame", `Quick, test_read_oversize_frame_result);
    ("read_bad_stream_id", `Quick, test_read_bad_stream_id_result);
    ("meta_single", `Quick, test_meta_single);
    ("meta_with_continuation", `Quick, test_meta_with_continuation);
    ("meta_two_continuation", `Quick, test_meta_two_continuation);
    ("meta_truncated", `Quick, test_meta_truncated);
    ("meta_pseudo_after_regular", `Quick, test_meta_pseudo_after_regular);
    ("meta_unknown_pseudo", `Quick, test_meta_unknown_pseudo);
    ("meta_dup_pseudo", `Quick, test_meta_dup_pseudo);
    ("meta_invalid_field_name", `Quick, test_meta_invalid_field_name);
  ]
