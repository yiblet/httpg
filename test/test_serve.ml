(* Integration tests for the HTTP/1.x Server, a ported subset of
   go/src/net/http/serve_test.go. (ServeMux routing tests live in {!Test_mux},
   which exercises the mux in-process without a socket.)

   Each test starts a real loopback server on an ephemeral port, drives it with a
   raw client socket (raw bytes, since these assert on the wire) and asserts on
   the raw response bytes. Bounded by Test_harness.with_env. *)

open Httpg

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
        match
          Server.listen_and_serve_started ~net ~clock ~sw ~addr:"127.0.0.1"
            ~port:0 handler
        with
        | Ok v -> v
        | Error e -> Alcotest.failf "net: %s" (Net.error_to_string e)
      in
      Eio.Fiber.fork ~sw serve_loop;
      Fun.protect
        ~finally:(fun () -> Server.close srv)
        (fun () ->
          let flow =
            match Net.connect ~sw net ~host:"127.0.0.1" ~port with
            | Ok x -> x
            | Error e -> Alcotest.failf "net: %s" (Net.error_to_string e)
          in
          Net.with_connection flow (fun r w -> fn r w)))

let send w s =
  Eio.Buf_write.string w s;
  Eio.Buf_write.flush w

(* ---- handlers ---- *)

let hello_handler =
 fun ~sw:_ _r -> Response.with_body_string "hello" (Response.create ())

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

let tests =
  [
    Alcotest.test_case "hello_handler" `Quick hello_handler_test;
    Alcotest.test_case "http10_close" `Quick http10_close_test;
  ]
