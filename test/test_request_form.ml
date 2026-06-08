(* Tests for the composable body parsers {!Form} (urlencoded) and {!Multipart}
   (multipart/form-data), which replace Go's Request-mutating ParseForm /
   ParseMultipartForm (a deliberate Httpg deviation — see lib/form.mli,
   lib/multipart.mli). The Go form rows that depended on the Request cache or on
   Go's mime/multipart error surface are recast around the new functions:
   - urlencoded body params come from {!Form.of_body} (the merged query+body
     [Form] is now the caller's own composition; demonstrated in
     [form_query_body_merge]);
   - multipart parts are a [(part, error) result Seq.t] from {!Multipart.of_body},
     each part settled to memory or a tempfile (cleaned on the [~sw] switch). *)

open Httpg

(* ---- Form: application/x-www-form-urlencoded body parsing ---- *)

let form_of_body () =
  match
    Form.of_body (Body.of_string "z=post&both=y&prio=2&orphan&empty=&=nokey")
  with
  | Error e -> Alcotest.failf "of_body: %s" (Form.error_to_string e)
  | Ok v ->
      Alcotest.(check string) "z" "post" (Form.get v "z");
      Alcotest.(check string) "prio" "2" (Form.get v "prio");
      (* a key with no '=' has value "" *)
      Alcotest.(check (list string)) "orphan" [ "" ] (Form.find v "orphan");
      Alcotest.(check (list string)) "empty" [ "" ] (Form.find v "empty");
      (* "=nokey" is the empty key with value "nokey" *)
      Alcotest.(check (list string)) "nokey" [ "nokey" ] (Form.find v "")

(* The merged Go [Form] (body params first, then query) is now an explicit
   caller-side composition (Form.merge) rather than magic on the Request. *)
let form_query_body_merge () =
  let url = Uri.of_string "http://x/s?q=foo&q=bar&both=x" in
  let query, _ =
    Form.parse_query (Option.value ~default:"" (Uri.verbatim_query url))
  in
  let body =
    match Form.of_body (Body.of_string "z=post&both=y") with
    | Ok v -> v
    | Error _ -> Alcotest.fail "body parse"
  in
  (* body values first, then the query values appended per key. *)
  let form = Form.merge body query in
  Alcotest.(check (list string))
    "q (query only)" [ "foo"; "bar" ] (Form.find form "q");
  Alcotest.(check (list string))
    "both (body first)" [ "y"; "x" ] (Form.find form "both");
  Alcotest.(check string) "z (body only)" "post" (Form.get form "z")

(* A bare ';' separator in a urlencoded body is rejected (Form.parse_query). *)
let form_semicolon_error () =
  match Form.of_body (Body.of_string "q=foo;q=bar&a=1") with
  | Error Form.Invalid_semicolon_separator -> ()
  | Error _ -> Alcotest.fail "want Invalid_semicolon_separator"
  | Ok _ -> Alcotest.fail "want error, got Ok"

(* A body over maxFormSize (10 MB) is rejected without parsing. *)
let form_too_large () =
  let big = "a=" ^ String.make ((10 * 1024 * 1024) + 1) 'x' in
  match Form.of_body (Body.of_string big) with
  | Error Form.Too_large -> ()
  | _ -> Alcotest.fail "want Too_large"

(* ---- Multipart: boundary extraction ---- *)

let boundary () =
  let ok ct want =
    match Multipart.boundary ~content_type:ct with
    | Ok b -> Alcotest.(check string) ("boundary " ^ ct) want b
    | Error e -> Alcotest.failf "%s: %s" ct (Multipart.error_to_string e)
  in
  let not_multipart ct =
    match Multipart.boundary ~content_type:ct with
    | Error Multipart.Not_multipart -> ()
    | _ -> Alcotest.failf "%s: want Not_multipart" ct
  in
  ok "multipart/form-data; boundary=foo123" "foo123";
  ok {|multipart/form-data; boundary="foo 123"|} "foo 123";
  ok "MULTIPART/FORM-DATA; BOUNDARY=xYz" "xYz" (* case-insensitive type/key *);
  not_multipart "application/x-www-form-urlencoded";
  not_multipart "";
  not_multipart "multipart/form-data" (* no boundary *);
  not_multipart "text/plain; boundary=foo" (* not multipart *);
  (* a genuinely malformed Content-Type is a parse error *)
  match Multipart.boundary ~content_type:"garbage" with
  | Error (Multipart.Parse m) ->
      Alcotest.(check bool) "parse error message" true (String.length m > 0)
  | _ -> Alcotest.fail "want Parse error for malformed content-type"

(* ---- Multipart: parsing parts ---- *)

