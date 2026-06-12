(* HTTP/2 streaming alignment integration tests.

   Connects a Httpg_http2.H2_transport client_conn to H2_server.serve over a real
   loopback TCP socket pair (as test_h2_transport.ml does) and asserts that h2
   bodies stream end-to-end: the server frames DATA per write/flush (no hidden
   whole-body buffer), a large body spanning many DATA frames (and exercising
   flow control) round-trips intact, and the client reads the response body
   incrementally (first chunk before EOF). Bounded so a hang fails. *)

open Httpg_http2

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
    creq_host = None;
    creq_content_length = content_length;
    creq_close = false;
  }

(* Run [client cc] against an H2_server.serve over a real loopback socket pair,
   bounded. The server runs [handler]. *)
let run ?(timeout = 15.) ~handler client =
  H2_test_util.with_h2_server ~timeout ~handler client

(* ---- server frames multiple DATA frames as the handler writes+flushes ---- *)
(* The handler writes "alpha", flushes, then blocks on a promise the test
   resolves only after the client has read that first chunk — proving the chunk
   is observable on the wire before the handler completes (DATA-per-write, not a
   whole-body buffer). It then writes "beta"/"gamma" with flushes between. *)
let test_server_streams_multiple_data () =
  let released, release = Eio.Promise.create () in
  let handler (rw : H2_server.response_writer) (_req : Api.server_request) =
    rw.rw_write "alpha";
    rw.rw_flush ();
    Eio.Promise.await released;
    rw.rw_write "beta";
    rw.rw_flush ();
    rw.rw_write "gamma";
    rw.rw_flush ()
  in
  let client cc =
    let req = mk_request ~meth:"GET" ~path:"/" () in
    let resp = H2_transport.round_trip cc req in
    (* Read the first chunk from the streaming response body. The server is
       suspended on [released] until we wake it, so receiving "alpha" here proves
       the first DATA frame arrived before the handler finished. *)
    let first_chunk =
      match resp.cres_body with Api.Body.Stream next -> next () | _ -> None
    in
    let handler_suspended_when_first_seen =
      not (Eio.Promise.is_resolved released)
    in
    Eio.Promise.resolve release ();
    let rest = Api.Body.read_all resp.cres_body in
    let full = (match first_chunk with Some s -> s | None -> "") ^ rest in
    ( Httpg_base.Status.to_int resp.cres_status_code,
      first_chunk,
      handler_suspended_when_first_seen,
      full )
  in
  let code, first_chunk, suspended, full = run ~handler client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check (option string))
    "first chunk is alpha" (Some "alpha") first_chunk;
  Alcotest.(check bool) "handler suspended when first chunk seen" true suspended;
  Alcotest.(check string) "full body" "alphabetagamma" full

(* ---- large body spanning many DATA frames + flow control ---- *)
(* 200 KiB > the 16384 default max frame size and large enough to exercise
   stream/conn flow control and WINDOW_UPDATE; must round-trip byte-for-byte. *)
let test_large_body () =
  let n = 200 * 1024 in
  let payload = String.init n (fun i -> Char.chr (i mod 256)) in
  let handler (rw : H2_server.response_writer) (_req : Api.server_request) =
    (* one big write: the writer must auto-frame it into many DATA frames *)
    rw.rw_write payload;
    rw.rw_flush ()
  in
  let client cc =
    let req = mk_request ~meth:"GET" ~path:"/big" () in
    let resp = H2_transport.round_trip cc req in
    let body = Api.Body.read_all resp.cres_body in
    (Httpg_base.Status.to_int resp.cres_status_code, body)
  in
  let code, body = run ~handler client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check int) "body length" n (String.length body);
  Alcotest.(check bool) "body bytes match" true (body = payload)

(* ---- incremental client read: first chunk readable before EOF ---- *)
(* The handler streams many chunks with flushes; the client pulls a single chunk
   and asserts it gets data while more remains (the body is not pre-materialized). *)
let test_incremental_client_read () =
  let chunk = String.make 8192 'x' in
  let chunks = 20 in
  let handler (rw : H2_server.response_writer) (_req : Api.server_request) =
    for _ = 1 to chunks do
      rw.rw_write chunk;
      rw.rw_flush ()
    done
  in
  let client cc =
    let req = mk_request ~meth:"GET" ~path:"/stream" () in
    let resp = H2_transport.round_trip cc req in
    let first =
      match resp.cres_body with Api.Body.Stream next -> next () | _ -> None
    in
    let first_len = match first with Some s -> String.length s | None -> 0 in
    let rest = Api.Body.read_all resp.cres_body in
    let total = first_len + String.length rest in
    (Httpg_base.Status.to_int resp.cres_status_code, first_len, total)
  in
  let code, first_len, total = run ~handler client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check bool) "first chunk readable before EOF" true (first_len > 0);
  Alcotest.(check int)
    "total body length"
    (chunk |> String.length |> ( * ) chunks)
    total

let tests =
  [
    Alcotest.test_case "server_streams_multiple_data" `Quick
      test_server_streams_multiple_data;
    Alcotest.test_case "large_body" `Quick test_large_body;
    Alcotest.test_case "incremental_client_read" `Quick
      test_incremental_client_read;
  ]
