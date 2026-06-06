(* Unit tests for H2_write: serialize each writer value through the framer into
   an in-memory buffer and read it back through a Buf_read, asserting fields.
   Covers the write.go writeFramer values and splitHeaderBlock. Frame IO is
   synchronous, so no fibers/switch are needed. *)

open Httpg_http2
module W = H2_write
module F = H2_frame

(* Serialize [w] into a string via Buf_write, then read it back through a fresh
   Buf_read with [reader]. *)
let with_pipe (writer : Eio.Buf_write.t -> unit) (reader : Eio.Buf_read.t -> 'a)
    : 'a =
  reader
    (Test_harness.buf_read_of_string (Test_harness.with_output_string writer))

(* read_frame returns [result]; unwrap [Ok], re-raising the boundary error. *)
let read_frame_ok r =
  match F.read_frame r with
  | Ok f -> f
  | Error e -> raise (H2_error.to_exception e)

let write_one w oc =
  let enc = Hpack.new_encoder () in
  W.write_frame ~enc oc w

let test_settings () =
  let settings = [ { H2.id = H2.Max_frame_size; value = 16384l } ] in
  let f = with_pipe (write_one (W.Write_settings settings)) read_frame_ok in
  match f with
  | F.Settings (_, { settings = s; ack }) ->
      Alcotest.(check bool) "not ack" false ack;
      Alcotest.(check int) "one setting" 1 (List.length s)
  | _ -> Alcotest.fail "expected SETTINGS"

let test_settings_ack () =
  let f = with_pipe (write_one W.Write_settings_ack) read_frame_ok in
  match f with
  | F.Settings (_, { ack = true; settings = [] }) -> ()
  | _ -> Alcotest.fail "expected SETTINGS ack"

let test_window_update () =
  let f =
    with_pipe
      (write_one (W.Write_window_update { stream_id = 1; n = 100 }))
      read_frame_ok
  in
  match f with
  | F.Window_update (fh, { increment }) ->
      Alcotest.(check int) "stream" 1 fh.stream_id;
      Alcotest.(check int) "inc" 100 increment
  | _ -> Alcotest.fail "expected WINDOW_UPDATE"

let test_data () =
  let f =
    with_pipe
      (write_one
         (W.Write_data { stream_id = 3; data = "hello"; end_stream = true }))
      read_frame_ok
  in
  match f with
  | F.Data (fh, { data; end_stream }) ->
      Alcotest.(check int) "stream" 3 fh.stream_id;
      Alcotest.(check string) "data" "hello" data;
      Alcotest.(check bool) "end" true end_stream
  | _ -> Alcotest.fail "expected DATA"

let test_rst () =
  let f =
    with_pipe
      (write_one (W.Write_rst_stream { stream_id = 5; code = H2_error.Cancel }))
      read_frame_ok
  in
  match f with
  | F.RST_stream (fh, { error_code }) ->
      Alcotest.(check int) "stream" 5 fh.stream_id;
      Alcotest.(check bool) "code" true (error_code = H2_error.Cancel)
  | _ -> Alcotest.fail "expected RST_STREAM"

let test_goaway () =
  let f =
    with_pipe
      (write_one
         (W.Write_goaway { max_stream_id = 7; code = H2_error.NoError }))
      read_frame_ok
  in
  match f with
  | F.GoAway (_, { last_stream_id; _ }) ->
      Alcotest.(check int) "last stream" 7 last_stream_id
  | _ -> Alcotest.fail "expected GOAWAY"

let test_ping_ack () =
  let f = with_pipe (write_one (W.Write_ping_ack "abcdefgh")) read_frame_ok in
  match f with
  | F.Ping (_, { data; ack }) ->
      Alcotest.(check string) "data" "abcdefgh" data;
      Alcotest.(check bool) "ack" true ack
  | _ -> Alcotest.fail "expected PING ack"

(* writeResHeaders: read back via read_meta_headers, assert :status + fields. *)
let read_meta r =
  match F.read_frame r with
  | Ok (F.Headers (fh, h)) -> (
      let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
      match F.read_meta_headers dec (fh, h) r with
      | Ok mf -> mf
      | Error e -> raise (H2_error.to_exception e))
  | Ok _ -> failwith "expected HEADERS"
  | Error e -> raise (H2_error.to_exception e)

let field_value (m : F.meta_headers_frame) name =
  match
    List.find_opt (fun (f : Hpack.header_field) -> f.name = name) m.fields
  with
  | Some f -> f.value
  | None -> "<absent>"

let test_res_headers () =
  let h = Api.Header.create () in
  Api.Header.add h "X-Foo" "bar";
  let w =
    W.Write_res_headers
      {
        rh_stream_id = 1;
        http_res_code = 200;
        h;
        trailers = None;
        rh_end_stream = false;
        date = "";
        content_type = "text/plain";
        content_length = "5";
      }
  in
  let m = with_pipe (write_one w) read_meta in
  Alcotest.(check string) ":status" "200" (field_value m ":status");
  Alcotest.(check string)
    "content-type" "text/plain"
    (field_value m "content-type");
  Alcotest.(check string) "content-length" "5" (field_value m "content-length");
  Alcotest.(check string) "x-foo lowercased" "bar" (field_value m "x-foo")

(* 100-continue headers frame. *)
let test_100_continue () =
  let m = with_pipe (write_one (W.Write_100_continue 1)) read_meta in
  Alcotest.(check string) ":status 100" "100" (field_value m ":status")

(* Large header block forces HEADERS + CONTINUATION (split at 16384). *)
let test_continuation_split () =
  let h = Api.Header.create () in
  Api.Header.add h "X-Big" (String.make 40000 'a');
  let w =
    W.Write_res_headers
      {
        rh_stream_id = 1;
        http_res_code = 200;
        h;
        trailers = None;
        rh_end_stream = true;
        date = "";
        content_type = "";
        content_length = "";
      }
  in
  let m = with_pipe (write_one w) read_meta in
  Alcotest.(check string) ":status" "200" (field_value m ":status");
  Alcotest.(check int)
    "big value length" 40000
    (String.length (field_value m "x-big"))

let tests =
  [
    Alcotest.test_case "settings" `Quick test_settings;
    Alcotest.test_case "settings_ack" `Quick test_settings_ack;
    Alcotest.test_case "window_update" `Quick test_window_update;
    Alcotest.test_case "data" `Quick test_data;
    Alcotest.test_case "rst_stream" `Quick test_rst;
    Alcotest.test_case "goaway" `Quick test_goaway;
    Alcotest.test_case "ping_ack" `Quick test_ping_ack;
    Alcotest.test_case "res_headers" `Quick test_res_headers;
    Alcotest.test_case "headers_100_continue" `Quick test_100_continue;
    Alcotest.test_case "continuation_split" `Quick test_continuation_split;
  ]
