open Httpg_http2

(* Ported from go/src/net/http/internal/http2/errors_test.go
   (TestErrCodeString) and the constant block of http2.go / frame.go. *)

let check_string name expected actual () =
  Alcotest.(check string) name expected actual

let check_int name expected actual () =
  Alcotest.(check int) name expected actual

(* TestErrCodeString: stringer incl. the unknown-code fallback. *)
let err_code_string_tests =
  [
    ( "protocol",
      `Quick,
      check_string "PROTOCOL_ERROR" "PROTOCOL_ERROR"
        (H2_error.Private.err_code_string H2_error.ProtocolError) );
    ( "http11required",
      `Quick,
      check_string "HTTP_1_1_REQUIRED" "HTTP_1_1_REQUIRED"
        (H2_error.Private.err_code_string (H2_error.err_code_of_int 0xd)) );
    ( "unknown",
      `Quick,
      check_string "unknown 0xf" "unknown error code 0xf"
        (H2_error.Private.err_code_string (H2_error.err_code_of_int 0xf)) );
  ]

(* Wire-value round trips for every known error code. *)
let err_code_roundtrip_tests =
  let codes =
    H2_error.
      [
        NoError;
        ProtocolError;
        InternalError;
        FlowControlError;
        SettingsTimeout;
        StreamClosed;
        FrameSizeError;
        RefusedStream;
        Cancel;
        CompressionError;
        ConnectError;
        EnhanceYourCalm;
        InadequateSecurity;
        HTTP11Required;
      ]
  in
  List.mapi
    (fun i c ->
      ( Printf.sprintf "err_code_roundtrip_%d" i,
        `Quick,
        fun () ->
          let v = H2_error.err_code_to_int c in
          Alcotest.(check bool) "roundtrip" true (H2_error.err_code_of_int v = c)
      ))
    codes

(* Explicit wire values from errors.go. *)
let err_code_value_tests =
  let cases =
    H2_error.
      [
        (NoError, 0x0);
        (ProtocolError, 0x1);
        (InternalError, 0x2);
        (FlowControlError, 0x3);
        (SettingsTimeout, 0x4);
        (StreamClosed, 0x5);
        (FrameSizeError, 0x6);
        (RefusedStream, 0x7);
        (Cancel, 0x8);
        (CompressionError, 0x9);
        (ConnectError, 0xa);
        (EnhanceYourCalm, 0xb);
        (InadequateSecurity, 0xc);
        (HTTP11Required, 0xd);
      ]
  in
  List.mapi
    (fun i (c, v) ->
      ( Printf.sprintf "err_code_value_%d" i,
        `Quick,
        check_int "value" v (H2_error.err_code_to_int c) ))
    cases

(* Client preface bytes + length (http2.go ClientPreface). *)
let preface_tests =
  [
    ( "preface_bytes",
      `Quick,
      check_string "preface" "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        H2.client_preface );
    ("preface_len", `Quick, check_int "len" 24 H2.client_preface_len);
    ( "next_proto_tls",
      `Quick,
      check_string "alpn" "h2" H2.Private.next_proto_tls );
  ]

(* Frame type wire values (frame.go FrameType constants). *)
let frame_type_tests =
  let cases =
    H2.
      [
        (Data, 0x0);
        (Headers, 0x1);
        (Priority, 0x2);
        (RST_stream, 0x3);
        (Settings, 0x4);
        (Push_promise, 0x5);
        (Ping, 0x6);
        (Goaway, 0x7);
        (Window_update, 0x8);
        (Continuation, 0x9);
      ]
  in
  List.mapi
    (fun i (t, v) ->
      ( Printf.sprintf "frame_type_%d" i,
        `Quick,
        fun () ->
          check_int "value" v (H2.frame_type_to_int t) ();
          Alcotest.(check bool)
            "roundtrip" true
            (H2.frame_type_of_int v = Some t) ))
    cases

(* Frame flag values (frame.go Flag* constants). *)
let frame_flag_tests =
  [
    ("flag_end_stream", `Quick, check_int "END_STREAM" 0x1 H2.flag_end_stream);
    ("flag_end_headers", `Quick, check_int "END_HEADERS" 0x4 H2.flag_end_headers);
    ("flag_padded", `Quick, check_int "PADDED" 0x8 H2.flag_padded);
    ("flag_priority", `Quick, check_int "PRIORITY" 0x20 H2.flag_priority);
    ("flag_ack", `Quick, check_int "ACK" 0x1 H2.flag_ack);
  ]

(* Setting id wire values (http2.go SettingID constants). *)
let setting_id_tests =
  let cases =
    H2.
      [
        (Header_table_size, 0x1, "HEADER_TABLE_SIZE");
        (Enable_push, 0x2, "ENABLE_PUSH");
        (Max_concurrent_streams, 0x3, "MAX_CONCURRENT_STREAMS");
        (Initial_window_size, 0x4, "INITIAL_WINDOW_SIZE");
        (Max_frame_size, 0x5, "MAX_FRAME_SIZE");
        (Max_header_list_size, 0x6, "MAX_HEADER_LIST_SIZE");
      ]
  in
  List.mapi
    (fun i (s, v, name) ->
      ( Printf.sprintf "setting_id_%d" i,
        `Quick,
        fun () ->
          check_int "value" v (H2.setting_id_to_int s) ();
          Alcotest.(check bool)
            "roundtrip" true
            (H2.setting_id_of_int v = Some s);
          check_string "name" name (H2.Private.setting_id_string s) () ))
    cases

(* Default constants (http2.go). *)
let default_tests =
  [
    ("initial_window_size", `Quick, check_int "iws" 65535 H2.initial_window_size);
    ( "initial_max_frame_size",
      `Quick,
      check_int "imfs" 16384 H2.initial_max_frame_size );
    ( "initial_header_table_size",
      `Quick,
      check_int "ihts" 4096 H2.initial_header_table_size );
    ( "default_max_read_frame_size",
      `Quick,
      check_int "dmrfs" (1 lsl 20) H2.default_max_read_frame_size );
  ]

let tests =
  err_code_string_tests @ err_code_roundtrip_tests @ err_code_value_tests
  @ preface_tests @ frame_type_tests @ frame_flag_tests @ setting_id_tests
  @ default_tests
