(* Ported from go/src/net/http/request_test.go form tests
   (TestParseFormQuery, TestParseFormQueryMethods, TestParseFormSemicolonSeparator,
   TestParseFormUnknownContentType, TestParseMultipartFormPopulatesPostForm,
   TestParseMultipartFormFilename, TestFormValueCallsParseMultipartForm).

   URL-encoded parsing is the faithful port; multipart/form-data parsing goes
   through the multipart_form-lwt stand-in (the plan's intentional deviation),
   so a few Go rows that depend on Go's mime/multipart error surface or
   temp-file spill behavior are omitted (see the porting notes in the plan). *)

open Gohttp

let run = Lwt_main.run

(* Build a Body.t Request.t with the given method, raw URL (query taken from
   it), Content-Type header and urlencoded/multipart body string. *)
let make_req ?(meth = "POST") ?content_type ~url ~body () : Body.t Request.t =
  let header = Header.create () in
  (match content_type with Some ct -> Header.set header "Content-Type" ct | None -> ());
  {
    Request.meth;
    url = Uri.of_string url;
    proto = "HTTP/1.1";
    proto_major = 1;
    proto_minor = 1;
    header;
    body = Body.of_string body;
    content_length = Int64.of_int (String.length body);
    transfer_encoding = [];
    close = false;
    host = "";
    trailer = None;
    request_uri = "";
    remote_addr = "";
    form = None;
    post_form = None;
    multipart_form = None;
    ctx = Gohttp.Context.background;
  }

let values_get r_field key =
  match r_field with Some v -> Values.get v key | None -> ""

let values_find r_field key =
  match r_field with Some v -> Values.find v key | None -> []

(* ---- TestParseFormQuery: query + urlencoded body merge and precedence. *)
let parse_urlencoded () =
  let r =
    make_req ~meth:"POST"
      ~url:"http://www.google.com/search?q=foo&q=bar&both=x&prio=1&orphan=nope&empty=not"
      ~content_type:"application/x-www-form-urlencoded; param=value"
      ~body:"z=post&both=y&prio=2&=nokey&orphan&empty=&" ()
  in
  let q = run (Form.form_value r "q") in
  Alcotest.(check string) "FormValue q" "foo" q;
  let z = run (Form.form_value r "z") in
  Alcotest.(check string) "FormValue z" "post" z;
  (* PostForm has no "q" (it was only in the query). *)
  Alcotest.(check (list string)) "PostForm q empty" [] (values_find r.Request.post_form "q");
  let bz = run (Form.post_form_value r "z") in
  Alcotest.(check string) "PostFormValue z" "post" bz;
  (* Form["q"] = ["foo"; "bar"] (query values, in order). *)
  Alcotest.(check (list string)) "Form q" [ "foo"; "bar" ] (values_find r.Request.form "q");
  (* Form["both"] = ["y"; "x"] (body value first, then query). *)
  Alcotest.(check (list string)) "Form both" [ "y"; "x" ] (values_find r.Request.form "both");
  Alcotest.(check string) "FormValue prio" "2" (run (Form.form_value r "prio"));
  Alcotest.(check (list string)) "Form orphan" [ ""; "nope" ] (values_find r.Request.form "orphan");
  Alcotest.(check (list string)) "Form empty" [ ""; "not" ] (values_find r.Request.form "empty");
  Alcotest.(check (list string)) "Form nokey" [ "nokey" ] (values_find r.Request.form "")

(* ---- TestParseFormQueryMethods: only POST/PUT/PATCH read the body. *)
let parse_form_query_methods () =
  List.iter
    (fun meth ->
      let r =
        make_req ~meth ~url:"http://www.google.com/search"
          ~content_type:"application/x-www-form-urlencoded; param=value" ~body:"foo=bar" ()
      in
      let want = if meth = "FOO" then "" else "bar" in
      let got = run (Form.form_value r "foo") in
      Alcotest.(check string) (Printf.sprintf "method %s FormValue foo" meth) want got)
    [ "POST"; "PATCH"; "PUT"; "FOO" ]

(* ---- TestParseFormSemicolonSeparator: a non-encoded ';' in the query is an
   error, but valid params still populate Form. *)
let parse_form_semicolon () =
  List.iter
    (fun meth ->
      let r =
        make_req ~meth ~url:"http://www.google.com/search?q=foo;q=bar&a=1" ~body:"q" ()
      in
      let res = run (Form.parse_form r) in
      (match res with
      | Ok () -> Alcotest.failf "method %s: expected error, got success" meth
      | Error _ -> ());
      Alcotest.(check (list string))
        (Printf.sprintf "method %s Form a" meth)
        [ "1" ] (values_find r.Request.form "a"))
    [ "POST"; "PATCH"; "PUT"; "GET" ]

(* small substring helper (no Astring dep). *)
let str_contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec go i =
      if i + nl > hl then false else if String.sub haystack i nl = needle then true else go (i + 1)
    in
    go 0

(* ---- TestParseFormUnknownContentType (subset). *)
let parse_form_unknown_content_type () =
  let check name ?content_type want_err =
    let r =
      let header = Header.create () in
      (match content_type with Some ct -> Header.set header "Content-Type" ct | None -> ());
      {
        Request.meth = "POST";
        url = Uri.of_string "http://x/";
        proto = "HTTP/1.1";
        proto_major = 1;
        proto_minor = 1;
        header;
        body = Body.of_string "body";
        content_length = 4L;
        transfer_encoding = [];
        close = false;
        host = "";
        trailer = None;
        request_uri = "";
        remote_addr = "";
        form = None;
        post_form = None;
        multipart_form = None;
        ctx = Gohttp.Context.background;
      }
    in
    let res = run (Form.parse_form r) in
    match (res, want_err) with
    | Ok (), None -> ()
    | Error e, Some sub ->
        Alcotest.(check bool) (name ^ " err substr") true
          (str_contains (Form.error_to_string e) sub)
    | Ok (), Some w -> Alcotest.failf "%s: want error %S, got success" name w
    | Error e, None ->
        Alcotest.failf "%s: want success, got error %S" name (Form.error_to_string e)
  in
  check "text" ~content_type:"text/plain" None;
  check "empty" None;
  check "boundary" ~content_type:"text/plain; boundary=" (Some "invalid media parameter");
  check "unknown" ~content_type:"application/unknown" None

let multipart_boundary = "foo123"

let multipart_body () =
  String.concat "\r\n"
    [
      "--" ^ multipart_boundary;
      {|Content-Disposition: form-data; name="field1"|};
      "";
      "value1";
      "--" ^ multipart_boundary;
      {|Content-Disposition: form-data; name="file"; filename="hello.txt"|};
      "Content-Type: text/plain";
      "";
      "file-contents-here";
      "--" ^ multipart_boundary ^ "--";
      "";
    ]

(* ---- multipart: a text field + a file part. *)
let multipart () =
  let r =
    make_req ~meth:"POST" ~url:"http://x/"
      ~content_type:(Printf.sprintf {|multipart/form-data; boundary="%s"|} multipart_boundary)
      ~body:(multipart_body ()) ()
  in
  (match run (Form.parse_multipart_form r ~max_memory:10000L) with
  | Ok () -> ()
  | Error e -> Alcotest.failf "parse_multipart_form: %s" (Form.error_to_string e));
  (* text field merged into Form and PostForm. *)
  Alcotest.(check string) "field1 in Form" "value1" (values_get r.Request.form "field1");
  Alcotest.(check string) "field1 in PostForm" "value1" (values_get r.Request.post_form "field1");
  (* multipart_form.value also holds it. *)
  (match r.Request.multipart_form with
  | None -> Alcotest.fail "multipart_form is None"
  | Some mf -> Alcotest.(check string) "field1 in mf.value" "value1" (Values.get mf.Request.value "field1"));
  (* file part. *)
  match run (Form.form_file r "file") with
  | None -> Alcotest.fail "FormFile file is None"
  | Some (fn, content) ->
    Alcotest.(check string) "filename" "hello.txt" fn;
    Alcotest.(check string) "file content" "file-contents-here" content

(* ---- TestParseMultipartFormFilename (Issue 45789): strip directory path. *)
let multipart_filename () =
  let body =
    String.concat "\r\n"
      [
        "--xxx";
        {|Content-Disposition: form-data; name="file"; filename="../usr/foobar.txt/"|};
        "Content-Type: text/plain";
        "";
        "data";
        "--xxx--";
        "";
      ]
  in
  let r =
    make_req ~meth:"POST" ~url:"http://x/" ~content_type:"multipart/form-data; boundary=xxx" ~body ()
  in
  match run (Form.form_file r "file") with
  | None -> Alcotest.fail "FormFile file is None"
  | Some (fn, _) -> Alcotest.(check string) "stripped filename" "foobar.txt" fn

(* ---- TestFormValueCallsParseMultipartForm-style: FormValue lazily parses a
   multipart body and returns the first value. *)
let form_value_lazy () =
  let body =
    String.concat "\r\n"
      [ "--bnd"; {|Content-Disposition: form-data; name="key"|}; ""; "val"; "--bnd--"; "" ]
  in
  let r =
    make_req ~meth:"POST" ~url:"http://x/" ~content_type:"multipart/form-data; boundary=bnd" ~body ()
  in
  (* form is None until FormValue forces parsing. *)
  Alcotest.(check bool) "form unparsed before" true (r.Request.form = None);
  let v = run (Form.form_value r "key") in
  Alcotest.(check string) "FormValue key" "val" v;
  Alcotest.(check bool) "form parsed after" false (r.Request.form = None)

(* ---- Values unit: Encode sorts by key (url.Values.Encode). *)
let values_encode () =
  let v = Values.create () in
  Values.add v "foo" "quux";
  Values.add v "bar" "baz";
  Alcotest.(check string) "encode sorted" "bar=baz&foo=quux" (Values.encode v);
  Values.set v "foo" "x y";
  Alcotest.(check string) "encode space->plus" "bar=baz&foo=x+y" (Values.encode v)

(* Result migration T6: ParseMultipartForm on a non-multipart request returns
   [Error Not_multipart] (was a raised [Not_multipart]). *)
let parse_non_multipart () =
  let r =
    make_req ~meth:"POST" ~url:"http://x/"
      ~content_type:"application/x-www-form-urlencoded" ~body:"a=b" ()
  in
  (match run (Form.parse_multipart_form r ~max_memory:10000L) with
  | Error Form.Not_multipart -> ()
  | Error (Form.Form m) -> Alcotest.failf "expected Not_multipart, got Form %S" m
  | Ok () -> Alcotest.fail "expected Error Not_multipart, got Ok");
  (* No Content-Type at all is also Not_multipart. *)
  let r2 = make_req ~meth:"POST" ~url:"http://x/" ~body:"a=b" () in
  match run (Form.parse_multipart_form r2 ~max_memory:10000L) with
  | Error Form.Not_multipart -> ()
  | _ -> Alcotest.fail "no Content-Type -> Error Not_multipart"

let tests =
  [
    Alcotest.test_case "parse_urlencoded" `Quick parse_urlencoded;
    Alcotest.test_case "parse_form_query_methods" `Quick parse_form_query_methods;
    Alcotest.test_case "parse_form_semicolon" `Quick parse_form_semicolon;
    Alcotest.test_case "parse_form_unknown_content_type" `Quick parse_form_unknown_content_type;
    Alcotest.test_case "parse_non_multipart" `Quick parse_non_multipart;
    Alcotest.test_case "multipart" `Quick multipart;
    Alcotest.test_case "multipart_filename" `Quick multipart_filename;
    Alcotest.test_case "form_value" `Quick form_value_lazy;
    Alcotest.test_case "values_encode" `Quick values_encode;
  ]
