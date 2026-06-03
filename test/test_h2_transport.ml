(* Integration tests for Gohttp.H2_transport: connect an H2_transport client_conn
   to H2_server.serve (Ticket 8) over a real loopback TCP socket pair, performing
   GET / POST / concurrent round trips. Ported subset of
   go/src/net/http/internal/http2/transport_test.go (TestTransport / GET, POST,
   concurrent streams). Bounded by Net.with_timeout so a hang fails. *)

open Gohttp

let ( let* ) = Lwt.bind

let mk_request ~meth ~path ?(body = Body.Empty) () : Body.t Request.t =
  let content_length =
    match body with
    | Body.String s -> Int64.of_int (String.length s)
    | _ -> 0L
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
let run ~handler client =
  Lwt_main.run
    (Net.with_timeout 15.
       (let* lfd = Net.listen "127.0.0.1" 0 in
        let port = Net.bound_port lfd in
        (* server fiber: accept one connection and serve it. *)
        let server =
          let* cfd, _addr = Net.accept lfd in
          let s_ic, s_oc = Net.channels_of_fd cfd in
          H2_server.serve s_ic s_oc ~handler
        in
        Lwt.async (fun () ->
            Lwt.catch (fun () -> server) (fun _ -> Lwt.return_unit));
        (* client: connect, build a ClientConn, run the test body. *)
        let* c_ic, c_oc = Net.connect ~host:"127.0.0.1" ~port () in
        let* cc = H2_transport.new_client_conn c_ic c_oc in
        let* r = client cc in
        let* () =
          Lwt.catch (fun () -> H2_transport.close cc) (fun _ -> Lwt.return_unit)
        in
        Lwt.return r))

(* ---- TestTransport: simple GET, 200 + "hello" body ---- *)
let test_get () =
  let handler (rw : H2_server.response_writer) (_req : Body.t Request.t) =
    let* () = rw.write "hello" in
    rw.flush ()
  in
  let client cc =
    let req = mk_request ~meth:"GET" ~path:"/" () in
    let* resp = H2_transport.round_trip cc req in
    let* body = Body.read_all resp.Response.body in
    Lwt.return (resp.Response.status_code, body)
  in
  let code, body = run ~handler client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check string) "body hello" "hello" body

(* ---- TestTransport POST echo ---- *)
let test_post_echo () =
  let handler (rw : H2_server.response_writer) (req : Body.t Request.t) =
    let* body = Body.read_all req.Request.body in
    let* () = rw.write body in
    rw.flush ()
  in
  let client cc =
    let req = mk_request ~meth:"POST" ~path:"/echo" ~body:(Body.String "ping") () in
    let* resp = H2_transport.round_trip cc req in
    let* body = Body.read_all resp.Response.body in
    Lwt.return (resp.Response.status_code, body)
  in
  let code, body = run ~handler client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check string) "echo ping" "ping" body

(* ---- TestTransport two concurrent round trips on one ClientConn ---- *)
let test_concurrent () =
  let handler (rw : H2_server.response_writer) (req : Body.t Request.t) =
    let path = Uri.path req.Request.url in
    let* () = rw.write ("ok:" ^ path) in
    rw.flush ()
  in
  let client cc =
    let do_rt path =
      let req = mk_request ~meth:"GET" ~path () in
      let* resp = H2_transport.round_trip cc req in
      let* body = Body.read_all resp.Response.body in
      Lwt.return (resp.Response.status_code, body)
    in
    Lwt.both (do_rt "/a") (do_rt "/b")
  in
  let (c1, b1), (c2, b2) = run ~handler client in
  Alcotest.(check int) "s1 status" 200 c1;
  Alcotest.(check int) "s2 status" 200 c2;
  Alcotest.(check string) "s1 body" "ok:/a" b1;
  Alcotest.(check string) "s2 body" "ok:/b" b2

let tests =
  [
    Alcotest.test_case "get" `Quick test_get;
    Alcotest.test_case "post_echo" `Quick test_post_echo;
    Alcotest.test_case "concurrent" `Quick test_concurrent;
  ]