(* Collect a multipart body's parts (raising on a parse error) under [sw]. *)
(* [of_body] is pure (in-memory parts, no switch); collect the parts, raising on
   a parse error. *)
let collect ~boundary body =
  Multipart.of_body ~boundary (Body.of_string body)
  |> Seq.map (function
    | Ok p -> p
    | Error e -> Alcotest.failf "multipart: %s" (Multipart.error_to_string e))
  |> List.of_seq

let multipart_body boundary =
  String.concat "\r\n"
    [
      "--" ^ boundary;
      {|Content-Disposition: form-data; name="field1"|};
      "";
      "value1";
      "--" ^ boundary;
      {|Content-Disposition: form-data; name="file"; filename="hello.txt"|};
      "Content-Type: text/plain";
      "";
      "file-contents-here";
      "--" ^ boundary ^ "--";
      "";
    ]

let multipart () =
  match collect ~boundary:"foo123" (multipart_body "foo123") with
  | [ field1; file ] ->
      Alcotest.(check (option string)) "field1 name" (Some "field1") field1.name;
      Alcotest.(check (option string)) "field1 not a file" None field1.filename;
      Alcotest.(check string) "field1 value" "value1" field1.body;
      Alcotest.(check (option string)) "file name" (Some "file") file.name;
      Alcotest.(check (option string))
        "file filename" (Some "hello.txt") file.filename;
      Alcotest.(check string)
        "file Content-Type" "text/plain"
        (Header.get file.header "Content-Type");
      Alcotest.(check string) "file body" "file-contents-here" file.body
  | parts -> Alcotest.failf "expected 2 parts, got %d" (List.length parts)

(* Issue 45789: a filename with a directory path is reduced to its basename. *)
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
  match collect ~boundary:"xxx" body with
  | [ file ] ->
      Alcotest.(check (option string))
        "stripped filename" (Some "foobar.txt") file.filename
  | parts -> Alcotest.failf "expected 1 part, got %d" (List.length parts)

(* A large part is held in memory and parses correctly (no spill — for now). *)
let multipart_large_in_memory () =
  let big = String.make 100_000 'x' in
  let body =
    String.concat "\r\n"
      [
        "--bnd";
        {|Content-Disposition: form-data; name="big"; filename="big.bin"|};
        "Content-Type: application/octet-stream";
        "";
        big;
        "--bnd--";
        "";
      ]
  in
  match collect ~boundary:"bnd" body with
  | [ file ] ->
      Alcotest.(check (option string)) "filename" (Some "big.bin") file.filename;
      Alcotest.(check int) "content length" 100_000 (String.length file.body);
      Alcotest.(check string) "content" big file.body
  | parts -> Alcotest.failf "expected 1 part, got %d" (List.length parts)

(* ---- Form values unit: Encode sorts by key (url.Values.Encode). ---- *)
let values_encode () =
  let v = Form.create () in
  let v = Form.add v "foo" "quux" in
  let v = Form.add v "bar" "baz" in
  Alcotest.(check string) "encode sorted" "bar=baz&foo=quux" (Form.encode v);
  let v = Form.set v "foo" "x y" in
  (* deviation from Go: space encodes as "%20", not '+'. *)
  Alcotest.(check string)
    "encode space->%20" "bar=baz&foo=x%20y" (Form.encode v)

(* Round-trip: a space and a literal '+' survive encode -> parse_query. The space
   encodes as "%20" and the '+' as "%2B"; decode accepts both '+' and "%2B". *)
let encode_roundtrip () =
  let v = Form.set (Form.create ()) "k" "a b+c" in
  let encoded = Form.encode v in
  Alcotest.(check string) "encoded" "k=a%20b%2Bc" encoded;
  let parsed, res = Form.parse_query encoded in
  Alcotest.(check bool) "no parse error" true (res = Ok ());
  Alcotest.(check string) "value round-trips" "a b+c" (Form.get parsed "k")

let tests =
  [
    Alcotest.test_case "form_of_body" `Quick form_of_body;
    Alcotest.test_case "form_query_body_merge" `Quick form_query_body_merge;
    Alcotest.test_case "form_semicolon_error" `Quick form_semicolon_error;
    Alcotest.test_case "form_too_large" `Quick form_too_large;
    Alcotest.test_case "boundary" `Quick boundary;
    Alcotest.test_case "multipart" `Quick multipart;
    Alcotest.test_case "multipart_filename" `Quick multipart_filename;
    Alcotest.test_case "multipart_large_in_memory" `Quick
      multipart_large_in_memory;
    Alcotest.test_case "values_encode" `Quick values_encode;
    Alcotest.test_case "encode_roundtrip" `Quick encode_roundtrip;
  ]
