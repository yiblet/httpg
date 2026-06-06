(* Integration tests for the malicious-peer hardening work (the [Abuse] suite).

   Ticket 1 (server read / header / idle / write timeouts, Case 1): a slow /
   idle / incomplete client must not be able to pin a serve fiber forever
   (Slowloris). The server's duration knobs are ported from Go's
   [Server.ReadHeaderTimeout] / [IdleTimeout] (go/src/net/http/server.go:
   1007-1022, :2145-2149, :3717-3724), implemented here as child
   {!Gohttp_base.Context} deadlines (Lwt_io has no settable socket deadline).

   Each test starts a real loopback server on an ephemeral port via
   [Server.listen_and_serve_started] with a small timeout, drives it with a raw
   client socket, and asserts the connection is closed (a read returns EOF)
   within a bound. The whole run is wrapped in [Net.with_timeout] so a hang
   fails the test rather than blocking the suite. *)

open Gohttp
open Lwt.Infix

let hello_handler = Server.handler_func (fun w _r -> w.Server.write "hello")

(* Wait for the server to close the connection: read until [Lwt_io.read]
   returns "" (EOF). Returns the elapsed seconds. Bounded by [Net.with_timeout]
   at the call site so a connection that is never closed fails the test. *)
let wait_for_eof ic =
  let t0 = Unix.gettimeofday () in
  let rec loop () =
    Lwt.catch
      (fun () -> Lwt_io.read ~count:4096 ic >>= fun s -> Lwt.return (Some s))
      (fun _ -> Lwt.return None)
    >>= function
    | Some "" | None -> Lwt.return (Unix.gettimeofday () -. t0)
    | Some _ -> loop ()
  in
  loop ()

(* Read one Content-Length-framed response off [ic] (headers + body), so we do
   not block waiting for an EOF on a kept-alive connection. *)
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
        if chunk = "" then Lwt.return (Buffer.contents buf, Buffer.length buf)
        else begin
          Buffer.add_string buf chunk;
          read_headers ()
        end
  in
  read_headers () >>= fun (headers_str, hdr_len) ->
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
          Lwt_io.read ~count:1 ic >>= fun chunk ->
          if chunk = "" then Lwt.return (Buffer.contents buf)
          else begin
            Buffer.add_string buf chunk;
            read_body ()
          end
      in
      read_body ()

(* TestServerSlowlorisHeaderTimeout (Go's slow-header / ReadHeaderTimeout
   behavior, server.go:1011-1013): a client that sends the request line but
   never finishes the headers is dropped within [read_header_timeout]; the
   server hangs up (closes) with no reply. *)
let slowloris_header_timeout () =
  let run () =
    Server.listen_and_serve_started ~read_header_timeout:0.2 ~addr:"127.0.0.1"
      ~port:0 hello_handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize
      (fun () ->
        Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
        (* Send a partial request: the request line only, then nothing. *)
        Lwt_io.write oc "GET / HTTP/1.1\r\n" >>= fun () ->
        Lwt_io.flush oc >>= fun () ->
        wait_for_eof ic >>= fun elapsed ->
        Lwt_io.close oc >>= fun () -> Lwt.return elapsed)
      (fun () -> Server.close srv)
  in
  (* Bound the whole run well above the 0.2s deadline but below a hang. *)
  let elapsed = Lwt_main.run (Net.with_timeout 3. (run ())) in
  Alcotest.(check bool)
    (Printf.sprintf "connection closed by header timeout (%.3fs)" elapsed)
    true (elapsed < 1.5)

(* TestServerIdleTimeout (Go's IdleTimeout, server.go:2145-2156): a kept-alive
   connection that completes one request and then sits idle is closed within
   [idle_timeout]. *)
let idle_timeout () =
  let run () =
    Server.listen_and_serve_started ~idle_timeout:0.2 ~addr:"127.0.0.1" ~port:0
      hello_handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize
      (fun () ->
        Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
        (* One complete keep-alive request, read its (framed) response. *)
        Lwt_io.write oc "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        >>= fun () ->
        Lwt_io.flush oc >>= fun () ->
        read_one_response ic >>= fun resp1 ->
        (* Then hold the connection idle: the server must close it within the
           idle timeout. *)
        wait_for_eof ic >>= fun elapsed ->
        Lwt_io.close oc >>= fun () -> Lwt.return (resp1, elapsed))
      (fun () -> Server.close srv)
  in
  let resp1, elapsed = Lwt_main.run (Net.with_timeout 3. (run ())) in
  Alcotest.(check bool)
    "first request served 200" true
    (match Str.search_forward (Str.regexp_string "200 OK") resp1 0 with
    | _ -> true
    | exception Not_found -> false);
  Alcotest.(check bool)
    (Printf.sprintf "idle connection closed (%.3fs)" elapsed)
    true (elapsed < 1.5)

let tests =
  [
    Alcotest.test_case "slowloris_header_timeout" `Quick
      slowloris_header_timeout;
    Alcotest.test_case "idle_timeout" `Quick idle_timeout;
  ]
