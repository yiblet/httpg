(* Ports of go/src/net/http/transfer_test.go and the relevant
   go/src/net/http/internal/chunked_test.go cases. Direct-style over Eio. *)

open Httpg

(* An in-memory reader over a string (the analogue of strings.NewReader). *)
let buf_read_of_string = Eio.Buf_read.of_string

(* Collect what [f] writes to a Buf_write into a string. *)
let with_output_string (f : Eio.Buf_write.t -> unit) : string =
  let w = Eio.Buf_write.create 256 in
  f w;
  Eio.Buf_write.serialize_to_string w

(* Read everything a chunked reader yields, to a string. *)
let read_chunked_all (s : string) : string =
  let r = buf_read_of_string s in
  let next = Transfer.new_chunked_reader r in
  let buf = Buffer.create 64 in
  let rec loop () =
    match next () with
    | None -> Buffer.contents buf
    | Some d ->
        Buffer.add_string buf d;
        loop ()
  in
  loop ()

(* --- internal/chunked_test.go: TestChunk (writer wire format + roundtrip). *)

let test_chunk_writer_format () =
  let chunk1 = "hello, " in
  let chunk2 = "world! 0123456789abcdef" in
  let out =
    with_output_string (fun w ->
        Transfer.chunked_writer_write w chunk1;
        Transfer.chunked_writer_write w chunk2;
        Transfer.chunked_writer_close w)
  in
  Alcotest.(check string)
    "chunk writer wire format"
    "7\r\nhello, \r\n17\r\nworld! 0123456789abcdef\r\n0\r\n" out

let test_chunked_roundtrip () =
  let chunk1 = "hello, " in
  let chunk2 = "world! 0123456789abcdef" in
  let encoded =
    with_output_string (fun w ->
        Transfer.chunked_writer_write w chunk1;
        Transfer.chunked_writer_write w chunk2;
        (* Close writes "0\r\n"; the reader consumes a trailing CRLF after the
           final chunk, so append it (the http layer writes the terminating CRLF
           separately). *)
        Transfer.chunked_writer_close w;
        Eio.Buf_write.string w "\r\n")
  in
  let decoded = read_chunked_all encoded in
  Alcotest.(check string)
    "chunked roundtrip byte-equality" (chunk1 ^ chunk2) decoded

(* TestChunkReadingIgnoresExtensions. *)
let test_chunk_ignores_extensions () =
  let input =
    "7;ext=\"some quoted string\"\r\n" ^ "hello, \r\n" ^ "17;someext\r\n"
    ^ "world! 0123456789abcdef\r\n" ^ "0;someextension=sometoken\r\n" ^ "\r\n"
  in
  Alcotest.(check string)
    "extensions ignored" "hello, world! 0123456789abcdef"
    (read_chunked_all input)

(* TestParseHexUint (the explicit error/value rows). *)
let test_parse_hex_uint () =
  let ok in_ want =
    match Transfer.parse_hex_uint in_ with
    | Ok n ->
        Alcotest.(check int64) (Printf.sprintf "parseHexUint %S" in_) want n
    | Error e ->
        Alcotest.failf "parseHexUint %S unexpected error %s" in_
          (Transfer.error_to_string e)
  in
  let err in_ frag =
    match Transfer.parse_hex_uint in_ with
    | Error (Transfer.Chunk msg) ->
        Alcotest.(check bool)
          (Printf.sprintf "parseHexUint %S error contains %S (got %S)" in_ frag
             msg)
          true
          (let re = Str.regexp_string frag in
           try
             ignore (Str.search_forward re msg 0);
             true
           with Not_found -> false)
    | Error e ->
        Alcotest.failf "parseHexUint %S = Error %s; want %S" in_
          (Transfer.error_to_string e)
          frag
    | Ok n -> Alcotest.failf "parseHexUint %S = %Ld; want error %S" in_ n frag
  in
  err "x" "invalid byte in chunk length";
  ok "0000000000000000" 0L;
  ok "0000000000000001" 1L;
  ok "ffffffffffffffff" (-1L) (* 1<<64-1 as a 64-bit pattern *);
  err "000000000000bogus" "invalid byte in chunk length";
  err "00000000000000000" "http chunk length too large";
  err "10000000000000000" "http chunk length too large";
  err "00000000000000001" "http chunk length too large";
  err "" "empty hex number for chunk length";
  List.iter
    (fun i -> ok (Printf.sprintf "%x" i) (Int64.of_int i))
    [ 0; 1; 15; 16; 255; 256; 1234 ]

