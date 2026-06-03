(* Ports of go/src/net/http/transfer_test.go and the relevant
   go/src/net/http/internal/chunked_test.go cases. Lwt is driven synchronously
   via Lwt_main.run. *)

open Gohttp

(* An in-memory input channel over a string (the analogue of
   strings.NewReader). *)
let ic_of_string s =
  Lwt_io.of_bytes ~mode:Lwt_io.input (Lwt_bytes.of_string s)

(* An in-memory output channel collecting bytes into a buffer; returns the
   channel and a getter for the written contents. We use a pipe and read the
   other end. *)
let with_output_string (f : Lwt_io.output_channel -> unit Lwt.t) : string =
  Lwt_main.run
    (let ic, oc = Lwt_io.pipe () in
     let writer =
       Lwt.bind (f oc) (fun () -> Lwt_io.close oc)
     in
     let reader = Lwt_io.read ic in
     Lwt.bind (Lwt.join [ writer ]) (fun () -> reader))

(* Read everything a chunked reader yields, to a string. *)
let read_chunked_all (s : string) : string =
  Lwt_main.run
    (let ic = ic_of_string s in
     let next = Transfer.new_chunked_reader ic in
     let buf = Buffer.create 64 in
     let rec loop () =
       Lwt.bind (next ()) (function
         | None -> Lwt.return (Buffer.contents buf)
         | Some d ->
           Buffer.add_string buf d;
           loop ())
     in
     loop ())

(* --- internal/chunked_test.go: TestChunk (writer wire format + roundtrip). *)

let test_chunk_writer_format () =
  let chunk1 = "hello, " in
  let chunk2 = "world! 0123456789abcdef" in
  let out =
    with_output_string (fun oc ->
        Lwt.bind (Transfer.chunked_writer_write oc chunk1) (fun () ->
            Lwt.bind (Transfer.chunked_writer_write oc chunk2) (fun () ->
                Transfer.chunked_writer_close oc)))
  in
  Alcotest.(check string)
    "chunk writer wire format"
    "7\r\nhello, \r\n17\r\nworld! 0123456789abcdef\r\n0\r\n" out

(* Success Criterion: encode with the chunked writer, decode with the chunked
   reader, assert byte equality. *)
let test_chunked_roundtrip () =
  let chunk1 = "hello, " in
  let chunk2 = "world! 0123456789abcdef" in
  let encoded =
    with_output_string (fun oc ->
        Lwt.bind (Transfer.chunked_writer_write oc chunk1) (fun () ->
            Lwt.bind (Transfer.chunked_writer_write oc chunk2) (fun () ->
                (* Close writes "0\r\n"; the reader consumes a trailing CRLF
                   after the final chunk, so append it (the http layer writes
                   the terminating CRLF separately). *)
                Lwt.bind (Transfer.chunked_writer_close oc) (fun () ->
                    Lwt_io.write oc "\r\n"))))
  in
  let decoded = read_chunked_all encoded in
  Alcotest.(check string) "chunked roundtrip byte-equality" (chunk1 ^ chunk2) decoded

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
    Alcotest.(check int64)
      (Printf.sprintf "parseHexUint %S" in_)
      want
      (Transfer.parse_hex_uint in_)
  in
  let err in_ frag =
    match Transfer.parse_hex_uint in_ with
    | exception Transfer.Chunk_error msg ->
      Alcotest.(check bool)
        (Printf.sprintf "parseHexUint %S error contains %S (got %S)" in_ frag msg)
        true
        (let re = Str.regexp_string frag in
         try ignore (Str.search_forward re msg 0); true with Not_found -> false)
    | n -> Alcotest.failf "parseHexUint %S = %Ld; want error %S" in_ n frag
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
  (* sample of the i = 0..1234 rows *)
  List.iter (fun i -> ok (Printf.sprintf "%x" i) (Int64.of_int i)) [ 0; 1; 15; 16; 255; 256; 1234 ]

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

(* TestChunkReadPartial (the malformed-tail portion): a chunk declaring size 7
   with data "1234567" followed by "xx" instead of CRLF is malformed. (Go's
   streaming reader defers the CRLF check to the next Read; this reader reads
   the chunk data and its terminating CRLF together, so the malformed error
   surfaces on the pull that consumes the chunk -- same error, eagerly.) *)
