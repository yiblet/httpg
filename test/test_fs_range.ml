(* Byte-range request tests for the file-serving path, a ported subset of
   go/src/net/http/fs_test.go's range cases plus a unit test for
   [Fs.parse_range].

   Networked tests create a unique temp dir under the fs capability, serve it via
   an ephemeral loopback [Httptest.Server] + the httpg [Client], and clean up
   afterwards. Bounded by Test_harness.with_fs. *)

open Httpg
module Ts = Httptest.Server

(* Unwrap a happy-path client result, failing the test on a transport/redirect
   error (a 206/416 status is still [Ok]). *)
let ok_resp = function
  | Ok resp -> resp
  | Error e -> Alcotest.failf "client: %s" (Client.error_to_string e)

let read_body b =
  match Body.read_all b with
  | Ok s -> s
  | Error e -> Alcotest.failf "body: %s" (Body.error_to_string e)

let with_tmpdir ~fs ~net ~clock ~sw f =
  let name =
    Printf.sprintf "httpg_fsrange_%d_%d" (Unix.getpid ())
      (Random.int 1_000_000_000)
  in
  let dir = Eio.Path.(fs / Filename.get_temp_dir_name () / name) in
  Eio.Path.mkdir ~perm:0o755 dir;
  Fun.protect
    (fun () -> f ~net ~sw ~clock dir)
    ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)

