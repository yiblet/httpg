(* Ported assertions for go/src/net/url ParseQuery error cases, exercising the
   typed [Form.error] surface. *)

open Httpg

(* A semicolon separator is rejected (Go's ParseQuery error). *)
let test_parse_query_typed () =
  (match Form.parse_query "a;b=c" with
  | _, None -> Alcotest.fail "\"a;b=c\": expected Some error, got None"
  | _, Some Form.Invalid_semicolon_separator -> ()
  | _, Some e ->
      Alcotest.failf "\"a;b=c\": got %s, wrong arm" (Form.error_to_string e));
  (* A well-formed query parses cleanly. *)
  let m, res = Form.parse_query "a=1&b=2" in
  (match res with
  | None -> ()
  | Some e ->
      Alcotest.failf "valid query returned Some %s" (Form.error_to_string e));
  Alcotest.(check string) "a" "1" (Form.get m "a");
  Alcotest.(check string) "b" "2" (Form.get m "b")

let tests = [ ("parse_query_typed", `Quick, test_parse_query_typed) ]