let test_chunk_read_partial () =
  let input = "7\r\n1234567xx" in
  match read_chunked_all input with
  | exception Transfer.Chunk_error msg ->
    Alcotest.(check bool)
      (Printf.sprintf "malformed error (got %S)" msg)
      true
      (let re = Str.regexp_string "malformed" in
       try ignore (Str.search_forward re msg 0); true with Not_found -> false)
  | got -> Alcotest.failf "expected malformed error, parsed %S" got

(* TestIncompleteChunk: every proper prefix of a valid stream is
   ErrUnexpectedEOF (here: Chunk_error "unexpected EOF"); the full stream is
   fine. *)
let test_incomplete_chunk () =
  let valid = "4\r\nabcd\r\n" ^ "5\r\nabc\r\n\r\n" ^ "0\r\n" in
  for i = 0 to String.length valid - 1 do
    let incomplete = String.sub valid 0 i in
    match read_chunked_all incomplete with
    | exception Transfer.Chunk_error _ -> ()
    | exception Transfer.Err_line_too_long -> ()
    | got -> Alcotest.failf "expected unexpected-EOF for prefix len %d, got %S" i got
  done;
  (* The full valid stream decodes without error. The second chunk's declared
     size 5 covers "abc\r\n" (the data itself contains a CRLF), so the decoded
     bytes are "abcd" ^ "abc\r\n". Like Go's internal chunked reader, ours stops
     at the 0-length chunk without consuming any trailing CRLF. *)
  Alcotest.(check string) "full valid stream" "abcdabc\r\n" (read_chunked_all valid)

(* --- transfer.go: TestParseContentLength. *)
let test_parse_content_length () =
  let ok cl =
    match Transfer.parse_content_length [ cl ] with
    | _ -> Alcotest.(check pass) (Printf.sprintf "CL %S ok" cl) () ()
    | exception e -> Alcotest.failf "CL %S unexpected error %s" cl (Printexc.to_string e)
  in
  let err cl what =
    match Transfer.parse_content_length [ cl ] with
    | n -> Alcotest.failf "CL %S = %Ld; want error %S" cl n what
    | exception Transfer.Bad_string_error (w, v) ->
      Alcotest.(check string) (Printf.sprintf "CL %S error what" cl) what w;
      Alcotest.(check string) (Printf.sprintf "CL %S error value" cl) cl v
  in
  err "" "invalid empty Content-Length";
  ok "3";
  err "+3" "bad Content-Length";
  err "-3" "bad Content-Length";
  ok "9223372036854775807";
  err "9223372036854775808" "bad Content-Length"

(* --- transfer.go: TestParseTransferEncoding (the error/ok rows). *)
let test_parse_transfer_encoding () =
  let run te =
    let h = Header.create () in
    List.iter (fun v -> Hashtbl.add h "Transfer-Encoding" [ v ]) [];
    Hashtbl.replace h "Transfer-Encoding" te;
    Transfer.parse_transfer_encoding ~major:1 ~minor:1 ~header:h
  in
  let err te frag =
    match run te with
    | exception Transfer.Chunk_error msg ->
      Alcotest.(check bool)
        (Printf.sprintf "TE %s error contains %S (got %S)" (String.concat "," te) frag msg)
        true
        (let re = Str.regexp_string frag in
         try ignore (Str.search_forward re msg 0); true with Not_found -> false)
    | b -> Alcotest.failf "TE %s = %b; want error" (String.concat "," te) b
  in
  err [ "fugazi" ] "unsupported transfer encoding";
  err [ "chunked, chunked"; "identity"; "chunked" ] "too many transfer encodings";
  err [ "" ] "unsupported transfer encoding";
  err [ "chunked, identity" ] "unsupported transfer encoding";
  err [ "chunked"; "identity" ] "too many transfer encodings";
  (* "chunked" alone -> true, no error. *)
  Alcotest.(check bool) "chunked alone -> true" true (run [ "chunked" ]);
  (* HTTP/1.0 ignores Transfer-Encoding entirely (Issue 12785). *)
  let h = Header.create () in
  Hashtbl.replace h "Transfer-Encoding" [ "chunked" ];
  Alcotest.(check bool) "HTTP/1.0 ignores TE" false
    (Transfer.parse_transfer_encoding ~major:1 ~minor:0 ~header:h)

