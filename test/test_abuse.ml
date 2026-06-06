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

(* Read the response status line (the first CRLF-terminated line) off [ic], or
   "" if the server hung up first. *)
let read_status_line ic =
  let rec loop acc =
    Lwt_io.read ~count:1 ic >>= fun c ->
    if c = "" then Lwt.return acc
    else if c = "\n" then Lwt.return acc
    else loop (acc ^ c)
  in
  loop "" >>= fun line ->
  (* Strip a trailing CR. *)
  let n = String.length line in
  if n > 0 && line.[n - 1] = '\r' then Lwt.return (String.sub line 0 (n - 1))
  else Lwt.return line

(* TestServerRequestHeaderTooLarge (Go's errTooLarge -> 431, server.go:2053-2062;
   the initialReadLimitSize bound, :929,:1024): a request whose header block
   exceeds [max_header_bytes] is answered [431 Request Header Fields Too Large]
   and the connection closed. *)
let request_header_too_large () =
  let run () =
    Server.listen_and_serve_started ~max_header_bytes:8192 ~addr:"127.0.0.1"
      ~port:0 hello_handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize
      (fun () ->
        Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
        (* Request line + a header block well over the 8 KiB limit (+4096 slop):
           many filler header lines summing to ~32 KiB. *)
        Lwt_io.write oc "GET / HTTP/1.1\r\nHost: localhost\r\n" >>= fun () ->
        let filler = String.make 200 'x' in
        let rec write_fillers i =
          if i >= 160 then Lwt.return_unit
          else
            Lwt_io.write oc (Printf.sprintf "X-Filler-%d: %s\r\n" i filler)
            >>= fun () -> write_fillers (i + 1)
        in
        write_fillers 0 >>= fun () ->
        Lwt_io.write oc "\r\n" >>= fun () ->
        Lwt_io.flush oc >>= fun () ->
        read_status_line ic >>= fun status ->
        (* Drain to confirm the connection is closed. *)
        wait_for_eof ic >>= fun elapsed ->
        Lwt_io.close oc >>= fun () -> Lwt.return (status, elapsed))
      (fun () -> Server.close srv)
  in
  let status, elapsed = Lwt_main.run (Net.with_timeout 3. (run ())) in
  Alcotest.(check bool)
    (Printf.sprintf "431 status line (%S)" status)
    true
    (match Str.search_forward (Str.regexp_string "431") status 0 with
    | _ -> true
    | exception Not_found -> false);
  Alcotest.(check bool)
    (Printf.sprintf "connection closed (%.3fs)" elapsed)
    true (elapsed < 1.5)

(* TestServerRequestLineTooLong: a single request line exceeding the limit is
   itself caught by the cumulative budget (server.go:929,:1024) -> 431. *)
let request_line_too_long () =
  let run () =
    Server.listen_and_serve_started ~max_header_bytes:8192 ~addr:"127.0.0.1"
      ~port:0 hello_handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize
      (fun () ->
        Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
        (* One enormous request line (a long URI) past the 8 KiB + 4096 budget. *)
        let long_uri = "/" ^ String.make 20000 'a' in
        Lwt_io.write oc (Printf.sprintf "GET %s HTTP/1.1\r\n" long_uri)
        >>= fun () ->
        Lwt_io.flush oc >>= fun () ->
        read_status_line ic >>= fun status ->
        wait_for_eof ic >>= fun elapsed ->
        Lwt_io.close oc >>= fun () -> Lwt.return (status, elapsed))
      (fun () -> Server.close srv)
  in
  let status, elapsed = Lwt_main.run (Net.with_timeout 3. (run ())) in
  Alcotest.(check bool)
    (Printf.sprintf "431 status line (%S)" status)
    true
    (match Str.search_forward (Str.regexp_string "431") status 0 with
    | _ -> true
    | exception Not_found -> false);
  Alcotest.(check bool)
    (Printf.sprintf "connection closed (%.3fs)" elapsed)
    true (elapsed < 1.5)

(* TestServerHeadersUnderLimitOk: a normal request comfortably under the limit
   is served 200 — the bound must not produce false positives. *)
let headers_under_limit_ok () =
  let run () =
    Server.listen_and_serve_started ~max_header_bytes:8192 ~addr:"127.0.0.1"
      ~port:0 hello_handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize
      (fun () ->
        Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
        Lwt_io.write oc
          "GET / HTTP/1.1\r\nHost: localhost\r\nX-Small: ok\r\n\r\n"
        >>= fun () ->
        Lwt_io.flush oc >>= fun () ->
        read_one_response ic >>= fun resp ->
        Lwt_io.close oc >>= fun () -> Lwt.return resp)
      (fun () -> Server.close srv)
  in
  let resp = Lwt_main.run (Net.with_timeout 3. (run ())) in
  Alcotest.(check bool)
    (Printf.sprintf "served 200 (%S)"
       (String.sub resp 0 (min 20 (String.length resp))))
    true
    (match Str.search_forward (Str.regexp_string "200 OK") resp 0 with
    | _ -> true
    | exception Not_found -> false)

