(* Integration tests for the malicious-peer hardening work (the [Abuse] suite),
   HTTP/1.x portion. The HTTP/2 abuse cases live in test_abuse_h2.ml, deferred to
   ticket 010 (h2 stack out of build).

   Server duration knobs (read_header_timeout / idle_timeout) are Eio.Time
   deadlines, enforced when a clock is passed to serve. Each networked test
   starts a real loopback server on an ephemeral port with a small timeout,
   drives it with a raw client socket, and asserts the connection is closed or
   the expected status arrives within a bound (Test_harness.with_env). *)

open Httpg

(* Unwrap a happy-path client result, failing the test on a transport/redirect
   error. *)
let ok_resp = function
  | Ok resp -> resp
  | Error e -> Alcotest.failf "client: %s" (Client.error_to_string e)

let hello_handler =
 fun ~sw:_ _r -> Response.with_body_string "hello" (Response.create ())

(* Start [handler] (built via [mk_server ~net ~clock ~sw]) and run [fn r w] over
   a raw buffered client connection, then close the server. *)
let with_started ~secs mk_server fn =
  Test_harness.with_env ~secs (fun ~net ~clock ~sw ->
      let srv, port = mk_server ~net ~clock ~sw in
      let result = ref None in
      Fun.protect
        ~finally:(fun () -> Server.close srv)
        (fun () ->
          let flow =
            match Net.connect ~sw net ~host:"127.0.0.1" ~port with
            | Ok x -> x
            | Error e -> Alcotest.failf "net: %s" (Net.error_to_string e)
          in
          (* A hardening server may reset the connection while the client is
             still writing (Slowloris / oversized-header cases); the writer's
             flush fiber then raises a broken-pipe/reset [Eio.Io]. Tolerate it
             once the test result has been captured. *)
          (try
             Net.with_connection flow (fun r w ->
                 result := Some (fn ~clock r w))
           with Eio.Io _ when Option.is_some !result -> ());
          match !result with
          | Some v -> v
          | None -> failwith "with_started: connection lost before result"))

let start ?read_timeout ?read_header_timeout ?write_timeout ?idle_timeout
    ?max_header_bytes handler ~net ~clock ~sw =
  let srv, port, serve_loop =
    Server.listen_and_serve_started ?read_timeout ?read_header_timeout
      ?write_timeout ?idle_timeout ?max_header_bytes ~net ~clock ~sw
      ~addr:"127.0.0.1" ~port:0 handler
  in
  Eio.Fiber.fork ~sw serve_loop;
  (srv, port)

let send w s =
  Eio.Buf_write.string w s;
  Eio.Buf_write.flush w

(* Wait until the server closes the connection (a read returns EOF). Returns the
   elapsed seconds, measured on [clock]. *)
let wait_for_eof ~clock (r : Eio.Buf_read.t) =
  let t0 = Eio.Time.now clock in
  (try
     while true do
       Eio.Buf_read.consume r (Eio.Buf_read.buffered_bytes r);
       Eio.Buf_read.ensure r 1
     done
   with
  | End_of_file -> ()
  (* A server that closes mid-write may surface as a connection reset rather
     than a clean EOF; either way the connection is gone. *)
  | Eio.Io _ -> ());
  Eio.Time.now clock -. t0

(* Read one Content-Length-framed response (headers + body). *)
let read_one_response (r : Eio.Buf_read.t) =
  let buf = Buffer.create 256 in
  let rec read_headers () =
    let c = Eio.Buf_read.any_char r in
    Buffer.add_char buf c;
    let s = Buffer.contents buf in
    let n = String.length s in
    if n >= 4 && String.sub s (n - 4) 4 = "\r\n\r\n" then s else read_headers ()
  in
  let headers = read_headers () in
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
  | None | Some 0 -> headers
  | Some n -> headers ^ Eio.Buf_read.take n r

(* Read the response status line (first CRLF-terminated line), or "" on EOF. *)
let read_status_line (r : Eio.Buf_read.t) =
  try
    let line = Eio.Buf_read.line r in
    line
  with End_of_file -> ""

let status_contains status needle =
  match Str.search_forward (Str.regexp_string needle) status 0 with
  | _ -> true
  | exception Not_found -> false

