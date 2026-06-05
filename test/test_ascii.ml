(* Port of go/src/net/http/internal/ascii/print_test.go. *)

module Ascii = Gohttp_internal.Ascii

let test_equal_fold () =
  let cases =
    [
      (* name, a, b, want *)
      ("empty", "", "", true);
      ("simple match", "CHUNKED", "chunked", true);
      ("same string", "chunked", "chunked", true);
      (* This "K" is 'KELVIN SIGN' (K), so EqualFold must be false. *)
      ("Unicode Kelvin symbol", "chun\xe2\x84\xaaed", "chunked", false);
    ]
  in
  List.iter
    (fun (name, a, b, want) ->
      Alcotest.(check bool) name want (Ascii.equal_fold a b))
    cases

let test_is_print () =
  let cases =
    [
      ("empty", "", true);
      ("ASCII low", "This is a space: ' '", true);
      ("ASCII high", "This is a tilde: '~'", true);
      ("ASCII low non-print", "This is a unit separator: \x1f", false);
      ("ASCII high non-print", "This is a Delete: \x7f", false);
      (* Kelvin sign U+212A. *)
      ( "Unicode letter",
        "Today it's 280\xe2\x84\xaa outside: it's freezing!",
        false );
      (* Cheese emoji U+1F9C0. *)
      ("Unicode emoji", "Gophers like \xf0\x9f\xa7\x80", false);
    ]
  in
  List.iter
    (fun (name, s, want) -> Alcotest.(check bool) name want (Ascii.is_print s))
    cases

let test_is () =
  Alcotest.(check bool) "ascii" true (Ascii.is "chunked");
  Alcotest.(check bool) "empty" true (Ascii.is "");
  Alcotest.(check bool) "high byte" false (Ascii.is "ch\xe2\x84\xaaed")

let test_to_lower () =
  let lower, ok = Ascii.to_lower "CHUNKED" in
  Alcotest.(check bool) "ascii ok" true ok;
  Alcotest.(check string) "ascii lower" "chunked" lower;
  let _, ok = Ascii.to_lower "ch\xe2\x84\xaaed" in
  Alcotest.(check bool) "non-ascii not ok" false ok;
  let _, ok = Ascii.to_lower "ctl\x1f" in
  Alcotest.(check bool) "non-print not ok" false ok

let tests =
  [
    ("EqualFold", `Quick, test_equal_fold);
    ("IsPrint", `Quick, test_is_print);
    ("Is", `Quick, test_is);
    ("ToLower", `Quick, test_to_lower);
  ]