(* TestChunkInvalidInputs: each must error. *)
let test_chunk_invalid_inputs () =
  let bad name b =
    match read_chunked_all b with
    | exception (Transfer.Chunk_error _ | Transfer.Err_line_too_long) ->
        Alcotest.(check pass) name () ()
    | got -> Alcotest.failf "%s: unexpectedly parsed %S" name got
  in
  bad "bare LF in chunk size" "1\na\r\n0\r\n";
  bad "extra LF in chunk size" "1\r\r\na\r\n0\r\n";
  bad "bare LF in chunk data" "1\r\na\n0\r\n";
  bad "bare LF in chunk extension" "1;\na\r\n0\r\n"

(* TestChunkReadPartial (malformed tail): the malformed error surfaces on the
   pull that consumes the chunk -- same error as Go, eagerly. *)
let test_chunk_read_partial () =
  let input = "7\r\n1234567xx" in
  match read_chunked_all input with
  | exception Transfer.Chunk_error msg ->
      Alcotest.(check bool)
        (Printf.sprintf "malformed error (got %S)" msg)
        true
        (let re = Str.regexp_string "malformed" in
         try
           ignore (Str.search_forward re msg 0);
           true
         with Not_found -> false)
  | got -> Alcotest.failf "expected malformed error, parsed %S" got

(* TestIncompleteChunk: every proper prefix of a valid stream is
   ErrUnexpectedEOF (Chunk_error "unexpected EOF"); the full stream is fine. *)
let test_incomplete_chunk () =
  let valid = "4\r\nabcd\r\n" ^ "5\r\nabc\r\n\r\n" ^ "0\r\n" in
  for i = 0 to String.length valid - 1 do
    let incomplete = String.sub valid 0 i in
    match read_chunked_all incomplete with
    | exception Transfer.Chunk_error _ -> ()
    | exception Transfer.Err_line_too_long -> ()
    | got ->
        Alcotest.failf "expected unexpected-EOF for prefix len %d, got %S" i got
  done;
  Alcotest.(check string)
    "full valid stream" "abcdabc\r\n" (read_chunked_all valid)

(* --- transfer.go: TestParseContentLength. *)
let test_parse_content_length () =
  let ok cl =
    match Transfer.parse_content_length [ cl ] with
    | Ok _ -> Alcotest.(check pass) (Printf.sprintf "CL %S ok" cl) () ()
    | Error e ->
        Alcotest.failf "CL %S unexpected error %s" cl
          (Transfer.error_to_string e)
  in
  let err cl =
    match Transfer.parse_content_length [ cl ] with
    | Ok n -> Alcotest.failf "CL %S = %Ld; want error" cl n
    | Error (Transfer.Bad_content_length v) ->
        Alcotest.(check string) (Printf.sprintf "CL %S error value" cl) cl v
    | Error e ->
        Alcotest.failf "CL %S = Error %s; want Bad_content_length" cl
          (Transfer.error_to_string e)
  in
  err "";
  ok "3";
  err "+3";
  err "-3";
  ok "9223372036854775807";
  err "9223372036854775808"