(* --- fix_length: status/method/version-driven length rules. *)
let test_fix_length () =
  let mk pairs =
    let h = Header.create () in
    List.iter (fun (k, v) -> Hashtbl.replace h k [ v ]) pairs;
    h
  in
  let check name ~is_response ~status ~request_method ~header ~chunked expected =
    let got = Transfer.fix_length ~is_response ~status ~request_method ~header ~chunked in
    Alcotest.(check int64) name expected got
  in
  (* HEAD response: always 0. *)
  check "HEAD response -> 0" ~is_response:true ~status:200 ~request_method:"HEAD"
    ~header:(mk [ ("Content-Length", "10") ]) ~chunked:false 0L;
  (* 1xx / 204 / 304 -> 0. *)
  check "204 -> 0" ~is_response:true ~status:204 ~request_method:"GET" ~header:(mk [])
    ~chunked:false 0L;
  check "304 -> 0" ~is_response:true ~status:304 ~request_method:"GET" ~header:(mk [])
    ~chunked:false 0L;
  check "100 -> 0" ~is_response:true ~status:100 ~request_method:"GET" ~header:(mk [])
    ~chunked:false 0L;
  (* chunked -> -1 (and Content-Length removed). *)
  let h = mk [ ("Content-Length", "10") ] in
  check "chunked -> -1" ~is_response:true ~status:200 ~request_method:"GET" ~header:h
    ~chunked:true (-1L);
  Alcotest.(check (list string)) "chunked drops Content-Length" []
    (Header.values h "Content-Length");
  (* explicit Content-Length -> that value. *)
  check "explicit CL -> value" ~is_response:true ~status:200 ~request_method:"GET"
    ~header:(mk [ ("Content-Length", "42") ]) ~chunked:false 42L;
  (* request with no CL, no chunk -> 0. *)
  check "request no CL -> 0" ~is_response:false ~status:200 ~request_method:"GET"
    ~header:(mk []) ~chunked:false 0L;
  (* response with no CL, no chunk -> -1 (unbounded / close-delimited). *)
  check "response no CL -> -1" ~is_response:true ~status:200 ~request_method:"GET"
    ~header:(mk []) ~chunked:false (-1L);
  (* duplicate identical Content-Length is deduped, not an error. *)
  let hd = Header.create () in
  Hashtbl.replace hd "Content-Length" [ "5"; "5" ];
  check "dup identical CL -> value" ~is_response:false ~status:200 ~request_method:"POST"
    ~header:hd ~chunked:false 5L;
  (* conflicting Content-Length -> error. *)
  let hc = Header.create () in
  Hashtbl.replace hc "Content-Length" [ "5"; "6" ];
  (match
     Transfer.fix_length ~is_response:false ~status:200 ~request_method:"POST" ~header:hc
       ~chunked:false
   with
  | n -> Alcotest.failf "conflicting CL = %Ld; want error" n
  | exception Transfer.Chunk_error _ -> Alcotest.(check pass) "conflicting CL errors" () ())

(* --- should_close: version-sensitive connection management. *)
let test_should_close () =
  let mk conn =
    let h = Header.create () in
    (match conn with Some v -> Hashtbl.replace h "Connection" [ v ] | None -> ());
    h
  in
  let chk name ~major ~minor conn expected =
    Alcotest.(check bool) name expected
      (Transfer.should_close ~major ~minor ~header:(mk conn) ~remove_close_header:false)
  in
  (* HTTP/0.9-ish (major < 1) always closes. *)
  chk "major<1 closes" ~major:0 ~minor:9 None true;
  (* HTTP/1.0 defaults to close. *)
  chk "1.0 default closes" ~major:1 ~minor:0 None true;
  chk "1.0 keep-alive stays open" ~major:1 ~minor:0 (Some "keep-alive") false;
  chk "1.0 close closes" ~major:1 ~minor:0 (Some "close") true;
  (* HTTP/1.1 defaults to keep-alive. *)
  chk "1.1 default keeps open" ~major:1 ~minor:1 None false;
  chk "1.1 close closes" ~major:1 ~minor:1 (Some "close") true

