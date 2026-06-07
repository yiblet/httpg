module Status = Httpg_base.Status

let check_text name code expected () =
  let s =
    match Status.of_int_result code with
    | Ok s -> s
    | Error _ -> Alcotest.failf "of_int_result rejected %d" code
  in
  Alcotest.(check string) name expected (Status.to_string s)

(* Ported from go/src/net/http/status.go StatusText. Codes with no dedicated
   variant ([of_int_result] -> [Custom]) carry the reason phrase "Custom". *)
let tests =
  [
    ("200 -> OK", `Quick, check_text "200" 200 "OK");
    ("404 -> Not Found", `Quick, check_text "404" 404 "Not Found");
    ("418 -> I'm a teapot", `Quick, check_text "418" 418 "I'm a teapot");
    ("100 -> Continue", `Quick, check_text "100" 100 "Continue");
    ( "500 -> Internal Server Error",
      `Quick,
      check_text "500" 500 "Internal Server Error" );
    ("unknown 999 -> Custom", `Quick, check_text "999" 999 "Custom");
    ("unused 306 -> Custom", `Quick, check_text "306" 306 "Custom");
  ]
