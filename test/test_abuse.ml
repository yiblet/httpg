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

(* ------------------------------------------------------------------ *)
(* Ticket 4 — server read-path header-name/value + Host validation     *)
(* (Cases 6 & 8).                                                       *)
(*                                                                      *)
(* Go runs a post-parse validation sweep on every inbound request       *)
(* (server.go:1045-1062): a missing required Host on HTTP/1.1, a         *)
(* malformed Host value (httpguts.ValidHostHeader), and any non-token    *)
(* header name / CTL-bearing header value all yield 400 Bad Request via  *)
(* badRequestError. We drive a real loopback server with a raw socket    *)
(* and assert the status line. *)
(* ------------------------------------------------------------------ *)

(* Send [raw] to a fresh loopback server, read the status line, confirm the
   connection is then closed. Returns the status line. *)
let send_raw_expect_status raw =
  let run () =
    Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 hello_handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize
      (fun () ->
        Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
        Lwt_io.write oc raw >>= fun () ->
        Lwt_io.flush oc >>= fun () ->
        read_status_line ic >>= fun status ->
        Lwt_io.close oc >>= fun () -> Lwt.return status)
      (fun () -> Server.close srv)
  in
  Lwt_main.run (Net.with_timeout 3. (run ()))

let status_contains status needle =
  match Str.search_forward (Str.regexp_string needle) status 0 with
  | _ -> true
  | exception Not_found -> false

(* TestServerRejectsInvalidHeaderName (server.go:1053-1055,
   httpguts.ValidHeaderFieldName): a header whose name is not a token (here a
   space inside the name) -> 400 Bad Request. *)
let rejects_invalid_header_name () =
  let status =
    send_raw_expect_status
      "GET / HTTP/1.1\r\nHost: localhost\r\nFoo Bar: x\r\n\r\n"
  in
  Alcotest.(check bool)
    (Printf.sprintf "400 for invalid header name (%S)" status)
    true
    (status_contains status "400")

(* TestServerRejectsBadHostHeader (server.go:1050-1051,
   httpguts.ValidHostHeader): a Host value bearing a byte outside the lenient
   host byte set (a space) -> 400 Bad Request. *)
let rejects_bad_host_header () =
  let status =
    send_raw_expect_status "GET / HTTP/1.1\r\nHost: bad host\r\n\r\n"
  in
  Alcotest.(check bool)
    (Printf.sprintf "400 for malformed Host (%S)" status)
    true
    (status_contains status "400")

(* TestServerRejectsMissingHostHTTP11 (server.go:1045-1048): an HTTP/1.1 request
   with no Host header, non-CONNECT, non-h2-upgrade -> 400 Bad Request. *)
let rejects_missing_host_http11 () =
  let status = send_raw_expect_status "GET / HTTP/1.1\r\n\r\n" in
  Alcotest.(check bool)
    (Printf.sprintf "400 for missing Host on HTTP/1.1 (%S)" status)
    true
    (status_contains status "400")

(* TestServerAcceptsValidHostAndHeaders: a normal, valid HTTP/1.1 request with a
   well-formed Host and header is served 200 — the sweep must not produce false
   positives. *)
