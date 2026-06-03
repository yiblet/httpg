open Gohttp

let check_text name code expected () =
  Alcotest.(check string) name expected (Status.status_text code)

(* Ported from go/src/net/http/status.go StatusText. *)
let tests =
  [
    ("200 -> OK", `Quick, check_text "200" 200 "OK");
    ("404 -> Not Found", `Quick, check_text "404" 404 "Not Found");
    ("418 -> I'm a teapot", `Quick, check_text "418" 418 "I'm a teapot");
    ("100 -> Continue", `Quick, check_text "100" 100 "Continue");
    ( "500 -> Internal Server Error",
      `Quick,
      check_text "500" 500 "Internal Server Error" );
    ("unknown 999 -> empty", `Quick, check_text "999" 999 "");
    ("unused 306 -> empty", `Quick, check_text "306" 306 "");
  ]
