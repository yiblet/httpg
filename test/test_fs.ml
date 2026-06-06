(* Integration tests for the file-serving core, a ported subset of
   go/src/net/http/fs_test.go.

   Each test creates a unique temp directory under the fs capability, populates
   it, serves it via a [Fs.file_server] over an ephemeral loopback
   [Httptest.Server], drives it with the httpg [Client], and removes the temp dir
   afterwards. The whole run is bounded by a timeout (Test_harness.with_fs). *)

open Httpg
module Ts = Httptest.Server

(* Run [f ~net ~sw ~clock dir_path] with a fresh temp dir (an [Eio.Path] under
   the fs capability), cleaning up afterwards. *)
let with_tmpdir ~fs ~net ~clock ~sw f =
  let name =
    Printf.sprintf "httpg_fs_%d_%d" (Unix.getpid ()) (Random.int 1_000_000_000)
  in
  let dir = Eio.Path.(fs / Filename.get_temp_dir_name () / name) in
  Eio.Path.mkdir ~perm:0o755 dir;
  Fun.protect
    (fun () -> f ~net ~sw ~clock dir)
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)

let write_file dir name contents =
  Eio.Path.save ~create:(`Exclusive 0o644) Eio.Path.(dir / name) contents

(* Serve [dir] over an ephemeral loopback server and run [client ~sw c url]
   ([c] captures net/clock), stopping the server afterwards. *)
let serve_dir ~net ~sw ~clock dir client =
  let handler = Fs.file_server (Fs.dir dir) in
  let s = Ts.new_server ~net ~clock ~sw handler in
  Fun.protect
    (fun () -> client ~sw (Ts.client s) (Ts.url s))
    ~finally:(fun () -> Ts.close s)

(* ---- Fs.serve_file (known file) ---- *)
let serve_known_file () =
  let body_contents = "hello, file server\n" in
  let status, body, ct, lm, ar =
    Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
        with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
            write_file dir "hello.txt" body_contents;
            serve_dir ~net ~sw ~clock dir (fun ~sw c url ->
                let resp = Client.get ~sw c (url ^ "/hello.txt") in
                let body = Body.read_all resp.Response.body in
                ( resp.Response.status_code,
                  body,
                  Header.get resp.Response.header "Content-Type",
                  Header.get resp.Response.header "Last-Modified",
                  Header.get resp.Response.header "Accept-Ranges" ))))
  in
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body == file contents" body_contents body;
  Alcotest.(check string) "content-type .txt" "text/plain; charset=utf-8" ct;
  Alcotest.(check bool) "last-modified present" true (lm <> "");
  Alcotest.(check string) "accept-ranges bytes" "bytes" ar

(* ---- Fs.dir_list ---- *)
let dir_listing () =
  let status, body, ct =
    Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
        with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
            write_file dir "alpha.txt" "a";
            write_file dir "beta.txt" "b";
            serve_dir ~net ~sw ~clock dir (fun ~sw c url ->
                let resp = Client.get ~sw c (url ^ "/") in
                let body = Body.read_all resp.Response.body in
                ( resp.Response.status_code,
                  body,
                  Header.get resp.Response.header "Content-Type" ))))
  in
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "content-type html" "text/html; charset=utf-8" ct;
  let contains sub =
    let re = Str.regexp_string sub in
    try
      ignore (Str.search_forward re body 0);
      true
    with Not_found -> false
  in
  Alcotest.(check bool) "lists alpha.txt" true (contains "alpha.txt");
  Alcotest.(check bool) "lists beta.txt" true (contains "beta.txt")

(* ---- traversal guard ---- *)
let traversal_blocked () =
  let status =
    Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
        with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
            write_file dir "ok.txt" "ok";
            serve_dir ~net ~sw ~clock dir (fun ~sw c url ->
                let resp = Client.get ~sw c (url ^ "/../../../../etc/passwd") in
                ignore (Body.drain resp.Response.body);
                resp.Response.status_code)))
  in
  (* path.Clean("/../../etc/passwd") = "/etc/passwd", absent in the temp root
     → 404 (never escapes). *)
  Alcotest.(check int) "traversal blocked (404)" 404 status

(* ---- missing file ---- *)
let missing_file () =
  let status =
    Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
        with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
            serve_dir ~net ~sw ~clock dir (fun ~sw c url ->
                let resp = Client.get ~sw c (url ^ "/nope.txt") in
                ignore (Body.drain resp.Response.body);
                resp.Response.status_code)))
  in
  Alcotest.(check int) "missing file 404" 404 status

(* ---- dir → dir/ redirect (301) ---- *)
(* A directory request without a trailing slash gets a 301 to dir/. We use
   Transport.round_trip to observe the raw 301 (the Client would follow it). *)
let dir_redirect () =
  let status, loc =
    Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
        with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
            Eio.Path.mkdir ~perm:0o755 Eio.Path.(dir / "sub");
            write_file dir "sub/x.txt" "x";
            let handler = Fs.file_server (Fs.dir dir) in
            let s = Ts.new_server ~net ~clock ~sw handler in
            Fun.protect
              (fun () ->
                let tr = Transport.create ~net ~clock () in
                Transport.run tr ~sw (fun () ->
                    let req = Client.make_request "GET" (Ts.url s ^ "/sub") in
                    let resp = Transport.round_trip tr req in
                    ignore (Body.drain resp.Response.body);
                    ( resp.Response.status_code,
                      Header.get resp.Response.header "Location" )))
              ~finally:(fun () -> Ts.close s)))
  in
  Alcotest.(check int) "dir redirect 301" 301 status;
  Alcotest.(check string) "Location is sub/" "sub/" loc

let tests =
  [
    Alcotest.test_case "serve_known_file" `Quick serve_known_file;
    Alcotest.test_case "dir_listing" `Quick dir_listing;
    Alcotest.test_case "traversal_blocked" `Quick traversal_blocked;
    Alcotest.test_case "missing_file" `Quick missing_file;
    Alcotest.test_case "dir_redirect" `Quick dir_redirect;
  ]