(* ---- ReadHeaderTimeout: a partial request is dropped within the budget. *)
let slowloris_header_timeout () =
  let elapsed =
    with_started ~secs:3.
      (fun ~net ~clock ~sw ->
        start ~read_header_timeout:0.2 hello_handler ~net ~clock ~sw)
      (fun ~clock r w ->
        send w "GET / HTTP/1.1\r\n";
        wait_for_eof ~clock r)
  in
  Alcotest.(check bool)
    (Printf.sprintf "connection closed by header timeout (%.3fs)" elapsed)
    true (elapsed < 1.5)

(* ---- ReadHeaderTimeout over TLS: the duration knobs must reach the TLS
   entry point too (Go keeps them on the single Server struct shared by
   ListenAndServe and ListenAndServeTLS). A partial request over a TLS
   connection (ALPN -> http/1.1) is dropped within the budget. *)
let slowloris_header_timeout_tls () =
  let elapsed =
    Test_harness.with_env ~secs:3. (fun ~net ~clock ~sw ->
        let certificates = Net.test_server_certificate () in
        let srv, port, serve_loop =
          Server.listen_and_serve_tls_started ~read_header_timeout:0.2 ~net
            ~clock ~certificates ~sw ~addr:"127.0.0.1" ~port:0 hello_handler
        in
        Eio.Fiber.fork ~sw serve_loop;
        Fun.protect
          ~finally:(fun () -> Server.close srv)
          (fun () ->
            match
              Net.connect_tls ~sw net ~host:"127.0.0.1" ~port ~tls:true
                ~insecure:true (fun r w ->
                  (try send w "GET / HTTP/1.1\r\n" with Eio.Io _ -> ());
                  wait_for_eof ~clock r)
            with
            | Ok elapsed -> elapsed
            | Error e -> Alcotest.failf "net: %s" (Net.error_to_string e)))
  in
  Alcotest.(check bool)
    (Printf.sprintf "TLS connection closed by header timeout (%.3fs)" elapsed)
    true (elapsed < 1.5)

(* ---- IdleTimeout: an idle kept-alive connection is closed within the budget. *)
let idle_timeout () =
  let resp1, elapsed =
    with_started ~secs:3.
      (fun ~net ~clock ~sw ->
        start ~idle_timeout:0.2 hello_handler ~net ~clock ~sw)
      (fun ~clock r w ->
        send w "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
        let resp1 = read_one_response r in
        let elapsed = wait_for_eof ~clock r in
        (resp1, elapsed))
  in
  Alcotest.(check bool)
    "first request served 200" true
    (status_contains resp1 "200 OK");
  Alcotest.(check bool)
    (Printf.sprintf "idle connection closed (%.3fs)" elapsed)
    true (elapsed < 1.5)

(* ---- request header block over MaxHeaderBytes -> 431, closed. *)
let request_header_too_large () =
  let status, elapsed =
    with_started ~secs:3.
      (fun ~net ~clock ~sw ->
        start ~max_header_bytes:8192 hello_handler ~net ~clock ~sw)
      (fun ~clock r w ->
        Eio.Buf_write.string w "GET / HTTP/1.1\r\nHost: localhost\r\n";
        let filler = String.make 200 'x' in
        for i = 0 to 159 do
          Eio.Buf_write.string w (Printf.sprintf "X-Filler-%d: %s\r\n" i filler)
        done;
        Eio.Buf_write.string w "\r\n";
        Eio.Buf_write.flush w;
        let status = read_status_line r in
        let elapsed = wait_for_eof ~clock r in
        (status, elapsed))
  in
  Alcotest.(check bool)
    (Printf.sprintf "431 status line (%S)" status)
    true
    (status_contains status "431");
  Alcotest.(check bool)
    (Printf.sprintf "connection closed (%.3fs)" elapsed)
    true (elapsed < 1.5)

