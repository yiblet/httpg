(* Ported from go/src/net/http/internal/http2/writesched_test.go and
   writesched_roundrobin_test.go. *)

open Gohttp
module WS = H2_writesched
module W = H2_write

(* makeWriteNonStreamRequest: a SETTINGS ACK with no stream (control). *)
let make_write_non_stream_request () : WS.frame_write_request =
  { write = W.Write_settings_ack; stream = None }

(* makeWriteRSTStream: streamError(streamID, ErrCodeInternal) as a writer with
   no stream. *)
let make_write_rst_stream stream_id : WS.frame_write_request =
  {
    write = W.Write_rst_stream { stream_id; code = H2_error.InternalError };
    stream = None;
  }

(* A DATA write request on stream [st] of [size] bytes, endStream true. *)
let make_data_request (st : WS.stream) size : WS.frame_write_request =
  {
    write = W.Write_data { stream_id = st.id; data = String.make size '\000'; end_stream = true };
    stream = Some st;
  }

(* Describe a consume result as (consumed_size, consumed_end, rest_size,
   rest_end, n) so we can assert on it without comparing whole records. *)
let describe_consume (wr : WS.frame_write_request) n =
  let consumed, rest, num = WS.consume wr n in
  let data_of w =
    match w.WS.write with
    | W.Write_data { data; end_stream; _ } -> (String.length data, end_stream)
    | W.Write_settings_ack -> (-1, false)
    | _ -> (-2, false)
  in
  let cs, ce = data_of consumed in
  let rs, re = data_of rest in
  (cs, ce, rs, re, num)

let max_int32 = 0x7fffffff

(* TestFrameWriteRequestNonData *)
let test_non_data () =
  let wr = make_write_non_stream_request () in
  Alcotest.(check int) "settings ack DataSize" 0 (WS.data_size wr);
  (* Non-DATA frames are consumed whole: (wr, empty, 1) *)
  let _, _, num = WS.consume wr 0 in
  Alcotest.(check int) "settings ack consume n" 1 num;
  let wr = make_write_rst_stream 123 in
  Alcotest.(check int) "rst DataSize" 0 (WS.data_size wr);
  let _, _, num = WS.consume wr 0 in
  Alcotest.(check int) "rst consume n" 1 num

(* TestFrameWriteRequest_StreamID *)
let test_stream_id () =
  let wr = make_write_rst_stream 123 in
  Alcotest.(check int) "StreamID of StreamError writer" 123 (WS.stream_id wr)

(* TestFrameWriteRequestWithData (flow-control blocked) *)
let test_with_data_blocked () =
  let st = WS.make_stream ~max_frame_size:16 1 in
  let size = 32 in
  let wr = make_data_request st size in
  Alcotest.(check int) "DataSize" size (WS.data_size wr);
  (* No flow-control bytes available: cannot consume anything -> n=0 *)
  let _, _, num = WS.consume wr max_int32 in
  Alcotest.(check int) "blocked consume n" 0 num;
  (* Non-DATA whole *)
  let wr = make_write_non_stream_request () in
  let _, _, num = WS.consume wr 0 in
  Alcotest.(check int) "non-data consume n" 1 num;
  let wr = make_write_rst_stream 1 in
  let _, _, num = WS.consume wr 0 in
  Alcotest.(check int) "rst consume n" 1 num

