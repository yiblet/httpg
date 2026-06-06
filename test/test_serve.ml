(* Integration tests for the HTTP/1.x Server + ServeMux, a ported subset of
   go/src/net/http/serve_test.go.

   Each test starts a real loopback server on an ephemeral port, drives it with a
   raw client socket (raw bytes, since these assert on the wire) and asserts on
   the raw response bytes. Bounded by Test_harness.with_env. *)

open Httpg

let handle_func mux pattern f = Result.get_ok (Server.handle_func mux pattern f)

(* Read everything until EOF (connection close). *)
let read_to_eof (r : Eio.Buf_read.t) = Eio.Buf_read.take_all r

(* Read headers + a fixed Content-Length body (does not require the server to
   close). Reads byte-by-byte until "\r\n\r\n", parses Content-Length, then the
   body. *)
let read_one_response (r : Eio.Buf_read.t) =
  let headers =
    (* Read up to and including the blank line, byte by byte. *)
    let buf = Buffer.create 256 in
    let rec loop () =
      let c = Eio.Buf_read.any_char r in
      Buffer.add_char buf c;
      let s = Buffer.contents buf in
      let n = String.length s in
      if n >= 4 && String.sub s (n - 4) 4 = "\r\n\r\n" then s else loop ()
    in
    loop ()
  in
  let cl =
    try
      let _ =
        Str.search_forward
          (Str.regexp_case_fold "content-length:[ \t]*\\([0-9]+\\)")
          headers 0
      in
      Some (int_of_string (Str.matched_group 1 headers))
    with Not_found -> None
  in
  match cl with
  | None -> headers
  | Some 0 -> headers
  | Some n -> headers ^ Eio.Buf_read.take n r

let body_of resp =
  match Str.search_forward (Str.regexp "\r\n\r\n") resp 0 with
  | i -> String.sub resp (i + 4) (String.length resp - i - 4)
  | exception Not_found -> ""

let status_line resp =
  match String.index_opt resp '\r' with
  | Some i -> String.sub resp 0 i
  | None -> resp

let contains haystack needle =
  match Str.search_forward (Str.regexp_string needle) haystack 0 with
  | _ -> true
  | exception Not_found -> false

(* Start [handler], connect a raw client and run [fn r w] over buffered
   channels, then close the server. *)
let with_raw_client handler fn =
  Test_harness.with_env (fun ~net ~clock ~sw ->
      let srv, port, serve_loop =
        Server.listen_and_serve_started ~net ~clock ~sw ~addr:"127.0.0.1"
          ~port:0 handler
      in
      Eio.Fiber.fork ~sw serve_loop;
      Fun.protect
        ~finally:(fun () -> Server.close srv)
        (fun () ->
          let flow = Net.connect ~sw net ~host:"127.0.0.1" ~port in
          Net.with_connection flow (fun r w -> fn r w)))

let send w s =
  Eio.Buf_write.string w s;
  Eio.Buf_write.flush w

(* ---- handlers ---- *)

let hello_handler = Server.handler_func (fun w _r -> w.Server.write "hello")

(* ---- tests ---- *)

