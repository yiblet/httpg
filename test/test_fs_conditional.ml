(* Conditional-request tests for the file-serving path (Tier 1, Ticket 4), a
   ported subset of the precondition cases of go/src/net/http/fs_test.go
   (TestServeContent's table + the directory If-Modified-Since cases) plus a
   focused unit test for [Fs.scan_etag].

   Networked tests create a unique temp dir, serve it via an ephemeral loopback
   [Httptest.Server], drive it with the gohttp [Client], and clean up in an
   [Lwt.finalize]. The whole run is bounded by [Net.with_timeout] so a hang
   fails rather than blocks. *)

open Gohttp
open Lwt.Infix

module Ts = Httptest.Server

(* ---- temp-dir helpers (same shape as test_fs.ml) ---- *)

let mktempdir () =
  let base = Filename.get_temp_dir_name () in
  let name =
    Printf.sprintf "gohttp_fscond_%d_%d" (Unix.getpid ())
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

(* ---- scan_etag (Go's scanETag) ---- *)
let scan_etag_unit () =
  (* valid strong ETag, no remainder *)
  (match Fs.scan_etag "\"123\"" with
  | Some (etag, remain) ->
      Alcotest.(check string) "strong etag" "\"123\"" etag;
      Alcotest.(check string) "strong remain" "" remain
  | None -> Alcotest.fail "expected strong ETag to scan");
  (* valid weak ETag W/"..." *)
  (match Fs.scan_etag "W/\"foo\"" with
  | Some (etag, _) -> Alcotest.(check string) "weak etag" "W/\"foo\"" etag
  | None -> Alcotest.fail "expected weak ETag to scan");
  (* leading whitespace trimmed, trailing text returned as remainder *)
  (match Fs.scan_etag "  \"a\", \"b\"" with
  | Some (etag, remain) ->
      Alcotest.(check string) "first etag" "\"a\"" etag;
      Alcotest.(check string) "remainder" ", \"b\"" remain
  | None -> Alcotest.fail "expected first ETag to scan");
  (* invalid: no opening quote *)
  Alcotest.(check bool) "no quote -> None" true (Fs.scan_etag "123" = None);
  (* invalid: empty *)
  Alcotest.(check bool) "empty -> None" true (Fs.scan_etag "" = None);
  (* invalid: unterminated quote *)
  Alcotest.(check bool) "unterminated -> None" true
    (Fs.scan_etag "\"abc" = None)

(* ---- A handler that sets an ETag (when given) then serves a file via
   serve_content, mirroring Go's TestServeContent which sets w.Header()'s Etag
   before ServeContent. ---- *)
let etag_file_handler ~path ~etag =
  Server.handler_func (fun w r ->
      Lwt_unix.stat path >>= fun st ->
      let size = Int64.of_int st.Lwt_unix.st_size in
      let modtime = st.Lwt_unix.st_mtime in
      (match etag with
      | Some e -> Header.set (w.Server.header ()) "Etag" e
      | None -> ());
      Lwt_unix.openfile path [ Unix.O_RDONLY ] 0 >>= fun fd ->
      let read_window ~off ~len =
        Lwt_unix.LargeFile.lseek fd off Unix.SEEK_SET >>= fun _ ->
        let buf = Bytes.create len in
        let rec loop got =
          if got >= len then Lwt.return got
          else
            Lwt_unix.read fd buf got (len - got) >>= fun n ->
            if n = 0 then Lwt.return got else loop (got + n)
        in
        loop 0 >>= fun got -> Lwt.return (Bytes.sub_string buf 0 got)
      in
      Lwt.finalize
        (fun () ->
          Fs.serve_content w r ~name:(Filename.basename path) ~modtime ~size
            ~read_window)
        (fun () -> Lwt_unix.close fd))

(* Build a request to [url] with extra headers, send it via [Client.do_] (which
   returns 3xx/4xx directly — 304/412 are not redirects), read its body, and
   return (status, body). *)
let request_with_headers c url headers =
  let req = Client.make_request "GET" url in
  List.iter (fun (k, v) -> Header.set req.Request.header k v) headers;
  Client.do_ c req >>= fun resp ->
  Body.read_all resp.Response.body >>= fun body ->
  Lwt.return (resp.Response.status_code, body, resp.Response.header)

(* ---- If-Modified-Since >= modtime -> 304 (empty body), and a plain GET first
   to learn the Last-Modified value. ---- *)
let if_modified_since_304 () =
  let contents = "conditional body\n" in
  let run () =
    with_tmpdir (fun dir ->
        let path = Filename.concat dir "x.txt" in
        write_file path contents;
        let handler = Fs.file_server (Fs.dir dir) in
        Ts.new_server handler >>= fun s ->
        Lwt.finalize
          (fun () ->
            let c = Ts.client s in
            (* plain GET to learn Last-Modified *)
            Client.get c (Ts.url s ^ "/x.txt") >>= fun r0 ->
            Body.drain r0.Response.body >>= fun () ->
            let last_mod = Header.get r0.Response.header "Last-Modified" in
            (* If-Modified-Since == Last-Modified -> 304 *)
            request_with_headers c
              (Ts.url s ^ "/x.txt")
              [ ("If-Modified-Since", last_mod) ]
            >>= fun (status, body, _) -> Lwt.return (last_mod, status, body))
          (fun () -> Ts.close s))
  in
  let last_mod, status, body =
    Lwt_main.run (Net.with_timeout 10. (run ()))
  in
  Alcotest.(check bool) "Last-Modified present" true (last_mod <> "");
  Alcotest.(check int) "If-Modified-Since >= modtime -> 304" 304 status;
  Alcotest.(check string) "304 body empty" "" body

(* ---- If-Modified-Since < modtime -> 200 (served). ---- *)
let if_modified_since_200 () =
  let contents = "served fresh\n" in
  let run () =
    with_tmpdir (fun dir ->
        let path = Filename.concat dir "y.txt" in
        write_file path contents;
        let handler = Fs.file_server (Fs.dir dir) in
        Ts.new_server handler >>= fun s ->
        Lwt.finalize
          (fun () ->
            let c = Ts.client s in
            (* an old date, well before the file modtime *)
            request_with_headers c
              (Ts.url s ^ "/y.txt")
              [ ("If-Modified-Since", "Mon, 02 Jan 2006 15:04:05 GMT") ]
            >>= fun (status, body, _) -> Lwt.return (status, body))
          (fun () -> Ts.close s))
  in
  let status, body = Lwt_main.run (Net.with_timeout 10. (run ())) in
  Alcotest.(check int) "If-Modified-Since < modtime -> 200" 200 status;
  Alcotest.(check string) "body served" contents body

(* ---- If-None-Match matching ETag -> 304 (GET). Uses a handler that sets the
   ETag before serve_content (FileServer does not auto-generate one). ---- *)
let if_none_match_304 () =
  let contents = "etagged\n" in
  let run () =
    with_tmpdir (fun dir ->
        let path = Filename.concat dir "z.txt" in
        write_file path contents;
        let handler = etag_file_handler ~path ~etag:(Some "\"foo\"") in
        Ts.new_server handler >>= fun s ->
        Lwt.finalize
          (fun () ->
            let c = Ts.client s in
            (* exact strong match -> 304 *)
            request_with_headers c (Ts.url s)
              [ ("If-None-Match", "\"foo\"") ]
            >>= fun (st1, b1, _) ->
            (* weak-match in a list -> 304 (If-None-Match uses weak compare) *)
            request_with_headers c (Ts.url s)
              [ ("If-None-Match", "\"baz\", W/\"foo\"") ]
            >>= fun (st2, _, _) ->
            (* non-matching ETag -> 200 served *)
            request_with_headers c (Ts.url s)
              [ ("If-None-Match", "\"Foo\"") ]
            >>= fun (st3, b3, _) -> Lwt.return (st1, b1, st2, st3, b3))
          (fun () -> Ts.close s))
  in
  let st1, b1, st2, st3, b3 = Lwt_main.run (Net.with_timeout 10. (run ())) in
  Alcotest.(check int) "If-None-Match exact -> 304" 304 st1;
  Alcotest.(check string) "304 body empty" "" b1;
  Alcotest.(check int) "If-None-Match weak list -> 304" 304 st2;
  Alcotest.(check int) "If-None-Match mismatch -> 200" 200 st3;
  Alcotest.(check string) "200 body served" contents b3

(* ---- If-Match mismatch -> 412. ---- *)
let if_match_412 () =
  let contents = "match me\n" in
  let run () =
    with_tmpdir (fun dir ->
        let path = Filename.concat dir "m.txt" in
        write_file path contents;
        let handler = etag_file_handler ~path ~etag:(Some "\"right\"") in
        Ts.new_server handler >>= fun s ->
        Lwt.finalize
          (fun () ->
            let c = Ts.client s in
            (* If-Match a wrong ETag -> 412 *)
            request_with_headers c (Ts.url s)
              [ ("If-Match", "\"wrong\"") ]
            >>= fun (st_bad, _, _) ->
            (* If-Match the right ETag -> 200 *)
            request_with_headers c (Ts.url s)
              [ ("If-Match", "\"right\"") ]
            >>= fun (st_ok, b_ok, _) ->
            (* If-Match: * -> 200 *)
            request_with_headers c (Ts.url s) [ ("If-Match", "*") ]
            >>= fun (st_star, _, _) ->
            Lwt.return (st_bad, st_ok, b_ok, st_star))
          (fun () -> Ts.close s))
  in
  let st_bad, st_ok, b_ok, st_star =
    Lwt_main.run (Net.with_timeout 10. (run ()))
  in
  Alcotest.(check int) "If-Match wrong -> 412" 412 st_bad;
  Alcotest.(check int) "If-Match right -> 200" 200 st_ok;
  Alcotest.(check string) "200 body served" contents b_ok;
  Alcotest.(check int) "If-Match * -> 200" 200 st_star

(* ---- If-Unmodified-Since older than modtime -> 412. ---- *)
let if_unmodified_since_412 () =
  let contents = "unmodified test\n" in
  let run () =
    with_tmpdir (fun dir ->
        let path = Filename.concat dir "u.txt" in
        write_file path contents;
        let handler = Fs.file_server (Fs.dir dir) in
        Ts.new_server handler >>= fun s ->
        Lwt.finalize
          (fun () ->
            let c = Ts.client s in
            (* an old date < modtime -> 412 *)
            request_with_headers c
              (Ts.url s ^ "/u.txt")
              [ ("If-Unmodified-Since", "Mon, 02 Jan 2006 15:04:05 GMT") ]
            >>= fun (st_old, _, _) ->
            (* learn Last-Modified, then If-Unmodified-Since == modtime -> 200 *)
            Client.get c (Ts.url s ^ "/u.txt") >>= fun r0 ->
            Body.drain r0.Response.body >>= fun () ->
            let last_mod = Header.get r0.Response.header "Last-Modified" in
            request_with_headers c
              (Ts.url s ^ "/u.txt")
              [ ("If-Unmodified-Since", last_mod) ]
            >>= fun (st_eq, b_eq, _) -> Lwt.return (st_old, st_eq, b_eq))
          (fun () -> Ts.close s))
  in
  let st_old, st_eq, b_eq = Lwt_main.run (Net.with_timeout 10. (run ())) in
  Alcotest.(check int) "If-Unmodified-Since < modtime -> 412" 412 st_old;
  Alcotest.(check int) "If-Unmodified-Since == modtime -> 200" 200 st_eq;
  Alcotest.(check string) "200 body served" contents b_eq

let tests =
  [
    Alcotest.test_case "scan_etag" `Quick scan_etag_unit;
    Alcotest.test_case "if_modified_since_304" `Quick if_modified_since_304;
    Alcotest.test_case "if_modified_since_200" `Quick if_modified_since_200;
    Alcotest.test_case "if_none_match_304" `Quick if_none_match_304;
    Alcotest.test_case "if_match_412" `Quick if_match_412;
    Alcotest.test_case "if_unmodified_since_412" `Quick if_unmodified_since_412;
  ]
