(* Ported assertions for go/src/net/url ParseQuery error cases, exercising the
   typed [Values.error] surface. *)

open Gohttp

(* A semicolon separator is rejected (Go's ParseQuery error). *)
let test_parse_query_typed () =
  (match Values.parse_query "a;b=c" with
  | _, Ok () -> Alcotest.fail "\"a;b=c\": expected Error, got Ok"
  | _, Error Values.Invalid_semicolon_separator -> ()
  | _, Error e ->
      Alcotest.failf "\"a;b=c\": got %s, wrong arm" (Values.error_to_string e));
  (* A well-formed query parses cleanly. *)
  let m, res = Values.parse_query "a=1&b=2" in
  (match res with
  | Ok () -> ()
  | Error e -> Alcotest.failf "valid query returned Error %s" (Values.error_to_string e));
  Alcotest.(check string) "a" "1" (Values.get m "a");
  Alcotest.(check string) "b" "2" (Values.get m "b")

let tests = [ ("parse_query_typed", `Quick, test_parse_query_typed) ]