let write_file dir name contents =
  Eio.Path.save ~create:(`Exclusive 0o644) Eio.Path.(dir / name) contents

(* Send a GET with extra headers, return (status, body, headers). 206/416 are
   not redirects, so [Client.send] returns them directly. *)
let request_with_headers ~sw c url headers =
  let req = Request.make ~meth:Httpg_base.Method.Get (Uri.of_string url) in
  req.Request.header <-
    List.fold_left (fun h (k, v) -> Header.set k v h) req.Request.header headers;
  let resp = ok_resp (Client.send ~sw c req) in
  ( Httpg_base.Status.to_int resp.Response.status,
    read_body resp.Response.body,
    resp.Response.header )

(* Serve a temp dir of [files] (name -> contents) and run [f ~sw client base_url]
   ([client] captures net/clock). *)
let with_server files f =
  Test_harness.with_fs (fun ~net ~clock ~sw ~fs ->
      with_tmpdir ~fs ~net ~clock ~sw (fun ~net ~sw ~clock dir ->
          List.iter (fun (name, contents) -> write_file dir name contents) files;
          let handler = Fs.file_server (Fs.dir dir) in
          let s = Ts.new_server ~net ~clock ~sw handler in
          Fun.protect
            ~finally:(fun () -> Ts.close s)
            (fun () -> f ~sw (Ts.client s) (Ts.url s))))

(* ---- parse_range unit test ---- *)
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
    | Error Fs.No_overlap ->
        Alcotest.failf "%s: expected Invalid_range, got No_overlap" name
    | Error _ -> Alcotest.failf "%s: expected Invalid_range" name
    | Ok _ -> Alcotest.failf "%s: expected Error, got Ok" name
  in
  let err_no_overlap name s size =
    match Fs.parse_range s size with
    | Error Fs.No_overlap -> ()
    | _ -> Alcotest.failf "%s: expected No_overlap" name
  in
  ok "empty" "" 10L [];
  ok "bytes=0-4" "bytes=0-4" 10L [ r 0L 5L ];
  ok "bytes=2-5" "bytes=2-5" 10L [ r 2L 4L ];
  ok "bytes=3-" "bytes=3-" 10L [ r 3L 7L ];
  ok "bytes=-4" "bytes=-4" 10L [ r 6L 4L ];
  ok "bytes=-20" "bytes=-20" 10L [ r 0L 10L ];
  ok "bytes=5-99" "bytes=5-99" 10L [ r 5L 5L ];
  ok "bytes=0-1,3-4" "bytes=0-1,3-4" 10L [ r 0L 2L; r 3L 2L ];
  ok "bytes= 0-1 , 3-4 " "bytes= 0-1 , 3-4 " 10L [ r 0L 2L; r 3L 2L ];
  err_invalid "no bytes prefix" "0-4" 10L;
  err_invalid "no dash" "bytes=5" 10L;
  err_invalid "start>end" "bytes=4-2" 10L;
  err_invalid "non-numeric" "bytes=abc-def" 10L;
  err_invalid "double dash" "bytes=--4" 10L;
  err_no_overlap "beyond size" "bytes=99-" 10L

(* ---- serve_file_range (plain GET / range / conditional) ---- *)
let serve_file_range () =
  let contents = "0123456789abcdef" in
  let size = String.length contents in
  let code200, b200, lm, ar, ct, st206, b206, cr, st304, b304 =
    with_server
      [ ("data.txt", contents) ]
      (fun ~sw c base ->
        let url = base ^ "/data.txt" in
        let r200 = ok_resp (Client.get ~sw c url) in
        let b200 = read_body r200.Response.body in
        let lm = Header.get r200.Response.header "Last-Modified" in
        let ar = Header.get r200.Response.header "Accept-Ranges" in
        let ct = Header.get r200.Response.header "Content-Type" in
        let st206, b206, h206 =
          request_with_headers ~sw c url [ ("Range", "bytes=4-7") ]
        in
        let cr = Header.get h206 "Content-Range" in
        let st304, b304, _ =
          request_with_headers ~sw c url
            [ ("If-Modified-Since", Option.get lm) ]
        in
        ( Httpg_base.Status.to_int r200.Response.status,
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
  Alcotest.(check int) "plain GET -> 200" 200 code200;
  Alcotest.(check string) "full body" contents b200;
  Alcotest.(check (option string))
    "Content-Type" (Some "text/plain; charset=utf-8") ct;
  Alcotest.(check bool) "Last-Modified present" true (Option.is_some lm);
  Alcotest.(check (option string)) "Accept-Ranges" (Some "bytes") ar;
  Alcotest.(check int) "Range -> 206" 206 st206;
  Alcotest.(check string) "range bytes" (String.sub contents 4 4) b206;
  Alcotest.(check (option string))
    "Content-Range"
    (Some (Printf.sprintf "bytes 4-7/%d" size))
    cr;
  Alcotest.(check int) "If-Modified-Since -> 304" 304 st304;
  Alcotest.(check string) "304 body empty" "" b304

(* ---- single range forms: 2-5, -4, 3- ---- *)
let single_ranges () =
  let contents = "0123456789abcdef" in
  let size = String.length contents in
  let (s1, b1, cr1), (s2, b2, cr2), (s3, b3, cr3) =
    with_server
      [ ("f.txt", contents) ]
      (fun ~sw c base ->
        let url = base ^ "/f.txt" in
        let s1, b1, h1 =
          request_with_headers ~sw c url [ ("Range", "bytes=2-5") ]
        in
        let s2, b2, h2 =
          request_with_headers ~sw c url [ ("Range", "bytes=-4") ]
        in
        let s3, b3, h3 =
          request_with_headers ~sw c url [ ("Range", "bytes=3-") ]
        in
        ( (s1, b1, Header.get h1 "Content-Range"),
          (s2, b2, Header.get h2 "Content-Range"),
          (s3, b3, Header.get h3 "Content-Range") ))
  in
  Alcotest.(check int) "2-5 status" 206 s1;
  Alcotest.(check string) "2-5 body" (String.sub contents 2 4) b1;
  Alcotest.(check (option string))
    "2-5 CR"
    (Some (Printf.sprintf "bytes 2-5/%d" size))
    cr1;
  Alcotest.(check int) "-4 status" 206 s2;
  Alcotest.(check string) "-4 body" (String.sub contents (size - 4) 4) b2;
  Alcotest.(check (option string))
    "-4 CR"
    (Some (Printf.sprintf "bytes %d-%d/%d" (size - 4) (size - 1) size))
    cr2;
  Alcotest.(check int) "3- status" 206 s3;
  Alcotest.(check string) "3- body" (String.sub contents 3 (size - 3)) b3;
  Alcotest.(check (option string))
    "3- CR"
    (Some (Printf.sprintf "bytes 3-%d/%d" (size - 1) size))
    cr3

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec loop i =
    if i + nl > hl then false
    else if String.sub haystack i nl = needle then true
    else loop (i + 1)
  in
  loop 0

(* ---- multiple ranges -> multipart/byteranges ---- *)
let multi_range () =
  let contents = "0123456789abcdef" in
  let size = String.length contents in
  let st, body, ct =
    with_server
      [ ("m.txt", contents) ]
      (fun ~sw c base ->
        let st, body, h =
          request_with_headers ~sw c (base ^ "/m.txt")
            [ ("Range", "bytes=0-1,3-4") ]
        in
        (st, body, Header.get h "Content-Type"))
  in
  Alcotest.(check int) "multi -> 206" 206 st;
  Alcotest.(check bool)
    "Content-Type multipart/byteranges" true
    (match ct with
    | Some ct -> contains ct "multipart/byteranges; boundary="
    | None -> false);
  Alcotest.(check bool)
    "part1 CR" true
    (contains body (Printf.sprintf "Content-Range: bytes 0-1/%d" size));
  Alcotest.(check bool)
    "part2 CR" true
    (contains body (Printf.sprintf "Content-Range: bytes 3-4/%d" size));
  Alcotest.(check bool)
    "part1 bytes" true
    (contains body (String.sub contents 0 2));
  Alcotest.(check bool)
    "part2 bytes" true
    (contains body (String.sub contents 3 2))

(* ---- unsatisfiable range -> 416 + Content-Range: bytes */SIZE ---- *)
let unsatisfiable_range () =
  let contents = "0123456789" in
  let size = String.length contents in
  let st, cr =
    with_server
      [ ("u.txt", contents) ]
      (fun ~sw c base ->
        let st, _, h =
          request_with_headers ~sw c (base ^ "/u.txt")
            [ ("Range", "bytes=9999-") ]
        in
        (st, Header.get h "Content-Range"))
  in
  Alcotest.(check int) "beyond size -> 416" 416 st;
  Alcotest.(check (option string))
    "Content-Range bytes */SIZE"
    (Some (Printf.sprintf "bytes */%d" size))
    cr

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