let test_parse_content_length_result () =
  (match Transfer.parse_content_length [ "x" ] with
  | Error (Transfer.Bad_content_length "x") ->
      Alcotest.(check pass) "\"x\" -> Bad_content_length" () ()
  | other ->
      Alcotest.failf "\"x\" -> %s; want Error (Bad_content_length \"x\")"
        (match other with
        | Ok n -> Printf.sprintf "Ok %Ld" n
        | Error e -> "Error " ^ Transfer.error_to_string e));
  (match Transfer.parse_content_length [ "42" ] with
  | Ok 42L -> Alcotest.(check pass) "\"42\" -> Ok 42" () ()
  | other ->
      Alcotest.failf "\"42\" -> %s; want Ok 42"
        (match other with
        | Ok n -> Printf.sprintf "Ok %Ld" n
        | Error e -> "Error " ^ Transfer.error_to_string e));
  let h = Header.create () in
  Hashtbl.replace h "Content-Length" [ "5"; "6" ];
  match
    Transfer.fix_length ~is_response:false ~status:200 ~request_method:"POST"
      ~header:h ~chunked:false
  with
  | Error (Transfer.Chunk _) ->
      Alcotest.(check pass) "conflicting CL -> Error (Chunk _)" () ()
  | Error e ->
      Alcotest.failf "conflicting CL -> Error %s; want Chunk"
        (Transfer.error_to_string e)
  | Ok n -> Alcotest.failf "conflicting CL = Ok %Ld; want Error" n

(* --- transfer.go: TestParseTransferEncoding (the error/ok rows). *)
let test_parse_transfer_encoding () =
  let run te =
    let h = Header.create () in
    Hashtbl.replace h "Transfer-Encoding" te;
    Transfer.parse_transfer_encoding ~major:1 ~minor:1 ~header:h
  in
  let err te frag =
    match run te with
    | Error e ->
        let msg = Transfer.error_to_string e in
        Alcotest.(check bool)
          (Printf.sprintf "TE %s error contains %S (got %S)"
             (String.concat "," te) frag msg)
          true
          (let re = Str.regexp_string frag in
           try
             ignore (Str.search_forward re msg 0);
             true
           with Not_found -> false)
    | Ok b -> Alcotest.failf "TE %s = %b; want error" (String.concat "," te) b
  in
  err [ "fugazi" ] "unsupported transfer encoding";
  err
    [ "chunked, chunked"; "identity"; "chunked" ]
    "too many transfer encodings";
  err [ "" ] "unsupported transfer encoding";
  err [ "chunked, identity" ] "unsupported transfer encoding";
  err [ "chunked"; "identity" ] "too many transfer encodings";
  Alcotest.(check bool)
    "chunked alone -> true" true
    (match run [ "chunked" ] with Ok b -> b | Error _ -> false);
  let h = Header.create () in
  Hashtbl.replace h "Transfer-Encoding" [ "chunked" ];
  Alcotest.(check bool)
    "HTTP/1.0 ignores TE" false
    (match Transfer.parse_transfer_encoding ~major:1 ~minor:0 ~header:h with
    | Ok b -> b
    | Error _ -> true)

