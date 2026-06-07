module Method = Httpg_base.Method

(* Ported from go/src/net/http/method.go constant values: each canonical method
   round-trips through to_string / of_string. *)
let check name expected m () =
  Alcotest.(check string) (name ^ ": to_string") expected (Method.to_string m);
  Alcotest.(check bool)
    (name ^ ": of_string") true
    (Method.of_string expected = m)

let tests =
  [
    ("get", `Quick, check "get" "GET" Method.Get);
    ("head", `Quick, check "head" "HEAD" Method.Head);
    ("post", `Quick, check "post" "POST" Method.Post);
    ("put", `Quick, check "put" "PUT" Method.Put);
    ("patch", `Quick, check "patch" "PATCH" Method.Patch);
    ("delete", `Quick, check "delete" "DELETE" Method.Delete);
    ("connect", `Quick, check "connect" "CONNECT" Method.Connect);
    ("options", `Quick, check "options" "OPTIONS" Method.Options);
    ("trace", `Quick, check "trace" "TRACE" Method.Trace);
    (* Aliases resolve to the variant constructors. *)
    ( "aliases",
      `Quick,
      fun () ->
        Alcotest.(check bool) "get" true (Method.get = Method.Get);
        Alcotest.(check bool) "post" true (Method.post = Method.Post) );
    (* Non-canonical and empty tokens become Custom, preserved verbatim. *)
    ( "custom",
      `Quick,
      fun () ->
        Alcotest.(check bool)
          "propfind" true
          (Method.of_string "PROPFIND" = Method.Custom "PROPFIND");
        Alcotest.(check bool)
          "lowercase" true
          (Method.of_string "get" = Method.Custom "get");
        Alcotest.(check bool)
          "empty" true
          (Method.of_string "" = Method.Custom "");
        Alcotest.(check string)
          "custom to_string" "PROPFIND"
          (Method.to_string (Method.Custom "PROPFIND")) );
  ]
