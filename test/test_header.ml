open Gohttp

(* Ported from go/src/net/http/header_test.go and the canonicalization behavior
   of textproto.CanonicalMIMEHeaderKey. *)

let canon name input expected () =
  Alcotest.(check string) name expected (Header.canonical_header_key input)

(* Build a header from a list of (key, values). Keys are inserted via direct
   set-style semantics on canonical keys; to faithfully reproduce the Go test
   tables (which assign canonical keys directly to the map), we use a helper that
   appends each value via Add on the raw key. The Go tables already use canonical
   keys, so Add canonicalizes them to themselves. *)
(* Mirror Go's test tables, which assign keys *directly* to the map
   (map[string][]string{...}) and thus bypass canonicalization. We build the
   header by raw-inserting each (key, values) entry. This is required to
   faithfully reproduce rows that use non-canonical raw keys (e.g. "k1",
   "NewlineInKey\r\n"). *)
let make pairs = Header.of_list pairs

let write_test name pairs exclude expected =
  let run () =
    let h = make pairs in
    let buf = Buffer.create 256 in
    Header.write_subset h buf ~exclude;
    Alcotest.(check string) name expected (Buffer.contents buf)
  in
  (name, `Quick, run)

(* headerWriteTests rows that map cleanly onto our API. Rows that rely on
   defining a key with a 0-length / nil value slice (Go's "Nil"/"Empty") simply
   contribute no output lines, identical to omitting them, so they are folded in
   below where relevant. *)
let write_tests =
  [
    write_test "empty header" [] [] "";
    write_test "two keys sorted"
      [
        ("Content-Type", [ "text/html; charset=UTF-8" ]);
        ("Content-Length", [ "0" ]);
      ]
      [] "Content-Length: 0\r\nContent-Type: text/html; charset=UTF-8\r\n";
    write_test "multi-value"
      [ ("Content-Length", [ "0"; "1"; "2" ]) ]
      [] "Content-Length: 0\r\nContent-Length: 1\r\nContent-Length: 2\r\n";
    write_test "exclude one key"
      [
        ("Expires", [ "-1" ]);
        ("Content-Length", [ "0" ]);
        ("Content-Encoding", [ "gzip" ]);
      ]
      [ "Content-Length" ] "Content-Encoding: gzip\r\nExpires: -1\r\n";
    write_test "exclude multi-value key"
      [
        ("Expires", [ "-1" ]);
        ("Content-Length", [ "0"; "1"; "2" ]);
        ("Content-Encoding", [ "gzip" ]);
      ]
      [ "Content-Length" ] "Content-Encoding: gzip\r\nExpires: -1\r\n";
    write_test "exclude all keys"
      [
        ("Expires", [ "-1" ]);
        ("Content-Length", [ "0" ]);
        ("Content-Encoding", [ "gzip" ]);
      ]
      [ "Content-Length"; "Expires"; "Content-Encoding" ]
      "";
    write_test "blank values"
      [ ("Blank", [ "" ]); ("Double-Blank", [ ""; "" ]) ]
      [] "Blank: \r\nDouble-Blank: \r\nDouble-Blank: \r\n";
    write_test "sort over insertion threshold"
      [
        ("k1", [ "1a"; "1b" ]);
        ("k2", [ "2a"; "2b" ]);
        ("k3", [ "3a"; "3b" ]);
        ("k4", [ "4a"; "4b" ]);
        ("k5", [ "5a"; "5b" ]);
        ("k6", [ "6a"; "6b" ]);
        ("k7", [ "7a"; "7b" ]);
        ("k8", [ "8a"; "8b" ]);
        ("k9", [ "9a"; "9b" ]);
      ]
      [ "k5" ]
      ("k1: 1a\r\nk1: 1b\r\nk2: 2a\r\nk2: 2b\r\nk3: 3a\r\nk3: 3b\r\n"
     ^ "k4: 4a\r\nk4: 4b\r\nk6: 6a\r\nk6: 6b\r\n"
     ^ "k7: 7a\r\nk7: 7b\r\nk8: 8a\r\nk8: 8b\r\nk9: 9a\r\nk9: 9b\r\n");
    (* Invalid characters in headers: keys with newlines/colons are not valid
       header field names and are dropped; newline-in-value is replaced with
       spaces. We add the keys with their raw (non-canonical) text. *)
    write_test "invalid characters in headers"
      [
        ("Content-Type", [ "text/html; charset=UTF-8" ]);
        ("NewlineInValue", [ "1\r\nBar: 2" ]);
        ("NewlineInKey\r\n", [ "1" ]);
        ("Colon:InKey", [ "1" ]);
        ("Evil: 1\r\nSmuggledValue", [ "1" ]);
      ]
      []
      ("Content-Type: text/html; charset=UTF-8\r\n"
     ^ "NewlineInValue: 1  Bar: 2\r\n");
  ]

let canon_tests =
  [
    ( "canonical uSER-aGeNT",
      `Quick,
      canon "user-agent" "uSER-aGeNT" "User-Agent" );
    ( "canonical accept-encoding",
      `Quick,
      canon "accept-encoding" "accept-encoding" "Accept-Encoding" );
    ("canonical host", `Quick, canon "host" "host" "Host");
    ( "canonical if-modified-since",
      `Quick,
      canon "ifmod" "if-modified-since" "If-Modified-Since" );
    ( "already canonical unchanged",
      `Quick,
      canon "user-agent canonical" "User-Agent" "User-Agent" );
    (* Invalid bytes => returned unchanged. *)
    ("invalid space unchanged", `Quick, canon "space" "Foo Bar" "Foo Bar");
    ("invalid colon unchanged", `Quick, canon "colon" "Foo:Bar" "Foo:Bar");
    ("empty unchanged", `Quick, canon "empty" "" "");
  ]

let get_set_add_del () =
  let h = Header.create () in
  Alcotest.(check string) "missing -> empty" "" (Header.get h "Foo");
  Header.set h "foo" "bar";
  Alcotest.(check string) "get canonicalizes" "bar" (Header.get h "FOO");
  Header.set h "Foo" "baz";
  Alcotest.(check string) "set replaces" "baz" (Header.get h "foo");
  Header.add h "foo" "qux";
  Alcotest.(check (list string))
    "add appends" [ "baz"; "qux" ] (Header.values h "Foo");
  Header.del h "FOO";
  Alcotest.(check (list string)) "del removes" [] (Header.values h "foo");
  Alcotest.(check bool) "has after del" false (Header.has h "foo")

let values_and_first () =
  let h = Header.create () in
  Header.add h "X-Multi" "a";
  Header.add h "X-Multi" "b";
  Header.add h "X-Multi" "c";
  Alcotest.(check (list string))
    "values returns all" [ "a"; "b"; "c" ]
    (Header.values h "x-multi");
  Alcotest.(check string) "get returns first" "a" (Header.get h "x-multi")

let clone_independent () =
  let h = Header.create () in
  Header.set h "A" "1";
  let h2 = Header.clone h in
  Header.set h2 "A" "2";
  Header.add h2 "B" "3";
  Alcotest.(check string) "original unchanged value" "1" (Header.get h "A");
  Alcotest.(check bool) "original has no B" false (Header.has h "B");
  Alcotest.(check string) "clone has new value" "2" (Header.get h2 "A");
  Alcotest.(check string) "clone has B" "3" (Header.get h2 "B")

let semantics_tests =
  [
    ("get/set/add/del", `Quick, get_set_add_del);
    ("values + first", `Quick, values_and_first);
    ("clone is independent", `Quick, clone_independent);
  ]

let tests = canon_tests @ write_tests @ semantics_tests