(* ---- a single enormous request line is caught by the cumulative budget -> 431. *)
let request_line_too_long () =
  let status, elapsed =
    with_started ~secs:3.
      (fun ~net ~clock ~sw ->
        start ~max_header_bytes:8192 hello_handler ~net ~clock ~sw)
      (fun ~clock r w ->
        let long_uri = "/" ^ String.make 20000 'a' in
        send w (Printf.sprintf "GET %s HTTP/1.1\r\n" long_uri);
        let status = read_status_line r in
        let elapsed = wait_for_eof ~clock r in
        (status, elapsed))
  in
  Alcotest.(check bool)
    (Printf.sprintf "431 status line (%S)" status)
    true
    (status_contains status "431");
  Alcotest.(check bool)
    (Printf.sprintf "connection closed (%.3fs)" elapsed)
    true (elapsed < 1.5)

(* ---- a normal request under the limit is served 200 (no false positive). *)
let headers_under_limit_ok () =
  let resp =
    with_started ~secs:3.
      (fun ~net ~clock ~sw ->
        start ~max_header_bytes:8192 hello_handler ~net ~clock ~sw)
      (fun ~clock:_ r w ->
        send w "GET / HTTP/1.1\r\nHost: localhost\r\nX-Small: ok\r\n\r\n";
        read_one_response r)
  in
  Alcotest.(check bool) "served 200" true (status_contains resp "200 OK")

(* ---- bounded chunked trailer (in-memory, via Io.read_response). *)

let read_response_str s =
  match Io.read_response (Eio.Buf_read.of_string s) with
  | Ok r -> r
  | Error e -> failwith ("read_response: " ^ Io.error_to_string e)

let chunked_trailer_too_long () =
  let huge_value = String.make 8192 'x' in
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n"
    ^ "0\r\n" ^ "X-Trailer: " ^ huge_value ^ "\r\n"
    (* deliberately no closing CRLF *)
  in
  let r = read_response_str raw in
  let outcome =
    try
      ignore (Body.drain r.Response.body);
      `No_error
    with
    | Io.Trailer_too_large -> `Trailer_too_large
    | e -> `Other (Printexc.to_string e)
  in
  match outcome with
  | `Trailer_too_large -> ()
  | `No_error ->
      Alcotest.fail "expected Trailer_too_large, body drained cleanly"
  | `Other s -> Alcotest.fail ("expected Trailer_too_large, got: " ^ s)

let chunked_empty_trailer_ok () =
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n"
    ^ "3\r\nbar\r\n" ^ "0\r\n\r\n"
  in
  let r = read_response_str raw in
  let data = Body.read_all r.Response.body in
  Alcotest.(check string) "body" "foobar" data;
  Alcotest.(check bool) "no trailer" true (r.Response.trailer = None)

let chunked_small_trailer_ok () =
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: Md5\r\n\r\n"
    ^ "3\r\nfoo\r\n" ^ "0\r\n" ^ "Md5: abc123\r\n" ^ "\r\n"
  in
  let r = read_response_str raw in
  let data = Body.read_all r.Response.body in
  Alcotest.(check string) "body" "foo" data;
  match r.Response.trailer with
  | Some t ->
      Alcotest.(check (option string))
        "trailer Md5" (Some "abc123") (Header.get t "Md5")
  | None -> Alcotest.fail "expected a parsed trailer header"

(* ---- server read-path header/Host validation: send raw, read status line. *)
let send_raw_expect_status raw =
  with_started ~secs:3.
    (fun ~net ~clock ~sw -> start hello_handler ~net ~clock ~sw)
    (fun ~clock:_ r w ->
      send w raw;
      read_status_line r)

let rejects_invalid_header_name () =
  let status =
    send_raw_expect_status
      "GET / HTTP/1.1\r\nHost: localhost\r\nFoo Bar: x\r\n\r\n"
  in
  Alcotest.(check bool)
    (Printf.sprintf "400 for invalid header name (%S)" status)
    true
    (status_contains status "400")

let rejects_bad_host_header () =
  let status =
    send_raw_expect_status "GET / HTTP/1.1\r\nHost: bad host\r\n\r\n"
  in
  Alcotest.(check bool)
    (Printf.sprintf "400 for malformed Host (%S)" status)
    true
    (status_contains status "400")

let rejects_missing_host_http11 () =
  let status = send_raw_expect_status "GET / HTTP/1.1\r\n\r\n" in
  Alcotest.(check bool)
    (Printf.sprintf "400 for missing Host on HTTP/1.1 (%S)" status)
    true
    (status_contains status "400")

