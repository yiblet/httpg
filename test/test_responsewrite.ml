(* Ported from go/src/net/http/responsewrite_test.go (respWriteTests). *)

let capture (f : Eio.Buf_write.t -> unit) : string =
  let w = Eio.Buf_write.create 256 in
  f w;
  Eio.Buf_write.serialize_to_string w

let dummy_req ?(meth = "GET") ?(proto_minor = 0) () :
    Httpg.Body.t Httpg.Request.t =
  {
    Httpg.Request.meth = Httpg_base.Method.of_string meth;
    url = Uri.of_string "/";
    proto = Printf.sprintf "HTTP/1.%d" proto_minor;
    proto_major = 1;
    proto_minor;
    header = Httpg.Header.create ();
    body = Httpg.Body.Empty;
    content_length = 0L;
    transfer_encoding = [];
    close = false;
    host = "";
    trailer = None;
    request_uri = "";
    remote_addr = "";
    form = None;
    post_form = None;
    multipart_form = None;
  }

let header pairs =
  let h = Httpg.Header.create () in
  List.iter (fun (k, v) -> Httpg.Header.add h k v) pairs;
  h

let resp ?(status = "") ~status_code ?(proto_major = 1) ?(proto_minor = 1)
    ?(header = Httpg.Header.create ()) ?(body = Httpg.Body.Empty)
    ?(content_length = 0L) ?(transfer_encoding = []) ?(close = false) ?request
    () : Httpg.Body.t Httpg.Response.t =
  {
    Httpg.Response.status;
    status_code =
      (match Httpg_base.Status.of_int_result status_code with
      | Ok s -> s
      | Error _ -> Httpg_base.Status.Custom status_code);
    proto = Printf.sprintf "HTTP/%d.%d" proto_major proto_minor;
    proto_major;
    proto_minor;
    header;
    body;
    content_length;
    transfer_encoding;
    close;
    uncompressed = false;
    trailer = None;
    request;
  }

let write r = capture (fun oc -> Httpg.Io.write_response oc r)
let body s = Httpg.Body.of_string s

let http10_identity () =
  let r =
    resp ~status_code:503 ~proto_minor:0 ~request:(dummy_req ())
      ~body:(body "abcdef") ~content_length:6L ()
  in
  Alcotest.(check string)
    "503" "HTTP/1.0 503 Service Unavailable\r\nContent-Length: 6\r\n\r\nabcdef"
    (write r)

let http10_no_length () =
  let r =
    resp ~status_code:200 ~proto_minor:0 ~request:(dummy_req ())
      ~body:(body "abcdef") ~content_length:(-1L) ()
  in
  Alcotest.(check string) "1.0 no len" "HTTP/1.0 200 OK\r\n\r\nabcdef" (write r)

let http11_unknown_close () =
  let r =
    resp ~status_code:200 ~proto_minor:1
      ~request:(dummy_req ~proto_minor:1 ())
      ~body:(body "abcdef") ~content_length:(-1L) ~close:true ()
  in
  Alcotest.(check string)
    "1.1 close" "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabcdef" (write r)

let http11_unknown_no_close () =
  (* Go forces Connection: close for HTTP/1.1 unknown length. *)
  let r =
    resp ~status_code:200 ~proto_minor:1
      ~request:(dummy_req ~proto_minor:1 ())
      ~body:(body "abcdef") ~content_length:(-1L) ()
  in
  Alcotest.(check string)
    "1.1 forced close" "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabcdef"
    (write r)

let http11_chunked () =
  let r =
    resp ~status_code:200 ~proto_minor:1
      ~request:(dummy_req ~proto_minor:1 ())
      ~body:(body "abcdef") ~content_length:(-1L)
      ~transfer_encoding:[ "chunked" ] ()
  in
  Alcotest.(check string)
    "1.1 chunked"
    "HTTP/1.1 200 OK\r\n\
     Transfer-Encoding: chunked\r\n\
     \r\n\
     6\r\n\
     abcdef\r\n\
     0\r\n\
     \r\n"
    (write r)

let http11_zero_len_nil_body () =
  let r =
    resp ~status_code:200 ~proto_minor:1
      ~request:(dummy_req ~proto_minor:1 ())
      ~content_length:0L ()
  in
  Alcotest.(check string)
    "1.1 zero nil" "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" (write r)

