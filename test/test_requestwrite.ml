(* Ported from go/src/net/http/requestwrite_test.go (representative rows). *)

let chunk s = Printf.sprintf "%x\r\n%s\r\n" (String.length s) s

(* Capture output written by [f oc] into a string. *)
let capture (f : Lwt_io.output_channel -> unit Lwt.t) : string =
  Lwt_main.run
    (let buf = Buffer.create 256 in
     let oc =
       Lwt_io.make ~mode:Lwt_io.output (fun bytes off len ->
           let b = Bytes.create len in
           Lwt_bytes.blit_to_bytes bytes off b 0 len;
           Buffer.add_bytes buf b;
           Lwt.return len)
     in
     Lwt.bind (f oc) (fun () -> Lwt.bind (Lwt_io.close oc) (fun () -> Lwt.return (Buffer.contents buf))))

let header pairs =
  let h = Gohttp.Header.create () in
  List.iter (fun (k, v) -> Gohttp.Header.add h k v) pairs;
  h

let req ?(meth = "GET") ?(proto_major = 1) ?(proto_minor = 1) ?(header = Gohttp.Header.create ())
    ?(body = Gohttp.Body.Empty) ?(content_length = 0L) ?(transfer_encoding = []) ?(close = false)
    ?(host = "") url : Gohttp.Body.t Gohttp.Request.t =
  {
    Gohttp.Request.meth;
    url = Uri.of_string url;
    proto = Printf.sprintf "HTTP/%d.%d" proto_major proto_minor;
    proto_major;
    proto_minor;
    header;
    body;
    content_length;
    transfer_encoding;
    close;
    host;
    trailer = None;
    request_uri = "";
    remote_addr = "";
  }

let write r = capture (fun oc -> Gohttp.Io.write_request oc r)

(* Row 0: GET, no body, custom headers, no Content-Length. *)
let row0 () =
  let r =
    req ~host:"www.techcrunch.com"
      ~header:
        (header
           [
             ("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
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
    "GET / HTTP/1.1\r\n" ^ "Host: www.techcrunch.com\r\n" ^ "User-Agent: Fake\r\n"
    ^ "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
    ^ "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7\r\n" ^ "Accept-Encoding: gzip,deflate\r\n"
    ^ "Accept-Language: en-us,en;q=0.5\r\n" ^ "Keep-Alive: 300\r\n"
    ^ "Proxy-Connection: keep-alive\r\n\r\n"
  in
  Alcotest.(check string) "row0" want (write r)

(* Row 1: GET chunked body. *)
let row1 () =
  let r = req ~transfer_encoding:[ "chunked" ] ~body:(Gohttp.Body.of_string "abcdef") "http://www.google.com/search" in
  let want =
    "GET /search HTTP/1.1\r\n" ^ "Host: www.google.com\r\n" ^ "User-Agent: Go-http-client/1.1\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n" ^ chunk "abcdef" ^ chunk ""
  in
  Alcotest.(check string) "row1" want (write r)

(* Row 2: POST chunked body, Close. *)
let row2 () =
  let r =
    req ~meth:"POST" ~close:true ~transfer_encoding:[ "chunked" ]
      ~body:(Gohttp.Body.of_string "abcdef") "http://www.google.com/search"
  in
  let want =
    "POST /search HTTP/1.1\r\n" ^ "Host: www.google.com\r\n" ^ "User-Agent: Go-http-client/1.1\r\n"
    ^ "Connection: close\r\n" ^ "Transfer-Encoding: chunked\r\n\r\n" ^ chunk "abcdef" ^ chunk ""
  in
  Alcotest.(check string) "row2" want (write r)

(* Row 3: POST with Content-Length, Close, no chunking. *)
let row3 () =
  let r = req ~meth:"POST" ~close:true ~content_length:6L ~body:(Gohttp.Body.of_string "abcdef") "http://www.google.com/search" in
  let want =
    "POST /search HTTP/1.1\r\n" ^ "Host: www.google.com\r\n" ^ "User-Agent: Go-http-client/1.1\r\n"
    ^ "Connection: close\r\n" ^ "Content-Length: 6\r\n" ^ "\r\n" ^ "abcdef"
  in
  Alcotest.(check string) "row3" want (write r)

(* Row 4: Content-Length in headers is ignored (derived from the field). *)
let row4 () =
  let r =
    req ~meth:"POST" ~host:"example.com" ~content_length:6L
      ~header:(header [ ("Content-Length", "10") ])
      ~body:(Gohttp.Body.of_string "abcdef") "http://example.com/"
  in
  let want =
    "POST / HTTP/1.1\r\n" ^ "Host: example.com\r\n" ^ "User-Agent: Go-http-client/1.1\r\n"
    ^ "Content-Length: 6\r\n" ^ "\r\n" ^ "abcdef"
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
