(* Integration tests for the HTTP/1.x Server + ServeMux (Ticket 9), a ported
   subset of go/src/net/http/serve_test.go.

   Each test starts a real loopback server on an ephemeral port via
   [Server.listen_and_serve_started], drives it with a raw client socket
   ([Net.connect] + raw [Lwt_io], since the gohttp Client is Ticket 10), and
   asserts on the raw response bytes. The whole run is bounded by
   [Net.with_timeout] so a hang fails rather than blocks the suite. *)

open Gohttp
open Lwt.Infix

(* Registration is now a [result]; at wiring time a conflict is a programmer
   error, so unwrap with [Result.get_ok]. *)
let handle_func mux pattern f = Result.get_ok (Server.handle_func mux pattern f)

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

(* Read exactly the headers + a fixed Content-Length body (does not require the
   server to close the connection). Reads until the byte count of headers+body
   is satisfied, parsing Content-Length from the header block. *)
let read_one_response ic =
  let buf = Buffer.create 256 in
  let header_end () =
    let s = Buffer.contents buf in
    match Str.search_forward (Str.regexp "\r\n\r\n") s 0 with
    | i -> Some (s, i + 4)
    | exception Not_found -> None
  in
  let rec read_headers () =
    match header_end () with
    | Some (s, hdr_len) -> Lwt.return (s, hdr_len)
    | None ->
        Lwt_io.read ~count:1 ic >>= fun chunk ->
        if chunk = "" then
          Lwt.return (Buffer.contents buf, Buffer.length buf)
        else begin
          Buffer.add_string buf chunk;
          read_headers ()
        end
  in
  read_headers () >>= fun (headers_str, hdr_len) ->
  (* Find Content-Length. *)
  let cl =
    try
      let _ =
        Str.search_forward
          (Str.regexp_case_fold "content-length:[ \t]*\\([0-9]+\\)")
          headers_str 0
      in
      Some (int_of_string (Str.matched_group 1 headers_str))
    with Not_found -> None
  in
  match cl with
  | None -> Lwt.return (Buffer.contents buf)
  | Some n ->
      let target = hdr_len + n in
      let rec read_body () =
        if Buffer.length buf >= target then Lwt.return (Buffer.contents buf)
        else
          Lwt_io.read ~count:(target - Buffer.length buf) ic >>= fun chunk ->
          if chunk = "" then Lwt.return (Buffer.contents buf)
          else begin
            Buffer.add_string buf chunk;
            read_body ()
          end
      in
      read_body ()

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

(* Start a server with [handler], run [client ~port] against it, stop it. *)
let with_server handler client =
  let run () =
    Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize (fun () -> client ~port) (fun () -> Server.close srv)
  in
  Lwt_main.run (Net.with_timeout 10. (run ()))

(* ---- handlers ---- *)

let hello_handler =
  Server.handler_func (fun w _r -> w.Server.write "hello")

(* ---- tests ---- *)

let hello_handler_test () =
  let client ~port =
    Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
    Lwt_io.write oc "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    >>= fun () ->
    Lwt_io.flush oc >>= fun () ->
    read_to_eof ic >>= fun resp ->
    Lwt_io.close oc >>= fun () -> Lwt.return resp
  in
  let resp = with_server hello_handler client in
  Alcotest.(check bool) "200 status line"
    true
    (contains (status_line resp) "200 OK");
  Alcotest.(check string) "body" "hello" (body_of resp)

let not_found_test () =
  let mux = Server.new_serve_mux () in
  handle_func mux "/known" (fun w _r -> w.Server.write "ok");
  let client ~port =
    Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
    Lwt_io.write oc
      "GET /missing HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    >>= fun () ->
    Lwt_io.flush oc >>= fun () ->
    read_to_eof ic >>= fun resp ->
    Lwt_io.close oc >>= fun () -> Lwt.return resp
  in
  let resp = with_server (Server.serve_mux_handler mux) client in
  Alcotest.(check bool) "404 status line"
    true
    (contains (status_line resp) "404 Not Found");
  Alcotest.(check bool) "body mentions not found"
    true
    (contains resp "404 page not found")