(* ------------------------------------------------------------------ *)
(* Ticket 3 — bounded chunked trailer (Case 5).                        *)
(*                                                                     *)
(* The trailer block following a chunked body must be bounded so a     *)
(* malicious peer cannot OOM us with an endless / gigantic trailer.    *)
(* Go bounds it to the bufio buffer size (~4kB) via seeUpcomingDouble  *)
(* CRLF (go/src/net/http/transfer.go:894-951, :934); we reproduce the  *)
(* effect with the T2 [read_line ?limit] budget. Driven over an        *)
(* in-memory channel through [Io.read_response]; the trailer is read   *)
(* mid-stream when the body reaches EOF, so the error surfaces from a   *)
(* body pull (Body.drain / read_all), not from read_response.          *)
(* ------------------------------------------------------------------ *)

let ic_of_string s = Lwt_io.of_bytes ~mode:Lwt_io.input (Lwt_bytes.of_string s)

(* TestChunkedTrailerTooLong (transfer.go:925-935): a chunked body followed by an
   oversized, unterminated trailer block. Draining the body triggers the trailer
   read, which must fail with the modeled [Trailer_too_large] error rather than
   buffering the whole trailer. *)
let chunked_trailer_too_long () =
  (* A well-framed chunked body, then a trailer block far over the 4096-byte
     buffer budget with no terminating blank line: one gigantic trailer line. *)
  let huge_value = String.make 8192 'x' in
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n"
    ^ "0\r\n" ^ "X-Trailer: " ^ huge_value ^ "\r\n"
    (* deliberately no closing CRLF: an endless/oversized trailer *)
  in
  let run () =
    let ic = ic_of_string raw in
    Io.read_response ic >>= function
    | Error e -> Lwt.fail (Failure ("read_response: " ^ Io.error_to_string e))
    | Ok r ->
        (* The header boundary parsed fine; the trailer error is mid-stream. *)
        Lwt.catch
          (fun () -> Body.drain r.Response.body >|= fun _ -> `No_error)
          (function
            | Io.Trailer_too_large -> Lwt.return `Trailer_too_large
            | e -> Lwt.return (`Other (Printexc.to_string e)))
  in
  let outcome = Lwt_main.run (Net.with_timeout 3. (run ())) in
  match outcome with
  | `Trailer_too_large -> ()
  | `No_error ->
      Alcotest.fail "expected Trailer_too_large, body drained cleanly"
  | `Other s -> Alcotest.fail ("expected Trailer_too_large, got: " ^ s)

(* TestChunkedEmptyTrailerOk (transfer.go:913-917, the common case): a chunked
   body terminated by a bare CRLF (no trailer headers) drains cleanly and yields
   no trailer. *)
let chunked_empty_trailer_ok () =
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n"
    ^ "3\r\nbar\r\n" ^ "0\r\n\r\n"
  in
  let run () =
    let ic = ic_of_string raw in
    Io.read_response ic >>= function
    | Error e -> Lwt.fail (Failure ("read_response: " ^ Io.error_to_string e))
    | Ok r ->
        Body.read_all r.Response.body >|= fun data -> (data, r.Response.trailer)
  in
  let data, trailer = Lwt_main.run (Net.with_timeout 3. (run ())) in
  Alcotest.(check string) "body" "foobar" data;
  Alcotest.(check bool) "no trailer" true (trailer = None)

(* TestChunkedSmallTrailerOk: a chunked body + one small trailer header parses
   within the budget and is surfaced on the response trailer after the body is
   consumed to EOF (Go's body.readTrailer -> mergeSetHeader). *)
let chunked_small_trailer_ok () =
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: Md5\r\n\r\n"
    ^ "3\r\nfoo\r\n" ^ "0\r\n" ^ "Md5: abc123\r\n" ^ "\r\n"
  in
  let run () =
    let ic = ic_of_string raw in
    Io.read_response ic >>= function
    | Error e -> Lwt.fail (Failure ("read_response: " ^ Io.error_to_string e))
    | Ok r ->
        Body.read_all r.Response.body >|= fun data -> (data, r.Response.trailer)
  in
  let data, trailer = Lwt_main.run (Net.with_timeout 3. (run ())) in
  Alcotest.(check string) "body" "foo" data;
  match trailer with
  | Some t ->
      Alcotest.(check string) "trailer Md5" "abc123" (Header.get t "Md5")
  | None -> Alcotest.fail "expected a parsed trailer header"

let tests =
  [
    Alcotest.test_case "slowloris_header_timeout" `Quick
      slowloris_header_timeout;
    Alcotest.test_case "idle_timeout" `Quick idle_timeout;
    Alcotest.test_case "request_header_too_large" `Quick
      request_header_too_large;
    Alcotest.test_case "request_line_too_long" `Quick request_line_too_long;
    Alcotest.test_case "headers_under_limit_ok" `Quick headers_under_limit_ok;
    Alcotest.test_case "chunked_trailer_too_long" `Quick
      chunked_trailer_too_long;
    Alcotest.test_case "chunked_empty_trailer_ok" `Quick
      chunked_empty_trailer_ok;
    Alcotest.test_case "chunked_small_trailer_ok" `Quick
      chunked_small_trailer_ok;
  ]
