(* Ported from go/src/net/http/pattern_test.go. *)

module Pattern = Httpg_internal.Pattern

let lit name = { Pattern.s = name; wild = false; multi = false }
let wild name = { Pattern.s = name; wild = true; multi = false }
let multi name = { Pattern.s = name; wild = true; multi = true }

let must_parse s =
  match Pattern.parse s with
  | Ok p -> p
  | Error e ->
      Alcotest.failf "parse %S failed: %s" s (Pattern.error_to_string e)

(* equal: same as Go's pattern.equal — method, host, segments. *)
let pat_equal (p1 : Pattern.t) (p2 : Pattern.t) =
  p1.method_ = p2.method_ && p1.host = p2.host && p1.segments = p2.segments

let segs_str segs =
  String.concat ";"
    (List.map
       (fun s -> Printf.sprintf "{%S w=%b m=%b}" s.Pattern.s s.wild s.multi)
       segs)

(* TestParsePattern. *)
let test_parse_pattern () =
  let cases =
    [
      ( "/",
        { Pattern.str = ""; method_ = ""; host = ""; segments = [ multi "" ] }
      );
      ( "/a",
        { Pattern.str = ""; method_ = ""; host = ""; segments = [ lit "a" ] } );
      ( "/a/",
        {
          Pattern.str = "";
          method_ = "";
          host = "";
          segments = [ lit "a"; multi "" ];
        } );
      ( "/path/to/something",
        {
          Pattern.str = "";
          method_ = "";
          host = "";
          segments = [ lit "path"; lit "to"; lit "something" ];
        } );
      ( "/{w1}/lit/{w2}",
        {
          Pattern.str = "";
          method_ = "";
          host = "";
          segments = [ wild "w1"; lit "lit"; wild "w2" ];
        } );
      ( "/{w1}/lit/{w2}/",
        {
          Pattern.str = "";
          method_ = "";
          host = "";
          segments = [ wild "w1"; lit "lit"; wild "w2"; multi "" ];
        } );
      ( "example.com/",
        {
          Pattern.str = "";
          method_ = "";
          host = "example.com";
          segments = [ multi "" ];
        } );
      ( "GET /",
        {
          Pattern.str = "";
          method_ = "GET";
          host = "";
          segments = [ multi "" ];
        } );
      ( "POST example.com/foo/{w}",
        {
          Pattern.str = "";
          method_ = "POST";
          host = "example.com";
          segments = [ lit "foo"; wild "w" ];
        } );
      ( "/{$}",
        { Pattern.str = ""; method_ = ""; host = ""; segments = [ lit "/" ] } );
      ( "DELETE example.com/a/{foo12}/{$}",
        {
          Pattern.str = "";
          method_ = "DELETE";
          host = "example.com";
          segments = [ lit "a"; wild "foo12"; lit "/" ];
        } );
      ( "/foo/{$}",
        {
          Pattern.str = "";
          method_ = "";
          host = "";
          segments = [ lit "foo"; lit "/" ];
        } );
      ( "/{a}/foo/{rest...}",
        {
          Pattern.str = "";
          method_ = "";
          host = "";
          segments = [ wild "a"; lit "foo"; multi "rest" ];
        } );
      ( "//",
        {
          Pattern.str = "";
          method_ = "";
          host = "";
          segments = [ lit ""; multi "" ];
        } );
      ( "/foo///./../bar",
        {
          Pattern.str = "";
          method_ = "";
          host = "";
          segments = [ lit "foo"; lit ""; lit ""; lit "."; lit ".."; lit "bar" ];
        } );
      ( "a.com/foo//",
        {
          Pattern.str = "";
          method_ = "";
          host = "a.com";
          segments = [ lit "foo"; lit ""; multi "" ];
        } );
      ( "/%61%62/%7b/%",
        {
          Pattern.str = "";
          method_ = "";
          host = "";
          segments = [ lit "ab"; lit "{"; lit "%" ];
        } );
      ( "GET\t  /",
        {
          Pattern.str = "";
          method_ = "GET";
          host = "";
          segments = [ multi "" ];
        } );
      ( "POST \t  example.com/foo/{w}",
        {
          Pattern.str = "";
          method_ = "POST";
          host = "example.com";
          segments = [ lit "foo"; wild "w" ];
        } );
      ( "DELETE    \texample.com/a/{foo12}/{$}",
        {
          Pattern.str = "";
          method_ = "DELETE";
          host = "example.com";
          segments = [ lit "a"; wild "foo12"; lit "/" ];
        } );
    ]
  in
  List.iter
    (fun (in_, want) ->
      let got = must_parse in_ in
      if not (pat_equal got want) then
        Alcotest.failf
          "%S:\n\
          \ got  method=%S host=%S segs=%s\n\
          \ want method=%S host=%S segs=%s"
          in_ got.method_ got.host (segs_str got.segments) want.Pattern.method_
          want.host (segs_str want.segments))
    cases

(* TestParsePatternError. *)
let test_parse_pattern_error () =
  let cases =
    [
      ("", "empty pattern");
      ("A=B /", "at offset 0: invalid method");
      (" ", "at offset 1: host/path missing /");
      ("/{w}x", "at offset 1: bad wildcard segment");
      ("/x{w}", "at offset 1: bad wildcard segment");
      ("/{wx", "at offset 1: bad wildcard segment");
      ("/a/{/}/c", "at offset 3: bad wildcard segment");
      ("/a/{%61}/c", "at offset 3: bad wildcard name");
      ("/{a$}", "at offset 1: bad wildcard name");
      ("/{}", "at offset 1: empty wildcard");
      ("POST a.com/x/{}/y", "at offset 13: empty wildcard");
      ("/{...}", "at offset 1: empty wildcard");
      ("/{$...}", "at offset 1: bad wildcard");
      ("/{$}/", "at offset 1: {$} not at end");
      ("/{$}/x", "at offset 1: {$} not at end");
      ("/abc/{$}/x", "at offset 5: {$} not at end");
      ("/{a...}/", "at offset 1: {...} wildcard not at end");
      ("/{a...}/x", "at offset 1: {...} wildcard not at end");
      ("{a}/b", "at offset 0: host contains '{' (missing initial '/'?)");
      ("/a/{x}/b/{x...}", "at offset 9: duplicate wildcard name");
      ("GET //", "at offset 4: non-CONNECT pattern with unclean path");
    ]
  in
  let contains haystack needle =
    let nl = String.length needle and hl = String.length haystack in
    let rec loop i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else loop (i + 1)
    in
    loop 0
  in
  List.iter
    (fun (in_, want) ->
      match Pattern.parse in_ with
      | Ok _ ->
          Alcotest.failf "%S: expected error containing %S, got Ok" in_ want
      | Error e ->
          let e = Pattern.error_to_string e in
          if not (contains e want) then
            Alcotest.failf "%S: got error %S, want containing %S" in_ e want)
    cases

(* Representative bad patterns map to the right typed [Pattern.error] arm; a
   valid pattern parses to [Ok]. *)
let test_parse_errors_typed () =
  let check name in_ pred =
    match Pattern.parse in_ with
    | Ok _ -> Alcotest.failf "%s: %S parsed Ok, expected Error" name in_
    | Error e ->
        if not (pred e) then
          Alcotest.failf "%s: %S got %s, wrong arm" name in_
            (Pattern.error_to_string e)
  in
  check "empty" "" (function Pattern.Empty_pattern -> true | _ -> false);
  check "method" "A=B /" (function
    | Pattern.Invalid_method _ -> true
    | _ -> false);
  check "missing_path" " " (function
    | Pattern.Missing_path _ -> true
    | _ -> false);
  check "host_brace" "{a}/b" (function
    | Pattern.Host_has_brace _ -> true
    | _ -> false);
  check "unclean" "GET //" (function
    | Pattern.Unclean_path _ -> true
    | _ -> false);
  check "bad_wildcard" "/x{w}" (function
    | Pattern.Bad_wildcard _ -> true
    | _ -> false);
  check "empty_wildcard" "/{}" (function
    | Pattern.Bad_wildcard _ -> true
    | _ -> false);
  check "dup_wildcard" "/a/{x}/b/{x...}" (function
    | Pattern.Duplicate_wildcard (_, "x") -> true
    | _ -> false);
  match Pattern.parse "GET /a/{id}" with
  | Ok _ -> ()
  | Error e ->
      Alcotest.failf "valid pattern returned Error %s"
        (Pattern.error_to_string e)

let rel_testable =
  Alcotest.testable
    (fun fmt r -> Format.pp_print_string fmt (Pattern.relationship_to_string r))
    ( = )

(* TestCompareMethods (with commutative inverse check). *)
let test_compare_methods () =
  let cases =
    [
      ("/", "/", Pattern.Equivalent);
      ("GET /", "GET /", Pattern.Equivalent);
      ("HEAD /", "HEAD /", Pattern.Equivalent);
      ("POST /", "POST /", Pattern.Equivalent);
      ("GET /", "POST /", Pattern.Disjoint);
      ("GET /", "/", Pattern.More_specific);
      ("HEAD /", "/", Pattern.More_specific);
      ("GET /", "HEAD /", Pattern.More_general);
    ]
  in
  List.iter
    (fun (p1s, p2s, want) ->
      let p1 = must_parse p1s and p2 = must_parse p2s in
      Alcotest.check rel_testable
        (Printf.sprintf "%s vs %s" p1s p2s)
        want
        (Pattern.compare_methods p1 p2);
      Alcotest.check rel_testable
        (Printf.sprintf "%s vs %s (inv)" p2s p1s)
        (Pattern.inverse_relationship want)
        (Pattern.compare_methods p2 p1))
    cases

(* TestComparePaths (subset of representative + edge rows, with inverse + self checks). *)
let test_compare_paths () =
  let cases =
    [
      ("/a", "/a", Pattern.Equivalent);
      ("/a", "/b", Pattern.Disjoint);
      ("/a", "/", Pattern.More_specific);
      ("/a", "/{$}", Pattern.Disjoint);
      ("/a", "/{x}", Pattern.More_specific);
      ("/a", "/{x...}", Pattern.More_specific);
      ("/{z}", "/{x}", Pattern.Equivalent);
      ("/{z}", "/", Pattern.More_specific);
      ("/", "/a", Pattern.More_general);
      ("/", "/{x...}", Pattern.Equivalent);
      ("/a/{z}/", "/{z}/a/", Pattern.Overlaps);
      ("/a/{z}/b/", "/{x}/c/{y...}", Pattern.Overlaps);
      ("/{m...}", "/", Pattern.Equivalent);
      ("/{m...}", "/{x...}", Pattern.Equivalent);
      ("/b/{m...}", "/a/{x...}", Pattern.Disjoint);
      ("/{z}/{m...}", "/{w}/", Pattern.Equivalent);
      ("/a/{z}/{m...}", "/{z}/a/", Pattern.Overlaps);
      ("/a/{z}/b/{m...}", "/{x}/c/{y...}", Pattern.Overlaps);
      ("/a/{z}/a/{m...}", "/{x}/b", Pattern.Disjoint);
      ("/{$}", "/a", Pattern.Disjoint);
      ("/{$}", "/{$}", Pattern.Equivalent);
      ("/{$}", "/", Pattern.More_specific);
      ("/{$}", "/{x...}", Pattern.More_specific);
      ("/b/{$}", "/b/c/{x...}", Pattern.Disjoint);
      ("/b/{x}/a/{$}", "/{x}/c/{y...}", Pattern.Overlaps);
      ("/{z}/{$}", "/a/", Pattern.Overlaps);
      ("/{z}/{$}", "/a/{x...}", Pattern.Overlaps);
      ("/a/{z}/{$}", "/{z}/a/", Pattern.Overlaps);
    ]
  in
  List.iter
    (fun (p1s, p2s, want) ->
      let p1 = must_parse p1s and p2 = must_parse p2s in
      Alcotest.check rel_testable
        (Printf.sprintf "%s self" p1s)
        Pattern.Equivalent
        (Pattern.compare_paths p1 p1);
      Alcotest.check rel_testable
        (Printf.sprintf "%s self" p2s)
        Pattern.Equivalent
        (Pattern.compare_paths p2 p2);
      Alcotest.check rel_testable
        (Printf.sprintf "%s vs %s" p1s p2s)
        want
        (Pattern.compare_paths p1 p2);
      Alcotest.check rel_testable
        (Printf.sprintf "%s vs %s (inv)" p2s p1s)
        (Pattern.inverse_relationship want)
        (Pattern.compare_paths p2 p1))
    cases

(* TestConflictsWith (with commutativity). *)
let test_conflicts_with () =
  let cases =
    [
      ("/a", "/a", true);
      ("/a", "/ab", false);
      ("/a/b/cd", "/a/b/cd", true);
      ("/a/b/cd", "/a/b/c", false);
      ("/a/b/c", "/a/c/c", false);
      ("/{x}", "/{y}", true);
      ("/{x}", "/a", false);
      ("/{x}/{y}", "/{x}/a", false);
      ("/{x}/{y}", "/{x}/a/b", false);
      ("/{x}", "/a/{y}", false);
      ("/{x}/{y}", "/{x}/a/", false);
      ("/{x}", "/a/{y...}", false);
      ("/{x}/a/{y}", "/{x}/a/{y...}", false);
      ("/{x}/{y}", "/{x}/a/{$}", false);
      ("/{x}/{y}/{$}", "/{x}/a/{$}", false);
      ("/a/{x}", "/{x}/b", true);
      ("/", "GET /", false);
      ("/", "GET /foo", false);
      ("GET /", "GET /foo", false);
      ("GET /", "/foo", true);
      ("GET /foo", "HEAD /", true);
    ]
  in
  List.iter
    (fun (p1s, p2s, want) ->
      let p1 = must_parse p1s and p2 = must_parse p2s in
      Alcotest.(check bool)
        (Printf.sprintf "%s cw %s" p1s p2s)
        want
        (Pattern.conflicts_with p1 p2);
      Alcotest.(check bool)
        (Printf.sprintf "%s cw %s (comm)" p2s p1s)
        want
        (Pattern.conflicts_with p2 p1))
    cases

(* TestDescribeConflict. *)
let test_describe_conflict () =
  let cases =
    [
      ("/a/{x}", "/a/{y}", "the same requests");
      ("/", "/{m...}", "the same requests");
      ("/a/{x}", "/{y}/b", "both match some paths");
      ( "/a",
        "GET /{x}",
        "matches more methods than GET /{x}, but has a more specific path \
         pattern" );
      ( "GET /a",
        "HEAD /",
        "matches more methods than HEAD /, but has a more specific path pattern"
      );
      ( "POST /",
        "/a",
        "matches fewer methods than /a, but has a more general path pattern" );
    ]
  in
  let contains haystack needle =
    let nl = String.length needle and hl = String.length haystack in
    let rec loop i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else loop (i + 1)
    in
    loop 0
  in
  List.iter
    (fun (p1s, p2s, want) ->
      let got = Pattern.describe_conflict (must_parse p1s) (must_parse p2s) in
      if not (contains got want) then
        Alcotest.failf "%s vs %s:\ngot:\n%s\nwhich does not contain %S" p1s p2s
          got want)
    cases

(* TestCommonPath. *)
let test_common_path () =
  let cases =
    [
      ("/a/{x}", "/{x}/a", "/a/a");
      ("/a/{z}/", "/{z}/a/", "/a/a/");
      ("/a/{z}/{m...}", "/{z}/a/", "/a/a/");
      ("/{z}/{$}", "/a/", "/a/");
      ("/{z}/{$}", "/a/{x...}", "/a/");
      ("/a/{z}/{$}", "/{z}/a/", "/a/a/");
      ("/a/{x}/b/{y...}", "/{x}/c/{y...}", "/a/c/b/");
      ("/a/{x}/b/", "/{x}/c/{y...}", "/a/c/b/");
      ("/a/{x}/b/{$}", "/{x}/c/{y...}", "/a/c/b/");
      ("/a/{z}/{x...}", "/{z}/b/{y...}", "/a/b/");
    ]
  in
  List.iter
    (fun (p1s, p2s, want) ->
      let p1 = must_parse p1s and p2 = must_parse p2s in
      Alcotest.check rel_testable
        (Printf.sprintf "%s overlaps %s" p1s p2s)
        Pattern.Overlaps
        (Pattern.compare_paths p1 p2);
      Alcotest.(check string)
        (Printf.sprintf "common %s %s" p1s p2s)
        want
        (Pattern.common_path p1 p2))
    cases

(* TestDifferencePath. *)
let test_difference_path () =
  let cases =
    [
      ("/a/{x}", "/{x}/a", "/a/x");
      ("/{x}/a", "/a/{x}", "/x/a");
      ("/a/{z}/", "/{z}/a/", "/a/z/");
      ("/{z}/a/", "/a/{z}/", "/z/a/");
      ("/{a}/a/", "/a/{z}/", "/ax/a/");
      ("/a/{z}/{x...}", "/{z}/b/{y...}", "/a/z/");
      ("/{z}/b/{y...}", "/a/{z}/{x...}", "/z/b/");
      ("/a/b/", "/a/b/c", "/a/b/");
      ("/a/b/{x...}", "/a/b/c", "/a/b/");
      ("/a/b/{x...}", "/a/b/c/d", "/a/b/");
      ("/a/b/{x...}", "/a/b/c/d/", "/a/b/");
      ("/a/{z}/{m...}", "/{z}/a/", "/a/z/");
      ("/{z}/a/", "/a/{z}/{m...}", "/z/a/");
      ("/{z}/{$}", "/a/", "/z/");
      ("/a/", "/{z}/{$}", "/a/x");
      ("/{z}/{$}", "/a/{x...}", "/z/");
      ("/a/{foo...}", "/{z}/{$}", "/a/foo");
      ("/a/{z}/{$}", "/{z}/a/", "/a/z/");
      ("/{z}/a/", "/a/{z}/{$}", "/z/a/x");
      ("/a/{x}/b/{y...}", "/{x}/c/{y...}", "/a/x/b/");
      ("/{x}/c/{y...}", "/a/{x}/b/{y...}", "/x/c/");
      ("/a/{c}/b/", "/{x}/c/{y...}", "/a/cx/b/");
      ("/{x}/c/{y...}", "/a/{c}/b/", "/x/c/");
      ("/a/{x}/b/{$}", "/{x}/c/{y...}", "/a/x/b/");
      ("/{x}/c/{y...}", "/a/{x}/b/{$}", "/x/c/");
    ]
  in
  List.iter
    (fun (p1s, p2s, want) ->
      let p1 = must_parse p1s and p2 = must_parse p2s in
      let rel = Pattern.compare_paths p1 p2 in
      if rel <> Pattern.Overlaps && rel <> Pattern.More_general then
        Alcotest.failf "%s vs %s are %s, need overlaps or moreGeneral" p1s p2s
          (Pattern.relationship_to_string rel);
      Alcotest.(check string)
        (Printf.sprintf "diff %s %s" p1s p2s)
        want
        (Pattern.difference_path p1 p2))
    cases

let tests =
  [
    ("parse_pattern", `Quick, test_parse_pattern);
    ("parse_pattern_error", `Quick, test_parse_pattern_error);
    ("parse_errors_typed", `Quick, test_parse_errors_typed);
    ("compare_methods", `Quick, test_compare_methods);
    ("compare_paths", `Quick, test_compare_paths);
    ("conflicts_with", `Quick, test_conflicts_with);
    ("describe_conflict", `Quick, test_describe_conflict);
    ("common_path", `Quick, test_common_path);
    ("difference_path", `Quick, test_difference_path);
  ]