(* --- fix_trailer. *)
let test_fix_trailer () =
  let mk_tr v =
    let h = Header.create () in
    Hashtbl.replace h "Trailer" [ v ];
    h
  in
  (* not chunked -> None (and Trailer kept in header). *)
  Alcotest.(check bool) "trailer ignored when not chunked" true
    (Transfer.fix_trailer ~header:(mk_tr "Md5") ~chunked:false = None);
  (* chunked: parses canonical keys. *)
  let h = mk_tr "md5, Some-Other" in
  (match Transfer.fix_trailer ~header:h ~chunked:true with
  | Some tr ->
    Alcotest.(check bool) "Trailer header deleted" false (Header.has h "Trailer");
    Alcotest.(check bool) "trailer has Md5" true (Hashtbl.mem tr "Md5");
    Alcotest.(check bool) "trailer has Some-Other" true (Hashtbl.mem tr "Some-Other")
  | None -> Alcotest.fail "expected a trailer");
  (* forbidden trailer key -> error. *)
  (match Transfer.fix_trailer ~header:(mk_tr "Content-Length") ~chunked:true with
  | _ -> Alcotest.fail "expected bad trailer key error"
  | exception Transfer.Bad_string_error (w, _) ->
    Alcotest.(check string) "bad trailer key" "bad trailer key" w)

(* --- write_body: representative transferWriter rows
   (TestTransferWriterWriteBodyReaderTypes analogue). We assert the wire bytes
   for chunked vs fixed-length, since OCaml has no reflect.Type. *)
let test_write_body_chunked () =
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(Body.of_string "hello")
      ~content_length:(-1L) ~transfer_encoding:[ "chunked" ] ()
  in
  let out = with_output_string (fun oc -> Transfer.write_body oc tw) in
  (* chunked body "hello" + close + terminating CRLF (no trailers). *)
  Alcotest.(check string) "chunked write_body" "5\r\nhello\r\n0\r\n\r\n" out

let test_write_body_fixed () =
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(Body.of_string "hello")
      ~content_length:5L ~transfer_encoding:[] ()
  in
  let out = with_output_string (fun oc -> Transfer.write_body oc tw) in
  Alcotest.(check string) "fixed-length write_body" "hello" out

let test_write_body_length_mismatch () =
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(Body.of_string "hello")
      ~content_length:3L ~transfer_encoding:[] ()
  in
  match with_output_string (fun oc -> Transfer.write_body oc tw) with
  | _ -> Alcotest.fail "expected ContentLength mismatch error"
  | exception Transfer.Chunk_error _ -> Alcotest.(check pass) "mismatch errors" () ()

(* A [Body.Stream] yielding each element of [chunks] in order, then EOF. *)
let stream_body (chunks : string list) : Body.t =
  let remaining = ref chunks in
  Body.of_stream (fun () ->
      match !remaining with
      | [] -> Lwt.return None
      | c :: rest ->
        remaining := rest;
        Lwt.return (Some c))

(* A multi-chunk streaming body written chunked streams per source chunk (Go's
   io.Copy into the chunkedWriter) and dechunks back to the concatenation. *)
let test_write_body_chunked_stream () =
  let chunks = [ "alpha"; "beta"; "gamma" ] in
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(stream_body chunks)
      ~content_length:(-1L) ~transfer_encoding:[ "chunked" ] ()
  in
  let out = with_output_string (fun oc -> Transfer.write_body oc tw) in
  (* One chunk per source chunk, then the 0-chunk + terminating CRLF. *)
  Alcotest.(check string)
    "chunked stream wire format" "5\r\nalpha\r\n4\r\nbeta\r\n5\r\ngamma\r\n0\r\n\r\n" out;
  (* Dechunked (drop the trailing CRLF the http layer appends) == concatenation. *)
  let body_part = "5\r\nalpha\r\n4\r\nbeta\r\n5\r\ngamma\r\n0\r\n" in
  Alcotest.(check string)
    "chunked stream dechunks to concatenation" "alphabetagamma"
    (read_chunked_all body_part)