let hello_handler_test () =
  let resp =
    with_raw_client hello_handler (fun r w ->
        send w "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        read_to_eof r)
  in
  Alcotest.(check bool)
    "200 status line" true
    (contains (status_line resp) "200 OK");
  Alcotest.(check string) "body" "hello" (body_of resp)

let not_found_test () =
  let mux = Server.new_serve_mux () in
  handle_func mux "/known" (fun w _r -> w.Server.write "ok");
  let resp =
    with_raw_client (Server.serve_mux_handler mux) (fun r w ->
        send w
          "GET /missing HTTP/1.1\r\n\
           Host: localhost\r\n\
           Connection: close\r\n\
           \r\n";
        read_to_eof r)
  in
  Alcotest.(check bool)
    "404 status line" true
    (contains (status_line resp) "404 Not Found");
  Alcotest.(check bool)
    "body mentions not found" true
    (contains resp "404 page not found")

let mux_routing_test () =
  let mux = Server.new_serve_mux () in
  handle_func mux "/a" (fun w _r -> w.Server.write "handler-a");
  handle_func mux "/b" (fun w _r -> w.Server.write "handler-b");
  handle_func mux "POST /c" (fun w _r -> w.Server.write "handler-c-post");
  let h = Server.serve_mux_handler mux in
  let get path r w =
    send w
      (Printf.sprintf
         "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" path);
    read_to_eof r
  in
  let ra = with_raw_client h (get "/a") in
  Alcotest.(check string) "path /a" "handler-a" (body_of ra);
  let rb = with_raw_client h (get "/b") in
  Alcotest.(check string) "path /b" "handler-b" (body_of rb);
  let rc_get = with_raw_client h (get "/c") in
  Alcotest.(check bool)
    "GET /c 405" true
    (contains (status_line rc_get) "405 Method Not Allowed");
  Alcotest.(check bool) "Allow header" true (contains rc_get "Allow: POST");
  let rc_post =
    with_raw_client h (fun r w ->
        send w
          "POST /c HTTP/1.1\r\n\
           Host: localhost\r\n\
           Content-Length: 0\r\n\
           Connection: close\r\n\
           \r\n";
        read_to_eof r)
  in
  Alcotest.(check string) "POST /c" "handler-c-post" (body_of rc_post)

(* HTTP/1.0: closes by default; keep-alive only when requested. *)
let http10_close_test () =
  let resp =
    with_raw_client hello_handler (fun r w ->
        send w "GET / HTTP/1.0\r\n\r\n";
        read_to_eof r)
  in
  Alcotest.(check bool)
    "HTTP/1.0 status" true
    (contains (status_line resp) "HTTP/1.0 200");
  Alcotest.(check string) "HTTP/1.0 body" "hello" (body_of resp);
  Alcotest.(check bool)
    "no keep-alive on default 1.0" false
    (contains resp "Connection: keep-alive");

  (* HTTP/1.0 with Connection: keep-alive: server keeps the connection open,
     emits "Connection: keep-alive", and we read a second response on the same
     socket. *)
  let resp1, resp2 =
    with_raw_client hello_handler (fun r w ->
        send w "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n";
        let resp1 = read_one_response r in
        send w "GET / HTTP/1.0\r\n\r\n";
        let resp2 = read_to_eof r in
        (resp1, resp2))
  in
  Alcotest.(check bool)
    "1.0 keep-alive advertised" true
    (contains resp1 "Connection: keep-alive");
  Alcotest.(check string) "keep-alive resp1 body" "hello" (body_of resp1);
  Alcotest.(check string) "keep-alive resp2 body" "hello" (body_of resp2)

(* Registering two conflicting patterns returns [Error (Register _)]. *)
let handle_conflict_result () =
  let mux = Server.new_serve_mux () in
  (match Server.handle_func mux "/a/{x}" (fun w _r -> w.Server.write "a") with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "first registration should succeed");
  (match Server.handle_func mux "/a/{y}" (fun w _r -> w.Server.write "b") with
  | Error (Server.Register msg) ->
      Alcotest.(check bool)
        "conflict message" true
        (contains msg "conflicts with")
  | Ok () -> Alcotest.fail "conflicting registration should be Error");
  match Server.handle_func mux "" (fun w _r -> w.Server.write "c") with
  | Error (Server.Register _) -> ()
  | Ok () -> Alcotest.fail "empty pattern should be Error"

let tests =
  [
    Alcotest.test_case "hello_handler" `Quick hello_handler_test;
    Alcotest.test_case "not_found" `Quick not_found_test;
    Alcotest.test_case "mux_routing" `Quick mux_routing_test;
    Alcotest.test_case "http10_close" `Quick http10_close_test;
    Alcotest.test_case "handle_conflict_result" `Quick handle_conflict_result;
  ]
