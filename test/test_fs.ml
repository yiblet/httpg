(* Integration tests for the file-serving core (Tier 1, Ticket 3), a ported
   subset of go/src/net/http/fs_test.go.

   Each test creates a unique temp directory, populates it, serves it via a
   [Fs.file_server] over an ephemeral loopback [Httptest.Server], drives it with
   the gohttp [Client], and removes the temp dir in an [Lwt.finalize]. The whole
   run is bounded by [Net.with_timeout] so a hang fails rather than blocks. *)

open Gohttp
open Lwt.Infix
module Ts = Httptest.Server

(* ---- temp-dir helpers ---- *)

let mktempdir () =
  let base = Filename.get_temp_dir_name () in
  let name =
    Printf.sprintf "gohttp_fs_%d_%d" (Unix.getpid ()) (Random.int 1_000_000_000)
  in
  let dir = Filename.concat base name in
  Unix.mkdir dir 0o755;
  dir

let rec rm_rf path =
  match Unix.lstat path with
  | exception _ -> ()
  | st ->
      if st.Unix.st_kind = Unix.S_DIR then begin
        Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
        Unix.rmdir path
      end
      else Unix.unlink path

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

(* Run [f tmpdir] with a fresh temp dir, cleaning up afterwards. *)
let with_tmpdir f =
  let dir = mktempdir () in
  Lwt.finalize
    (fun () -> f dir)
    (fun () ->
      rm_rf dir;
      Lwt.return_unit)

(* ---- Fs.serve_file (known file) ---- *)
(* Go's TestServeFile (subset): GET a known file → 200 + exact bytes +
   Content-Type from the extension + Last-Modified + Accept-Ranges. *)
let serve_known_file () =
  let body_contents = "hello, file server\n" in
  let run () =
    with_tmpdir (fun dir ->
        write_file (Filename.concat dir "hello.txt") body_contents;
        let handler = Fs.file_server (Fs.dir dir) in
        Ts.new_server handler >>= fun s ->
        Lwt.finalize
          (fun () ->
            let c = Ts.client s in
            Client.get c (Ts.url s ^ "/hello.txt") >>= fun resp ->
            Body.read_all resp.Response.body >>= fun body ->
            let ct = Header.get resp.Response.header "Content-Type" in
            let lm = Header.get resp.Response.header "Last-Modified" in
            let ar = Header.get resp.Response.header "Accept-Ranges" in
            Lwt.return (resp.Response.status_code, body, ct, lm, ar))
          (fun () -> Ts.close s))
  in
  let status, body, ct, lm, ar = Lwt_main.run (Net.with_timeout 10. (run ())) in
  Alcotest.(check int) "status 200" 200 status;
  Alcotest.(check string) "body == file contents" body_contents body;
  Alcotest.(check string) "content-type .txt" "text/plain; charset=utf-8" ct;
  Alcotest.(check bool) "last-modified present" true (lm <> "");
  Alcotest.(check string) "accept-ranges bytes" "bytes" ar

(* ---- Fs.dir_list ---- *)
(* Go's TestDirectoryIfNotModified / dirList: GET a directory → 200,
   text/html, body lists the entry filenames. *)
let dir_listing () =
  let run () =
    with_tmpdir (fun dir ->
        write_file (Filename.concat dir "alpha.txt") "a";
        write_file (Filename.concat dir "beta.txt") "b";
        let handler = Fs.file_server (Fs.dir dir) in
        Ts.new_server handler >>= fun s ->
        Lwt.finalize
          (fun () ->
            let c = Ts.client s in
            Client.get c (Ts.url s ^ "/") >>= fun resp ->
            Body.read_all resp.Response.body >>= fun body ->
            let ct = Header.get resp.Response.header "Content-Type" in
            Lwt.return (resp.Response.status_code, body, ct))
          (fun () -> Ts.close s))
  in
  let status, body, ct = Lwt_main.run (Net.with_timeout 10. (run ())) in
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
(* Go's TestServeFileDirPanicEmptyPath / containsDotDot: a "/../" path must not
   escape the root; the FileServer 404s it. *)
let traversal_blocked () =
  let run () =
    with_tmpdir (fun dir ->
        write_file (Filename.concat dir "ok.txt") "ok";
        let handler = Fs.file_server (Fs.dir dir) in
        Ts.new_server handler >>= fun s ->
        Lwt.finalize
          (fun () ->
            let c = Ts.client s in
            (* a literal ../ escape attempt; path.Clean collapses it within the
               root, and Dir.Open rejects any residual "..". *)
            Client.get c (Ts.url s ^ "/../../../../etc/passwd") >>= fun resp ->
            Body.drain resp.Response.body >>= fun _ ->
            Lwt.return resp.Response.status_code)
          (fun () -> Ts.close s))
  in
  let status = Lwt_main.run (Net.with_timeout 10. (run ())) in
  (* path.Clean("/../../etc/passwd") = "/etc/passwd", which does not exist in
     the temp root → 404 (never escapes). *)
  Alcotest.(check int) "traversal blocked (404)" 404 status

(* ---- missing file ---- *)
let missing_file () =
  let run () =
    with_tmpdir (fun dir ->
        let handler = Fs.file_server (Fs.dir dir) in
        Ts.new_server handler >>= fun s ->
        Lwt.finalize
          (fun () ->
            let c = Ts.client s in
            Client.get c (Ts.url s ^ "/nope.txt") >>= fun resp ->
            Body.drain resp.Response.body >>= fun _ ->
            Lwt.return resp.Response.status_code)
          (fun () -> Ts.close s))
  in
  let status = Lwt_main.run (Net.with_timeout 10. (run ())) in
  Alcotest.(check int) "missing file 404" 404 status

(* ---- dir → dir/ redirect (301) ---- *)
(* Go's TestFileServerImplicitLeadingSlash / redirect: a request for a directory
   without a trailing slash gets a 301 to dir/. We use Transport.round_trip to
   observe the raw 301 (the Client would follow it). *)
let dir_redirect () =
  let run () =
    with_tmpdir (fun dir ->
        Unix.mkdir (Filename.concat dir "sub") 0o755;
        write_file (Filename.concat dir "sub/x.txt") "x";
        let handler = Fs.file_server (Fs.dir dir) in
        Ts.new_server handler >>= fun s ->
        Lwt.finalize
          (fun () ->
            let tr = Transport.create () in
            let req = Client.make_request "GET" (Ts.url s ^ "/sub") in
            Transport.round_trip tr req >>= fun resp ->
            Body.drain resp.Response.body >>= fun _ ->
            let loc = Header.get resp.Response.header "Location" in
            Lwt.return (resp.Response.status_code, loc))
          (fun () -> Ts.close s))
  in
  let status, loc = Lwt_main.run (Net.with_timeout 10. (run ())) in
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
