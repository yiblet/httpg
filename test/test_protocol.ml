module Protocol = Httpg_base.Protocol

(* to_string / of_string round-trip for the named versions, plus major/minor. *)
let check name str p () =
  Alcotest.(check string) (name ^ ": to_string") str (Protocol.to_string p);
  Alcotest.(check bool)
    (name ^ ": of_string") true
    (Protocol.of_string str = Some p)

let tests =
  [
    ("http10", `Quick, check "http10" "HTTP/1.0" Protocol.Http10);
    ("http11", `Quick, check "http11" "HTTP/1.1" Protocol.Http11);
    ("http20", `Quick, check "http20" "HTTP/2.0" Protocol.Http20);
    (* of_string normalizes the named versions; Other only holds non-standard. *)
    ( "normalize",
      `Quick,
      fun () ->
        Alcotest.(check bool)
          "1.0" true
          (Protocol.of_string "HTTP/1.0" = Some Http10);
        Alcotest.(check bool)
          "2.0" true
          (Protocol.of_string "HTTP/2.0" = Some Http20);
        Alcotest.(check bool)
          "0.9 -> Other" true
          (Protocol.of_string "HTTP/0.9" = Some (Other (0, 9)));
        Alcotest.(check string)
          "Other to_string" "HTTP/3.5"
          (Protocol.to_string (Other (3, 5))) );
    (* Malformed versions (ParseHTTPVersion failure cases). *)
    ( "malformed",
      `Quick,
      fun () ->
        Alcotest.(check bool) "no prefix" true (Protocol.of_string "1.1" = None);
        Alcotest.(check bool)
          "bad len" true
          (Protocol.of_string "HTTP/1.10" = None);
        Alcotest.(check bool)
          "non-digit" true
          (Protocol.of_string "HTTP/x.1" = None);
        Alcotest.(check bool) "empty" true (Protocol.of_string "" = None) );
    (* major / minor accessors. *)
    ( "major_minor",
      `Quick,
      fun () ->
        Alcotest.(check int) "1.1 major" 1 (Protocol.major Http11);
        Alcotest.(check int) "1.1 minor" 1 (Protocol.minor Http11);
        Alcotest.(check int) "2.0 major" 2 (Protocol.major Http20);
        Alcotest.(check int) "other major" 3 (Protocol.major (Other (3, 5)));
        Alcotest.(check int) "other minor" 5 (Protocol.minor (Other (3, 5))) );
    (* at_least (ProtoAtLeast). *)
    ( "at_least",
      `Quick,
      fun () ->
        Alcotest.(check bool) "1.1 >= 1.1" true (Protocol.at_least Http11 1 1);
        Alcotest.(check bool) "1.0 >= 1.1" false (Protocol.at_least Http10 1 1);
        Alcotest.(check bool) "1.0 >= 1.0" true (Protocol.at_least Http10 1 0);
        Alcotest.(check bool) "2.0 >= 1.1" true (Protocol.at_least Http20 1 1)
    );
  ]
