(* Ported from go/src/net/http/routing_tree_test.go. Handlers are () (Go's nil). *)

module Pattern = Httpg_base.Pattern
module Routing_tree = Httpg_internal.Routing_tree

let build_tree pats =
  List.fold_left
    (fun tree p ->
      match Pattern.parse p with
      | Ok pat -> Routing_tree.add_pattern pat () tree
      | Error e -> Alcotest.failf "parse %S: %s" p (Pattern.error_to_string e))
    Routing_tree.empty pats

let get_test_tree () =
  build_tree
    [
      "/a";
      "/a/b";
      "/a/{x}";
      "/g/h/i";
      "/g/{x}/j";
      "/a/b/{x...}";
      "/a/b/{y}";
      "/a/b/{$}";
    ]

(* TestRoutingFirstSegment. *)
let test_first_segment () =
  let cases =
    [
      ("/a/b/c", [ "a"; "b"; "c" ]);
      ("/a/b/", [ "a"; "b"; "/" ]);
      ("/", [ "/" ]);
      ("/a/%62/c", [ "a"; "b"; "c" ]);
      ("/a%2Fb%2fc", [ "a/b/c" ]);
    ]
  in
  List.iter
    (fun (in_, want) ->
      let got = ref [] in
      let rest = ref in_ in
      while String.length !rest > 0 do
        let seg, r = Routing_tree.Private.first_segment !rest in
        got := !got @ [ seg ];
        rest := r
      done;
      Alcotest.(check (list string))
        (Printf.sprintf "firstSegment %s" in_)
        want !got)
    cases

(* TestRoutingAddPattern: tree structure rendering. *)
let test_add_pattern () =
  let want =
    "\"\":\n\
    \    \"\":\n\
    \        \"a\":\n\
    \            \"/a\"\n\
    \            \"\":\n\
    \                \"/a/{x}\"\n\
    \            \"b\":\n\
    \                \"/a/b\"\n\
    \                \"\":\n\
    \                    \"/a/b/{y}\"\n\
    \                \"/\":\n\
    \                    \"/a/b/{$}\"\n\
    \                MULTI:\n\
    \                    \"/a/b/{x...}\"\n\
    \        \"g\":\n\
    \            \"\":\n\
    \                \"j\":\n\
    \                    \"/g/{x}/j\"\n\
    \            \"h\":\n\
    \                \"i\":\n\
    \                    \"/g/h/i\"\n"
  in
  let b = Buffer.create 256 in
  Routing_tree.Private.print (get_test_tree ()) b;
  Alcotest.(check string) "tree structure" want (Buffer.contents b)

(* TestRoutingNodeMatch. *)
let run_match_cases name tree cases =
  List.iter
    (fun (method_, host, path, want_pat, want_matches) ->
      let got_pat, got_matches =
        match
          Routing_tree.match_ tree ~host
            ~method_:(Httpg_base.Method.of_string method_)
            ~path
        with
        | None -> ("", None)
        | Some ((p, ()), m) -> (Pattern.to_string p, Some m)
      in
      Alcotest.(check string)
        (Printf.sprintf "%s: %s %s %s pat" name host method_ path)
        want_pat got_pat;
      (* want_matches: None means Go's nil; Some [] means empty non-nil slice.
         For the pattern we compare the list when there is a match. *)
      match (want_matches, got_matches) with
      | None, _ -> (
          (* expecting nil matches (or no match). got should be [] or n/a. *)
          match got_matches with
          | None -> ()
          | Some m ->
              Alcotest.(check (list string))
                (Printf.sprintf "%s: %s %s %s matches" name host method_ path)
                [] m)
      | Some wm, Some gm ->
          Alcotest.(check (list string))
            (Printf.sprintf "%s: %s %s %s matches" name host method_ path)
            wm gm
      | Some wm, None ->
          Alcotest.(check (list string))
            (Printf.sprintf "%s: %s %s %s matches (no match)" name host method_
               path)
            wm [])
    cases

let test_node_match () =
  run_match_cases "tree1" (get_test_tree ())
    [
      ("GET", "", "/a", "/a", None);
      ("Get", "", "/b", "", None);
      ("Get", "", "/a/b", "/a/b", None);
      ("Get", "", "/a/c", "/a/{x}", Some [ "c" ]);
      ("Get", "", "/a/b/", "/a/b/{$}", None);
      ("Get", "", "/a/b/c", "/a/b/{y}", Some [ "c" ]);
      ("Get", "", "/a/b/c/d", "/a/b/{x...}", Some [ "c/d" ]);
      ("Get", "", "/g/h/i", "/g/h/i", None);
      ("Get", "", "/g/h/j", "/g/{x}/j", Some [ "h" ]);
    ];
  let tree =
    build_tree
      [
        "/item/";
        "POST /item/{user}";
        "GET /item/{user}";
        "/item/{user}";
        "/item/{user}/{id}";
        "/item/{user}/new";
        "/item/{$}";
        "POST alt.com/item/{user}";
        "GET /headwins";
        "HEAD /headwins";
        "/path/{p...}";
      ]
  in
  run_match_cases "tree2" tree
    [
      ("GET", "", "/item/jba", "GET /item/{user}", Some [ "jba" ]);
      ("POST", "", "/item/jba", "POST /item/{user}", Some [ "jba" ]);
      ("HEAD", "", "/item/jba", "GET /item/{user}", Some [ "jba" ]);
      ("get", "", "/item/jba", "/item/{user}", Some [ "jba" ]);
      ("POST", "", "/item/jba/17", "/item/{user}/{id}", Some [ "jba"; "17" ]);
      ("GET", "", "/item/jba/new", "/item/{user}/new", Some [ "jba" ]);
      ("GET", "", "/item/", "/item/{$}", Some []);
      ("GET", "", "/item/jba/17/line2", "/item/", None);
      ( "POST",
        "alt.com",
        "/item/jba",
        "POST alt.com/item/{user}",
        Some [ "jba" ] );
      ("GET", "alt.com", "/item/jba", "GET /item/{user}", Some [ "jba" ]);
      ("GET", "", "/item", "", None);
      ("GET", "", "/headwins", "GET /headwins", None);
      ("HEAD", "", "/headwins", "HEAD /headwins", None);
      ("GET", "", "/path/to/file", "/path/{p...}", Some [ "to/file" ]);
      ("GET", "", "/path/*", "/path/{p...}", Some [ "*" ]);
    ];
  (* {$} only matches trailing slash. *)
  run_match_cases "pat1"
    (build_tree [ "/a/b/{$}" ])
    [
      ("GET", "", "/a/b", "", None);
      ("GET", "", "/a/b/", "/a/b/{$}", None);
      ("GET", "", "/a/b/c", "", None);
      ("GET", "", "/a/b/c/d", "", None);
    ];
  (* single wildcard does not match trailing slash. *)
  run_match_cases "pat2"
    (build_tree [ "/a/b/{w}" ])
    [
      ("GET", "", "/a/b", "", None);
      ("GET", "", "/a/b/", "", None);
      ("GET", "", "/a/b/c", "/a/b/{w}", Some [ "c" ]);
      ("GET", "", "/a/b/c/d", "", None);
    ];
  (* multi wildcard matches both. *)
  run_match_cases "pat3"
    (build_tree [ "/a/b/{w...}" ])
    [
      ("GET", "", "/a/b", "", None);
      ("GET", "", "/a/b/", "/a/b/{w...}", Some [ "" ]);
      ("GET", "", "/a/b/c", "/a/b/{w...}", Some [ "c" ]);
      ("GET", "", "/a/b/c/d", "/a/b/{w...}", Some [ "c/d" ]);
    ];
  (* all three together. *)
  run_match_cases "all"
    (build_tree [ "/a/b/{$}"; "/a/b/{w}"; "/a/b/{w...}" ])
    [
      ("GET", "", "/a/b", "", None);
      ("GET", "", "/a/b/", "/a/b/{$}", None);
      ("GET", "", "/a/b/c", "/a/b/{w}", Some [ "c" ]);
      ("GET", "", "/a/b/c/d", "/a/b/{w...}", Some [ "c/d" ]);
    ]

(* A non-standard explicit method must match itself exactly, while a method-less
   ("any method") pattern catches every other verb. This pins the distinction
   between "method PROPFIND", "method GET", and "no method" — three states that a
   single empty-string method key would conflate. *)
let test_custom_method_match () =
  let tree = build_tree [ "PROPFIND /x"; "/x"; "GET /y" ] in
  run_match_cases "custom" tree
    [
      (* Exact custom-method match wins over the method-less sibling. *)
      ("PROPFIND", "", "/x", "PROPFIND /x", None);
      (* Any other verb falls back to the method-less pattern. *)
      ("GET", "", "/x", "/x", None);
      ("POST", "", "/x", "/x", None);
      ("PROPFIND", "", "/x", "PROPFIND /x", None);
      (* A method-specific pattern with no method-less sibling rejects other
         verbs rather than matching them. *)
      ("GET", "", "/y", "GET /y", None);
      ("PROPFIND", "", "/y", "", None);
      ("POST", "", "/y", "", None);
    ]

(* TestMatchingMethods. *)
let test_matching_methods () =
  let host_tree = build_tree [ "GET a.com/"; "PUT b.com/"; "POST /foo/{x}" ] in
  let cases =
    [
      ("post", build_tree [ "POST /" ], "", "/foo", "POST");
      ("get", build_tree [ "GET /" ], "", "/foo", "GET,HEAD");
      ("host", host_tree, "", "/foo", "");
      ("host", host_tree, "", "/foo/bar", "POST");
      ("host2", host_tree, "a.com", "/foo/bar", "GET,HEAD,POST");
      ("host3", host_tree, "b.com", "/bar", "PUT");
      ("empty", build_tree [ "/" ], "", "/", "");
    ]
  in
  List.iter
    (fun (name, tree, host, path, want) ->
      let set = Hashtbl.create 8 in
      Routing_tree.matching_methods tree ~host ~path set;
      let keys =
        Hashtbl.fold
          (fun k _ acc -> Httpg_base.Method.to_string k :: acc)
          set []
        |> List.sort String.compare
      in
      let got = String.concat "," keys in
      Alcotest.(check string)
        (Printf.sprintf "matchingMethods %s" name)
        want got)
    cases

let tests =
  [
    ("first_segment", `Quick, test_first_segment);
    ("add_pattern", `Quick, test_add_pattern);
    ("node_match", `Quick, test_node_match);
    ("custom_method_match", `Quick, test_custom_method_match);
    ("matching_methods", `Quick, test_matching_methods);
  ]
