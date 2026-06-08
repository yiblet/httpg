(* Conditional-request tests for the file-serving path, a ported subset of the
   precondition cases of go/src/net/http/fs_test.go plus a unit test for
   [Fs.scan_etag].

   Networked tests create a unique temp dir under the fs capability, serve it via
   an ephemeral loopback [Httptest.Server], drive it with the httpg [Client], and
   clean up afterwards. Bounded by Test_harness.with_fs. *)

open Httpg
module Ts = Httptest.Server

(* ---- temp-dir + file helpers ---- *)

let with_tmpdir ~fs ~net ~clock ~sw f =
  let name =
    Printf.sprintf "httpg_fscond_%d_%d" (Unix.getpid ())
      (Random.int 1_000_000_000)
  in
  let dir = Eio.Path.(fs / Filename.get_temp_dir_name () / name) in
  Eio.Path.mkdir ~perm:0o755 dir;
  Fun.protect
    (fun () -> f ~net ~sw ~clock dir)
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)

let write_file dir name contents =
  Eio.Path.save ~create:(`Exclusive 0o644) Eio.Path.(dir / name) contents

(* ---- scan_etag (Go's scanETag) ---- *)
let scan_etag_unit () =
  (match Fs.scan_etag "\"123\"" with
  | Some (etag, remain) ->
      Alcotest.(check string) "strong etag" "\"123\"" etag;
      Alcotest.(check string) "strong remain" "" remain
  | None -> Alcotest.fail "expected strong ETag to scan");
  (match Fs.scan_etag "W/\"foo\"" with
  | Some (etag, _) -> Alcotest.(check string) "weak etag" "W/\"foo\"" etag
  | None -> Alcotest.fail "expected weak ETag to scan");
  (match Fs.scan_etag "  \"a\", \"b\"" with
  | Some (etag, remain) ->
      Alcotest.(check string) "first etag" "\"a\"" etag;
      Alcotest.(check string) "remainder" ", \"b\"" remain
  | None -> Alcotest.fail "expected first ETag to scan");
  Alcotest.(check bool) "no quote -> None" true (Fs.scan_etag "123" = None);
  Alcotest.(check bool) "empty -> None" true (Fs.scan_etag "" = None);
  Alcotest.(check bool) "unterminated -> None" true (Fs.scan_etag "\"abc" = None)

(* A handler that sets an ETag (when given) then serves [path] via serve_content,
   mirroring Go's TestServeContent which sets w.Header()'s Etag before
   ServeContent. Uses the [Fs.dir] machinery so the file handle is managed. *)
let etag_file_handler ~dir ~name ~etag =
 fun ~sw r ->
  let fsys = Fs.dir dir in
  (* Open under the request switch [~sw]: the served body streams from the
         fd after the handler returns, so it must outlive this call. *)
  match fsys.Fs.open_ ~sw name with
  | Error _ -> Server.error "not found" Httpg_base.Status.NotFound
  | Ok f ->
      let d = f.Fs.stat () in
      let header =
        match etag with
        | Some e -> Header.set (Header.create ()) "Etag" e
        | None -> Header.create ()
      in
      Fs.serve_content ~header r ~name:d.Fs.fi_name ~modtime:d.Fs.fi_mod_time
        ~size:d.Fs.fi_size ~read_window:f.Fs.read_window

(* Build a GET to [url] with extra headers, send via [Client.do_] (304/412 are
   not redirects, so do_ returns them directly), read its body. *)
let request_with_headers ~sw c url headers =
  let req = Client.make_request Httpg_base.Method.Get url in
  req.Request.header <-
    List.fold_left (fun h (k, v) -> Header.set h k v) req.Request.header headers;
  let resp = Client.do_ ~sw c req in
  ( Httpg_base.Status.to_int resp.Response.status,
    Body.read_all resp.Response.body,
    resp.Response.header )

let serve ~net ~sw ~clock handler client =
  let s = Ts.new_server ~net ~clock ~sw handler in
  Fun.protect
    (fun () -> client ~sw (Ts.client s) (Ts.url s))
    ~finally:(fun () -> Ts.close s)

(* ---- If-Modified-Since >= modtime -> 304 ---- *)
let if_modified_since_304 () =
  let contents = "conditional body\n" in
  let last_mod, status, body =
    Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
        with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
            write_file dir "x.txt" contents;
            let handler = Fs.file_server (Fs.dir dir) in
            serve ~net ~sw ~clock handler (fun ~sw c url ->
                let r0 = Client.get ~sw c (url ^ "/x.txt") in
                ignore (Body.drain r0.Response.body);
                let last_mod = Header.get r0.Response.header "Last-Modified" in
                let status, body, _ =
                  request_with_headers ~sw c (url ^ "/x.txt")
                    [ ("If-Modified-Since", last_mod) ]
                in
                (last_mod, status, body))))
  in
  Alcotest.(check bool) "Last-Modified present" true (last_mod <> "");
  Alcotest.(check int) "If-Modified-Since >= modtime -> 304" 304 status;
  Alcotest.(check string) "304 body empty" "" body

(* ---- If-Modified-Since < modtime -> 200 ---- *)
let if_modified_since_200 () =
  let contents = "served fresh\n" in
  let status, body =
    Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
        with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
            write_file dir "y.txt" contents;
            let handler = Fs.file_server (Fs.dir dir) in
            serve ~net ~sw ~clock handler (fun ~sw c url ->
                let status, body, _ =
                  request_with_headers ~sw c (url ^ "/y.txt")
                    [ ("If-Modified-Since", "Mon, 02 Jan 2006 15:04:05 GMT") ]
                in
                (status, body))))
  in
  Alcotest.(check int) "If-Modified-Since < modtime -> 200" 200 status;
  Alcotest.(check string) "body served" contents body

(* ---- If-None-Match matching ETag -> 304 (GET) ---- *)
let if_none_match_304 () =
  let contents = "etagged\n" in
  let st1, b1, st2, st3, b3 =
    Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
        with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
            write_file dir "z.txt" contents;
            let handler =
              etag_file_handler ~dir ~name:"z.txt" ~etag:(Some "\"foo\"")
            in
            serve ~net ~sw ~clock handler (fun ~sw c url ->
                let st1, b1, _ =
                  request_with_headers ~sw c url
                    [ ("If-None-Match", "\"foo\"") ]
                in
                let st2, _, _ =
                  request_with_headers ~sw c url
                    [ ("If-None-Match", "\"baz\", W/\"foo\"") ]
                in
                let st3, b3, _ =
                  request_with_headers ~sw c url
                    [ ("If-None-Match", "\"Foo\"") ]
                in
                (st1, b1, st2, st3, b3))))
  in
  Alcotest.(check int) "If-None-Match exact -> 304" 304 st1;
  Alcotest.(check string) "304 body empty" "" b1;
  Alcotest.(check int) "If-None-Match weak list -> 304" 304 st2;
  Alcotest.(check int) "If-None-Match mismatch -> 200" 200 st3;
  Alcotest.(check string) "200 body served" contents b3

(* ---- If-Match mismatch -> 412 ---- *)
let if_match_412 () =
  let contents = "match me\n" in
  let st_bad, st_ok, b_ok, st_star =
    Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
        with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
            write_file dir "m.txt" contents;
            let handler =
              etag_file_handler ~dir ~name:"m.txt" ~etag:(Some "\"right\"")
            in
            serve ~net ~sw ~clock handler (fun ~sw c url ->
                let st_bad, _, _ =
                  request_with_headers ~sw c url [ ("If-Match", "\"wrong\"") ]
                in
                let st_ok, b_ok, _ =
                  request_with_headers ~sw c url [ ("If-Match", "\"right\"") ]
                in
                let st_star, _, _ =
                  request_with_headers ~sw c url [ ("If-Match", "*") ]
                in
                (st_bad, st_ok, b_ok, st_star))))
  in
  Alcotest.(check int) "If-Match wrong -> 412" 412 st_bad;
  Alcotest.(check int) "If-Match right -> 200" 200 st_ok;
  Alcotest.(check string) "200 body served" contents b_ok;
  Alcotest.(check int) "If-Match * -> 200" 200 st_star

(* ---- If-Unmodified-Since older than modtime -> 412 ---- *)
let if_unmodified_since_412 () =
  let contents = "unmodified test\n" in
  let st_old, st_eq, b_eq =
    Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
        with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
            write_file dir "u.txt" contents;
            let handler = Fs.file_server (Fs.dir dir) in
            serve ~net ~sw ~clock handler (fun ~sw c url ->
                let st_old, _, _ =
                  request_with_headers ~sw c (url ^ "/u.txt")
                    [ ("If-Unmodified-Since", "Mon, 02 Jan 2006 15:04:05 GMT") ]
                in
                let r0 = Client.get ~sw c (url ^ "/u.txt") in
                ignore (Body.drain r0.Response.body);
                let last_mod = Header.get r0.Response.header "Last-Modified" in
                let st_eq, b_eq, _ =
                  request_with_headers ~sw c (url ^ "/u.txt")
                    [ ("If-Unmodified-Since", last_mod) ]
                in
                (st_old, st_eq, b_eq))))
  in
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