(* TestFrameWriteRequestData: split by flow + maxFrameSize, then further. *)
let test_data_split () =
  let st = WS.make_stream ~max_frame_size:16 1 in
  let size = 32 in
  let wr = make_data_request st size in
  Alcotest.(check int) "DataSize" size (WS.data_size wr);
  (* No flow control yet: blocked. *)
  let _, _, num = WS.consume wr max_int32 in
  Alcotest.(check int) "no-flow consume n" 0 num;
  (* Add enough flow control for the whole frame, but maxFrameSize=16 caps. *)
  ignore (H2_flow.add st.flow (Int32.of_int size));
  let cs, ce, rs, re, num = describe_consume wr max_int32 in
  Alcotest.(check int) "split n" 2 num;
  Alcotest.(check int) "consumed size = maxFrameSize" 16 cs;
  Alcotest.(check bool) "consumed not end" false ce;
  Alcotest.(check int) "rest size" (size - 16) rs;
  Alcotest.(check bool) "rest end" true re;
  (* rest = remaining 16 bytes; consume 8. *)
  let _, rest, _ = WS.consume wr max_int32 in
  (* re-derive rest via a fresh stream window so we can keep consuming *)
  ignore rest;
  (* Build the rest request explicitly mirroring Go's "rest := want[1]". *)
  let rest_req : WS.frame_write_request =
    {
      write =
        W.Write_data
          { stream_id = st.id; data = String.make (size - 16) '\000'; end_stream = true };
      stream = Some st;
    }
  in
  (* Give it flow again (the first consume took 16; add back). *)
  ignore (H2_flow.add st.flow (Int32.of_int 16));
  let cs, ce, rs, re, num = describe_consume rest_req 8 in
  Alcotest.(check int) "consume8 n" 2 num;
  Alcotest.(check int) "consume8 consumed" 8 cs;
  Alcotest.(check bool) "consume8 consumed not end" false ce;
  Alcotest.(check int) "consume8 rest" (size - 16 - 8) rs;
  Alcotest.(check bool) "consume8 rest end" true re;
  (* Consume all remaining bytes (8 left). *)
  let rest_req2 : WS.frame_write_request =
    {
      write =
        W.Write_data
          {
            stream_id = st.id;
            data = String.make (size - 16 - 8) '\000';
            end_stream = true;
          };
      stream = Some st;
    }
  in
  let cs, ce, _, _, num = describe_consume rest_req2 max_int32 in
  Alcotest.(check int) "consume rest n" 1 num;
  Alcotest.(check int) "consume rest size" (size - 16 - 8) cs;
  Alcotest.(check bool) "consume rest end" true ce

(* TestRoundRobinScheduler: control frames first, then round-robin over streams
   each emitting maxFrameSize chunks until drained. *)
let test_round_robin () =
  let max_frame_size = 16 in
  let ws = WS.create () in
  let streams = Array.init 4 (fun i -> WS.make_stream ~max_frame_size (i + 1)) in
  Array.iteri
    (fun i st ->
      ignore (H2_flow.add st.WS.flow (Int32.of_int (1 lsl 20)));
      WS.open_stream ws st.WS.id;
      let wr : WS.frame_write_request =
        {
          write =
            W.Write_data
              {
                stream_id = st.WS.id;
                data = String.make (max_frame_size * (i + 1)) '\000';
                end_stream = false;
              };
          stream = Some st;
        }
      in
      WS.push ws wr)
    streams;
  let control_frames = 2 in
  for _ = 1 to control_frames do
    WS.push ws (make_write_non_stream_request ())
  done;
  (* Control frames first: stream id 0. *)
  for _ = 1 to control_frames do
    match WS.pop ws with
    | Some wr -> Alcotest.(check int) "control stream id" 0 (WS.stream_id wr)
    | None -> Alcotest.fail "expected control frame"
  done;
  (* Each stream writes maxFrameSize bytes until it runs out.
     Stream 1: 1 frame, 2: 2 frames, etc. *)
  let want = [ 1; 2; 3; 4; 2; 3; 4; 3; 4; 4 ] in
  let got = ref [] in
  let rec drain () =
    match WS.pop ws with
    | None -> ()
    | Some wr ->
        Alcotest.(check int) "data size = maxFrameSize" max_frame_size
          (WS.data_size wr);
        got := WS.stream_id wr :: !got;
        drain ()
  in
  drain ();
  Alcotest.(check (list int)) "round-robin order" want (List.rev !got)

(* Control-priority + flow-control-skip: a DATA frame on a stream with no
   window is skipped while a control frame is delivered, and once a sibling
   stream has window its data is popped. *)
let test_flow_control_skip () =
  let ws = WS.create () in
  (* Stream 1: no flow window -> blocked. *)
  let s1 = WS.make_stream ~max_frame_size:16 1 in
  WS.open_stream ws s1.WS.id;
  WS.push ws
    {
      write =
        W.Write_data { stream_id = 1; data = String.make 10 'x'; end_stream = true };
      stream = Some s1;
    };
  (* Stream 3: has flow window. *)
  let s3 = WS.make_stream ~max_frame_size:16 3 in
  ignore (H2_flow.add s3.WS.flow 100l);
  WS.open_stream ws s3.WS.id;
  WS.push ws
    {
      write =
        W.Write_data { stream_id = 3; data = String.make 5 'y'; end_stream = true };
      stream = Some s3;
    };
  (* pop: stream 1 is blocked (no window), stream 3 delivers. *)
  (match WS.pop ws with
  | Some wr -> Alcotest.(check int) "skipped blocked, got stream 3" 3 (WS.stream_id wr)
  | None -> Alcotest.fail "expected stream 3 data");
  (* Now only stream 1 (blocked) remains -> nothing poppable. *)
  (match WS.pop ws with
  | None -> ()
  | Some wr ->
      Alcotest.failf "expected None (stream 1 blocked) got stream %d"
        (WS.stream_id wr));
  (* Give stream 1 window; now it pops. *)
  ignore (H2_flow.add s1.WS.flow 100l);
  match WS.pop ws with
  | Some wr -> Alcotest.(check int) "stream 1 now unblocked" 1 (WS.stream_id wr)
  | None -> Alcotest.fail "expected stream 1 data after window"

(* close_stream drops queued frames for that stream. *)
let test_close_stream_drops () =
  let ws = WS.create () in
  let s1 = WS.make_stream 1 in
  ignore (H2_flow.add s1.WS.flow 100l);
  WS.open_stream ws s1.WS.id;
  WS.push ws
    {
      write =
        W.Write_data { stream_id = 1; data = String.make 5 'z'; end_stream = true };
      stream = Some s1;
    };
  WS.close_stream ws 1;
  match WS.pop ws with
  | None -> ()
  | Some wr ->
      Alcotest.failf "expected None after close, got stream %d" (WS.stream_id wr)

let tests =
  [
    Alcotest.test_case "frame_write_request_non_data" `Quick test_non_data;
    Alcotest.test_case "frame_write_request_stream_id" `Quick test_stream_id;
    Alcotest.test_case "frame_write_request_with_data" `Quick
      test_with_data_blocked;
    Alcotest.test_case "frame_write_request_data_split" `Quick test_data_split;
    Alcotest.test_case "round_robin_scheduler" `Quick test_round_robin;
    Alcotest.test_case "flow_control_skip" `Quick test_flow_control_skip;
    Alcotest.test_case "close_stream_drops" `Quick test_close_stream_drops;
  ]
