(* Ported pure-helper cases from go/src/net/http/request_test.go. *)

let parse_http_version () =
  let cases =
    [
      ("HTTP/0.0", Some (0, 0));
      ("HTTP/0.9", Some (0, 9));
      ("HTTP/1.0", Some (1, 0));
      ("HTTP/1.1", Some (1, 1));
      ("HTTP", None);
      ("HTTP/one.one", None);
      ("HTTP/1.1/", None);
      ("HTTP/-1,0", None);
      ("HTTP/0,-1", None);
      ("HTTP/", None);
      ("HTTP/1,1", None);
      ("HTTP/+1.1", None);
      ("HTTP/1.+1", None);
      ("HTTP/0000000001.1", None);
      ("HTTP/1.0000000001", None);
      ("HTTP/3.14", None);
      ("HTTP/12.3", None);
    ]
  in
  List.iter
    (fun (vers, want) ->
      let got = Httpg.Request.parse_http_version vers in
      Alcotest.(check (option (pair int int))) vers want got)
    cases

let b64 s = Base64.encode_string s

let parse_basic_auth () =
  let cases =
    [
      ("Basic " ^ b64 "Aladdin:open sesame", Some ("Aladdin", "open sesame"));
      ("BASIC " ^ b64 "Aladdin:open sesame", Some ("Aladdin", "open sesame"));
      ("basic " ^ b64 "Aladdin:open sesame", Some ("Aladdin", "open sesame"));
      ("Basic " ^ b64 "Aladdin:open:sesame", Some ("Aladdin", "open:sesame"));
      ("Basic " ^ b64 ":", Some ("", ""));
      ("Basic" ^ b64 "Aladdin:open sesame", None);
      (b64 "Aladdin:open sesame", None);
      ("Basic ", None);
      ("Basic Aladdin:open sesame", None);
      ({|Digest username="Aladdin"|}, None);
    ]
  in
  List.iter
    (fun (header, want) ->
      let got = Httpg.Request.parse_basic_auth header in
      Alcotest.(check (option (pair string string))) header want got)
    cases

let dummy_req () : Httpg.Request.t =
  {
    Httpg.Request.meth = Httpg_base.Method.Get;
    url = Uri.of_string "http://example.com/";
    proto = Httpg_base.Protocol.Http11;
    header = Httpg.Header.create ();
    body = Httpg.Body.Empty;
    content_length = 0L;
    transfer_encoding = [];
    close = false;
    host = "";
    trailer = None;
    request_uri = "";
    remote_addr = "";
  }

let basic_auth_roundtrip () =
  let cases =
    [ ("Aladdin", "open sesame"); ("Aladdin", "open:sesame"); ("", "") ]
  in
  List.iter
    (fun (u, p) ->
      let r = dummy_req () in
      Httpg.Request.set_basic_auth r u p;
      match Httpg.Request.basic_auth r with
      | Some (gu, gp) ->
          Alcotest.(check string) "user" u gu;
          Alcotest.(check string) "pass" p gp
      | None -> Alcotest.fail "expected basic auth")
    cases;
  (* Unauthenticated request. *)
  let r = dummy_req () in
  Alcotest.(check bool) "unauth" true (Httpg.Request.basic_auth r = None)

let add_cookie () =
  let r = dummy_req () in
  Httpg.Request.add_cookie r
    { Httpg.Cookie.default with name = "a"; value = "1" };
  Httpg.Request.add_cookie r
    { Httpg.Cookie.default with name = "b"; value = "2" };
  Alcotest.(check (option string))
    "cookie header" (Some "a=1; b=2")
    (Httpg.Header.get r.header "Cookie")

let tests =
  [
    ("parse_http_version", `Quick, parse_http_version);
    ("parse_basic_auth", `Quick, parse_basic_auth);
    ("basic_auth_roundtrip", `Quick, basic_auth_roundtrip);
    ("add_cookie", `Quick, add_cookie);
  ]