(* --- fix_length: status/method/version-driven length rules. *)
let test_fix_length () =
  let mk pairs =
    let h = Header.create () in
    List.iter (fun (k, v) -> Hashtbl.replace h k [ v ]) pairs;
    h
  in
  let check name ~is_response ~status ~request_method ~header ~chunked expected
      =
    match
      Transfer.fix_length ~is_response ~status ~request_method ~header ~chunked
    with
    | Ok got -> Alcotest.(check int64) name expected got
    | Error e ->
        Alcotest.failf "%s: unexpected error %s" name
          (Transfer.error_to_string e)
  in
  check "HEAD response -> 0" ~is_response:true ~status:200
    ~request_method:"HEAD"
    ~header:(mk [ ("Content-Length", "10") ])
    ~chunked:false 0L;
  check "204 -> 0" ~is_response:true ~status:204 ~request_method:"GET"
    ~header:(mk []) ~chunked:false 0L;
  check "304 -> 0" ~is_response:true ~status:304 ~request_method:"GET"
    ~header:(mk []) ~chunked:false 0L;
  check "100 -> 0" ~is_response:true ~status:100 ~request_method:"GET"
    ~header:(mk []) ~chunked:false 0L;
  let h = mk [ ("Content-Length", "10") ] in
  check "chunked -> -1" ~is_response:true ~status:200 ~request_method:"GET"
    ~header:h ~chunked:true (-1L);
  Alcotest.(check (list string))
    "chunked drops Content-Length" []
    (Header.values h "Content-Length");
  check "explicit CL -> value" ~is_response:true ~status:200
    ~request_method:"GET"
    ~header:(mk [ ("Content-Length", "42") ])
    ~chunked:false 42L;
  check "request no CL -> 0" ~is_response:false ~status:200
    ~request_method:"GET" ~header:(mk []) ~chunked:false 0L;
  check "response no CL -> -1" ~is_response:true ~status:200
    ~request_method:"GET" ~header:(mk []) ~chunked:false (-1L);
  let hd = Header.create () in
  Hashtbl.replace hd "Content-Length" [ "5"; "5" ];
  check "dup identical CL -> value" ~is_response:false ~status:200
    ~request_method:"POST" ~header:hd ~chunked:false 5L;
  let hc = Header.create () in
  Hashtbl.replace hc "Content-Length" [ "5"; "6" ];
  match
    Transfer.fix_length ~is_response:false ~status:200 ~request_method:"POST"
      ~header:hc ~chunked:false
  with
  | Ok n -> Alcotest.failf "conflicting CL = %Ld; want error" n
  | Error (Transfer.Chunk _) ->
      Alcotest.(check pass) "conflicting CL errors" () ()
  | Error e ->
      Alcotest.failf "conflicting CL = Error %s; want Chunk"
        (Transfer.error_to_string e)

(* --- should_close: version-sensitive connection management. *)
let test_should_close () =
  let mk conn =
    let h = Header.create () in
    (match conn with
    | Some v -> Hashtbl.replace h "Connection" [ v ]
    | None -> ());
    h
  in
  let chk name ~major ~minor conn expected =
    Alcotest.(check bool)
      name expected
      (Transfer.should_close ~major ~minor ~header:(mk conn)
         ~remove_close_header:false)
  in
  chk "major<1 closes" ~major:0 ~minor:9 None true;
  chk "1.0 default closes" ~major:1 ~minor:0 None true;
  chk "1.0 keep-alive stays open" ~major:1 ~minor:0 (Some "keep-alive") false;
  chk "1.0 close closes" ~major:1 ~minor:0 (Some "close") true;
  chk "1.1 default keeps open" ~major:1 ~minor:1 None false;
  chk "1.1 close closes" ~major:1 ~minor:1 (Some "close") true

(* --- fix_trailer. *)
let test_fix_trailer () =
  let mk_tr v =
    let h = Header.create () in
    Hashtbl.replace h "Trailer" [ v ];
    h
  in
  Alcotest.(check bool)
    "trailer ignored when not chunked" true
    (Transfer.fix_trailer ~header:(mk_tr "Md5") ~chunked:false = Ok None);
  let h = mk_tr "md5, Some-Other" in
  (match Transfer.fix_trailer ~header:h ~chunked:true with
  | Ok (Some tr) ->
      Alcotest.(check bool)
        "Trailer header deleted" false (Header.has h "Trailer");
      Alcotest.(check bool) "trailer has Md5" true (Hashtbl.mem tr "Md5");
      Alcotest.(check bool)
        "trailer has Some-Other" true
        (Hashtbl.mem tr "Some-Other")
  | Ok None -> Alcotest.fail "expected a trailer"
  | Error e -> Alcotest.failf "unexpected error %s" (Transfer.error_to_string e));
  match Transfer.fix_trailer ~header:(mk_tr "Content-Length") ~chunked:true with
  | Ok _ -> Alcotest.fail "expected bad trailer key error"
  | Error (Transfer.Bad_header (w, _)) ->
      Alcotest.(check string) "bad trailer key" "bad trailer key" w
  | Error e -> Alcotest.failf "unexpected error %s" (Transfer.error_to_string e)

