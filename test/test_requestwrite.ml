(* Ported from go/src/net/http/requestwrite_test.go (representative rows). *)

let chunk s = Printf.sprintf "%x\r\n%s\r\n" (String.length s) s

(* Capture output written by [f w] into a string. *)
let capture (f : Eio.Buf_write.t -> unit) : string =
  let w = Eio.Buf_write.create 256 in
  f w;
  Eio.Buf_write.serialize_to_string w

let header pairs =
  let h = Httpg.Header.create () in
  List.iter (fun (k, v) -> Httpg.Header.add h k v) pairs;
  h

let req ?(meth = "GET") ?(proto_major = 1) ?(proto_minor = 1)
    ?(header = Httpg.Header.create ()) ?(body = Httpg.Body.Empty)
    ?(content_length = 0L) ?(transfer_encoding = []) ?(close = false)
    ?(host = "") url : Httpg.Body.t Httpg.Request.t =
  {
    Httpg.Request.meth = Httpg_base.Method.of_string meth;
    url = Uri.of_string url;
    proto =
      Option.get
        (Httpg_base.Protocol.of_string
           (Printf.sprintf "HTTP/%d.%d" proto_major proto_minor));
    header;
    body;
    content_length;
    transfer_encoding;
    close;
    host;
    trailer = None;
    request_uri = "";
    remote_addr = "";
    form = None;
    post_form = None;
    multipart_form = None;
  }

let write r =
  capture (fun w ->
      match Httpg.Io.write_request w r with
      | Ok () -> ()
      | Error e -> failwith (Httpg.Io.error_to_string e))

(* Row 0: GET, no body, custom headers, no Content-Length. *)
let row0 () =
  let r =
    req ~host:"www.techcrunch.com"
      ~header:
        (header
           [
             ( "Accept",
               "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
             );
             ("Accept-Charset", "ISO-8859-1,utf-8;q=0.7,*;q=0.7");
             ("Accept-Encoding", "gzip,deflate");
             ("Accept-Language", "en-us,en;q=0.5");
             ("Keep-Alive", "300");
             ("Proxy-Connection", "keep-alive");
             ("User-Agent", "Fake");
           ])
      "http://www.techcrunch.com/"
  in
  let want =
    "GET / HTTP/1.1\r\n" ^ "Host: www.techcrunch.com\r\n"
    ^ "User-Agent: Fake\r\n"
    ^ "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
    ^ "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7\r\n"
    ^ "Accept-Encoding: gzip,deflate\r\n"
    ^ "Accept-Language: en-us,en;q=0.5\r\n" ^ "Keep-Alive: 300\r\n"
    ^ "Proxy-Connection: keep-alive\r\n\r\n"
  in
  Alcotest.(check string) "row0" want (write r)

(* Row 1: GET chunked body. *)
let row1 () =
  let r =
    req ~transfer_encoding:[ "chunked" ]
      ~body:(Httpg.Body.of_string "abcdef")
      "http://www.google.com/search"
  in
  let want =
    "GET /search HTTP/1.1\r\n" ^ "Host: www.google.com\r\n"
    ^ "User-Agent: Go-http-client/1.1\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n" ^ chunk "abcdef" ^ chunk ""
  in
  Alcotest.(check string) "row1" want (write r)

(* Row 2: POST chunked body, Close. *)
let row2 () =
  let r =
    req ~meth:"POST" ~close:true ~transfer_encoding:[ "chunked" ]
      ~body:(Httpg.Body.of_string "abcdef")
      "http://www.google.com/search"
  in
  let want =
    "POST /search HTTP/1.1\r\n" ^ "Host: www.google.com\r\n"
    ^ "User-Agent: Go-http-client/1.1\r\n" ^ "Connection: close\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n" ^ chunk "abcdef" ^ chunk ""
  in
  Alcotest.(check string) "row2" want (write r)

(* Row 3: POST with Content-Length, Close, no chunking. *)
let row3 () =
  let r =
    req ~meth:"POST" ~close:true ~content_length:6L
      ~body:(Httpg.Body.of_string "abcdef")
      "http://www.google.com/search"
  in
  let want =
    "POST /search HTTP/1.1\r\n" ^ "Host: www.google.com\r\n"
    ^ "User-Agent: Go-http-client/1.1\r\n" ^ "Connection: close\r\n"
    ^ "Content-Length: 6\r\n" ^ "\r\n" ^ "abcdef"
  in
  Alcotest.(check string) "row3" want (write r)

(* Row 4: Content-Length in headers is ignored (derived from the field). *)
let row4 () =
  let r =
    req ~meth:"POST" ~host:"example.com" ~content_length:6L
      ~header:(header [ ("Content-Length", "10") ])
      ~body:(Httpg.Body.of_string "abcdef")
      "http://example.com/"
  in
  let want =
    "POST / HTTP/1.1\r\n" ^ "Host: example.com\r\n"
    ^ "User-Agent: Go-http-client/1.1\r\n" ^ "Content-Length: 6\r\n" ^ "\r\n"
    ^ "abcdef"
  in
  Alcotest.(check string) "row4" want (write r)

let tests =
  [
    ("row0_get_headers", `Quick, row0);
    ("row1_get_chunked", `Quick, row1);
    ("row2_post_chunked_close", `Quick, row2);
    ("row3_post_content_length", `Quick, row3);
    ("row4_content_length_header_ignored", `Quick, row4);
  ]
