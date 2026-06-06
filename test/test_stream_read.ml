(* Ticket 1 (streaming reads): Io.read_request/read_response return a streaming
   Body without buffering. These tests prove (a) the first chunk is obtainable
   before the stream reaches EOF (no full-body buffering), (b) Body.read_all of
   a fresh parse yields the full payload, (c) chunked trailers populate the
   message trailer after the body is drained, and (d) two messages concatenated
   on one channel can be read in sequence once the first body is drained
   (keep-alive positioning). All bounded by Net.with_timeout. *)

open Lwt.Infix

let ic_of_string s = Lwt_io.of_bytes ~mode:Lwt_io.input (Lwt_bytes.of_string s)
let run t = Lwt_main.run (Httpg.Net.with_timeout 5.0 t)

(* Unwrap Io.read_response's result; a parse error fails the test loudly. *)
let read_response_ok ic =
  Httpg.Io.read_response ic >>= function
  | Ok r -> Lwt.return r
  | Error e -> Lwt.fail (Failure (Httpg.Io.error_to_string e))

(* A chunked response: three small chunks, no trailer. *)
let chunked_resp =
  "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n"
  ^ "3\r\nbar\r\n" ^ "3\r\nbaz\r\n" ^ "0\r\n\r\n"

(* First chunk obtainable before EOF: pull a single chunk from the stream and
   assert we got payload while the stream has NOT yet signalled EOF. This proves
   read_response did not collapse the whole body into a String up front. *)
let first_chunk_before_eof () =
  run
    (let ic = ic_of_string chunked_resp in
     read_response_ok ic >>= fun r ->
     match r.Httpg.Response.body with
     | Httpg.Body.Stream next ->
         next () >>= fun first ->
         (* The first chunk is "foo"; the stream is not at EOF (more chunks
          remain), proving incremental delivery. *)
         Alcotest.(check (option string)) "first chunk" (Some "foo") first;
         next () >|= fun second ->
         Alcotest.(check (option string)) "second chunk" (Some "bar") second
     | _ -> Alcotest.fail "expected a streaming body")

(* read_all of a fresh parse equals the full payload. *)
let read_all_full_payload () =
  run
    (let ic = ic_of_string chunked_resp in
     read_response_ok ic >>= fun r ->
     Httpg.Body.read_all r.Httpg.Response.body >|= fun data ->
     Alcotest.(check string) "full body" "foobarbaz" data)

(* Chunked body WITH a trailer: after draining the body the response trailer
   carries the trailer header (Go's body.readTrailer -> mergeSetHeader). *)
let trailer_after_drain () =
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: Md5\r\n\r\n"
    ^ "3\r\nfoo\r\n" ^ "3\r\nbar\r\n" ^ "0\r\n" ^ "Md5: abc123\r\n" ^ "\r\n"
  in
  run
    (let ic = ic_of_string raw in
     read_response_ok ic >>= fun r ->
     Httpg.Body.drain r.Httpg.Response.body >|= fun _ ->
     match r.Httpg.Response.trailer with
     | Some t ->
         Alcotest.(check string)
           "trailer Md5" "abc123"
           (Httpg.Header.get t "Md5")
     | None -> Alcotest.fail "expected trailer after drain")

(* A trailer without a declared Trailer header (Go still merges what is read
   after the 0-chunk). *)
let trailer_undeclared_after_drain () =
  let raw =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n"
    ^ "0\r\n" ^ "X-Late: yes\r\n" ^ "\r\n"
  in
  run
    (let ic = ic_of_string raw in
     read_response_ok ic >>= fun r ->
     Httpg.Body.read_all r.Httpg.Response.body >|= fun data ->
     Alcotest.(check string) "body" "foo" data;
     match r.Httpg.Response.trailer with
     | Some t ->
         Alcotest.(check string)
           "late trailer" "yes"
           (Httpg.Header.get t "X-Late")
     | None -> Alcotest.fail "expected trailer")

(* Keep-alive: two HTTP/1.1 responses concatenated on one channel. Read the
   first, drain its body, then successfully read the second and its body. This
   exercises the body positioning the streaming reader leaves the channel in. *)
let keep_alive_two_responses () =
  let resp1 = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" in
  let resp2 =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "5\r\nworld\r\n"
    ^ "0\r\n\r\n"
  in
  run
    (let ic = ic_of_string (resp1 ^ resp2) in
     read_response_ok ic >>= fun r1 ->
     Httpg.Body.read_all r1.Httpg.Response.body >>= fun b1 ->
     Alcotest.(check string) "resp1 body" "hello" b1;
     (* Drain (already at EOF for a fixed-length body; mirrors the server
        finishRequest drain) then read the next message. *)
     Httpg.Body.drain r1.Httpg.Response.body >>= fun _ ->
     read_response_ok ic >>= fun r2 ->
     Httpg.Body.read_all r2.Httpg.Response.body >|= fun b2 ->
     Alcotest.(check int) "resp2 code" 200 r2.Httpg.Response.status_code;
     Alcotest.(check string) "resp2 body" "world" b2)

(* Keep-alive across a chunked first body: drain a chunked body (consuming its
   trailing CRLF) then read a second response on the same channel. *)
let keep_alive_chunked_then_next () =
  let resp1 =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ^ "3\r\nfoo\r\n"
    ^ "3\r\nbar\r\n" ^ "0\r\n\r\n"
  in
  let resp2 = "HTTP/1.1 204 No Content\r\n\r\n" in
  run
    (let ic = ic_of_string (resp1 ^ resp2) in
     read_response_ok ic >>= fun r1 ->
     (* Drain without reading: must consume body + trailer block. *)
     Httpg.Body.drain r1.Httpg.Response.body >>= fun _ ->
     read_response_ok ic >|= fun r2 ->
     Alcotest.(check int) "resp2 code" 204 r2.Httpg.Response.status_code)

let tests =
  [
    ("first_chunk_before_eof", `Quick, first_chunk_before_eof);
    ("read_all_full_payload", `Quick, read_all_full_payload);
    ("trailer_after_drain", `Quick, trailer_after_drain);
    ("trailer_undeclared_after_drain", `Quick, trailer_undeclared_after_drain);
    ("keep_alive_two_responses", `Quick, keep_alive_two_responses);
    ("keep_alive_chunked_then_next", `Quick, keep_alive_chunked_then_next);
  ]