(* --- write_body: representative transferWriter rows. *)
let test_write_body_chunked () =
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(Body.of_string "hello")
      ~content_length:(-1L) ~transfer_encoding:[ "chunked" ] ()
  in
  let out = with_output_string (fun w -> Transfer.write_body w tw) in
  Alcotest.(check string) "chunked write_body" "5\r\nhello\r\n0\r\n\r\n" out

let test_write_body_fixed () =
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(Body.of_string "hello")
      ~content_length:5L ~transfer_encoding:[] ()
  in
  let out = with_output_string (fun w -> Transfer.write_body w tw) in
  Alcotest.(check string) "fixed-length write_body" "hello" out

let test_write_body_length_mismatch () =
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(Body.of_string "hello")
      ~content_length:3L ~transfer_encoding:[] ()
  in
  match with_output_string (fun w -> Transfer.write_body w tw) with
  | _ -> Alcotest.fail "expected ContentLength mismatch error"
  | exception Transfer.Chunk_error _ ->
      Alcotest.(check pass) "mismatch errors" () ()

(* A [Body.Stream] yielding each element of [chunks] in order, then EOF. *)
let stream_body (chunks : string list) : Body.t =
  let remaining = ref chunks in
  Body.of_stream (fun () ->
      match !remaining with
      | [] -> None
      | c :: rest ->
          remaining := rest;
          Some c)

let test_write_body_chunked_stream () =
  let chunks = [ "alpha"; "beta"; "gamma" ] in
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(stream_body chunks)
      ~content_length:(-1L) ~transfer_encoding:[ "chunked" ] ()
  in
  let out = with_output_string (fun w -> Transfer.write_body w tw) in
  Alcotest.(check string)
    "chunked stream wire format"
    "5\r\nalpha\r\n4\r\nbeta\r\n5\r\ngamma\r\n0\r\n\r\n" out;
  let body_part = "5\r\nalpha\r\n4\r\nbeta\r\n5\r\ngamma\r\n0\r\n" in
  Alcotest.(check string)
    "chunked stream dechunks to concatenation" "alphabetagamma"
    (read_chunked_all body_part)

let test_write_body_fixed_stream () =
  let chunks = [ "alpha"; "beta"; "gamma" ] in
  let total = String.length (String.concat "" chunks) in
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(stream_body chunks)
      ~content_length:(Int64.of_int total) ~transfer_encoding:[] ()
  in
  let out = with_output_string (fun w -> Transfer.write_body w tw) in
  Alcotest.(check string)
    "fixed-length stream == concatenation" "alphabetagamma" out;
  Alcotest.(check int) "fixed-length stream length" total (String.length out)

let test_write_body_fixed_stream_mismatch () =
  let chunks =
    [ "alpha"; "beta" ]
    (* 9 bytes *)
  in
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(stream_body chunks)
      ~content_length:20L ~transfer_encoding:[] ()
  in
  match with_output_string (fun w -> Transfer.write_body w tw) with
  | _ -> Alcotest.fail "expected ContentLength mismatch error"
  | exception Transfer.Chunk_error _ ->
      Alcotest.(check pass) "stream mismatch errors" () ()

(* --- read_transfer: end-to-end chunked response body decode. *)
let test_read_transfer_chunked () =
  let h = Header.create () in
  Hashtbl.replace h "Transfer-Encoding" [ "chunked" ];
  let msg =
    {
      Transfer.is_response = true;
      header = h;
      status_code = Httpg_base.Status.Ok;
      request_method = "GET";
      proto_major = 1;
      proto_minor = 1;
      close = false;
    }
  in
  let body_bytes = "0a\r\nBody here\n\r\n09\r\ncontinued\r\n0\r\n\r\n" in
  let r = buf_read_of_string body_bytes in
  let got =
    match Transfer.read_transfer msg r with
    | Ok res ->
        Alcotest.(check bool) "is_chunked" true res.Transfer.is_chunked;
        Body.read_all res.Transfer.body
    | Error e ->
        Alcotest.failf "read_transfer error %s" (Transfer.error_to_string e)
  in
  Alcotest.(check string) "chunked body decoded" "Body here\ncontinued" got

