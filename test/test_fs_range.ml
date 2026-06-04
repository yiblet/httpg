(* Byte-range request tests for the file-serving path (Tier 1, Ticket 5), a
   ported subset of go/src/net/http/fs_test.go's range cases (TestServeContent's
   range table + TestServeFileContentType / the FileServer range behavior),
   plus a focused unit test for [Fs.parse_range].

   Networked tests create a unique temp dir, serve it via an ephemeral loopback
   [Httptest.Server] + the gohttp [Client], and clean up in an [Lwt.finalize].
   The whole run is bounded by [Net.with_timeout] so a hang fails rather than
   blocks. *)

open Gohttp
open Lwt.Infix

module Ts = Httptest.Server

(* ---- temp-dir helpers (same shape as test_fs_conditional.ml) ---- *)

let mktempdir () =
  let base = Filename.get_temp_dir_name () in
  let name =
    Printf.sprintf "gohttp_fsrange_%d_%d" (Unix.getpid ())
      (Random.int 1_000_000_000)
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

let with_tmpdir f =
  let dir = mktempdir () in
  Lwt.finalize (fun () -> f dir) (fun () -> rm_rf dir; Lwt.return_unit)

(* Send a GET with extra headers, return (status, body, headers). 206/416 are
   not redirects, so [Client.do_] returns them directly. *)
let request_with_headers c url headers =
  let req = Client.make_request "GET" url in
  List.iter (fun (k, v) -> Header.set req.Request.header k v) headers;
  Client.do_ c req >>= fun resp ->
  Body.read_all resp.Response.body >>= fun body ->
  Lwt.return (resp.Response.status_code, body, resp.Response.header)

(* Serve a temp dir of [files] (name -> contents) and run [f client base_url]. *)
let with_server files f =
  with_tmpdir (fun dir ->
      List.iter
        (fun (name, contents) -> write_file (Filename.concat dir name) contents)
        files;
      let handler = Fs.file_server (Fs.dir dir) in
      Ts.new_server handler >>= fun s ->
      Lwt.finalize
        (fun () ->
          let c = Ts.client s in
          f c (Ts.url s))
        (fun () -> Ts.close s))

(* ---- parse_range unit test (Go TestParseRange) ---- *)

let parse_range_unit () =
  let r start length = Fs.{ start; length } in
  let ok name s size expected =
    match Fs.parse_range s size with
    | Ok got -> Alcotest.(check bool) name true (got = expected)
    | Error _ -> Alcotest.failf "%s: expected Ok, got Error" name
  in
  let err_invalid name s size =
    match Fs.parse_range s size with
    | Error (Fs.Invalid_range _) -> ()
    | Error Fs.No_overlap -> Alcotest.failf "%s: expected Invalid_range, got No_overlap" name
    | Error _ -> Alcotest.failf "%s: expected Invalid_range" name
    | Ok _ -> Alcotest.failf "%s: expected Error, got Ok" name
  in
  let err_no_overlap name s size =
    match Fs.parse_range s size with
    | Error Fs.No_overlap -> ()
    | _ -> Alcotest.failf "%s: expected No_overlap" name
  in
  (* empty header -> [] *)
  ok "empty" "" 10L [];
  (* single explicit range *)
  ok "bytes=0-4" "bytes=0-4" 10L [ r 0L 5L ];
  ok "bytes=2-5" "bytes=2-5" 10L [ r 2L 4L ];
  (* open range to EOF *)
  ok "bytes=3-" "bytes=3-" 10L [ r 3L 7L ];
  (* suffix range: last N bytes *)
  ok "bytes=-4" "bytes=-4" 10L [ r 6L 4L ];
  (* suffix longer than file clamps to whole file *)
  ok "bytes=-20" "bytes=-20" 10L [ r 0L 10L ];
  (* end past EOF clamps to last byte *)
  ok "bytes=5-99" "bytes=5-99" 10L [ r 5L 5L ];
  (* multiple ranges *)
  ok "bytes=0-1,3-4" "bytes=0-1,3-4" 10L [ r 0L 2L; r 3L 2L ];
  (* whitespace tolerated *)
  ok "bytes= 0-1 , 3-4 " "bytes= 0-1 , 3-4 " 10L [ r 0L 2L; r 3L 2L ];
  (* malformed: missing "bytes=" *)
  err_invalid "no bytes prefix" "0-4" 10L;
  (* malformed: no dash *)
  err_invalid "no dash" "bytes=5" 10L;
  (* malformed: start > end *)
  err_invalid "start>end" "bytes=4-2" 10L;
  (* malformed: non-numeric *)
  err_invalid "non-numeric" "bytes=abc-def" 10L;
  (* malformed: negative suffix form *)
  err_invalid "double dash" "bytes=--4" 10L;
  (* no overlap: starts beyond size *)
  err_no_overlap "beyond size" "bytes=99-" 10L

