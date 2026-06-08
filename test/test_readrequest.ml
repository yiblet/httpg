(* Ported from go/src/net/http/readrequest_test.go (representative rows). *)

let read s =
  match Httpg.Io.read_request (Eio.Buf_read.of_string s) with
  | Ok r -> r
  | Error e -> failwith (Httpg.Io.error_to_string e)

let body_of (r : Httpg.Request.t) = Httpg.Body.read_all r.body

(* Baseline: all fields included. *)
let baseline () =
  let raw =
    "GET http://www.techcrunch.com/ HTTP/1.1\r\n"
    ^ "Host: www.techcrunch.com\r\n" ^ "User-Agent: Fake\r\n"
    ^ "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
    ^ "Accept-Language: en-us,en;q=0.5\r\n"
    ^ "Accept-Encoding: gzip,deflate\r\n"
    ^ "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7\r\n"
    ^ "Keep-Alive: 300\r\n" ^ "Content-Length: 7\r\n"
    ^ "Proxy-Connection: keep-alive\r\n\r\n" ^ "abcdef\n???"
  in
  let r = read raw in
  Alcotest.(check string) "method" "GET" (Httpg_base.Method.to_string r.meth);
  Alcotest.(check string)
    "proto" "HTTP/1.1"
    (Httpg_base.Protocol.to_string r.proto);
  Alcotest.(check int) "major" 1 (Httpg_base.Protocol.major r.proto);
  Alcotest.(check int) "minor" 1 (Httpg_base.Protocol.minor r.proto);
  Alcotest.(check string) "host" "www.techcrunch.com" r.host;
  Alcotest.(check string)
    "request_uri" "http://www.techcrunch.com/" r.request_uri;
  Alcotest.(check bool) "close" false r.close;
  Alcotest.(check (list (of_pp Fmt.string)))
    "content_length" [ "7" ]
    [ Int64.to_string r.content_length ];
  Alcotest.(check string)
    "user-agent" "Fake"
    (Httpg.Header.get r.header "User-Agent");
  (* Host promoted out of the header map. *)
  Alcotest.(check bool) "host deleted" false (Httpg.Header.has r.header "Host");
  Alcotest.(check string) "body" "abcdef\n" (body_of r)

(* Simple GET, no body. *)
let simple_get () =
  let r = read "GET / HTTP/1.1\r\nHost: foo.com\r\n\r\n" in
  Alcotest.(check string) "method" "GET" (Httpg_base.Method.to_string r.meth);
  Alcotest.(check string) "host" "foo.com" r.host;
  Alcotest.(check string) "request_uri" "/" r.request_uri;
  Alcotest.(check string)
    "content_length" "0"
    (Int64.to_string r.content_length);
  Alcotest.(check string) "body" "" (body_of r)

(* Chunked body with trailer. *)
let chunked_trailer () =
  let raw =
    "POST / HTTP/1.1\r\n" ^ "Host: foo.com\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n" ^ "3\r\nbar\r\n"
    ^ "0\r\n" ^ "Trailer-Key: Trailer-Value\r\n" ^ "\r\n"
  in
  let r = read raw in
  Alcotest.(check string) "method" "POST" (Httpg_base.Method.to_string r.meth);
  Alcotest.(check (list string)) "te" [ "chunked" ] r.transfer_encoding;
  Alcotest.(check string)
    "content_length" "-1"
    (Int64.to_string r.content_length);
  Alcotest.(check string) "body" "foobar" (body_of r);
  match r.trailer with
  | Some t ->
      Alcotest.(check string)
        "trailer" "Trailer-Value"
        (Httpg.Header.get t "Trailer-Key")
  | None -> Alcotest.fail "expected trailer"

(* Chunked body with a bogus Content-Length to be removed. *)
let chunked_drops_content_length () =
  let raw =
    "POST / HTTP/1.1\r\n" ^ "Host: foo.com\r\n"
    ^ "Transfer-Encoding: chunked\r\n" ^ "Content-Length: 9999\r\n\r\n"
    ^ "3\r\nfoo\r\n" ^ "3\r\nbar\r\n" ^ "0\r\n" ^ "\r\n"
  in
  let r = read raw in
  Alcotest.(check (list string)) "te" [ "chunked" ] r.transfer_encoding;
  Alcotest.(check string)
    "content_length" "-1"
    (Int64.to_string r.content_length);
  Alcotest.(check bool)
    "no content-length header" false
    (Httpg.Header.has r.header "Content-Length");
  Alcotest.(check string) "body" "foobar" (body_of r)

(* HTTP/1.0 request: close-by-default, content-length body. *)
let http10 () =
  let raw =
    "GET /index.html HTTP/1.0\r\nHost: foo.com\r\nContent-Length: 3\r\n\r\nabc"
  in
  let r = read raw in
  Alcotest.(check string)
    "proto" "HTTP/1.0"
    (Httpg_base.Protocol.to_string r.proto);
  Alcotest.(check int) "minor" 0 (Httpg_base.Protocol.minor r.proto);
  Alcotest.(check bool) "close (1.0 default)" true r.close;
  Alcotest.(check string) "body" "abc" (body_of r)

(* HTTP/1.0 keep-alive honored. *)
let http10_keepalive () =
  let raw =
    "GET / HTTP/1.0\r\nHost: foo.com\r\nConnection: keep-alive\r\n\r\n"
  in
  let r = read raw in
  Alcotest.(check bool) "keep-alive" false r.close

let tests =
  [
    ("baseline", `Quick, baseline);
    ("simple_get", `Quick, simple_get);
    ("chunked_trailer", `Quick, chunked_trailer);
    ("chunked_drops_content_length", `Quick, chunked_drops_content_length);
    ("http10", `Quick, http10);
    ("http10_keepalive", `Quick, http10_keepalive);
  ]