let accepts_valid_host_and_headers () =
  let resp =
    with_started ~secs:3.
      (fun ~net ~clock ~sw -> start hello_handler ~net ~clock ~sw)
      (fun ~clock:_ r w ->
        send w "GET / HTTP/1.1\r\nHost: localhost:8080\r\nX-Token: ok\r\n\r\n";
        read_one_response r)
  in
  Alcotest.(check bool) "served 200" true (status_contains resp "200 OK")

(* ---- Expect: 100-continue handling + 417. *)
let expect_100_continue () =
  let handler =
   fun ~sw:_ r ->
    Response.create ()
    |> Response.with_body_string (Body.read_all r.Request.body)
  in
  let interim, rest =
    with_started ~secs:5.
      (fun ~net ~clock ~sw -> start handler ~net ~clock ~sw)
      (fun ~clock:_ r w ->
        send w
          "POST / HTTP/1.1\r\n\
           Host: localhost\r\n\
           Content-Length: 5\r\n\
           Expect: 100-continue\r\n\
           \r\n";
        (* Blocks until the server lazily writes the 100-continue line. *)
        let interim = read_status_line r in
        send w "hello";
        let rest = read_one_response r in
        (interim, rest))
  in
  Alcotest.(check bool)
    (Printf.sprintf "interim 100 Continue line (%S)" interim)
    true
    (status_contains interim "HTTP/1.1 100 Continue");
  Alcotest.(check bool)
    "final 200 OK after 100" true
    (status_contains rest "200 OK");
  Alcotest.(check bool) "echoed body" true (status_contains rest "hello")

let expect_unknown () =
  let resp =
    with_started ~secs:5.
      (fun ~net ~clock ~sw -> start hello_handler ~net ~clock ~sw)
      (fun ~clock:_ r w ->
        send w
          "POST / HTTP/1.1\r\n\
           Host: localhost\r\n\
           Content-Length: 5\r\n\
           Expect: bogus\r\n\
           \r\n";
        Eio.Buf_read.take_all r)
  in
  Alcotest.(check bool)
    "417 Expectation Failed" true
    (status_contains resp "417");
  Alcotest.(check bool)
    "Connection: close" true
    (status_contains resp "Connection: close");
  Alcotest.(check bool) "handler not run" false (status_contains resp "hello")

(* ---- client Transport.MaxResponseHeaderBytes: a raw malicious server. *)

(* Run a single-shot raw server fiber [serve r w] on an ephemeral loopback port,
   then run [client ~net ~sw ~clock ~port], bounded. *)
let with_raw_server ~secs ~serve client =
  Test_harness.with_env ~secs (fun ~net ~clock ~sw ->
      let listener = Net.listen ~sw net "127.0.0.1" 0 in
      let port = Net.bound_port listener in
      Eio.Fiber.fork ~sw (fun () ->
          try
            let flow, _addr = Net.accept ~sw listener in
            Net.with_connection flow (fun r w -> serve r w)
          with _ -> ());
      client ~net ~sw ~clock ~port)

let response_header_too_large () =
  let serve _r w =
    Eio.Buf_write.string w "HTTP/1.1 200 OK\r\n";
    let filler = String.make 200 'y' in
    try
      let i = ref 0 in
      while true do
        Eio.Buf_write.string w (Printf.sprintf "X-Flood-%d: %s\r\n" !i filler);
        Eio.Buf_write.flush w;
        incr i
      done
    with _ -> ()
  in
  let client ~net ~sw ~clock ~port =
    let transport =
      Transport.create ~net ~clock ~max_response_header_bytes:8192 ()
    in
    let c = Client.create ~net ~clock ~transport () in
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    match Client.get ~sw c url with
    | Ok _ -> Error "no error"
    | Error e -> Ok (Client.error_to_string e)
  in
  match with_raw_server ~secs:5. ~serve client with
  | Error msg -> Alcotest.fail (Printf.sprintf "expected failure, got %s" msg)
  | Ok exn_str ->
      Alcotest.(check bool)
        (Printf.sprintf "modeled response-header-too-large error (%S)" exn_str)
        true
        (status_contains exn_str "MaxResponseHeaderBytes")