(* ---- Success Criterion: serve_file_range (plain GET / range / conditional) ---- *)

let serve_file_range () =
  let contents = "0123456789abcdef" in
  let size = String.length contents in
  let run () =
    with_server
      [ ("data.txt", contents) ]
      (fun c base ->
        let url = base ^ "/data.txt" in
        (* plain GET -> 200 + full body + CT + Last-Modified + Accept-Ranges *)
        Client.get c url >>= fun r200 ->
        Body.read_all r200.Response.body >>= fun b200 ->
        let lm = Header.get r200.Response.header "Last-Modified" in
        let ar = Header.get r200.Response.header "Accept-Ranges" in
        let ct = Header.get r200.Response.header "Content-Type" in
        (* Range: bytes=4-7 -> 206 + Content-Range + exactly those bytes *)
        request_with_headers c url [ ("Range", "bytes=4-7") ]
        >>= fun (st206, b206, h206) ->
        let cr = Header.get h206 "Content-Range" in
        (* conditional GET -> 304 *)
        request_with_headers c url [ ("If-Modified-Since", lm) ]
        >>= fun (st304, b304, _) ->
        Lwt.return
          ( r200.Response.status_code,
            b200,
            lm,
            ar,
            ct,
            st206,
            b206,
            cr,
            st304,
            b304 ))
  in
  let code200, b200, lm, ar, ct, st206, b206, cr, st304, b304 =
    Lwt_main.run (Net.with_timeout 10. (run ()))
  in
  (* plain GET *)
  Alcotest.(check int) "plain GET -> 200" 200 code200;
  Alcotest.(check string) "full body" contents b200;
  Alcotest.(check string) "Content-Type" "text/plain; charset=utf-8" ct;
  Alcotest.(check bool) "Last-Modified present" true (lm <> "");
  Alcotest.(check string) "Accept-Ranges" "bytes" ar;
  (* range *)
  Alcotest.(check int) "Range -> 206" 206 st206;
  Alcotest.(check string) "range bytes" (String.sub contents 4 4) b206;
  Alcotest.(check string) "Content-Range"
    (Printf.sprintf "bytes 4-7/%d" size)
    cr;
  (* conditional *)
  Alcotest.(check int) "If-Modified-Since -> 304" 304 st304;
  Alcotest.(check string) "304 body empty" "" b304

(* ---- single range forms: 2-5, -4, 3- ---- *)

let single_ranges () =
  let contents = "0123456789abcdef" in
  let size = String.length contents in
  let run () =
    with_server
      [ ("f.txt", contents) ]
      (fun c base ->
        let url = base ^ "/f.txt" in
        request_with_headers c url [ ("Range", "bytes=2-5") ]
        >>= fun (s1, b1, h1) ->
        request_with_headers c url [ ("Range", "bytes=-4") ]
        >>= fun (s2, b2, h2) ->
        request_with_headers c url [ ("Range", "bytes=3-") ]
        >>= fun (s3, b3, h3) ->
        Lwt.return
          ( (s1, b1, Header.get h1 "Content-Range"),
            (s2, b2, Header.get h2 "Content-Range"),
            (s3, b3, Header.get h3 "Content-Range") ))
  in
  let (s1, b1, cr1), (s2, b2, cr2), (s3, b3, cr3) =
    Lwt_main.run (Net.with_timeout 10. (run ()))
  in
  Alcotest.(check int) "2-5 status" 206 s1;
  Alcotest.(check string) "2-5 body" (String.sub contents 2 4) b1;
  Alcotest.(check string) "2-5 CR" (Printf.sprintf "bytes 2-5/%d" size) cr1;
  Alcotest.(check int) "-4 status" 206 s2;
  Alcotest.(check string) "-4 body" (String.sub contents (size - 4) 4) b2;
  Alcotest.(check string) "-4 CR"
    (Printf.sprintf "bytes %d-%d/%d" (size - 4) (size - 1) size)
    cr2;
  Alcotest.(check int) "3- status" 206 s3;
  Alcotest.(check string) "3- body" (String.sub contents 3 (size - 3)) b3;
  Alcotest.(check string) "3- CR"
    (Printf.sprintf "bytes 3-%d/%d" (size - 1) size)
    cr3

