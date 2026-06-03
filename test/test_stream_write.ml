(* Ticket 2 (streaming server responses, HTTP/1.x): the server [response_writer]
   mirrors Go's [response]/[chunkWriter] buffer-then-chunk model. These tests
   start a real loopback server on an ephemeral port via
   [Server.listen_and_serve_started], drive it with a raw client socket
   ([Net.connect] + raw [Lwt_io]) and assert on the raw response bytes:

   - server_streams_unbuffered (Success Criterion): a handler that writes
     several chunks calling [flush] between them produces a chunked HTTP/1.1
     response whose dechunked body equals the concatenation, AND a chunk is
     observable on the client before the handler signals completion.
   - small_response: a handler writing one <=2048-byte string produces an exact
     Content-Length and NO Transfer-Encoding: chunked (Go's common case).
   - large_response: a handler writing >2048 bytes without flush is chunked and
     the dechunked body is intact.

   Bounded by [Net.with_timeout] so a hang fails rather than blocks. *)

open Gohttp
open Lwt.Infix

let run t = Lwt_main.run (Net.with_timeout 10.0 t)

(* Read everything the server sends until EOF (connection close). *)
let read_to_eof ic =
  let buf = Buffer.create 256 in
  let rec loop () =
    Lwt.catch
      (fun () -> Lwt_io.read ~count:4096 ic >>= fun s -> Lwt.return (Some s))
      (fun _ -> Lwt.return None)
    >>= function
    | Some "" | None -> Lwt.return (Buffer.contents buf)
    | Some s ->
        Buffer.add_string buf s;
        loop ()
  in
  loop ()

(* Split a raw response into (header block, body). *)
let split_headers raw =
  match Str.search_forward (Str.regexp "\r\n\r\n") raw 0 with
  | i -> (String.sub raw 0 i, String.sub raw (i + 4) (String.length raw - i - 4))
  | exception Not_found -> (raw, "")

let header_has raw re = try ignore (Str.search_forward (Str.regexp_case_fold re) raw 0); true with Not_found -> false

(* Decode an HTTP/1.1 chunked body into its payload. *)
let dechunk body =
  let out = Buffer.create 256 in
  let n = String.length body in
  let rec loop i =
    (* read the chunk-size line *)
    match Str.search_forward (Str.regexp "\r\n") body i with
    | exception Not_found -> Buffer.contents out
    | crlf ->
        let size_line = String.sub body i (crlf - i) in
        let size = int_of_string ("0x" ^ String.trim size_line) in
        if size = 0 then Buffer.contents out
        else begin
          let data_start = crlf + 2 in
          Buffer.add_string out (String.sub body data_start size);
          (* skip the trailing CRLF after the chunk data *)
          loop (data_start + size + 2)
        end
  in
  if n = 0 then "" else loop 0

(* ---- Success Criterion: unbuffered streaming with flush ---- *)

(* A handler that writes three chunks, flushing between them. A condition lets
   the test observe that the client has received an early chunk BEFORE the
   handler is allowed to write the final chunk + return. *)
let server_streams_unbuffered () =
  run
    (let got_first = Lwt_condition.create () in
     let release_handler, wake_release = Lwt.wait () in
     let handler =
       Server.handler_func (fun w _r ->
           w.Server.write "alpha" >>= fun () ->
           w.Server.flush () >>= fun () ->
           (* Wait until the test confirms it received the first chunk before we
              finish, proving the chunk reached the client mid-handler. *)
           release_handler >>= fun () ->
           w.Server.write "beta" >>= fun () ->
           w.Server.flush () >>= fun () ->
           w.Server.write "gamma" >>= fun () -> w.Server.flush ())
     in
     Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 handler
     >>= fun (srv, port, _serve_t) ->
     Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
     Lwt_io.write oc "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
     >>= fun () ->
     Lwt_io.flush oc >>= fun () ->
     (* Read incrementally until we have seen the first body chunk "alpha"
        (after the header block). This must arrive before we release the
        handler — proving the data is flushed unbuffered. *)
     let acc = Buffer.create 256 in
     let rec read_until_alpha () =
       Lwt_io.read ~count:4096 ic >>= fun s ->
       if s = "" then Lwt.return_unit
       else begin
         Buffer.add_string acc s;
         let _, body = split_headers (Buffer.contents acc) in
         if dechunk body = "alpha" || header_has (Buffer.contents acc) "alpha"
         then Lwt.return_unit
         else read_until_alpha ()
       end
     in
     read_until_alpha () >>= fun () ->
     let early = Buffer.contents acc in
     Lwt_condition.signal got_first ();
     (* The early bytes must contain a chunked frame for "alpha" while the
        handler is still suspended. *)
     Alcotest.(check bool) "chunked encoding announced" true
       (header_has early "transfer-encoding:[ \t]*chunked");
     Alcotest.(check bool) "early alpha chunk present" true
       (let _, b = split_headers early in dechunk b = "alpha");
     ignore got_first;
     (* Now let the handler finish and read the rest to EOF. *)
     Lwt.wakeup_later wake_release ();
     read_to_eof ic >>= fun rest ->
     let full = early ^ rest in
     let _, body = split_headers full in
     Alcotest.(check string) "dechunked body" "alphabetagamma" (dechunk body);
     Server.close srv)

(* ---- Small response: <=2048 bytes => exact Content-Length, no chunking ---- *)
let small_response () =
  run
    (let handler =
       Server.handler_func (fun w _r -> w.Server.write "hello small body")
     in
     Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 handler
     >>= fun (srv, port, _serve_t) ->
     Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
     Lwt_io.write oc "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
     >>= fun () ->
     Lwt_io.flush oc >>= fun () ->
     read_to_eof ic >>= fun raw ->
     let headers, body = split_headers raw in
     Alcotest.(check bool) "has Content-Length" true
       (header_has headers "content-length:[ \t]*16");
     Alcotest.(check bool) "no chunked" false
       (header_has headers "transfer-encoding:[ \t]*chunked");
     Alcotest.(check string) "body" "hello small body" body;
     Server.close srv)

(* ---- Large response: >2048 bytes without flush => chunked, intact body ---- *)
let large_response () =
  run
    (let payload = String.make 5000 'z' in
     let handler = Server.handler_func (fun w _r -> w.Server.write payload) in
     Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 handler
     >>= fun (srv, port, _serve_t) ->
     Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
     Lwt_io.write oc "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
     >>= fun () ->
     Lwt_io.flush oc >>= fun () ->
     read_to_eof ic >>= fun raw ->
     let headers, body = split_headers raw in
     Alcotest.(check bool) "chunked" true
       (header_has headers "transfer-encoding:[ \t]*chunked");
     Alcotest.(check bool) "no Content-Length" false
       (header_has headers "content-length:");
     Alcotest.(check string) "dechunked body" payload (dechunk body);
     Server.close srv)

let tests =
  [
    ("server_streams_unbuffered", `Quick, server_streams_unbuffered);
    ("small_response", `Quick, small_response);
    ("large_response", `Quick, large_response);
  ]
