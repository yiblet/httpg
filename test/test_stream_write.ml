(* Streaming server responses (HTTP/1.x): the server [response_writer] mirrors
   Go's [response]/[chunkWriter] buffer-then-chunk model. These tests start a
   real loopback server on an ephemeral port, drive it with a raw client socket
   and assert on the raw response bytes:

   - server_streams_unbuffered: a handler that writes several chunks calling
     [flush] between them produces a chunked HTTP/1.1 response whose dechunked
     body equals the concatenation, AND a chunk is observable on the client
     before the handler signals completion.
   - small_response: a handler writing <=2048 bytes produces an exact
     Content-Length and NO Transfer-Encoding: chunked.
   - large_response: a handler writing >2048 bytes without flush is chunked.

   Bounded by Test_harness.with_env. *)

open Httpg

(* Read everything the server sends until EOF (connection close). *)
let read_to_eof (r : Eio.Buf_read.t) = Eio.Buf_read.take_all r

(* Pull the currently-buffered bytes (blocking for at least one), returning them
   as a string and consuming them. *)
let drain_buffered (r : Eio.Buf_read.t) =
  Eio.Buf_read.ensure r 1;
  let n = Eio.Buf_read.buffered_bytes r in
  let s = Cstruct.to_string (Eio.Buf_read.peek r) in
  Eio.Buf_read.consume r n;
  s

(* Split a raw response into (header block, body). *)
let split_headers raw =
  match Str.search_forward (Str.regexp "\r\n\r\n") raw 0 with
  | i -> (String.sub raw 0 i, String.sub raw (i + 4) (String.length raw - i - 4))
  | exception Not_found -> (raw, "")

let header_has raw re =
  try
    ignore (Str.search_forward (Str.regexp_case_fold re) raw 0);
    true
  with Not_found -> false

(* Decode an HTTP/1.1 chunked body into its payload. *)
let dechunk body =
  let out = Buffer.create 256 in
  let n = String.length body in
  let rec loop i =
    match Str.search_forward (Str.regexp "\r\n") body i with
    | exception Not_found -> Buffer.contents out
    | crlf ->
        let size_line = String.sub body i (crlf - i) in
        let size = int_of_string ("0x" ^ String.trim size_line) in
        if size = 0 then Buffer.contents out
        else begin
          let data_start = crlf + 2 in
          Buffer.add_string out (String.sub body data_start size);
          loop (data_start + size + 2)
        end
  in
  if n = 0 then "" else loop 0

(* Start [handler], connect a raw client socket, run [fn r w] over buffered
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

let send_get w =
  Eio.Buf_write.string w
    "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"

(* ---- unbuffered streaming with flush ---- *)
let server_streams_unbuffered () =
  let release, wake_release = Eio.Promise.create () in
  let handler =
    Server.handler_func (fun ~sw:_ _r ->
        (* The streaming loop now lives in the body closure: the serve loop pulls
           and flushes each chunk, so "alpha" reaches the client before "beta" is
           produced (the second pull blocks on [release]). *)
        let state = ref `Alpha in
        let next () =
          match !state with
          | `Alpha ->
              state := `Beta;
              Some "alpha"
          | `Beta ->
              Eio.Promise.await release;
              state := `Gamma;
              Some "beta"
          | `Gamma ->
              state := `Done;
              Some "gamma"
          | `Done -> None
        in
        Response.create () |> Response.with_body (Body.of_stream next))
  in
  with_raw_client handler (fun r w ->
      send_get w;
      (* Read incrementally until we have seen the first body chunk "alpha". *)
      let acc = Buffer.create 256 in
      let rec read_until_alpha () =
        Buffer.add_string acc (drain_buffered r);
        let _, body = split_headers (Buffer.contents acc) in
        if dechunk body = "alpha" then () else read_until_alpha ()
      in
      read_until_alpha ();
      let early = Buffer.contents acc in
      Alcotest.(check bool)
        "chunked encoding announced" true
        (header_has early "transfer-encoding:[ \t]*chunked");
      Alcotest.(check bool)
        "early alpha chunk present" true
        (let _, b = split_headers early in
         dechunk b = "alpha");
      (* Now let the handler finish and read the rest to EOF. *)
      Eio.Promise.resolve wake_release ();
      let rest = read_to_eof r in
      let _, body = split_headers (early ^ rest) in
      Alcotest.(check string) "dechunked body" "alphabetagamma" (dechunk body))

(* ---- Small response: <=2048 bytes => exact Content-Length, no chunking ---- *)
let small_response () =
  let handler =
    Server.handler_func (fun ~sw:_ _r ->
        Response.with_body_string "hello small body" (Response.create ()))
  in
  with_raw_client handler (fun r w ->
      send_get w;
      let raw = read_to_eof r in
      let headers, body = split_headers raw in
      Alcotest.(check bool)
        "has Content-Length" true
        (header_has headers "content-length:[ \t]*16");
      Alcotest.(check bool)
        "no chunked" false
        (header_has headers "transfer-encoding:[ \t]*chunked");
      Alcotest.(check string) "body" "hello small body" body)

(* ---- Large String body: exact Content-Length regardless of size ----
   Deviation from Go: with [Request -> Response] there is no
   bufferBeforeChunkingSize heuristic — a [Body.String] always has a known
   length and is sent with an exact Content-Length (chunking is reserved for an
   unknown-length [Body.Stream], see [server_streams_unbuffered]). *)
let large_response () =
  let payload = String.make 5000 'z' in
  let handler =
    Server.handler_func (fun ~sw:_ _r ->
        Response.create () |> Response.with_body_string payload)
  in
  with_raw_client handler (fun r w ->
      send_get w;
      let raw = read_to_eof r in
      let headers, body = split_headers raw in
      Alcotest.(check bool)
        "exact Content-Length" true
        (header_has headers "content-length:[ \t]*5000");
      Alcotest.(check bool)
        "not chunked" false
        (header_has headers "transfer-encoding:[ \t]*chunked");
      Alcotest.(check string) "body" payload body)

let tests =
  [
    ("server_streams_unbuffered", `Quick, server_streams_unbuffered);
    ("small_response", `Quick, small_response);
    ("large_response", `Quick, large_response);
  ]
