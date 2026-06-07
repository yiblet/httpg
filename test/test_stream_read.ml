(* Streaming reads: Io.read_request/read_response return a streaming Body without
   buffering. These tests prove (a) the first chunk is obtainable before EOF (no
   full-body buffering), (b) Body.read_all yields the full payload, (c) chunked
   trailers populate the message trailer after the body is drained, and (d) two
   messages on one reader can be read in sequence once the first is drained
   (keep-alive positioning). Pure (in-memory Buf_read), no IO. *)

let r_of_string = Eio.Buf_read.of_string

let read_response_ok r =
  match Httpg.Io.read_response r with
  | Ok x -> x
  | Error e -> failwith (Httpg.Io.error_to_string e)

(* A chunked response: three small chunks, no trailer. *)
let chunked_resp =
  "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n"
  ^ "3\r\nbar\r\n" ^ "3\r\nbaz\r\n" ^ "0\r\n\r\n"

(* First chunk obtainable before EOF. *)
let first_chunk_before_eof () =
  let r = read_response_ok (r_of_string chunked_resp) in
  match r.Httpg.Response.body with
  | Httpg.Body.Stream next ->
      Alcotest.(check (option string)) "first chunk" (Some "foo") (next ());
      Alcotest.(check (option string)) "second chunk" (Some "bar") (next ())
  | _ -> Alcotest.fail "expected a streaming body"

(* read_all of a fresh parse equals the full payload. *)
let read_all_full_payload () =
  let r = read_response_ok (r_of_string chunked_resp) in
  Alcotest.(check string)
    "full body" "foobarbaz"
    (Httpg.Body.read_all r.Httpg.Response.body)

(* Chunked body WITH a trailer: after draining the body the response trailer
   carries the trailer header. *)
let trailer_after_drain () =
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: Md5\r\n\r\n"
    ^ "3\r\nfoo\r\n" ^ "3\r\nbar\r\n" ^ "0\r\n" ^ "Md5: abc123\r\n" ^ "\r\n"
  in
  let r = read_response_ok (r_of_string raw) in
  ignore (Httpg.Body.drain r.Httpg.Response.body);
  match r.Httpg.Response.trailer with
  | Some t ->
      Alcotest.(check string) "trailer Md5" "abc123" (Httpg.Header.get t "Md5")
  | None -> Alcotest.fail "expected trailer after drain"

(* A trailer without a declared Trailer header. *)
let trailer_undeclared_after_drain () =
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n"
    ^ "0\r\n" ^ "X-Late: yes\r\n" ^ "\r\n"
  in
  let r = read_response_ok (r_of_string raw) in
  Alcotest.(check string)
    "body" "foo"
    (Httpg.Body.read_all r.Httpg.Response.body);
  match r.Httpg.Response.trailer with
  | Some t ->
      Alcotest.(check string) "late trailer" "yes" (Httpg.Header.get t "X-Late")
  | None -> Alcotest.fail "expected trailer"

(* Keep-alive: two HTTP/1.1 responses concatenated on one reader. *)
let keep_alive_two_responses () =
  let resp1 = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" in
  let resp2 =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "5\r\nworld\r\n"
    ^ "0\r\n\r\n"
  in
  let r = r_of_string (resp1 ^ resp2) in
  let r1 = read_response_ok r in
  Alcotest.(check string)
    "resp1 body" "hello"
    (Httpg.Body.read_all r1.Httpg.Response.body);
  ignore (Httpg.Body.drain r1.Httpg.Response.body);
  let r2 = read_response_ok r in
  Alcotest.(check int)
    "resp2 code" 200
    (Httpg_base.Status.to_int r2.Httpg.Response.status_code);
  Alcotest.(check string)
    "resp2 body" "world"
    (Httpg.Body.read_all r2.Httpg.Response.body)

(* Keep-alive across a chunked first body. *)
let keep_alive_chunked_then_next () =
  let resp1 =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n"
    ^ "3\r\nbar\r\n" ^ "0\r\n\r\n"
  in
  let resp2 = "HTTP/1.1 204 No Content\r\n\r\n" in
  let r = r_of_string (resp1 ^ resp2) in
  let r1 = read_response_ok r in
  ignore (Httpg.Body.drain r1.Httpg.Response.body);
  let r2 = read_response_ok r in
  Alcotest.(check int)
    "resp2 code" 204
    (Httpg_base.Status.to_int r2.Httpg.Response.status_code)

let tests =
  [
    ("first_chunk_before_eof", `Quick, first_chunk_before_eof);
    ("read_all_full_payload", `Quick, read_all_full_payload);
    ("trailer_after_drain", `Quick, trailer_after_drain);
    ("trailer_undeclared_after_drain", `Quick, trailer_undeclared_after_drain);
    ("keep_alive_two_responses", `Quick, keep_alive_two_responses);
    ("keep_alive_chunked_then_next", `Quick, keep_alive_chunked_then_next);
  ]
