open Gohttp
open Cookie

(* Ported from go/src/net/http/cookie_test.go.

   Omitted Go cases (with reason):
   - All GODEBUG=httpcookiemaxnum override rows in readSetCookiesTests /
     readCookiesTests / TestParseCookie: the GODEBUG override is not modeled
     (we always use the default limit of 3000). The default-limit-exceeded rows
     ARE ported. The "httpcookiemaxnum=<defaultMax+1>" rows that succeed under
     the override are equivalent to a within-limit parse and are not re-ported.
   - TestSetCookie / TestAddCookie / TestSetCookieDoubleQuotes: depend on
     ResponseWriter / Request (later tickets). The underlying formatting
     (set_cookie) and parsing (read_set_cookies) they exercise are covered by
     the write/read tables here.
   - The log-output assertions ("dropping invalid bytes" / "dropping domain
     attribute"): Go-specific; there is no log.Printf analog in the pure port. *)

(* ---------- testable for Cookie.t ---------- *)

let same_site_to_string = function
  | Same_site_unset -> "unset"
  | Same_site_default_mode -> "default"
  | Same_site_lax_mode -> "lax"
  | Same_site_strict_mode -> "strict"
  | Same_site_none_mode -> "none"

let cookie_to_string c =
  Printf.sprintf
    "{name=%S value=%S quoted=%b path=%S domain=%S expires=%g raw_expires=%S \
     max_age=%d secure=%b http_only=%b same_site=%s partitioned=%b raw=%S \
     unparsed=[%s]}"
    c.name c.value c.quoted c.path c.domain c.expires c.raw_expires c.max_age
    c.secure c.http_only (same_site_to_string c.same_site) c.partitioned c.raw
    (String.concat "; " c.unparsed)

let cookie_eq a b =
  a.name = b.name && a.value = b.value && a.quoted = b.quoted && a.path = b.path
  && a.domain = b.domain && a.expires = b.expires
  && a.raw_expires = b.raw_expires && a.max_age = b.max_age
  && a.secure = b.secure && a.http_only = b.http_only
  && a.same_site = b.same_site && a.partitioned = b.partitioned && a.raw = b.raw
  && a.unparsed = b.unparsed

let cookie_t = Alcotest.testable (Fmt.of_to_string cookie_to_string) cookie_eq

(* Mirrors Go's defaultCookieMaxNum (cookie.go). Not part of the public API, so
   duplicated here for the limit-exceeded fixtures. *)
let default_cookie_max_num = 3000

let header_of pairs =
  let h = Header.create () in
  List.iter (fun (k, vs) -> List.iter (fun v -> Header.add h k v) vs) pairs;
  h

(* Reference epochs (Unix seconds, UTC), matching Go's time.Date values. *)
let exp_2009 = 1257894000. (* Tue, 10 Nov 2009 23:00:00 GMT *)
let exp_2011 = 1322010303. (* Wed, 23 Nov 2011 01:05:03 GMT *)
let exp_2012 = 1331130306. (* Wed, 07 Mar 2012 14:25:06 GMT *)
let exp_1601 = -11644469939. (* Mon, 01 Jan 1601 01:01:01 GMT *)
let exp_1600 = -11644556339. (* year 1600 -> invalid *)

(* ---------- writeSetCookiesTests ---------- *)

let write_set_cookies_tests =
  [
    ({ default with name = "cookie-1"; value = "v$1" }, "cookie-1=v$1");
    ( { default with name = "cookie-2"; value = "two"; max_age = 3600 },
      "cookie-2=two; Max-Age=3600" );
    ( { default with name = "cookie-3"; value = "three"; domain = ".example.com" },
      "cookie-3=three; Domain=example.com" );
    ( { default with name = "cookie-4"; value = "four"; path = "/restricted/" },
      "cookie-4=four; Path=/restricted/" );
    ( { default with name = "cookie-5"; value = "five"; domain = "wrong;bad.abc" },
      "cookie-5=five" );
    ( { default with name = "cookie-6"; value = "six"; domain = "bad-.abc" },
      "cookie-6=six" );
    ( { default with name = "cookie-7"; value = "seven"; domain = "127.0.0.1" },
      "cookie-7=seven; Domain=127.0.0.1" );
    ( { default with name = "cookie-8"; value = "eight"; domain = "::1" },
      "cookie-8=eight" );
    ( { default with name = "cookie-9"; value = "expiring"; expires = exp_2009 },
      "cookie-9=expiring; Expires=Tue, 10 Nov 2009 23:00:00 GMT" );
    ( { default with
        name = "cookie-10";
        value = "expiring-1601";
        expires = exp_1601;
      },
      "cookie-10=expiring-1601; Expires=Mon, 01 Jan 1601 01:01:01 GMT" );
    ( { default with
        name = "cookie-11";
        value = "invalid-expiry";
        expires = exp_1600;
      },
      "cookie-11=invalid-expiry" );
    ( { default with
        name = "cookie-12";
        value = "samesite-default";
        same_site = Same_site_default_mode;
      },
      "cookie-12=samesite-default" );
    ( { default with
        name = "cookie-13";
        value = "samesite-lax";
        same_site = Same_site_lax_mode;
      },
      "cookie-13=samesite-lax; SameSite=Lax" );
    ( { default with
        name = "cookie-14";
        value = "samesite-strict";
        same_site = Same_site_strict_mode;
      },
      "cookie-14=samesite-strict; SameSite=Strict" );
    ( { default with
        name = "cookie-15";
        value = "samesite-none";
        same_site = Same_site_none_mode;
      },
      "cookie-15=samesite-none; SameSite=None" );
    ( { default with
        name = "cookie-16";
        value = "partitioned";
        same_site = Same_site_none_mode;
        secure = true;
        path = "/";
        partitioned = true;
      },
      "cookie-16=partitioned; Path=/; Secure; SameSite=None; Partitioned" );
    ({ default with name = "special-1"; value = "a z" }, "special-1=\"a z\"");
    ({ default with name = "special-2"; value = " z" }, "special-2=\" z\"");
    ({ default with name = "special-3"; value = "a " }, "special-3=\"a \"");
    ({ default with name = "special-4"; value = " " }, "special-4=\" \"");
    ({ default with name = "special-5"; value = "a,z" }, "special-5=\"a,z\"");
    ({ default with name = "special-6"; value = ",z" }, "special-6=\",z\"");
    ({ default with name = "special-7"; value = "a," }, "special-7=\"a,\"");
    ({ default with name = "special-8"; value = "," }, "special-8=\",\"");
    ({ default with name = "empty-value"; value = "" }, "empty-value=");
    ({ default with name = "" }, "");
    ({ default with name = "\t" }, "");
    ({ default with name = "\r" }, "");
    ({ default with name = "a\nb"; value = "v" }, "");
    ({ default with name = "a\rb"; value = "v" }, "");
    ( { default with name = "cookie"; value = "quoted"; quoted = true },
      "cookie=\"quoted\"" );
    ( { default with
        name = "cookie";
        value = "quoted with spaces";
        quoted = true;
      },
      "cookie=\"quoted with spaces\"" );
    ( { default with
        name = "cookie";
        value = "quoted,with,commas";
        quoted = true;
      },
      "cookie=\"quoted,with,commas\"" );
  ]

let write_set_cookies_cases =
  List.mapi
    (fun i (c, raw) ->
      ( Printf.sprintf "writeSetCookies #%d" i,
        `Quick,
        fun () -> Alcotest.(check string) "set_cookie" raw (set_cookie c) ))
    write_set_cookies_tests

(* ---------- readSetCookiesTests ---------- *)

let read_set_cookies_tests =
  [
    ( [ ("Set-Cookie", [ "Cookie-1=v$1" ]) ],
      [ { default with name = "Cookie-1"; value = "v$1"; raw = "Cookie-1=v$1" } ]
    );
    ( [ ( "Set-Cookie",
          [
            "NID=99=YsDT5i3E-CXax-; expires=Wed, 23-Nov-2011 01:05:03 GMT; \
             path=/; domain=.google.ch; HttpOnly";
          ] );
      ],
      [
        {
          default with
          name = "NID";
          value = "99=YsDT5i3E-CXax-";
          path = "/";
          domain = ".google.ch";
          http_only = true;
          expires = exp_2011;
          raw_expires = "Wed, 23-Nov-2011 01:05:03 GMT";
          raw =
            "NID=99=YsDT5i3E-CXax-; expires=Wed, 23-Nov-2011 01:05:03 GMT; \
             path=/; domain=.google.ch; HttpOnly";
        };
      ] );
    ( [ ( "Set-Cookie",
          [ ".ASPXAUTH=7E3AA; expires=Wed, 07-Mar-2012 14:25:06 GMT; path=/; HttpOnly" ]
        );
      ],
      [
        {
          default with
          name = ".ASPXAUTH";
          value = "7E3AA";
          path = "/";
          expires = exp_2012;
          raw_expires = "Wed, 07-Mar-2012 14:25:06 GMT";
          http_only = true;
          raw =
            ".ASPXAUTH=7E3AA; expires=Wed, 07-Mar-2012 14:25:06 GMT; path=/; HttpOnly";
        };
      ] );
    ( [ ("Set-Cookie", [ "ASP.NET_SessionId=foo; path=/; HttpOnly" ]) ],
      [
        {
          default with
          name = "ASP.NET_SessionId";
          value = "foo";
          path = "/";
          http_only = true;
          raw = "ASP.NET_SessionId=foo; path=/; HttpOnly";
        };
      ] );
    ( [ ("Set-Cookie", [ "samesitedefault=foo; SameSite" ]) ],
      [
        {
          default with
          name = "samesitedefault";
          value = "foo";
          same_site = Same_site_default_mode;
          raw = "samesitedefault=foo; SameSite";
        };
      ] );
    ( [ ("Set-Cookie", [ "samesiteinvalidisdefault=foo; SameSite=invalid" ]) ],
      [
        {
          default with
          name = "samesiteinvalidisdefault";
          value = "foo";
          same_site = Same_site_default_mode;
          raw = "samesiteinvalidisdefault=foo; SameSite=invalid";
        };
      ] );
    ( [ ("Set-Cookie", [ "samesitelax=foo; SameSite=Lax" ]) ],
      [
        {
          default with
          name = "samesitelax";
          value = "foo";
          same_site = Same_site_lax_mode;
          raw = "samesitelax=foo; SameSite=Lax";
        };
      ] );
    ( [ ("Set-Cookie", [ "samesitestrict=foo; SameSite=Strict" ]) ],
      [
        {
          default with
          name = "samesitestrict";
          value = "foo";
          same_site = Same_site_strict_mode;
          raw = "samesitestrict=foo; SameSite=Strict";
        };
      ] );
    ( [ ("Set-Cookie", [ "samesitenone=foo; SameSite=None" ]) ],
      [
        {
          default with
          name = "samesitenone";
          value = "foo";
          same_site = Same_site_none_mode;
          raw = "samesitenone=foo; SameSite=None";
        };
      ] );
    ( [ ("Set-Cookie", [ "special-1=a z" ]) ],
      [ { default with name = "special-1"; value = "a z"; raw = "special-1=a z" } ]
    );
    ( [ ("Set-Cookie", [ "special-2=\" z\"" ]) ],
      [
        {
          default with
          name = "special-2";
          value = " z";
          quoted = true;
          raw = "special-2=\" z\"";
        };
      ] );
    ( [ ("Set-Cookie", [ "special-3=\"a \"" ]) ],
      [
        {
          default with
          name = "special-3";
          value = "a ";
          quoted = true;
          raw = "special-3=\"a \"";
        };
      ] );
    ( [ ("Set-Cookie", [ "special-4=\" \"" ]) ],
      [
        {
          default with
          name = "special-4";
          value = " ";
          quoted = true;
          raw = "special-4=\" \"";
        };
      ] );
    ( [ ("Set-Cookie", [ "special-5=a,z" ]) ],
      [ { default with name = "special-5"; value = "a,z"; raw = "special-5=a,z" } ]
    );
    ( [ ("Set-Cookie", [ "special-6=\",z\"" ]) ],
      [
        {
          default with
          name = "special-6";
          value = ",z";
          quoted = true;
          raw = "special-6=\",z\"";
        };
      ] );
    ( [ ("Set-Cookie", [ "special-7=a," ]) ],
      [ { default with name = "special-7"; value = "a,"; raw = "special-7=a," } ]
    );
    ( [ ("Set-Cookie", [ "special-8=\",\"" ]) ],
      [
        {
          default with
          name = "special-8";
          value = ",";
          quoted = true;
          raw = "special-8=\",\"";
        };
      ] );
    ( [ ("Set-Cookie", [ "special-9 =\",\"" ]) ],
      [
        {
          default with
          name = "special-9";
          value = ",";
          quoted = true;
          raw = "special-9 =\",\"";
        };
      ] );
    ( [ ("Set-Cookie", [ "cookie=\"quoted\"" ]) ],
      [
        {
          default with
          name = "cookie";
          value = "quoted";
          quoted = true;
          raw = "cookie=\"quoted\"";
        };
      ] );
    (* Default cookie-limit exceeded -> empty slice. *)
    ( [ ("Set-Cookie", List.init (default_cookie_max_num + 1) (fun _ -> "a=")) ],
      [] );
  ]

let read_set_cookies_cases =
  List.mapi
    (fun i (hdr, want) ->
      ( Printf.sprintf "readSetCookies #%d" i,
        `Quick,
        fun () ->
          let h = header_of hdr in
          (* Run twice to verify readSetCookies doesn't mutate its input. *)
          Alcotest.(check (list cookie_t))
            "first" want (read_set_cookies h);
          Alcotest.(check (list cookie_t))
            "second" want (read_set_cookies h) ))
    read_set_cookies_tests

(* ---------- readCookiesTests ---------- *)

let read_cookies_tests =
  [
    ( [ ("Cookie", [ "Cookie-1=v$1"; "c2=v2" ]) ],
      "",
      [
        { default with name = "Cookie-1"; value = "v$1" };
        { default with name = "c2"; value = "v2" };
      ] );
    ( [ ("Cookie", [ "Cookie-1=v$1"; "c2=v2" ]) ],
      "c2",
      [ { default with name = "c2"; value = "v2" } ] );
    ( [ ("Cookie", [ "Cookie-1=v$1; c2=v2" ]) ],
      "",
      [
        { default with name = "Cookie-1"; value = "v$1" };
        { default with name = "c2"; value = "v2" };
      ] );
    ( [ ("Cookie", [ "Cookie-1=v$1; c2=v2" ]) ],
      "c2",
      [ { default with name = "c2"; value = "v2" } ] );
    ( [ ("Cookie", [ "Cookie-1=\"v$1\"; c2=\"v2\"" ]) ],
      "",
      [
        { default with name = "Cookie-1"; value = "v$1"; quoted = true };
        { default with name = "c2"; value = "v2"; quoted = true };
      ] );
    ( [ ("Cookie", [ "Cookie-1=\"v$1\"; c2=v2;" ]) ],
      "",
      [
        { default with name = "Cookie-1"; value = "v$1"; quoted = true };
        { default with name = "c2"; value = "v2" };
      ] );
    ([ ("Cookie", [ "" ]) ], "", []);
    (* Default cookie-limit exceeded (one Cookie field) -> empty slice. *)
    ( [ ( "Cookie",
          [
            (let b = Buffer.create 8192 in
             for _ = 1 to default_cookie_max_num + 1 do
               Buffer.add_string b "a=;"
             done;
             (* drop trailing ';' to mirror strings.Repeat(";a=",n+1)[1:] shape;
                the exact shape is unimportant: count of ';' still exceeds max. *)
             Buffer.contents b);
          ] );
      ],
      "",
      [] );
    (* Default cookie-limit exceeded (multiple Cookie fields) -> empty slice. *)
    ( [ ("Cookie", List.init (default_cookie_max_num + 1) (fun _ -> "a=")) ],
      "",
      [] );
  ]

let read_cookies_cases =
  List.mapi
    (fun i (hdr, filter, want) ->
      ( Printf.sprintf "readCookies #%d" i,
        `Quick,
        fun () ->
          let h = header_of hdr in
          Alcotest.(check (list cookie_t))
            "first" want (read_cookies h ~filter);
          Alcotest.(check (list cookie_t))
            "second" want (read_cookies h ~filter) ))
    read_cookies_tests

(* ---------- TestCookieSanitizeValue ---------- *)

let sanitize_value_tests =
  [
    ("foo", false, "foo");
    ("foo;bar", false, "foobar");
    ("foo\\bar", false, "foobar");
    ("foo\"bar", false, "foobar");
    ("\x00\x7e\x7f\x80", false, "\x7e");
    ("withquotes", true, "\"withquotes\"");
    ("\"withquotes\"", true, "\"withquotes\"");
    ("a z", false, "\"a z\"");
    (" z", false, "\" z\"");
    ("a ", false, "\"a \"");
    ("a,z", false, "\"a,z\"");
    (",z", false, "\",z\"");
    ("a,", false, "\"a,\"");
    ("", true, "\"\"");
  ]

let sanitize_value_cases =
  List.mapi
    (fun i (inp, quoted, want) ->
      ( Printf.sprintf "sanitizeCookieValue #%d" i,
        `Quick,
        fun () ->
          Alcotest.(check string)
            "sanitize_cookie_value" want
            (sanitize_cookie_value inp ~quoted) ))
    sanitize_value_tests

(* ---------- TestCookieSanitizePath ---------- *)

let sanitize_path_tests =
  [
    ("/path", "/path");
    ("/path with space/", "/path with space/");
    ("/just;no;semicolon\x00orstuff/", "/justnosemicolonorstuff/");
  ]

let sanitize_path_cases =
  List.mapi
    (fun i (inp, want) ->
      ( Printf.sprintf "sanitizeCookiePath #%d" i,
        `Quick,
        fun () ->
          Alcotest.(check string)
            "sanitize_cookie_path" want (sanitize_cookie_path inp) ))
    sanitize_path_tests

(* ---------- TestCookieValid ---------- *)

let valid_tests =
  [
    ({ default with name = "" }, false);
    ({ default with name = "invalid-value"; value = "foo\"bar" }, false);
    ({ default with name = "invalid-path"; path = "/foo;bar/" }, false);
    ( {
        default with
        name = "invalid-secure-for-partitioned";
        value = "foo";
        path = "/";
        secure = false;
        partitioned = true;
      },
      false );
    ({ default with name = "invalid-domain"; domain = "example.com:80" }, false);
    ( { default with name = "invalid-expiry"; value = ""; expires = exp_1600 },
      false );
    ({ default with name = "valid-empty" }, true);
    ( {
        default with
        name = "valid-expires";
        value = "foo";
        path = "/bar";
        domain = "example.com";
        (* time.Unix(0,0) = 1970-01-01: year 1970 >= 1601 but expires<>0., so
           validated; valid. Use a small positive epoch (1.) since 0. means
           unset in this port and Go's time.Unix(0,0) is NOT the zero time. *)
        expires = 1.;
      },
      true );
    ( {
        default with
        name = "valid-max-age";
        value = "foo";
        path = "/bar";
        domain = "example.com";
        max_age = 60;
      },
      true );
    ( {
        default with
        name = "valid-all-fields";
        value = "foo";
        path = "/bar";
        domain = "example.com";
        expires = 1.;
        max_age = 0;
      },
      true );
    ( {
        default with
        name = "valid-partitioned";
        value = "foo";
        path = "/";
        secure = true;
        partitioned = true;
      },
      true );
  ]

let valid_cases =
  List.mapi
    (fun i (c, want_valid) ->
      ( Printf.sprintf "Cookie.Valid #%d" i,
        `Quick,
        fun () ->
          let got_valid = match valid c with Ok () -> true | Error _ -> false in
          Alcotest.(check bool) "valid" want_valid got_valid ))
    valid_tests

let tests =
  write_set_cookies_cases @ read_set_cookies_cases @ read_cookies_cases
  @ sanitize_value_cases @ sanitize_path_cases @ valid_cases