let http11_zero_len_empty_body () =
  let r =
    resp ~status_code:200 ~proto_minor:1
      ~request:(dummy_req ~proto_minor:1 ())
      ~body:(body "") ~content_length:0L ()
  in
  Alcotest.(check string)
    "1.1 zero empty" "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" (write r)

let http11_zero_len_nonempty_body () =
  (* ContentLength 0 with a non-empty body: probe finds bytes, becomes unknown + close. *)
  let r =
    resp ~status_code:200 ~proto_minor:1
      ~request:(dummy_req ~proto_minor:1 ())
      ~body:(body "foo") ~content_length:0L ()
  in
  Alcotest.(check string)
    "1.1 zero nonempty" "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nfoo"
    (write r)

let http11_chunked_close () =
  let r =
    resp ~status_code:200 ~proto_minor:1 ~request:(dummy_req ())
      ~body:(body "abcdef") ~content_length:6L ~transfer_encoding:[ "chunked" ]
      ~close:true ()
  in
  Alcotest.(check string)
    "1.1 chunked close"
    "HTTP/1.1 200 OK\r\n\
     Connection: close\r\n\
     Transfer-Encoding: chunked\r\n\
     \r\n\
     6\r\n\
     abcdef\r\n\
     0\r\n\
     \r\n"
    (write r)

let header_newline () =
  let r =
    resp ~status_code:204 ~proto_minor:1 ~request:(dummy_req ())
      ~header:(header [ ("Foo", " Bar\nBaz ") ])
      ~content_length:0L ~transfer_encoding:[ "chunked" ] ~close:true ()
  in
  Alcotest.(check string)
    "newline"
    "HTTP/1.1 204 No Content\r\nConnection: close\r\nFoo: Bar Baz\r\n\r\n"
    (write r)

let post_single_content_length () =
  let r =
    resp ~status_code:200 ~proto_minor:1
      ~request:(dummy_req ~meth:"POST" ())
      ~content_length:0L ()
  in
  Alcotest.(check string)
    "post single CL" "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" (write r)

let post_negative_content_length () =
  let r =
    resp ~status_code:200 ~proto_minor:1
      ~request:(dummy_req ~meth:"POST" ())
      ~body:(body "abcdef") ~content_length:(-1L) ()
  in
  Alcotest.(check string)
    "post -1 CL" "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabcdef" (write r)

let status_zero_pad () =
  let r =
    resp ~status_code:7 ~status:"license to violate specs" ~proto_minor:0
      ~request:(dummy_req ()) ()
  in
  Alcotest.(check string)
    "zero pad"
    "HTTP/1.0 007 license to violate specs\r\nContent-Length: 0\r\n\r\n"
    (write r)

let status_1xx_no_length () =
  let r =
    resp ~status_code:123 ~status:"123 Sesame Street" ~proto_minor:0
      ~request:(dummy_req ()) ()
  in
  Alcotest.(check string)
    "1xx no len" "HTTP/1.0 123 Sesame Street\r\n\r\n" (write r)

let status_204_no_length () =
  let r =
    resp ~status_code:204 ~status:"No Content" ~proto_minor:0
      ~request:(dummy_req ()) ()
  in
  Alcotest.(check string)
    "204 no len" "HTTP/1.0 204 No Content\r\n\r\n" (write r)

let tests =
  [
    ("http10_identity", `Quick, http10_identity);
    ("http10_no_length", `Quick, http10_no_length);
    ("http11_unknown_close", `Quick, http11_unknown_close);
    ("http11_unknown_no_close", `Quick, http11_unknown_no_close);
    ("http11_chunked", `Quick, http11_chunked);
    ("http11_zero_len_nil_body", `Quick, http11_zero_len_nil_body);
    ("http11_zero_len_empty_body", `Quick, http11_zero_len_empty_body);
    ("http11_zero_len_nonempty_body", `Quick, http11_zero_len_nonempty_body);
    ("http11_chunked_close", `Quick, http11_chunked_close);
    ("header_newline", `Quick, header_newline);
    ("post_single_content_length", `Quick, post_single_content_length);
    ("post_negative_content_length", `Quick, post_negative_content_length);
    ("status_zero_pad", `Quick, status_zero_pad);
    ("status_1xx_no_length", `Quick, status_1xx_no_length);
    ("status_204_no_length", `Quick, status_204_no_length);
  ]
