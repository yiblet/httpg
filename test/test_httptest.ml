open Httpg
module R = Httptest.Response_recorder

(* Run a handler (response_writer -> unit) against a fresh recorder and return
   it, mirroring recorder_test.go's `h.ServeHTTP(rec, r)`. *)
let run (h : Server.response_writer -> unit) : R.t =
  let rec_ = R.create () in
  let w = R.to_response_writer rec_ in
  h w;
  rec_

let body_of_result (rec_ : R.t) : string = Body.read_all (R.result rec_).body

(* "recorder_basic" — the Success Criterion: set a header, WriteHeader(201),
   write a body; result has code 201, the header and the body. *)
let recorder_basic () =
  let rec_ =
    run (fun w ->
        Header.set (w.header ()) "X-Custom" "yes";
        w.write_header Httpg_base.Status.Created;
        w.write "hello body")
  in
  let res = R.result rec_ in
  Alcotest.(check int)
    "result.status_code" 201
    (Httpg_base.Status.to_int res.status_code);
  Alcotest.(check string) "result.status" "201 Created" res.status;
  Alcotest.(check string)
    "result header X-Custom" "yes"
    (Header.get res.header "X-Custom");
  Alcotest.(check string) "body via result" "hello body" (body_of_result rec_)

(* "200 default" — no writes at all -> Code stays 200, empty body. *)
let default_200 () =
  let rec_ = run (fun _w -> ()) in
  Alcotest.(check int) "code" 200 (R.code rec_);
  Alcotest.(check string) "body" "" (R.body_string rec_);
  Alcotest.(check int)
    "result status_code" 200
    (Httpg_base.Status.to_int (R.result rec_).status_code)

(* "first code only" — first WriteHeader wins. *)
let first_code_only () =
  let rec_ =
    run (fun w ->
        w.write_header Httpg_base.Status.Created;
        w.write_header Httpg_base.Status.Accepted;
        w.write "hi")
  in
  Alcotest.(check int) "code" 201 (R.code rec_);
  Alcotest.(check string) "body" "hi" (R.body_string rec_)

(* "write sends 200" — first Write implicitly WriteHeader(200). *)
let implicit_write_header () =
  let rec_ =
    run (fun w ->
        w.write "hi first";
        w.write_header Httpg_base.Status.Created;
        w.write_header Httpg_base.Status.Accepted)
  in
  Alcotest.(check int) "code" 200 (R.code rec_);
  Alcotest.(check string) "body" "hi first" (R.body_string rec_);
  Alcotest.(check bool) "flushed false" false rec_.flushed

(* "write string" — write equivalence + Content-Type sniff. *)
let write_string () =
  let rec_ = run (fun w -> w.write "hi first") in
  Alcotest.(check int) "code" 200 (R.code rec_);
  Alcotest.(check string) "body" "hi first" (R.body_string rec_);
  Alcotest.(check bool) "flushed false" false rec_.flushed;
  Alcotest.(check string)
    "Content-Type sniffed" "text/plain; charset=utf-8"
    (Header.get (R.result rec_).header "Content-Type")

(* "flush" — Flush() sends a 200 and sets flushed; result has no auto
   Content-Length (-1). *)
let flush_sets_flushed () =
  let rec_ =
    run (fun w ->
        w.flush ();
        w.write_header Httpg_base.Status.Created)
  in
  Alcotest.(check int) "code" 200 (R.code rec_);
  Alcotest.(check bool) "flushed true" true rec_.flushed;
  Alcotest.(check int64)
    "content_length -1" (-1L) (R.result rec_).content_length

(* "Content-Type detection" — html body sniffs to text/html. *)
let content_type_html () =
  let rec_ = run (fun w -> w.write "<html>") in
  Alcotest.(check string)
    "Content-Type" "text/html; charset=utf-8"
    (Header.get (R.result rec_).header "Content-Type")

(* "no Content-Type detection if set explicitly". *)
let content_type_explicit () =
  let rec_ =
    run (fun w ->
        Header.set (w.header ()) "Content-Type" "some/type";
        w.write "<html>")
  in
  Alcotest.(check string)
    "Content-Type" "some/type"
    (Header.get (R.result rec_).header "Content-Type")

(* "Header is not changed after write" — snapshot at first commit. *)
let header_snapshot () =
  let rec_ =
    run (fun w ->
        let h = w.header () in
        Header.set h "Key" "correct";
        w.write_header Httpg_base.Status.Ok;
        Header.set h "Key" "incorrect")
  in
  Alcotest.(check string)
    "snapshot Key" "correct"
    (Header.get (R.result rec_).header "Key")

(* "setting Content-Length header" — Content-Length parsed into result. *)
let content_length_header () =
  let rec_ =
    run (fun w ->
        let body = "Some body" in
        Header.set (w.header ()) "Content-Length"
          (string_of_int (String.length body));
        w.write body)
  in
  Alcotest.(check int) "code" 200 (R.code rec_);
  Alcotest.(check string) "body" "Some body" (R.body_string rec_);
  Alcotest.(check int64) "content_length 9" 9L (R.result rec_).content_length

let tests =
  [
    ("recorder_basic", `Quick, recorder_basic);
    ("default 200", `Quick, default_200);
    ("first code only", `Quick, first_code_only);
    ("implicit WriteHeader on first write", `Quick, implicit_write_header);
    ("write string", `Quick, write_string);
    ("flush sets flushed", `Quick, flush_sets_flushed);
    ("Content-Type detection html", `Quick, content_type_html);
    ("Content-Type explicit not overridden", `Quick, content_type_explicit);
    ("header snapshot at first commit", `Quick, header_snapshot);
    ("Content-Length header parsed", `Quick, content_length_header);
  ]
