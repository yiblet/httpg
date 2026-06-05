(* Integration tests for Gohttp.H2_server: drive a raw HTTP/2 client (the
   Ticket-4 Framer + Ticket-3 Hpack encoder) over an Lwt_io.pipe pair against
   H2_server.serve, asserting response HEADERS/DATA. Ported subset of
   go/src/net/http/internal/http2/server_test.go (TestServer / GET, POST echo,
   concurrent streams). Bounded by Net.with_timeout so a hang fails. *)

open Gohttp
open Gohttp_http2
module F = H2_frame
module S = H2_server

(* A full-duplex channel pair: [c2s] carries client->server bytes, [s2c]
   carries server->client bytes. Returns (server_ic, server_oc, client_ic,
   client_oc). *)
let duplex () =
  let s_ic, c_oc = Lwt_io.pipe () in
  (* client writes to c_oc -> server reads from s_ic *)
  let c_ic, s_oc = Lwt_io.pipe () in
  (* server writes to s_oc -> client reads from c_ic *)
  (s_ic, s_oc, c_ic, c_oc)

(* Client-side helper: send preface + an (empty) SETTINGS frame. *)
let client_handshake oc =
  let open Lwt.Syntax in
  let* () = Lwt_io.write oc H2.client_preface in
  let* () = F.write_settings oc [] in
  Lwt_io.flush oc

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
  let open Lwt.Syntax in
  let* f =
    Lwt.map
      (function Ok f -> f | Error e -> raise (H2_error.to_exception e))
      (F.read_frame ic)
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
  if until (List.rev acc) then Lwt.return (List.rev acc)
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

(* Run [client] against [serve handler] over a duplex pair, bounded. *)
let run ~handler client =
  Lwt_main.run
    (Net.with_timeout 15.
       (let s_ic, s_oc, c_ic, c_oc = duplex () in
        let server = S.serve s_ic s_oc ~handler in
        let open Lwt.Syntax in
        let driver =
          let* r = client c_ic c_oc in
          (* tell the server we're done: closing the client->server side
             gives the server's reader an EOF, ending serve. *)
          let* () = Lwt_io.close c_oc in
          Lwt.return r
        in
        let* r = driver in
        (* let the server finish draining; ignore its result. *)
        let* () =
          Lwt.catch
            (fun () -> Lwt.pick [ server; Lwt_unix.sleep 1.0 ])
            (fun _ -> Lwt.return_unit)
        in
        Lwt.return r))

(* ---- TestServer: simple GET, 200 + "hello" body ---- *)
let test_get () =
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    let open Lwt.Syntax in
    let* () = rw.rw_write "hello" in
    rw.rw_flush ()
  in
  let client ic oc =
    let open Lwt.Syntax in
    let* () = client_handshake oc in
    let* () =
      client_headers oc ~stream_id:1
        [
          (":method", "GET");
          (":path", "/");
          (":scheme", "https");
          (":authority", "example.com");
        ]
    in
    let* () = Lwt_io.flush oc in
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
    let open Lwt.Syntax in
    let* body = Api.Body.read_all req.sreq_body in
    let* () = rw.rw_write body in
    rw.rw_flush ()
  in
  let client ic oc =
    let open Lwt.Syntax in
    let* () = client_handshake oc in
    let* () =
      client_headers oc ~stream_id:1 ~end_stream:false
        [
          (":method", "POST");
          (":path", "/echo");
          (":scheme", "https");
          (":authority", "example.com");
        ]
    in
    let* () = F.write_data oc 1 true "ping" in
    let* () = Lwt_io.flush oc in
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
    let open Lwt.Syntax in
    (* echo the path so we can distinguish streams *)
    let path = Uri.path req.sreq_url in
    let* () = rw.rw_write ("ok:" ^ path) in
    rw.rw_flush ()
  in
  let client ic oc =
    let open Lwt.Syntax in
    let* () = client_handshake oc in
    let* () =
      client_headers oc ~stream_id:1
        [
          (":method", "GET");
          (":path", "/a");
          (":scheme", "https");
          (":authority", "x");
        ]
    in
    let* () =
      client_headers oc ~stream_id:3
        [
          (":method", "GET");
          (":path", "/b");
          (":scheme", "https");
          (":authority", "x");
        ]
    in
    let* () = Lwt_io.flush oc in
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

let tests =
  [
    Alcotest.test_case "get" `Quick test_get;
    Alcotest.test_case "post_echo" `Quick test_post_echo;
    Alcotest.test_case "two_streams" `Quick test_two_streams;
  ]