(* ---- multiple ranges -> multipart/byteranges ---- *)

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec loop i =
    if i + nl > hl then false
    else if String.sub haystack i nl = needle then true
    else loop (i + 1)
  in
  loop 0

let multi_range () =
  let contents = "0123456789abcdef" in
  let size = String.length contents in
  let run () =
    with_server
      [ ("m.txt", contents) ]
      (fun c base ->
        request_with_headers c (base ^ "/m.txt")
          [ ("Range", "bytes=0-1,3-4") ]
        >>= fun (st, body, h) ->
        Lwt.return (st, body, Header.get h "Content-Type"))
  in
  let st, body, ct = Lwt_main.run (Net.with_timeout 10. (run ())) in
  Alcotest.(check int) "multi -> 206" 206 st;
  Alcotest.(check bool) "Content-Type multipart/byteranges" true
    (contains ct "multipart/byteranges; boundary=");
  (* both parts' Content-Range headers present *)
  Alcotest.(check bool) "part1 CR" true
    (contains body (Printf.sprintf "Content-Range: bytes 0-1/%d" size));
  Alcotest.(check bool) "part2 CR" true
    (contains body (Printf.sprintf "Content-Range: bytes 3-4/%d" size));
  (* both parts' bytes present *)
  Alcotest.(check bool) "part1 bytes" true (contains body (String.sub contents 0 2));
  Alcotest.(check bool) "part2 bytes" true (contains body (String.sub contents 3 2))

(* ---- unsatisfiable range -> 416 + Content-Range: bytes */SIZE ---- *)

let unsatisfiable_range () =
  let contents = "0123456789" in
  let size = String.length contents in
  let run () =
    with_server
      [ ("u.txt", contents) ]
      (fun c base ->
        request_with_headers c (base ^ "/u.txt") [ ("Range", "bytes=9999-") ]
        >>= fun (st, _, h) -> Lwt.return (st, Header.get h "Content-Range"))
  in
  let st, cr = Lwt_main.run (Net.with_timeout 10. (run ())) in
  Alcotest.(check int) "beyond size -> 416" 416 st;
  Alcotest.(check string) "Content-Range bytes */SIZE"
    (Printf.sprintf "bytes */%d" size)
    cr

(* Result migration T6: parse_range returns typed errors. *)
let parse_range_typed () =
  (match Fs.parse_range "not-a-range" 10L with
  | Error (Fs.Invalid_range _) -> ()
  | _ -> Alcotest.fail "bad Range header -> Error (Invalid_range _)");
  (match Fs.parse_range "bytes=4-2" 10L with
  | Error (Fs.Invalid_range _) -> ()
  | _ -> Alcotest.fail "start>end -> Error (Invalid_range _)");
  (match Fs.parse_range "bytes=99-" 10L with
  | Error Fs.No_overlap -> ()
  | _ -> Alcotest.fail "unsatisfiable -> Error No_overlap");
  match Fs.parse_range "bytes=0-4" 10L with
  | Ok [ { Fs.start = 0L; length = 5L } ] -> ()
  | _ -> Alcotest.fail "valid range -> Ok"

let tests =
  [
    Alcotest.test_case "parse_range" `Quick parse_range_unit;
    Alcotest.test_case "parse_range_typed" `Quick parse_range_typed;
    Alcotest.test_case "serve_file_range" `Quick serve_file_range;
    Alcotest.test_case "single_ranges" `Quick single_ranges;
    Alcotest.test_case "multi_range" `Quick multi_range;
    Alcotest.test_case "unsatisfiable_range" `Quick unsatisfiable_range;
  ]