let mux_routing_test () =
  let mux = Server.new_serve_mux () in
  handle_func mux "/a" (fun w _r -> w.Server.write "handler-a");
  handle_func mux "/b" (fun w _r -> w.Server.write "handler-b");
  handle_func mux "POST /c" (fun w _r -> w.Server.write "handler-c-post");
  let get path ~port =
    Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
    Lwt_io.write oc
      (Printf.sprintf "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
         path)
    >>= fun () ->
    Lwt_io.flush oc >>= fun () ->
    read_to_eof ic >>= fun resp ->
    Lwt_io.close oc >>= fun () -> Lwt.return resp
  in
  let post path ~port =
    Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
    Lwt_io.write oc
      (Printf.sprintf
         "POST %s HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
         path)
    >>= fun () ->
    Lwt_io.flush oc >>= fun () ->
    read_to_eof ic >>= fun resp ->
    Lwt_io.close oc >>= fun () -> Lwt.return resp
  in
  let h = Server.serve_mux_handler mux in
  let ra = with_server h (get "/a") in
  Alcotest.(check string) "path /a" "handler-a" (body_of ra);
  let rb = with_server h (get "/b") in
  Alcotest.(check string) "path /b" "handler-b" (body_of rb);
  (* GET /c -> method not allowed (only POST registered). *)
  let rc_get = with_server h (get "/c") in
  Alcotest.(check bool) "GET /c 405"
    true
    (contains (status_line rc_get) "405 Method Not Allowed");
  Alcotest.(check bool) "Allow header"
    true
    (contains rc_get "Allow: POST");
  (* POST /c -> handler-c-post. *)
  let rc_post = with_server h (post "/c") in
  Alcotest.(check string) "POST /c" "handler-c-post" (body_of rc_post)

(* HTTP/1.0: closes by default; keep-alive only when requested. *)
let http10_close_test () =
  (* Default HTTP/1.0: server closes -> read_to_eof terminates with the body. *)
  let client_default ~port =
    Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
    Lwt_io.write oc "GET / HTTP/1.0\r\n\r\n" >>= fun () ->
    Lwt_io.flush oc >>= fun () ->
    read_to_eof ic >>= fun resp ->
    Lwt_io.close oc >>= fun () -> Lwt.return resp
  in
  let resp = with_server hello_handler client_default in
  Alcotest.(check bool) "HTTP/1.0 status"
    true
    (contains (status_line resp) "HTTP/1.0 200");
  Alcotest.(check string) "HTTP/1.0 body" "hello" (body_of resp);
  (* The default HTTP/1.0 response must NOT advertise keep-alive (it closes). *)
  Alcotest.(check bool) "no keep-alive on default 1.0"
    false
    (contains resp "Connection: keep-alive");

  (* HTTP/1.0 with Connection: keep-alive: server keeps the connection open,
     emits "Connection: keep-alive", and we can read a second response on the
     same socket. We read just one framed response (Content-Length) so we don't
     block waiting for EOF that won't come. *)
  let client_keepalive ~port =
    Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
    Lwt_io.write oc
      "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
    >>= fun () ->
    Lwt_io.flush oc >>= fun () ->
    read_one_response ic >>= fun resp1 ->
    (* Second request on the same connection, this time closing. *)
    Lwt_io.write oc "GET / HTTP/1.0\r\n\r\n" >>= fun () ->
    Lwt_io.flush oc >>= fun () ->
    read_to_eof ic >>= fun resp2 ->
    Lwt_io.close oc >>= fun () -> Lwt.return (resp1, resp2)
  in
  let resp1, resp2 = with_server hello_handler client_keepalive in
  Alcotest.(check bool) "1.0 keep-alive advertised"
    true
    (contains resp1 "Connection: keep-alive");
  Alcotest.(check string) "keep-alive resp1 body" "hello" (body_of resp1);
  Alcotest.(check string) "keep-alive resp2 body" "hello" (body_of resp2)

(* Result migration T6: registering two conflicting patterns returns
   [Error (Register _)] (was a raised [Register_error]). *)
let handle_conflict_result () =
  let mux = Server.new_serve_mux () in
  (match Server.handle_func mux "/a/{x}" (fun w _r -> w.Server.write "a") with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "first registration should succeed");
  (match Server.handle_func mux "/a/{y}" (fun w _r -> w.Server.write "b") with
  | Error (Server.Register msg) ->
      Alcotest.(check bool) "conflict message" true
        (contains msg "conflicts with")
  | Ok () -> Alcotest.fail "conflicting registration should be Error");
  (* Empty pattern and a malformed pattern are also Error (Register _). *)
  (match Server.handle_func mux "" (fun w _r -> w.Server.write "c") with
  | Error (Server.Register _) -> ()
  | Ok () -> Alcotest.fail "empty pattern should be Error")

let tests =
  [
    Alcotest.test_case "hello_handler" `Quick hello_handler_test;
    Alcotest.test_case "not_found" `Quick not_found_test;
    Alcotest.test_case "mux_routing" `Quick mux_routing_test;
    Alcotest.test_case "http10_close" `Quick http10_close_test;
    Alcotest.test_case "handle_conflict_result" `Quick handle_conflict_result;
  ]