(* --- read_transfer: fixed content-length body. *)
let test_read_transfer_content_length () =
  let h = Header.create () in
  Hashtbl.replace h "Content-Length" [ "5" ];
  let msg =
    {
      Transfer.is_response = false;
      header = h;
      status_code = Httpg_base.Status.Ok;
      request_method = "POST";
      proto_major = 1;
      proto_minor = 1;
      close = false;
    }
  in
  let r = buf_read_of_string "hello world" in
  let got =
    match Transfer.read_transfer msg r with
    | Ok res ->
        Alcotest.(check int64) "content_length" 5L res.Transfer.content_length;
        Body.read_all res.Transfer.body
    | Error e ->
        Alcotest.failf "read_transfer error %s" (Transfer.error_to_string e)
  in
  Alcotest.(check string) "content-length body" "hello" got

(* A boundary framing error short-circuits to [Error]; a bad chunk-size found
   mid-stream (after read_transfer returned [Ok], inside the Body.Stream thunk)
   keeps raising [Chunk_error] — the mid-stream policy (Resolution #1). *)
let test_read_transfer_bad_chunk () =
  let mk_msg header =
    {
      Transfer.is_response = false;
      header;
      status_code = Httpg_base.Status.Ok;
      request_method = "POST";
      proto_major = 1;
      proto_minor = 1;
      close = false;
    }
  in
  (* (a) Boundary error: unsupported transfer encoding -> Error. *)
  let h_bad_te = Header.create () in
  Hashtbl.replace h_bad_te "Transfer-Encoding" [ "fugazi" ];
  (match Transfer.read_transfer (mk_msg h_bad_te) (buf_read_of_string "") with
  | Error (Transfer.Unsupported_transfer_encoding "fugazi") ->
      Alcotest.(check pass) "unsupported TE -> Error" () ()
  | Error e ->
      Alcotest.failf
        "unsupported TE -> Error %s; want Unsupported_transfer_encoding"
        (Transfer.error_to_string e)
  | Ok _ -> Alcotest.fail "unsupported TE -> Ok; want Error");
  (* (b) Mid-stream bad chunk size: read_transfer returns Ok, the body thunk
     raises Chunk_error when it parses the bad hex size. *)
  let h_chunked = Header.create () in
  Hashtbl.replace h_chunked "Transfer-Encoding" [ "chunked" ];
  let r = buf_read_of_string "zz\r\nnope\r\n0\r\n\r\n" in
  match Transfer.read_transfer (mk_msg h_chunked) r with
  | Error e ->
      Alcotest.failf "chunked read_transfer boundary -> Error %s; want Ok"
        (Transfer.error_to_string e)
  | Ok res -> (
      match Body.read_all res.Transfer.body with
      | got ->
          Alcotest.failf "bad chunk size mid-stream parsed %S; want raise" got
      | exception Transfer.Chunk_error _ ->
          Alcotest.(check pass) "bad chunk -> mid-stream raise" () ())

(* F013: an unknown-length request body (content_length=-1, no explicit TE) must
   auto-select chunked framing (transfer.go:96 shouldSendChunkedRequestBody), so
   the body is framed on the wire rather than silently dropped. *)
let stream_of_list parts =
  let pending = ref parts in
  Body.of_stream (fun () ->
      match !pending with
      | [] -> None
      | x :: xs ->
          pending := xs;
          Some x)

let test_chunked_auto_select_post () =
  let body = stream_of_list [ "hello"; " world" ] in
  let tw =
    Transfer.make_transfer_writer ~method_:"POST" ~body ~content_length:(-1L)
      ~transfer_encoding:[] ()
  in
  Alcotest.(check (list string))
    "POST cl<0 no-TE -> chunked auto-selected" [ "chunked" ]
    tw.Transfer.tw_transfer_encoding;
  let hdr = with_output_string (fun w -> Transfer.write_transfer_header w tw) in
  Alcotest.(check string)
    "header advertises chunked" "Transfer-Encoding: chunked\r\n" hdr;
  let wire = with_output_string (fun w -> Transfer.write_body w tw) in
  (* full body present as chunks (5 + 6 bytes), then the 0-length terminator. *)
  Alcotest.(check string)
    "body framed chunked, full payload" "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
    wire

(* A body-lacking method (GET) with an EMPTY streaming body must NOT be chunked
   (Go probes and treats a content-less ReadCloser as nil; Issue 18257). *)
let test_chunked_auto_select_get_empty () =
  let body = stream_of_list [] in
  let tw =
    Transfer.make_transfer_writer ~method_:"GET" ~body ~content_length:(-1L)
      ~transfer_encoding:[] ()
  in
  Alcotest.(check (list string))
    "GET empty body -> no chunking" [] tw.Transfer.tw_transfer_encoding;
  Alcotest.(check bool)
    "GET empty body -> body cleared" true
    (tw.Transfer.tw_body = Body.Empty)

(* A body-lacking method (GET) with a NON-empty body is probed and chunked, the
   probed chunk re-prepended so the whole body still goes out. *)
let test_chunked_auto_select_get_nonempty () =
  let body = stream_of_list [ "ab"; "cd" ] in
  let tw =
    Transfer.make_transfer_writer ~method_:"GET" ~body ~content_length:(-1L)
      ~transfer_encoding:[] ()
  in
  Alcotest.(check (list string))
    "GET non-empty body -> chunked" [ "chunked" ]
    tw.Transfer.tw_transfer_encoding;
  let wire = with_output_string (fun w -> Transfer.write_body w tw) in
  Alcotest.(check string)
    "probed chunk re-prepended, full body framed"
    "2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n" wire

let tests =
  [
    ("chunk_writer_format", `Quick, test_chunk_writer_format);
    ("chunked_auto_select_post", `Quick, test_chunked_auto_select_post);
    ("chunked_auto_select_get_empty", `Quick, test_chunked_auto_select_get_empty);
    ( "chunked_auto_select_get_nonempty",
      `Quick,
      test_chunked_auto_select_get_nonempty );
    ("chunked_roundtrip", `Quick, test_chunked_roundtrip);
    ("chunk_ignores_extensions", `Quick, test_chunk_ignores_extensions);
    ("parse_hex_uint", `Quick, test_parse_hex_uint);
    ("chunk_invalid_inputs", `Quick, test_chunk_invalid_inputs);
    ("chunk_read_partial", `Quick, test_chunk_read_partial);
    ("incomplete_chunk", `Quick, test_incomplete_chunk);
    ("parse_content_length", `Quick, test_parse_content_length);
    ("parse_content_length_result", `Quick, test_parse_content_length_result);
    ("parse_transfer_encoding", `Quick, test_parse_transfer_encoding);
    ("fix_length", `Quick, test_fix_length);
    ("should_close", `Quick, test_should_close);
    ("fix_trailer", `Quick, test_fix_trailer);
    ("write_body_chunked", `Quick, test_write_body_chunked);
    ("write_body_fixed", `Quick, test_write_body_fixed);
    ("write_body_length_mismatch", `Quick, test_write_body_length_mismatch);
    ("write_body_chunked_stream", `Quick, test_write_body_chunked_stream);
    ("write_body_fixed_stream", `Quick, test_write_body_fixed_stream);
    ( "write_body_fixed_stream_mismatch",
      `Quick,
      test_write_body_fixed_stream_mismatch );
    ("read_transfer_chunked", `Quick, test_read_transfer_chunked);
    ("read_transfer_content_length", `Quick, test_read_transfer_content_length);
    ("read_transfer_bad_chunk", `Quick, test_read_transfer_bad_chunk);
  ]
