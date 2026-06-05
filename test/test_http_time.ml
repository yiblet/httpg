open Gohttp

(* The HTTP-date reference instant 2006-01-02 15:04:05 UTC, a Monday. *)
let epoch = Http_time.unix_of_utc 2006 1 2 15 4 5
let rfc1123 = "Mon, 02 Jan 2006 15:04:05 GMT"

let check_format () =
  Alcotest.(check string) "format_gmt" rfc1123 (Http_time.format_gmt epoch)

let check_parse name s =
  match Http_time.parse_http_time s with
  | Some t -> Alcotest.(check (float 0.0001)) name epoch t
  | None -> Alcotest.failf "%s: parse_http_time %S returned None" name s

let check_roundtrip () = check_parse "rfc1123 roundtrip" rfc1123
let check_rfc850 () = check_parse "rfc850" "Monday, 02-Jan-06 15:04:05 GMT"
let check_asctime () = check_parse "asctime" "Mon Jan  2 15:04:05 2006"

let check_garbage () =
  Alcotest.(check bool)
    "garbage -> None" true
    (Http_time.parse_http_time "not a date" = None)

let check_garbage2 () =
  Alcotest.(check bool)
    "empty -> None" true
    (Http_time.parse_http_time "" = None)

(* Ported from go/src/net/http parsing of http.TimeFormat / http.ParseTime
   (RFC1123, RFC850, ANSIC asctime). *)
let tests =
  [
    ("format_gmt known epoch", `Quick, check_format);
    ("parse_http_time rfc1123 roundtrip", `Quick, check_roundtrip);
    ("parse_http_time rfc850", `Quick, check_rfc850);
    ("parse_http_time asctime", `Quick, check_asctime);
    ("parse_http_time garbage -> None", `Quick, check_garbage);
    ("parse_http_time empty -> None", `Quick, check_garbage2);
  ]