let response_header_under_limit_ok () =
  let body = "hello world" in
  let serve _r w =
    send w
      (Printf.sprintf
         "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
         (String.length body) body)
  in
  let client ~net ~sw ~clock ~port =
    let transport =
      Transport.create ~net ~clock ~max_response_header_bytes:8192 ()
    in
    let c = Client.create ~net ~clock ~transport () in
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    let resp = ok_resp (Client.get ~sw c url) in
    ( Httpg_base.Status.to_int resp.Response.status,
      Body.read_all resp.Response.body )
  in
  let code, b = with_raw_server ~secs:5. ~serve client in
  Alcotest.(check int) "status 200" 200 code;
  Alcotest.(check string) "body intact" body b

(* ---- client sticky / subdomain-aware redirect header stripping + Referer.
   Driven against a stub round-tripper (no real DNS). *)

let stub_response req ?location () : Response.t =
  let header, status =
    match location with
    | Some loc ->
        (Header.set (Header.create ()) "Location" loc, Httpg_base.Status.Found)
    | None -> (Header.create (), Httpg_base.Status.Ok)
  in
  {
    Response.status;
    proto = Httpg_base.Protocol.Http11;
    header;
    body = Body.Empty;
    content_length = Some 0L;
    transfer_encoding = [];
    close = false;
    uncompressed = false;
    trailer = None;
    request = Some req;
  }

(* The stub round-trip overrides the per-hop round-tripper, so the client's
   captured [net] is unused here; we run inside with_env just to obtain one. *)
let drive_redirects ~start:start_url ~routes ~init_headers =
  Test_harness.with_env (fun ~net ~clock:_ ~sw:_ ->
      let seen = ref [] in
      let round_trip (req : Request.t) : (Response.t, Transport.error) result =
        seen := !seen @ [ (Uri.to_string req.Request.url, req.Request.header) ];
        match List.assoc_opt (Uri.to_string req.Request.url) routes with
        | Some next -> Ok (stub_response req ~location:next ())
        | None -> Ok (stub_response req ())
      in
      let c = Client.create ~net () in
      let req = Request.make ~meth:Httpg_base.Method.Get start_url in
      req.Request.header <-
        List.fold_left
          (fun h (k, v) -> Header.set h k v)
          req.Request.header init_headers;
      let resp = ok_resp (Client.Private.do_one ~round_trip c req) in
      ignore (Body.drain resp.Response.body);
      !seen)

let header_on seen url name =
  match List.assoc_opt url seen with
  | Some h -> Header.get h name
  | None -> Alcotest.failf "no hop recorded for %s" url

let redirect_strip_sticky_on_bounce_back () =
  let hops =
    Test_harness.with_env (fun ~net ~clock:_ ~sw:_ ->
        let seen2 = ref [] in
        let round_trip (req : Request.t) : (Response.t, Transport.error) result
            =
          let host = Option.value ~default:"" (Uri.host req.Request.url) in
          seen2 := !seen2 @ [ (host, req.Request.header) ];
          match host with
          | "a.com" when List.length !seen2 = 1 ->
              Ok (stub_response req ~location:"http://b.com/" ())
          | "b.com" -> Ok (stub_response req ~location:"http://a.com/" ())
          | _ -> Ok (stub_response req ())
        in
        let c = Client.create ~net () in
        let req = Request.make ~meth:Httpg_base.Method.Get "http://a.com/" in
        req.Request.header <-
          Header.set req.Request.header "Authorization" "Bearer secret";
        let resp = ok_resp (Client.Private.do_one ~round_trip c req) in
        ignore (Body.drain resp.Response.body);
        !seen2)
  in
  Alcotest.(check int) "three hops" 3 (List.length hops);
  let _, first_header = List.nth hops 0 in
  Alcotest.(check (option string))
    "auth present on initial a.com hop" (Some "Bearer secret")
    (Header.get first_header "Authorization");
  let _, second_header = List.nth hops 1 in
  Alcotest.(check (option string))
    "auth stripped crossing to b.com" None
    (Header.get second_header "Authorization");
  let _, final_header = List.nth hops 2 in
  Alcotest.(check (option string))
    "auth stripped on bounce-back a.com" None
    (Header.get final_header "Authorization")

