(* Stream Ticket 4 — HTTP/2 streaming alignment integration tests.

   Connects a Gohttp.H2_transport client_conn to H2_server.serve over a real
   loopback TCP socket pair (as test_h2_transport.ml does) and asserts that h2
   bodies stream end-to-end: the server frames DATA per write/flush (no hidden
   whole-body buffer), a large body spanning many DATA frames (and exercising
   flow control) round-trips intact, and the client reads the response body
   incrementally (first chunk before EOF). Bounded by Net.with_timeout so a hang
   fails. *)

open Gohttp

let ( let* ) = Lwt.bind

let mk_request ~meth ~path ?(body = Body.Empty) () : Body.t Request.t =
  let content_length =
    match body with Body.String s -> Int64.of_int (String.length s) | _ -> 0L
  in
  {
    Request.meth;
    url = Uri.of_string ("https://example.com" ^ path);
    proto = "HTTP/2.0";
    proto_major = 2;
    proto_minor = 0;
    header = Header.create ();
    body;
    content_length;
    transfer_encoding = [];
    close = false;
    host = "";
    trailer = None;
    request_uri = "";
    remote_addr = "";
    form = None;
    post_form = None;
    multipart_form = None;
    ctx = Context.background;
  }

(* Run [client cc] against an H2_server.serve over a real loopback socket pair,
   bounded. The server runs [handler]. *)
let run ?(timeout = 15.) ~handler client =
  Lwt_main.run
    (Net.with_timeout timeout
       (let* lfd = Net.listen "127.0.0.1" 0 in
        let port = Net.bound_port lfd in
        let server =
          let* cfd, _addr = Net.accept lfd in
          let s_ic, s_oc = Net.channels_of_fd cfd in
          H2_server.serve s_ic s_oc ~handler
        in
        Lwt.async (fun () ->
            Lwt.catch (fun () -> server) (fun _ -> Lwt.return_unit));
        let* c_ic, c_oc = Net.connect ~host:"127.0.0.1" ~port () in
        let* cc = H2_transport.new_client_conn c_ic c_oc in
        let* r = client cc in
        let* () =
          Lwt.catch (fun () -> H2_transport.close cc) (fun _ -> Lwt.return_unit)
        in
        Lwt.return r))

(* ---- server frames multiple DATA frames as the handler writes+flushes ---- *)
(* The handler writes "alpha", flushes, then blocks on a promise the test
   resolves only after the client has read that first chunk — proving the chunk
   is observable on the wire before the handler completes (DATA-per-write, not a
   whole-body buffer). It then writes "beta"/"gamma" with flushes between. *)
let test_server_streams_multiple_data () =
  let released, release = Lwt.wait () in
  let handler (rw : H2_server.response_writer) (_req : Body.t Request.t) =
    let* () = rw.write "alpha" in
    let* () = rw.flush () in
    let* () = released in
    let* () = rw.write "beta" in
    let* () = rw.flush () in
    let* () = rw.write "gamma" in
    rw.flush ()
  in
  let client cc =
    let req = mk_request ~meth:"GET" ~path:"/" () in
    let* resp = H2_transport.round_trip cc req in
    (* Read the first chunk from the streaming response body. The server is
       suspended on [released] until we wake it, so receiving "alpha" here proves
       the first DATA frame arrived before the handler finished. *)
    let first =
      match resp.Response.body with
      | Body.Stream next -> next ()
      | _ -> Lwt.return None
    in
    let* first_chunk = first in
    let handler_suspended_when_first_seen = Lwt.state released = Lwt.Sleep in
    Lwt.wakeup_later release ();
    (* drain the rest *)
    let* rest = Body.read_all resp.Response.body in
    let full = (match first_chunk with Some s -> s | None -> "") ^ rest in
    Lwt.return
      (resp.Response.status_code, first_chunk, handler_suspended_when_first_seen, full)
  in
  let code, first_chunk, suspended, full = run ~handler client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check (option string)) "first chunk is alpha" (Some "alpha") first_chunk;
  Alcotest.(check bool) "handler suspended when first chunk seen" true suspended;
  Alcotest.(check string) "full body" "alphabetagamma" full

(* ---- large body spanning many DATA frames + flow control ---- *)
(* 200 KiB > the 16384 default max frame size and large enough to exercise
   stream/conn flow control and WINDOW_UPDATE; must round-trip byte-for-byte. *)
let test_large_body () =
  let n = 200 * 1024 in
  let payload = String.init n (fun i -> Char.chr (i mod 256)) in
  let handler (rw : H2_server.response_writer) (_req : Body.t Request.t) =
    (* one big write: the writer must auto-frame it into many DATA frames *)
    let* () = rw.write payload in
    rw.flush ()
  in
  let client cc =
    let req = mk_request ~meth:"GET" ~path:"/big" () in
    let* resp = H2_transport.round_trip cc req in
    let* body = Body.read_all resp.Response.body in
    Lwt.return (resp.Response.status_code, body)
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
  let handler (rw : H2_server.response_writer) (_req : Body.t Request.t) =
    let rec loop i =
      if i >= chunks then Lwt.return_unit
      else
        let* () = rw.write chunk in
        let* () = rw.flush () in
        loop (i + 1)
    in
    loop 0
  in
  let client cc =
    let req = mk_request ~meth:"GET" ~path:"/stream" () in
    let* resp = H2_transport.round_trip cc req in
    let* first =
      match resp.Response.body with
      | Body.Stream next -> next ()
      | _ -> Lwt.return None
    in
    let first_len = match first with Some s -> String.length s | None -> 0 in
    let* rest = Body.read_all resp.Response.body in
    let total = first_len + String.length rest in
    Lwt.return (resp.Response.status_code, first_len, total)
  in
  let code, first_len, total = run ~handler client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check bool) "first chunk readable before EOF" true (first_len > 0);
  Alcotest.(check int) "total body length" (chunk |> String.length |> ( * ) chunks) total

let tests =
  [
    Alcotest.test_case "server_streams_multiple_data" `Quick
      test_server_streams_multiple_data;
    Alcotest.test_case "large_body" `Quick test_large_body;
    Alcotest.test_case "incremental_client_read" `Quick
      test_incremental_client_read;
  ]