(* A fixed-length streaming body whose total matches Content-Length writes the
   concatenation (Go's io.CopyN). *)
let test_write_body_fixed_stream () =
  let chunks = [ "alpha"; "beta"; "gamma" ] in
  let total = String.length (String.concat "" chunks) in
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(stream_body chunks)
      ~content_length:(Int64.of_int total) ~transfer_encoding:[] ()
  in
  let out = with_output_string (fun oc -> Transfer.write_body oc tw) in
  Alcotest.(check string) "fixed-length stream == concatenation" "alphabetagamma" out;
  Alcotest.(check int) "fixed-length stream length" total (String.length out)

(* A fixed-length streaming body whose total disagrees with Content-Length
   raises Chunk_error (the running byte counter). *)
let test_write_body_fixed_stream_mismatch () =
  let chunks = [ "alpha"; "beta" ] (* 9 bytes *) in
  let tw =
    Transfer.make_transfer_writer ~method_:"PUT" ~body:(stream_body chunks)
      ~content_length:20L ~transfer_encoding:[] ()
  in
  match with_output_string (fun oc -> Transfer.write_body oc tw) with
  | _ -> Alcotest.fail "expected ContentLength mismatch error"
  | exception Transfer.Chunk_error _ -> Alcotest.(check pass) "stream mismatch errors" () ()

(* --- read_transfer: end-to-end chunked response body decode
   (TestFinalChunkedBodyReadEOF analogue, without the Response struct). *)
let test_read_transfer_chunked () =
  let h = Header.create () in
  Hashtbl.replace h "Transfer-Encoding" [ "chunked" ];
  let msg =
    {
      Transfer.is_response = true;
      header = h;
      status_code = 200;
      request_method = "GET";
      proto_major = 1;
      proto_minor = 1;
      close = false;
    }
  in
  let body_bytes = "0a\r\nBody here\n\r\n09\r\ncontinued\r\n0\r\n\r\n" in
  let got =
    Lwt_main.run
      (let ic = ic_of_string body_bytes in
       Lwt.bind (Transfer.read_transfer msg ic) (fun r ->
           Alcotest.(check bool) "is_chunked" true r.Transfer.is_chunked;
           Body.read_all r.Transfer.body))
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
      status_code = 200;
      request_method = "POST";
      proto_major = 1;
      proto_minor = 1;
      close = false;
    }
  in
  let got =
    Lwt_main.run
      (let ic = ic_of_string "hello world" in
       Lwt.bind (Transfer.read_transfer msg ic) (fun r ->
           Alcotest.(check int64) "content_length" 5L r.Transfer.content_length;
           Body.read_all r.Transfer.body))
  in
  Alcotest.(check string) "content-length body" "hello" got

let tests =
  [
    ("chunk_writer_format", `Quick, test_chunk_writer_format);
    ("chunked_roundtrip", `Quick, test_chunked_roundtrip);
    ("chunk_ignores_extensions", `Quick, test_chunk_ignores_extensions);
    ("parse_hex_uint", `Quick, test_parse_hex_uint);
    ("chunk_invalid_inputs", `Quick, test_chunk_invalid_inputs);
    ("chunk_read_partial", `Quick, test_chunk_read_partial);
    ("incomplete_chunk", `Quick, test_incomplete_chunk);
    ("parse_content_length", `Quick, test_parse_content_length);
    ("parse_transfer_encoding", `Quick, test_parse_transfer_encoding);
    ("fix_length", `Quick, test_fix_length);
    ("should_close", `Quick, test_should_close);
    ("fix_trailer", `Quick, test_fix_trailer);
    ("write_body_chunked", `Quick, test_write_body_chunked);
    ("write_body_fixed", `Quick, test_write_body_fixed);
    ("write_body_length_mismatch", `Quick, test_write_body_length_mismatch);
    ("write_body_chunked_stream", `Quick, test_write_body_chunked_stream);
    ("write_body_fixed_stream", `Quick, test_write_body_fixed_stream);
    ("write_body_fixed_stream_mismatch", `Quick, test_write_body_fixed_stream_mismatch);
    ("read_transfer_chunked", `Quick, test_read_transfer_chunked);
    ("read_transfer_content_length", `Quick, test_read_transfer_content_length);
  ]