let redirect_keeps_header_on_subdomain () =
  let seen =
    drive_redirects ~start:"http://foo.com/"
      ~routes:[ ("http://foo.com/", "http://sub.foo.com/") ]
      ~init_headers:[ ("Authorization", "Bearer secret") ]
  in
  Alcotest.(check (option string))
    "auth kept on subdomain hop" (Some "Bearer secret")
    (header_on seen "http://sub.foo.com/" "Authorization")

let redirect_referer_https_to_http () =
  let seen_secure =
    drive_redirects ~start:"https://a.com/page"
      ~routes:[ ("https://a.com/page", "https://b.com/") ]
      ~init_headers:[]
  in
  Alcotest.(check (option string))
    "referer set on https->https hop" (Some "https://a.com/page")
    (header_on seen_secure "https://b.com/" "Referer");
  let seen_downgrade =
    drive_redirects ~start:"https://a.com/page"
      ~routes:[ ("https://a.com/page", "http://b.com/") ]
      ~init_headers:[]
  in
  Alcotest.(check (option string))
    "referer omitted on https->http hop" None
    (header_on seen_downgrade "http://b.com/" "Referer")

(* CheckRedirect cap exceeded: a stub that redirects forever drives the default
   policy past 10 hops, so [do_one] returns [Error (Client.Redirect _)] (the
   retired [exception Aborted] arm). Asserts the [Redirect] error arm. *)
let redirect_cap_is_error () =
  Test_harness.with_env (fun ~net ~clock:_ ~sw:_ ->
      (* Always-redirect stub: each hop points at the next path. *)
      let round_trip (req : Request.t) : (Response.t, Transport.error) result =
        let path = Uri.path req.Request.url in
        let n =
          try int_of_string (String.sub path 1 (String.length path - 1))
          with _ -> 0
        in
        Ok
          (stub_response req
             ~location:(Printf.sprintf "http://loop.com/%d" (n + 1))
             ())
      in
      let c = Client.create ~net () in
      let req = Request.make ~meth:Httpg_base.Method.Get "http://loop.com/0" in
      match Client.Private.do_one ~round_trip c req with
      | Error (Client.Redirect msg) ->
          Alcotest.(check bool)
            (Printf.sprintf "redirect-cap message (%S)" msg)
            true
            (status_contains msg "stopped after 10 redirects")
      | Error e ->
          Alcotest.failf "expected Error (Redirect _), got Error %s"
            (Client.error_to_string e)
      | Ok _ -> Alcotest.fail "expected Error (Redirect _), got Ok")

(* A round-trip failure threaded through the redirect loop surfaces as
   [Error (Client.Round_trip _)]. Asserts the [Round_trip] error arm via the
   stub (no real network). *)
let redirect_round_trip_error_is_error () =
  Test_harness.with_env (fun ~net ~clock:_ ~sw:_ ->
      let round_trip (_ : Request.t) : (Response.t, Transport.error) result =
        Error Transport.No_host
      in
      let c = Client.create ~net () in
      let req = Request.make ~meth:Httpg_base.Method.Get "http://x.com/" in
      match Client.Private.do_one ~round_trip c req with
      | Error (Client.Round_trip Transport.No_host) -> ()
      | Error e ->
          Alcotest.failf "expected Error (Round_trip No_host), got Error %s"
            (Client.error_to_string e)
      | Ok _ -> Alcotest.fail "expected Error (Round_trip No_host), got Ok")

let tests =
  [
    Alcotest.test_case "slowloris_header_timeout" `Slow slowloris_header_timeout;
    Alcotest.test_case "slowloris_header_timeout_tls" `Slow
      slowloris_header_timeout_tls;
    Alcotest.test_case "idle_timeout" `Slow idle_timeout;
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
    Alcotest.test_case "redirect_cap_is_error" `Quick redirect_cap_is_error;
    Alcotest.test_case "redirect_round_trip_error_is_error" `Quick
      redirect_round_trip_error_is_error;
  ]