let accepts_valid_host_and_headers () =
  let run () =
    Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 hello_handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize
      (fun () ->
        Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
        Lwt_io.write oc
          "GET / HTTP/1.1\r\nHost: localhost:8080\r\nX-Token: ok\r\n\r\n"
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
    (status_contains resp "200 OK")

(* ------------------------------------------------------------------ *)
(* Ticket 5 — Expect: 100-continue handling + 417 (Case 7).            *)
(*                                                                      *)
(* Go honors [Expect: 100-continue] by lazily emitting the interim     *)
(* "HTTP/1.1 100 Continue" line on the FIRST body read (server.go:     *)
(* 964-983, :2089-2096, via expectContinueReader) and rejects any      *)
(* other Expect value with 417 Expectation Failed + Connection: close  *)
(* without running the handler (server.go:2097-2100, :2236-2252). We   *)
(* drive a real loopback server with a raw socket and assert the wire  *)
(* bytes. *)
(* ------------------------------------------------------------------ *)

(* Read everything off [ic] until EOF (or a bound), returning the accumulated
   bytes. Used to capture the full interim + final response sequence. *)
let read_all_until_eof ic =
  let buf = Buffer.create 256 in
  let rec loop () =
    Lwt_io.read ~count:1024 ic >>= fun s ->
    if s = "" then Lwt.return (Buffer.contents buf)
    else begin
      Buffer.add_string buf s;
      loop ()
    end
  in
  loop ()

(* TestServerExpect100Continue (server.go:964-983,:2089-2096): a client sends
   request headers with [Expect: 100-continue] and a Content-Length, then waits
   WITHOUT sending the body. The handler reads the body; only then is the interim
   "HTTP/1.1 100 Continue" written (lazily). After the client sees the 100 it
   sends the body, the handler echoes it, and the final 200 arrives. We assert
   the raw bytes contain the 100-continue interim line BEFORE the final 200 OK
   status line, proving the lazy emit and the ordering. *)
let expect_100_continue () =
  (* Handler reads the whole request body, then echoes it back as the response.
     The body read is what triggers the lazy 100. *)
  let handler =
    Server.handler_func (fun w r ->
        Body.read_all r.Request.body >>= fun body -> w.Server.write body)
  in
  let run () =
    Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize
      (fun () ->
        Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
        (* Send headers only (Expect + Content-Length), withhold the body. *)
        Lwt_io.write oc
          "POST / HTTP/1.1\r\n\
           Host: localhost\r\n\
           Content-Length: 5\r\n\
           Expect: 100-continue\r\n\
           \r\n"
        >>= fun () ->
        Lwt_io.flush oc >>= fun () ->
        (* Wait until the server lazily writes the 100-continue line; reading the
           status line blocks until those bytes arrive (sent only once the
           handler pulls the body). *)
        read_status_line ic >>= fun interim ->
        (* Now send the withheld body; the handler unblocks and replies. The
           response is keep-alive (no Connection: close), so read exactly one
           framed response rather than to EOF. *)
        Lwt_io.write oc "hello" >>= fun () ->
        Lwt_io.flush oc >>= fun () ->
        read_one_response ic >>= fun rest ->
        Lwt_io.close oc >>= fun () -> Lwt.return (interim, rest))
      (fun () -> Server.close srv)
  in
  let interim, rest = Lwt_main.run (Net.with_timeout 5. (run ())) in
  Alcotest.(check bool)
    (Printf.sprintf "interim 100 Continue line (%S)" interim)
    true
    (status_contains interim "HTTP/1.1 100 Continue");
  (* The final response arrives after the body was sent, and echoes it. *)
  Alcotest.(check bool)
    (Printf.sprintf "final 200 OK after 100 (%S)"
       (String.sub rest 0 (min 40 (String.length rest))))
    true
    (status_contains rest "200 OK");
  Alcotest.(check bool) "echoed body" true (status_contains rest "hello")

(* TestServerExpectUnknown (server.go:2097-2100,:2236-2252): a client sends an
   Expect header with a value other than 100-continue; the server replies 417
   Expectation Failed with Connection: close and does NOT run the handler. *)
let expect_unknown () =
  (* A handler that would write "hello" — it must NOT run for an unknown Expect. *)
  let run () =
    Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 hello_handler
    >>= fun (srv, port, serve_loop) ->
    Lwt.async (fun () -> serve_loop);
    Lwt.finalize
      (fun () ->
        Net.connect ~host:"127.0.0.1" ~port () >>= fun (ic, oc) ->
        Lwt_io.write oc
          "POST / HTTP/1.1\r\n\
           Host: localhost\r\n\
           Content-Length: 5\r\n\
           Expect: bogus\r\n\
           \r\n"
        >>= fun () ->
        Lwt_io.flush oc >>= fun () ->
        read_all_until_eof ic >>= fun resp ->
        Lwt_io.close oc >>= fun () -> Lwt.return resp)
      (fun () -> Server.close srv)
  in
  let resp = Lwt_main.run (Net.with_timeout 5. (run ())) in
  Alcotest.(check bool)
    (Printf.sprintf "417 Expectation Failed (%S)"
       (String.sub resp 0 (min 40 (String.length resp))))
    true
    (status_contains resp "417");
  Alcotest.(check bool)
    "Connection: close" true
    (status_contains resp "Connection: close");
  (* The handler did not run: no "hello" body. *)
  Alcotest.(check bool) "handler not run" false (status_contains resp "hello")

(* ---------------------------------------------------------------------- *)
(* Ticket 6 — client Transport.MaxResponseHeaderBytes (Case 14).          *)
(*                                                                         *)
(* Mirror of Ticket 2 on the response side: a hostile/buggy server cannot  *)
(* OOM the client by streaming an unbounded response status line + header  *)
(* block. Go's [Transport.MaxResponseHeaderBytes] (default 10<<20),        *)
(* transport.go:275-280,:337-340,:364. The response BODY is already bounded *)
(* by streaming [Transfer], so this covers the head only.                  *)
(*                                                                         *)
(* These drive a RAW loopback server (a bare [Net.listen]/[Net.accept]     *)
(* loop, NOT a gohttp [Server]) so the test can emit arbitrary/malicious    *)
(* bytes, against a [Client] backed by a [Transport] with a small          *)
(* [~max_response_header_bytes]. Everything is bounded by [Net.with_timeout] *)
(* so a hang (the failure we are guarding against) fails the test.         *)

(* Run a single-shot raw server fiber [serve s_ic s_oc] on an ephemeral    *)
(* loopback port, then run [client ~port], bounded. The server accepts one  *)
(* connection, runs [serve], and is torn down with the listener at the end. *)
let with_raw_server ~serve client =
  let run () =
    Net.listen "127.0.0.1" 0 >>= fun lfd ->
    let port = Net.bound_port lfd in
    let server =
      Net.accept lfd >>= fun (cfd, _addr) ->
      let s_ic, s_oc = Net.channels_of_fd cfd in
      Lwt.finalize
        (fun () -> serve s_ic s_oc)
        (fun () ->
          Lwt.catch (fun () -> Lwt_unix.close cfd) (fun _ -> Lwt.return_unit))
    in
    Lwt.async (fun () ->
        Lwt.catch (fun () -> server) (fun _ -> Lwt.return_unit));
    Lwt.finalize
      (fun () -> client ~port)
      (fun () ->
        Lwt.catch (fun () -> Lwt_unix.close lfd) (fun _ -> Lwt.return_unit))
  in
  Lwt_main.run (Net.with_timeout 5. (run ()))

(* TestTransportResponseHeaderTooLarge (Go's MaxResponseHeaderBytes,
   transport.go:275-280,:337-340,:364): a server that writes a valid status
   line then an endless header stream must make the round trip FAIL with the
   modeled [Response_header_too_large] error within the budget — not hang or
   OOM. We set [~max_response_header_bytes:8192]; the client reads at most
   8192 + 4096 bytes of head before raising. *)
let response_header_too_large () =
  (* Malicious server: valid status line, then header lines forever. *)
  let serve s_ic s_oc =
    Lwt_io.write s_oc "HTTP/1.1 200 OK\r\n" >>= fun () ->
    let filler = String.make 200 'y' in
    let rec spew i =
      Lwt_io.write s_oc (Printf.sprintf "X-Flood-%d: %s\r\n" i filler)
      >>= fun () ->
      Lwt_io.flush s_oc >>= fun () -> spew (i + 1)
    in
    (* Keep the input channel referenced so it is not GC'd mid-write. *)
    ignore s_ic;
    spew 0
  in
  let client ~port =
    let transport = Transport.create ~max_response_header_bytes:8192 () in
    let c = Client.create ~transport () in
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    Lwt.catch
      (fun () ->
        Client.get c url >>= fun _resp -> Lwt.return (Error "no error"))
      (fun exn -> Lwt.return (Ok (Printexc.to_string exn)))
  in
  let result = with_raw_server ~serve client in
  match result with
  | Error msg -> Alcotest.fail (Printf.sprintf "expected failure, got %s" msg)
  | Ok exn_str ->
      (* The transport surfaces the Io error as a Protocol_error carrying the
         modeled [Response_header_too_large] message text. *)
      Alcotest.(check bool)
        (Printf.sprintf "modeled response-header-too-large error (%S)" exn_str)
        true
        (let needle = "MaxResponseHeaderBytes" in
         match Str.search_forward (Str.regexp_string needle) exn_str 0 with
         | _ -> true
         | exception Not_found -> false)

(* TestTransportResponseHeaderUnderLimitOk: a normal response whose head is
   well under the limit succeeds (200, body intact). *)
let response_header_under_limit_ok () =
  let body = "hello world" in
  let serve s_ic s_oc =
    ignore s_ic;
    Lwt_io.write s_oc
      (Printf.sprintf
         "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
         (String.length body) body)
    >>= fun () -> Lwt_io.flush s_oc
  in
  let client ~port =
    let transport = Transport.create ~max_response_header_bytes:8192 () in
    let c = Client.create ~transport () in
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    Client.get c url >>= fun resp ->
    Body.read_all resp.Response.body >>= fun b ->
    Lwt.return (resp.Response.status_code, b)
  in
  let code, b = with_raw_server ~serve client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check string) "body intact" body b

(* ---- Ticket 7: client sticky / subdomain-aware redirect header stripping +
   Referer (Case 15, go/src/net/http/client.go:691-698, :1008-1048, :147-170).

   These drive the redirect loop ({!Client.do_one}) against a stub round-tripper
   that captures the headers seen on each hop and returns canned redirects, so
   per-hop header presence is asserted without real DNS. *)

(* Build a [Body.t Response.t] for the stub: a redirect to [location] (when
   [Some]) carrying the [req] that produced it (so {!Response.location} resolves
   against the request URL), else a final 200. *)
let stub_response req ?location () : Body.t Response.t =
  let header = Header.create () in
  let status_code, status =
    match location with
    | Some loc ->
        Header.set header "Location" loc;
        (302, "302 Found")
    | None -> (200, "200 OK")
  in
  {
    Response.status;
    status_code;
    proto = "HTTP/1.1";
    proto_major = 1;
    proto_minor = 1;
    header;
    body = Body.Empty;
    content_length = 0L;
    transfer_encoding = [];
    close = false;
    uncompressed = false;
    trailer = None;
    request = Some req;
  }

(* Run the redirect loop with a stub that maps each request URL to either a
   redirect target or a final response, recording the headers seen on each hop
   (keyed by the request URL). Returns the assoc list of (url, header) seen. *)
let drive_redirects ~start ~routes ~init_headers =
  let seen = ref [] in
  let round_trip (req : Body.t Request.t) : Body.t Response.t Lwt.t =
    seen := !seen @ [ (Uri.to_string req.Request.url, req.Request.header) ];
    let url = Uri.to_string req.Request.url in
    match List.assoc_opt url routes with
    | Some next -> Lwt.return (stub_response req ~location:next ())
    | None -> Lwt.return (stub_response req ())
  in
  let c = Client.create () in
  let req = Client.make_request "GET" start in
  List.iter (fun (k, v) -> Header.set req.Request.header k v) init_headers;
  let run () =
    Client.do_one ~round_trip c req >>= fun resp ->
    Body.drain resp.Response.body >>= fun _ -> Lwt.return !seen
  in
  Lwt_main.run (Net.with_timeout 5. (run ()))

let header_on seen url name =
  match List.assoc_opt url seen with
  | Some h -> Header.get h name
  | None -> Alcotest.failf "no hop recorded for %s" url

let redirect_strip_sticky_on_bounce_back () =
  (* a.com (Authorization) -> b.com -> a.com. Once stripped crossing to b.com,
     Authorization stays stripped even bouncing back to the initial a.com.
     Both visits to a.com share a URL key, so this drives the loop directly and
     records hops in order, asserting on the FINAL (bounce-back) hop. *)
  let seen2 = ref [] in
  let round_trip (req : Body.t Request.t) : Body.t Response.t Lwt.t =
    let host = Option.value ~default:"" (Uri.host req.Request.url) in
    seen2 := !seen2 @ [ (host, req.Request.header) ];
    match host with
    | "a.com" when List.length !seen2 = 1 ->
        Lwt.return (stub_response req ~location:"http://b.com/" ())
    | "b.com" -> Lwt.return (stub_response req ~location:"http://a.com/" ())
    | _ -> Lwt.return (stub_response req ())
  in
  let c = Client.create () in
  let req = Client.make_request "GET" "http://a.com/" in
  Header.set req.Request.header "Authorization" "Bearer secret";
  let hops =
    Lwt_main.run
      (Net.with_timeout 5.
         ( Client.do_one ~round_trip c req >>= fun resp ->
           Body.drain resp.Response.body >>= fun _ -> Lwt.return !seen2 ))
  in
  Alcotest.(check int) "three hops" 3 (List.length hops);
  let _, first_header = List.nth hops 0 in
  Alcotest.(check string)
    "auth present on initial a.com hop" "Bearer secret"
    (Header.get first_header "Authorization");
  let _, second_header = List.nth hops 1 in
  Alcotest.(check string)
    "auth stripped crossing to b.com" ""
    (Header.get second_header "Authorization");
  let _, final_header = List.nth hops 2 in
  Alcotest.(check string)
    "auth stripped on bounce-back a.com" ""
    (Header.get final_header "Authorization")

let redirect_keeps_header_on_subdomain () =
  (* foo.com (Authorization) -> sub.foo.com keeps Authorization (subdomain of
     the initial host). *)
  let seen =
    drive_redirects ~start:"http://foo.com/"
      ~routes:[ ("http://foo.com/", "http://sub.foo.com/") ]
      ~init_headers:[ ("Authorization", "Bearer secret") ]
  in
  Alcotest.(check string)
    "auth kept on subdomain hop" "Bearer secret"
    (header_on seen "http://sub.foo.com/" "Authorization")

let redirect_referer_https_to_http () =
  (* https -> https keeps/sets Referer from the previous hop; https -> http
     omits it. *)
  let seen_secure =
    drive_redirects ~start:"https://a.com/page"
      ~routes:[ ("https://a.com/page", "https://b.com/") ]
      ~init_headers:[]
  in
  Alcotest.(check string)
    "referer set on https->https hop" "https://a.com/page"
    (header_on seen_secure "https://b.com/" "Referer");
  let seen_downgrade =
    drive_redirects ~start:"https://a.com/page"
      ~routes:[ ("https://a.com/page", "http://b.com/") ]
      ~init_headers:[]
  in
  Alcotest.(check string)
    "referer omitted on https->http hop" ""
    (header_on seen_downgrade "http://b.com/" "Referer")

(* ------------------------------------------------------------------ *)
(* Ticket 8 — HTTP/2 rapid-reset backlog cap (Case 9, CVE-2023-44487). *)
(*                                                                      *)
(* An open+RST_STREAM flood must not cheaply force unbounded handler    *)
(* scheduling: once the unstarted-handler backlog exceeds               *)
(* [4 * adv_max_streams], the server trips an ENHANCE_YOUR_CALM         *)
(* connection error (GOAWAY). Adapted from Go's                         *)
(* testServerMaxHandlerGoroutines (go/src/net/http/internal/http2/      *)
(* server_test.go:4257-4356; the cap is server.go:2263). Driven over    *)
(* the same in-memory Lwt_io pipe + raw H2 framer harness as            *)
(* test_h2_server.ml. *)
module F = Gohttp_http2.H2_frame
module S = Gohttp_http2.H2_server
module H2 = Gohttp_http2.H2
module Hpack = Gohttp_http2.Hpack
module H2_error = Gohttp_http2.H2_error
module Api = Gohttp_http2.Api

let h2_duplex () =
  let s_ic, c_oc = Lwt_io.pipe () in
  let c_ic, s_oc = Lwt_io.pipe () in
  (s_ic, s_oc, c_ic, c_oc)

let h2_encode_block (fields : (string * string) list) =
  let enc = Hpack.new_encoder () in
  let buf = Buffer.create 64 in
  Hpack.set_writer enc (fun s -> Buffer.add_string buf s);
  List.iter
    (fun (name, value) ->
      Hpack.write_field enc { Hpack.name; value; sensitive = false })
    fields;
  Buffer.contents buf

let h2_request_block path =
  h2_encode_block
    [
      (":method", "GET");
      (":path", path);
      (":scheme", "https");
      (":authority", "example.com");
    ]

let h2_open oc ~stream_id =
  F.write_headers oc ~stream_id ~end_stream:true ~end_headers:true
    (h2_request_block "/")

(* Read frames until a GOAWAY is seen; return its error code. *)
let rec read_until_goaway ic =
  F.read_frame ic >>= function
  | Ok (F.GoAway (_, gf)) -> Lwt.return gf.error_code
  | Ok _ -> read_until_goaway ic
  | Error e -> raise (H2_error.to_exception e)

let too_many_early_resets () =
  (* adv_max_streams = 1, so the backlog cap is 4 * 1 = 4: the 6th queued
     handler trips ENHANCE_YOUR_CALM. *)
  let max_streams = 1 in
  (* A blocking handler: the first (un-reset) stream's handler parks on a
     never-resolved promise, keeping cur_handlers == adv_max_streams so every
     later stream's handler is queued rather than started. *)
  let block, _wake = Lwt.wait () in
  let started, started_u = Lwt.wait () in
  let woken = ref false in
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    if not !woken then begin
      woken := true;
      Lwt.wakeup_later started_u ()
    end;
    block >>= fun () -> rw.Api.rw_flush ()
  in
  let code =
    Lwt_main.run
      (Net.with_timeout 15.
         (let s_ic, s_oc, c_ic, c_oc = h2_duplex () in
          let server =
            S.serve ~max_concurrent_streams:max_streams s_ic s_oc ~handler
          in
          (* client handshake: preface + empty SETTINGS *)
          Lwt_io.write c_oc H2.client_preface >>= fun () ->
          F.write_settings c_oc [] >>= fun () ->
          Lwt_io.flush c_oc >>= fun () ->
          (* Stream 1: starts the (blocking) handler, then reset it so
             cur_client_streams drops back to 0 while the handler fiber keeps
             running (cur_handlers stays at adv_max_streams). Mirrors Go's
             "reset after the handler goroutine has started". *)
          h2_open c_oc ~stream_id:1 >>= fun () ->
          Lwt_io.flush c_oc >>= fun () ->
          (* wait until the handler has actually started before resetting *)
          started >>= fun () ->
          F.write_rst_stream c_oc 1 H2_error.Cancel >>= fun () ->
          Lwt_io.flush c_oc >>= fun () ->
          (* Flood: open then immediately reset a stream, repeatedly. Each open
             reaches schedule_handler (cur_client_streams stays low because we
             reset each one), which queues it (cur_handlers is full). The reset
             removes the stream from sc.streams but the queued entry persists,
             so the backlog grows. After it exceeds 4*adv_max_streams the server
             must GOAWAY with ENHANCE_YOUR_CALM. Send 5*adv_max_streams*... well
             beyond the cap (matching Go's 5*maxHandlers loop). *)
          let flood =
            let rec loop sid n =
              if n = 0 then Lwt.return_unit
              else
                h2_open c_oc ~stream_id:sid >>= fun () ->
                F.write_rst_stream c_oc sid H2_error.Cancel >>= fun () ->
                Lwt_io.flush c_oc >>= fun () -> loop (sid + 2) (n - 1)
            in
            loop 3 20
          in
          flood >>= fun () ->
          read_until_goaway c_ic >>= fun code ->
          (* close down: drop the client side and let serve finish. *)
          Lwt_io.close c_oc >>= fun () ->
          Lwt.catch
            (fun () -> Lwt.pick [ server; Lwt_unix.sleep 1.0 ])
            (fun _ -> Lwt.return_unit)
          >>= fun () -> Lwt.return code))
  in
  Alcotest.(check bool)
    "GOAWAY error code is ENHANCE_YOUR_CALM" true
    (code = H2_error.EnhanceYourCalm)

(* Ticket 9 (Case 11): HTTP/2 MAX_HEADER_LIST_SIZE advertise/derive + HPACK
   per-string cap + Huffman bound. Refs: server.go:497-505,:778; frame.go:1716,
   :1722,:1774; hpack/hpack.go:84,:122,:488,:516. *)
module Huff = Gohttp_http2.Hpack_huffman

(* Read the server's first SETTINGS frame off the wire. *)
let rec read_first_settings ic =
  F.read_frame ic >>= function
  | Ok (F.Settings (_, sf)) -> Lwt.return sf
  | Ok _ -> read_first_settings ic
  | Error e -> raise (H2_error.to_exception e)

(* TestH2AdvertisesMaxHeaderListSize: the server's initial SETTINGS frame
   contains a MAX_HEADER_LIST_SIZE entry equal to the configured value
   (server.go:778). *)
let advertises_max_header_list_size () =
  let configured = 4096 in
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.Api.rw_flush ()
  in
  let value =
    Lwt_main.run
      (Net.with_timeout 10.
         (let s_ic, s_oc, c_ic, c_oc = h2_duplex () in
          let server =
            S.serve ~max_header_bytes:configured s_ic s_oc ~handler
          in
          (* The server sends its initial SETTINGS before reading the preface. *)
          read_first_settings c_ic >>= fun sf ->
          Lwt_io.close c_oc >>= fun () ->
          Lwt.catch
            (fun () -> Lwt.pick [ server; Lwt_unix.sleep 1.0 ])
            (fun _ -> Lwt.return_unit)
          >>= fun () ->
          let v =
            List.find_opt
              (fun (s : H2.setting) -> s.id = H2.Max_header_list_size)
              sf.settings
          in
          Lwt.return (Option.map (fun (s : H2.setting) -> s.value) v)))
  in
  Alcotest.(check (option int32))
    "advertised MAX_HEADER_LIST_SIZE = configured value"
    (Some (Int32.of_int configured))
    value

(* TestH2RejectsHeaderListBomb: a HEADERS block whose decoded header list
   exceeds the configured size is a connection PROTOCOL_ERROR (GOAWAY).
   frame.go:1774 ("frag more than twice the remaining header list bytes"). *)
let rejects_header_list_bomb () =
  let configured = 256 in
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.Api.rw_flush ()
  in
  (* One header whose value is ~4 KiB: the assembled fragment far exceeds
     2 * max_header_list_size, tripping the PROTOCOL_ERROR connection error. *)
  let bomb_block =
    h2_encode_block
      [
        (":method", "GET");
        (":path", "/");
        (":scheme", "https");
        (":authority", "example.com");
        ("x-bomb", String.make 4096 'a');
      ]
  in
  let code =
    Lwt_main.run
      (Net.with_timeout 15.
         (let s_ic, s_oc, c_ic, c_oc = h2_duplex () in
          let server =
            S.serve ~max_header_bytes:configured s_ic s_oc ~handler
          in
          Lwt_io.write c_oc H2.client_preface >>= fun () ->
          F.write_settings c_oc [] >>= fun () ->
          Lwt_io.flush c_oc >>= fun () ->
          F.write_headers c_oc ~stream_id:1 ~end_stream:true ~end_headers:true
            bomb_block
          >>= fun () ->
          Lwt_io.flush c_oc >>= fun () ->
          read_until_goaway c_ic >>= fun code ->
          Lwt_io.close c_oc >>= fun () ->
          Lwt.catch
            (fun () -> Lwt.pick [ server; Lwt_unix.sleep 1.0 ])
            (fun _ -> Lwt.return_unit)
          >>= fun () -> Lwt.return code))
  in
  Alcotest.(check bool)
    "GOAWAY error code is PROTOCOL_ERROR" true
    (code = H2_error.ProtocolError)

(* TestH2HuffmanStringCap: a Huffman-coded string whose DECODED length exceeds
   the decoder's per-string cap is rejected with the ErrStringLength-equivalent
   (hpack.go:516, huffman.go:67-68) without a large transient allocation. Driven
   as an HPACK unit test: build a literal-header-without-indexing wire block with
   a Huffman-coded value, feed it to a decoder with a small max string length. *)
let huffman_string_cap () =
  let cap = 64 in
  (* 'a' is a 5-bit code in the HPACK static Huffman table, so a run of 'a's
     compresses to ~5/8 of its length on the wire. We want the DECODED length to
     exceed [cap] while the ENCODED wire length stays <= [cap], so the
     encoded-length check in [read_string] passes and the cap must instead be
     enforced during Huffman decode. [cap + 8] bytes decoded -> ~45 wire bytes. *)
  let decoded = String.make (cap + 8) 'a' in
  let huff = Huff.encode decoded in
  (* The encoded wire form is shorter than the decoded length, so [read_string]'s
     encoded-length check (str_len > max_str_len) does NOT trip; the cap must be
     enforced during Huffman decode. *)
  Alcotest.(check bool)
    "encoded wire string is within the per-string cap (so the encoded-length \
     check alone would pass)"
    true
    (String.length huff <= cap);
  let buf = Buffer.create 64 in
  (* Literal Header Field without Indexing, new name (RFC 7541 6.2.2):
     first byte 0x00 (pattern 0000, 4-bit name index 0). *)
  Buffer.add_char buf '\x00';
  (* name string: not Huffman, length 1, "x". *)
  Hpack.append_var_int buf 7 1;
  Buffer.add_char buf 'x';
  (* value string: Huffman flag (0x80) | 7-bit length varint, then bytes. *)
  let len_buf = Buffer.create 8 in
  Hpack.append_var_int len_buf 7 (String.length huff);
  let len_bytes = Buffer.contents len_buf in
  (* set the Huffman flag on the first length byte. *)
  let first = Char.code len_bytes.[0] lor 0x80 in
  Buffer.add_char buf (Char.chr first);
  Buffer.add_substring buf len_bytes 1 (String.length len_bytes - 1);
  Buffer.add_string buf huff;
  let block = Buffer.contents buf in
  let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
  Hpack.set_max_string_length dec cap;
  let result =
    match Hpack.write_result dec block with
    | Error e -> Error e
    | Ok _ -> Hpack.close_result dec
  in
  match result with
  | Error Gohttp_http2.Hpack.String_too_long -> ()
  | Error e ->
      Alcotest.failf "expected String_too_long, got %s"
        (Gohttp_http2.Hpack.error_to_string e)
  | Ok () -> Alcotest.fail "expected String_too_long, got Ok"

(* Ticket 10 (Case 12): HTTP/2 duplicate-SETTINGS rejection. A SETTINGS frame
   whose entries repeat a setting ID is a connection PROTOCOL_ERROR (GOAWAY),
   mirroring Go's f.HasDuplicates() guard in processSettings
   (server.go:1616-1620; HasDuplicates frame.go:832). *)

(* TestH2RejectsDuplicateSettings: a single SETTINGS frame carrying two entries
   for the same ID trips a PROTOCOL_ERROR GOAWAY. *)
let rejects_duplicate_settings () =
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.Api.rw_flush ()
  in
  let code =
    Lwt_main.run
      (Net.with_timeout 10.
         (let s_ic, s_oc, c_ic, c_oc = h2_duplex () in
          let server = S.serve s_ic s_oc ~handler in
          Lwt_io.write c_oc H2.client_preface >>= fun () ->
          (* One SETTINGS frame, two entries for the SAME id (duplicate). *)
          F.write_settings c_oc
            [
              { H2.id = H2.Initial_window_size; value = 65535l };
              { H2.id = H2.Initial_window_size; value = 1024l };
            ]
          >>= fun () ->
          Lwt_io.flush c_oc >>= fun () ->
          read_until_goaway c_ic >>= fun code ->
          Lwt_io.close c_oc >>= fun () ->
          Lwt.catch
            (fun () -> Lwt.pick [ server; Lwt_unix.sleep 1.0 ])
            (fun _ -> Lwt.return_unit)
          >>= fun () -> Lwt.return code))
  in
  Alcotest.(check bool)
    "GOAWAY error code is PROTOCOL_ERROR" true
    (code = H2_error.ProtocolError)

(* TestH2AcceptsDistinctSettings: a single SETTINGS frame whose entries all have
   distinct IDs is accepted; a following GET is served normally (status 200, no
   GOAWAY). This is the negative control for [rejects_duplicate_settings] — the
   duplicate must be within one frame, not across the handshake. *)
let accepts_distinct_settings () =
  let handler (rw : S.response_writer) (_req : Api.server_request) =
    rw.Api.rw_write "ok" >>= fun () -> rw.Api.rw_flush ()
  in
  let status =
    Lwt_main.run
      (Net.with_timeout 10.
         (let s_ic, s_oc, c_ic, c_oc = h2_duplex () in
          let server = S.serve s_ic s_oc ~handler in
          Lwt_io.write c_oc H2.client_preface >>= fun () ->
          (* A SETTINGS frame with several DISTINCT setting IDs. *)
          F.write_settings c_oc
            [
              { H2.id = H2.Initial_window_size; value = 65535l };
              { H2.id = H2.Max_concurrent_streams; value = 100l };
              { H2.id = H2.Header_table_size; value = 4096l };
            ]
          >>= fun () ->
          Lwt_io.flush c_oc >>= fun () ->
          h2_open c_oc ~stream_id:1 >>= fun () ->
          Lwt_io.flush c_oc >>= fun () ->
          (* Read the server's first HEADERS frame and pull out :status. *)
          let dec =
            Hpack.new_decoder H2.initial_header_table_size (fun _ -> ())
          in
          let rec read_status () =
            F.read_frame c_ic >>= function
            | Ok (F.Headers (_, hf)) ->
                let fields = ref [] in
                Hpack.set_emit_func dec (fun (h : Hpack.header_field) ->
                    fields := (h.name, h.value) :: !fields);
                ignore (Hpack.write dec hf.header_frag);
                Hpack.close dec;
                Lwt.return (List.assoc_opt ":status" !fields)
            | Ok (F.GoAway (_, gf)) ->
                Alcotest.failf "unexpected GOAWAY %s"
                  (H2_error.err_code_string gf.error_code)
            | Ok _ -> read_status ()
            | Error e -> raise (H2_error.to_exception e)
          in
          read_status () >>= fun status ->
          Lwt_io.close c_oc >>= fun () ->
          Lwt.catch
            (fun () -> Lwt.pick [ server; Lwt_unix.sleep 1.0 ])
            (fun _ -> Lwt.return_unit)
          >>= fun () -> Lwt.return status))
  in
  Alcotest.(check (option string))
    "distinct SETTINGS accepted; GET served 200" (Some "200") status

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
    Alcotest.test_case "rejects_invalid_header_name" `Quick
      rejects_invalid_header_name;
    Alcotest.test_case "rejects_bad_host_header" `Quick rejects_bad_host_header;
    Alcotest.test_case "rejects_missing_host_http11" `Quick
      rejects_missing_host_http11;
    Alcotest.test_case "accepts_valid_host_and_headers" `Quick
      accepts_valid_host_and_headers;
    Alcotest.test_case "expect_100_continue" `Quick expect_100_continue;
    Alcotest.test_case "expect_unknown" `Quick expect_unknown;
    Alcotest.test_case "response_header_too_large" `Quick
      response_header_too_large;
    Alcotest.test_case "response_header_under_limit_ok" `Quick
      response_header_under_limit_ok;
    Alcotest.test_case "redirect_strip_sticky_on_bounce_back" `Quick
      redirect_strip_sticky_on_bounce_back;
    Alcotest.test_case "redirect_keeps_header_on_subdomain" `Quick
      redirect_keeps_header_on_subdomain;
    Alcotest.test_case "redirect_referer_https_to_http" `Quick
      redirect_referer_https_to_http;
    Alcotest.test_case "too_many_early_resets" `Quick too_many_early_resets;
    Alcotest.test_case "advertises_max_header_list_size" `Quick
      advertises_max_header_list_size;
    Alcotest.test_case "rejects_header_list_bomb" `Quick
      rejects_header_list_bomb;
    Alcotest.test_case "huffman_string_cap" `Quick huffman_string_cap;
    Alcotest.test_case "rejects_duplicate_settings" `Quick
      rejects_duplicate_settings;
    Alcotest.test_case "accepts_distinct_settings" `Quick
      accepts_distinct_settings;
  ]
