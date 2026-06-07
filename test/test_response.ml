(* Ported from go/src/net/http/response_test.go (ReadResponse rows). *)

let read ?request s =
  match Httpg.Io.read_response ?request (Eio.Buf_read.of_string s) with
  | Ok r -> r
  | Error e -> failwith (Httpg.Io.error_to_string e)

let body_of (r : Httpg.Body.t Httpg.Response.t) = Httpg.Body.read_all r.body
let i64 = Int64.to_string

(* HTTP/1.0 unchunked, Connection: close, no Content-Length. *)
let http10_close () =
  let raw = "HTTP/1.0 200 OK\r\nConnection: close\r\n\r\nBody here\n" in
  let r = read raw in
  Alcotest.(check string) "status" "200 OK" r.status;
  Alcotest.(check int) "code" 200 (Httpg_base.Status.to_int r.status_code);
  Alcotest.(check string) "proto" "HTTP/1.0" r.proto;
  Alcotest.(check bool) "close" true r.close;
  Alcotest.(check string) "content_length" "-1" (i64 r.content_length);
  Alcotest.(check string) "body" "Body here\n" (body_of r)

(* HTTP/1.1 unchunked, no Content-Length/Connection => close-delimited. *)
let http11_no_length () =
  let raw = "HTTP/1.1 200 OK\r\n\r\nBody here\n" in
  let r = read raw in
  Alcotest.(check bool) "close" true r.close;
  Alcotest.(check string) "content_length" "-1" (i64 r.content_length);
  Alcotest.(check string) "body" "Body here\n" (body_of r)

(* 204 No Content: no body even with bytes present. *)
let no_content () =
  let raw = "HTTP/1.1 204 No Content\r\n\r\nBody should not be read!\n" in
  let r = read raw in
  Alcotest.(check int) "code" 204 (Httpg_base.Status.to_int r.status_code);
  Alcotest.(check bool) "close" false r.close;
  Alcotest.(check string) "content_length" "0" (i64 r.content_length);
  Alcotest.(check string) "body" "" (body_of r)

(* Unchunked with Content-Length. *)
let content_length () =
  let raw =
    "HTTP/1.0 200 OK\r\n\
     Content-Length: 10\r\n\
     Connection: close\r\n\
     \r\n\
     Body here\n"
  in
  let r = read raw in
  Alcotest.(check string) "content_length" "10" (i64 r.content_length);
  Alcotest.(check bool) "close" true r.close;
  Alcotest.(check string)
    "cl header" "10"
    (Httpg.Header.get r.header "Content-Length");
  Alcotest.(check string) "body" "Body here\n" (body_of r)

(* Chunked, multiple chunks. *)
let chunked () =
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    ^ "0a\r\nBody here\n\r\n" ^ "09\r\ncontinued\r\n" ^ "0\r\n\r\n"
  in
  let r = read raw in
  Alcotest.(check (list string)) "te" [ "chunked" ] r.transfer_encoding;
  Alcotest.(check string) "content_length" "-1" (i64 r.content_length);
  Alcotest.(check string) "body" "Body here\ncontinued" (body_of r)

(* Location resolved against the request URL. *)
let location () =
  let request =
    {
      Httpg.Request.meth = "GET";
      url = Uri.of_string "http://example.com/from";
      proto = "HTTP/1.1";
      proto_major = 1;
      proto_minor = 1;
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
  in
  let raw =
    "HTTP/1.1 302 Found\r\nLocation: /to\r\nContent-Length: 0\r\n\r\n"
  in
  let r = read ~request raw in
  (match Httpg.Response.location r with
  | Some u ->
      Alcotest.(check string)
        "location" "http://example.com/to" (Uri.to_string u)
  | None -> Alcotest.fail "expected location");
  let raw2 = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" in
  let r2 = read raw2 in
  Alcotest.(check bool) "no location" true (Httpg.Response.location r2 = None)

let tests =
  [
    ("http10_close", `Quick, http10_close);
    ("http11_no_length", `Quick, http11_no_length);
    ("no_content_204", `Quick, no_content);
    ("content_length", `Quick, content_length);
    ("chunked", `Quick, chunked);
    ("location", `Quick, location);
  ]
