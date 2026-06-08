(* Ported from go/src/net/http/request_test.go form tests
   (TestParseFormQuery, TestParseFormQueryMethods, TestParseFormSemicolonSeparator,
   TestParseFormUnknownContentType, TestParseMultipartFormPopulatesPostForm,
   TestParseMultipartFormFilename, TestFormValueCallsParseMultipartForm).

   URL-encoded parsing is the faithful port; multipart/form-data parsing goes
   through the sans-io multipart_form parser (the plan's intentional deviation),
   so a few Go rows that depend on Go's mime/multipart error surface or
   temp-file spill behavior are omitted (see the porting notes in the plan). *)

open Httpg

(* Form functions are direct-style now; [run] is the identity (kept so the
   ported call sites read unchanged). *)
let run x = x

(* Build a Request.t with the given method, raw URL (query taken from
   it), Content-Type header and urlencoded/multipart body string. *)
let make_req ?(meth = "POST") ?content_type ~url ~body () : Request.t =
  let header =
    match content_type with
    | Some ct -> Header.set (Header.create ()) "Content-Type" ct
    | None -> Header.create ()
  in
  {
    Request.meth = Httpg_base.Method.of_string meth;
    url = Uri.of_string url;
    proto = Httpg_base.Protocol.Http11;
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
  }

let values_get r_field key =
  match r_field with Some v -> Values.get v key | None -> ""

let values_find r_field key =
  match r_field with Some v -> Values.find v key | None -> []

(* ---- TestParseFormQuery: query + urlencoded body merge and precedence. *)
let parse_urlencoded () =
  let r =
    make_req ~meth:"POST"
      ~url:
        "http://www.google.com/search?q=foo&q=bar&both=x&prio=1&orphan=nope&empty=not"
      ~content_type:"application/x-www-form-urlencoded; param=value"
      ~body:"z=post&both=y&prio=2&=nokey&orphan&empty=&" ()
  in
  let q = run (Form.form_value r "q") in
  Alcotest.(check string) "FormValue q" "foo" q;
  let z = run (Form.form_value r "z") in
  Alcotest.(check string) "FormValue z" "post" z;
  (* PostForm has no "q" (it was only in the query). *)
  Alcotest.(check (list string))
    "PostForm q empty" []
    (values_find r.Request.post_form "q");
  let bz = run (Form.post_form_value r "z") in
  Alcotest.(check string) "PostFormValue z" "post" bz;
  (* Form["q"] = ["foo"; "bar"] (query values, in order). *)
  Alcotest.(check (list string))
    "Form q" [ "foo"; "bar" ]
    (values_find r.Request.form "q");
  (* Form["both"] = ["y"; "x"] (body value first, then query). *)
  Alcotest.(check (list string))
    "Form both" [ "y"; "x" ]
    (values_find r.Request.form "both");
  Alcotest.(check string) "FormValue prio" "2" (run (Form.form_value r "prio"));
  Alcotest.(check (list string))
    "Form orphan" [ ""; "nope" ]
    (values_find r.Request.form "orphan");
  Alcotest.(check (list string))
    "Form empty" [ ""; "not" ]
    (values_find r.Request.form "empty");
  Alcotest.(check (list string))
    "Form nokey" [ "nokey" ]
    (values_find r.Request.form "")

(* ---- TestParseFormQueryMethods: only POST/PUT/PATCH read the body. *)
let parse_form_query_methods () =
  List.iter
    (fun meth ->
      let r =
        make_req ~meth ~url:"http://www.google.com/search"
          ~content_type:"application/x-www-form-urlencoded; param=value"
          ~body:"foo=bar" ()
      in
      let want = if meth = "FOO" then "" else "bar" in
      let got = run (Form.form_value r "foo") in
      Alcotest.(check string)
        (Printf.sprintf "method %s FormValue foo" meth)
        want got)
    [ "POST"; "PATCH"; "PUT"; "FOO" ]

(* ---- TestParseFormSemicolonSeparator: a non-encoded ';' in the query is an
   error, but valid params still populate Form. *)
let parse_form_semicolon () =
  List.iter
    (fun meth ->
      let r =
        make_req ~meth ~url:"http://www.google.com/search?q=foo;q=bar&a=1"
          ~body:"q" ()
      in
      let res = run (Form.parse_form r) in
      (match res with
      | Ok () -> Alcotest.failf "method %s: expected error, got success" meth
      | Error _ -> ());
      Alcotest.(check (list string))
        (Printf.sprintf "method %s Form a" meth)
        [ "1" ]
        (values_find r.Request.form "a"))
    [ "POST"; "PATCH"; "PUT"; "GET" ]

(* small substring helper (no Astring dep). *)
let str_contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec go i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else go (i + 1)
    in
    go 0

(* ---- TestParseFormUnknownContentType (subset). *)
let parse_form_unknown_content_type () =
  let check name ?content_type want_err =
    let r =
      let header =
        match content_type with
        | Some ct -> Header.set (Header.create ()) "Content-Type" ct
        | None -> Header.create ()
      in
      {
        Request.meth = Httpg_base.Method.Post;
        url = Uri.of_string "http://x/";
        proto = Httpg_base.Protocol.Http11;
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
      }
    in
    let res = run (Form.parse_form r) in
    match (res, want_err) with
    | Ok (), None -> ()
    | Error e, Some sub ->
        Alcotest.(check bool)
          (name ^ " err substr") true
          (str_contains (Form.error_to_string e) sub)
    | Ok (), Some w -> Alcotest.failf "%s: want error %S, got success" name w
    | Error e, None ->
        Alcotest.failf "%s: want success, got error %S" name
          (Form.error_to_string e)
  in
  check "text" ~content_type:"text/plain" None;
  check "empty" None;
  check "boundary" ~content_type:"text/plain; boundary="
    (Some "invalid media parameter");
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
      ~content_type:
        (Printf.sprintf {|multipart/form-data; boundary="%s"|}
           multipart_boundary)
      ~body:(multipart_body ()) ()
  in
  (match run (Form.parse_multipart_form r ~max_memory:10000L) with
  | Ok () -> ()
  | Error e ->
      Alcotest.failf "parse_multipart_form: %s" (Form.error_to_string e));
  (* text field merged into Form and PostForm. *)
  Alcotest.(check string)
    "field1 in Form" "value1"
    (values_get r.Request.form "field1");
  Alcotest.(check string)
    "field1 in PostForm" "value1"
    (values_get r.Request.post_form "field1");
  (* multipart_form.value also holds it. *)
  (match r.Request.multipart_form with
  | None -> Alcotest.fail "multipart_form is None"
  | Some mf ->
      Alcotest.(check string)
        "field1 in mf.value" "value1"
        (Values.get mf.Request.value "field1"));
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
    make_req ~meth:"POST" ~url:"http://x/"
      ~content_type:"multipart/form-data; boundary=xxx" ~body ()
  in
  match run (Form.form_file r "file") with
  | None -> Alcotest.fail "FormFile file is None"
  | Some (fn, _) -> Alcotest.(check string) "stripped filename" "foobar.txt" fn

(* ---- TestFormValueCallsParseMultipartForm-style: FormValue lazily parses a
   multipart body and returns the first value. *)
let form_value_lazy () =
  let body =
    String.concat "\r\n"
      [
        "--bnd";
        {|Content-Disposition: form-data; name="key"|};
        "";
        "val";
        "--bnd--";
        "";
      ]
  in
  let r =
    make_req ~meth:"POST" ~url:"http://x/"
      ~content_type:"multipart/form-data; boundary=bnd" ~body ()
  in
  (* form is None until FormValue forces parsing. *)
  Alcotest.(check bool) "form unparsed before" true (r.Request.form = None);
  let v = run (Form.form_value r "key") in
  Alcotest.(check string) "FormValue key" "val" v;
  Alcotest.(check bool) "form parsed after" false (r.Request.form = None)

(* ---- F016: a file part larger than max_memory spills to a temp file (not all
   in RAM), parses correctly, and the temp file is removed by remove_all. *)
let big_file_contents = String.make 5000 'x'

let spill_body () =
  String.concat "\r\n"
    [
      "--bnd";
      {|Content-Disposition: form-data; name="big"; filename="big.bin"|};
      "Content-Type: application/octet-stream";
      "";
      big_file_contents;
      "--bnd--";
      "";
    ]

let multipart_spill () =
  let r =
    make_req ~meth:"POST" ~url:"http://x/"
      ~content_type:"multipart/form-data; boundary=bnd" ~body:(spill_body ()) ()
  in
  (* Budget far below the 5000-byte part -> must spill to disk. *)
  (match Form.parse_multipart_form r ~max_memory:100L with
  | Ok () -> ()
  | Error e ->
      Alcotest.failf "parse_multipart_form: %s" (Form.error_to_string e));
  let mf =
    match r.Request.multipart_form with
    | Some mf -> mf
    | None -> Alcotest.fail "multipart_form is None"
  in
  let fh =
    match Hashtbl.find_opt mf.Request.file "big" with
    | Some (fh :: _) -> fh
    | _ -> Alcotest.fail "no file part 'big'"
  in
  (* Spilled: backed by a temp file on disk, NOT held in [content]. *)
  let path =
    match fh.Request.tmpfile with
    | Some p -> p
    | None -> Alcotest.fail "expected spill to temp file, got in-memory"
  in
  Alcotest.(check string) "spilled content empty in RAM" "" fh.Request.content;
  Alcotest.(check bool) "temp file exists" true (Sys.file_exists path);
  (* Content is correct (read back via FormFile / FileHeader.Open). *)
  (match Form.form_file r "big" with
  | Some (fn, content) ->
      Alcotest.(check string) "filename" "big.bin" fn;
      Alcotest.(check string) "spilled content" big_file_contents content
  | None -> Alcotest.fail "FormFile big is None");
  (* Cleanup: remove_all unlinks the temp file (Go's RemoveAll). *)
  Form.remove_all r;
  Alcotest.(check bool)
    "temp file gone after remove_all" false (Sys.file_exists path);
  Alcotest.(check bool)
    "remove_all idempotent" true
    (try
       Form.remove_all r;
       true
     with _ -> false)

(* Small file part (< max_memory) stays in memory: no temp file, common case
   unchanged. *)
let multipart_no_spill () =
  let r =
    make_req ~meth:"POST" ~url:"http://x/"
      ~content_type:
        (Printf.sprintf {|multipart/form-data; boundary="%s"|}
           multipart_boundary)
      ~body:(multipart_body ()) ()
  in
  (match Form.parse_multipart_form r ~max_memory:10000L with
  | Ok () -> ()
  | Error e ->
      Alcotest.failf "parse_multipart_form: %s" (Form.error_to_string e));
  match r.Request.multipart_form with
  | None -> Alcotest.fail "multipart_form is None"
  | Some mf -> (
      match Hashtbl.find_opt mf.Request.file "file" with
      | Some (fh :: _) ->
          Alcotest.(check bool) "no temp file" true (fh.Request.tmpfile = None);
          Alcotest.(check string)
            "in-memory content" "file-contents-here" fh.Request.content
      | _ -> Alcotest.fail "no file part")

(* Leak proof on the ABANDON path: this mirrors the serve loop's per-request
   switch exactly — a handler parses+spills, then raises (or simply returns)
   without ever calling remove_all. The [Switch.on_release] hook must still
   unlink the temp file when the switch closes, so it never outlives the
   request. Demonstrates the cleanup hook the serve loop wires (server.ml). *)
let multipart_abandon_switch_cleanup () =
  let spilled_path = ref None in
  let run_handler_under_request_switch raise_in_handler =
    Eio_main.run @@ fun _env ->
    let r =
      make_req ~meth:"POST" ~url:"http://x/"
        ~content_type:"multipart/form-data; boundary=bnd" ~body:(spill_body ())
        ()
    in
    try
      Eio.Switch.run (fun req_sw ->
          (* exactly what serve_loop registers *)
          Eio.Switch.on_release req_sw (fun () ->
              Request.remove_multipart_temp_files r);
          (* handler body: parse (spills), record path, then abandon. *)
          ignore (Form.parse_multipart_form r ~max_memory:100L);
          (match r.Request.multipart_form with
          | Some mf -> (
              match Hashtbl.find_opt mf.Request.file "big" with
              | Some (fh :: _) -> spilled_path := fh.Request.tmpfile
              | _ -> ())
          | None -> ());
          if raise_in_handler then failwith "handler boom")
    with Failure _ -> ()
  in
  (* (1) handler returns normally without remove_all: switch release cleans up. *)
  run_handler_under_request_switch false;
  (match !spilled_path with
  | Some p ->
      Alcotest.(check bool)
        "spilled temp gone after switch (normal return)" false
        (Sys.file_exists p)
  | None -> Alcotest.fail "expected a spilled temp file");
  (* (2) handler raises: switch release still cleans up. *)
  spilled_path := None;
  run_handler_under_request_switch true;
  match !spilled_path with
  | Some p ->
      Alcotest.(check bool)
        "spilled temp gone after switch (handler raised)" false
        (Sys.file_exists p)
  | None -> Alcotest.fail "expected a spilled temp file"

(* ---- Values unit: Encode sorts by key (url.Values.Encode). *)
let values_encode () =
  let v = Values.create () in
  Values.add v "foo" "quux";
  Values.add v "bar" "baz";
  Alcotest.(check string) "encode sorted" "bar=baz&foo=quux" (Values.encode v);
  Values.set v "foo" "x y";
  Alcotest.(check string)
    "encode space->plus" "bar=baz&foo=x+y" (Values.encode v)

(* Result migration T6: ParseMultipartForm on a non-multipart request returns
   [Error Not_multipart] (was a raised [Not_multipart]). *)
let parse_non_multipart () =
  let r =
    make_req ~meth:"POST" ~url:"http://x/"
      ~content_type:"application/x-www-form-urlencoded" ~body:"a=b" ()
  in
  (match run (Form.parse_multipart_form r ~max_memory:10000L) with
  | Error Form.Not_multipart -> ()
  | Error (Form.Form m) ->
      Alcotest.failf "expected Not_multipart, got Form %S" m
  | Ok () -> Alcotest.fail "expected Error Not_multipart, got Ok");
  (* No Content-Type at all is also Not_multipart. *)
  let r2 = make_req ~meth:"POST" ~url:"http://x/" ~body:"a=b" () in
  match run (Form.parse_multipart_form r2 ~max_memory:10000L) with
  | Error Form.Not_multipart -> ()
  | _ -> Alcotest.fail "no Content-Type -> Error Not_multipart"

let tests =
  [
    Alcotest.test_case "parse_urlencoded" `Quick parse_urlencoded;
    Alcotest.test_case "parse_form_query_methods" `Quick
      parse_form_query_methods;
    Alcotest.test_case "parse_form_semicolon" `Quick parse_form_semicolon;
    Alcotest.test_case "parse_form_unknown_content_type" `Quick
      parse_form_unknown_content_type;
    Alcotest.test_case "parse_non_multipart" `Quick parse_non_multipart;
    Alcotest.test_case "multipart" `Quick multipart;
    Alcotest.test_case "multipart_no_spill" `Quick multipart_no_spill;
    Alcotest.test_case "multipart_spill" `Quick multipart_spill;
    Alcotest.test_case "multipart_abandon_switch_cleanup" `Quick
      multipart_abandon_switch_cleanup;
    Alcotest.test_case "multipart_filename" `Quick multipart_filename;
    Alcotest.test_case "form_value" `Quick form_value_lazy;
    Alcotest.test_case "values_encode" `Quick values_encode;
  ]
