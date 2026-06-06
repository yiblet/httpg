open Httpg

let check_method name expected actual () =
  Alcotest.(check string) name expected actual

(* Ported from go/src/net/http/method.go constant values. *)
let tests =
  [
    ("get", `Quick, check_method "get" "GET" Method.get);
    ("head", `Quick, check_method "head" "HEAD" Method.head);
    ("post", `Quick, check_method "post" "POST" Method.post);
    ("put", `Quick, check_method "put" "PUT" Method.put);
    ("patch", `Quick, check_method "patch" "PATCH" Method.patch);
    ("delete", `Quick, check_method "delete" "DELETE" Method.delete);
    ("connect", `Quick, check_method "connect" "CONNECT" Method.connect);
    ("options", `Quick, check_method "options" "OPTIONS" Method.options);
    ("trace", `Quick, check_method "trace" "TRACE" Method.trace);
  ]
