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

let dummy_req () : Httpg.Request.t =
  {
    Httpg.Request.meth = Httpg_base.Method.Get;
    url = Uri.of_string "http://example.com/";
    proto = Httpg_base.Protocol.Http11;
    header = Httpg.Header.empty;
    body = Httpg.Body.empty;
    content_length = Some 0L;
    transfer_encoding = [];
    close = false;
    host = None;
    trailer = None;
    request_uri = None;
    remote_addr = None;
  }

let auth_roundtrip () =
  let cases =
    [ ("Aladdin", "open sesame"); ("Aladdin", "open:sesame"); ("", "") ]
  in
  List.iter
    (fun (u, p) ->
      let r = dummy_req () in
      Httpg.Request.set_auth r
        (Httpg.Authorization.Basic { username = u; password = p });
      match Httpg.Request.auth r with
      | Some (Httpg.Authorization.Basic { username; password }) ->
          Alcotest.(check string) "user" u username;
          Alcotest.(check string) "pass" p password
      | _ -> Alcotest.fail "expected Basic auth")
    cases;
  (* Bearer round-trips through set_auth/auth too. *)
  let r = dummy_req () in
  Httpg.Request.set_auth r (Httpg.Authorization.Bearer "tok123");
  (match Httpg.Request.auth r with
  | Some (Httpg.Authorization.Bearer t) ->
      Alcotest.(check string) "token" "tok123" t
  | _ -> Alcotest.fail "expected Bearer");
  (* Unauthenticated request. *)
  let r = dummy_req () in
  Alcotest.(check bool) "unauth" true (Httpg.Request.auth r = None)

let add_cookie () =
  let r = dummy_req () in
  Httpg.Request.add_cookie r (Httpg.Cookie.make ~name:"a" ~value:"1" ());
  Httpg.Request.add_cookie r (Httpg.Cookie.make ~name:"b" ~value:"2" ());
  Alcotest.(check (option string))
    "cookie header" (Some "a=1; b=2")
    (Httpg.Header.get r.header "Cookie")

let make () =
  (* defaults + host derived from the URL *)
  let r = Httpg.Request.make (Uri.of_string "http://example.com/path") in
  Alcotest.(check bool)
    "meth GET" true
    (r.Httpg.Request.meth = Httpg_base.Method.Get);
  Alcotest.(check (option string))
    "host from url" (Some "example.com") r.Httpg.Request.host;
  Alcotest.(check bool)
    "proto 1.1" true
    (r.Httpg.Request.proto = Httpg_base.Protocol.Http11);
  Alcotest.(check (option int64))
    "content_length 0" (Some 0L) r.Httpg.Request.content_length;
  (* explicit host overrides the URL-derived one; meth honored *)
  let r2 =
    Httpg.Request.make ~meth:Httpg_base.Method.Post ~host:"override.example"
      (Uri.of_string "http://example.com/")
  in
  Alcotest.(check (option string))
    "host override" (Some "override.example") r2.Httpg.Request.host;
  Alcotest.(check bool)
    "meth POST" true
    (r2.Httpg.Request.meth = Httpg_base.Method.Post)

let request_remote_addr_optional () =
  let url = Uri.of_string "http://example.com/path" in
  let r = Httpg.Request.make url in
  Alcotest.(check (option string))
    "remote_addr defaults to None" None r.Httpg.Request.remote_addr;
  r.Httpg.Request.remote_addr <- Some "127.0.0.1:80";
  Alcotest.(check (option string))
    "remote_addr reads back Some" (Some "127.0.0.1:80")
    r.Httpg.Request.remote_addr

let request_uri_optional () =
  let url = Uri.of_string "http://example.com/path" in
  let r = Httpg.Request.make url in
  Alcotest.(check (option string))
    "request_uri defaults to None (client request)" None
    r.Httpg.Request.request_uri;
  let r2 = Httpg.Request.make ~request_uri:"/foo" url in
  Alcotest.(check (option string))
    "request_uri wraps the provided target" (Some "/foo")
    r2.Httpg.Request.request_uri

let tests =
  [
    ("parse_http_version", `Quick, parse_http_version);
    ("auth_roundtrip", `Quick, auth_roundtrip);
    ("add_cookie", `Quick, add_cookie);
    ("make", `Quick, make);
    ("request_remote_addr_optional", `Quick, request_remote_addr_optional);
    ("request_uri_optional", `Quick, request_uri_optional);
  ]
