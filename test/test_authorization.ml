(* Tests for Httpg.Authorization: parse/encode of HTTP Authorization header
   values (Basic / Bearer / Other), ported from the Go BasicAuth parse cases
   plus Bearer/other-scheme coverage. *)

open Httpg
module A = Authorization

let b64 = Base64.encode_string

(* of_string parses the scheme + credentials (Basic case-insensitive). *)
let of_string_basic () =
  let ok header (u, p) =
    match A.of_string header with
    | Ok (A.Basic { username; password }) ->
        Alcotest.(check string) (header ^ " user") u username;
        Alcotest.(check string) (header ^ " pass") p password
    | Ok _ -> Alcotest.failf "%s: wrong arm" header
    | Error e -> Alcotest.failf "%s: %s" header (A.error_to_string e)
  in
  ok ("Basic " ^ b64 "Aladdin:open sesame") ("Aladdin", "open sesame");
  ok ("BASIC " ^ b64 "Aladdin:open sesame") ("Aladdin", "open sesame");
  ok ("basic " ^ b64 "Aladdin:open sesame") ("Aladdin", "open sesame");
  (* extra colons belong to the password *)
  ok ("Basic " ^ b64 "Aladdin:open:sesame") ("Aladdin", "open:sesame");
  ok ("Basic " ^ b64 ":") ("", "")

(* Bearer and unknown schemes. *)
let of_string_bearer_other () =
  (match A.of_string "Bearer tok-123" with
  | Ok (A.Bearer "tok-123") -> ()
  | _ -> Alcotest.fail "expected Bearer tok-123");
  (match A.of_string "bearer tok-123" with
  | Ok (A.Bearer "tok-123") -> () (* scheme case-insensitive *)
  | _ -> Alcotest.fail "expected Bearer (lowercase scheme)");
  match A.of_string {|Digest username="Aladdin", realm="x"|} with
  | Ok (A.Other { scheme = "Digest"; params }) ->
      Alcotest.(check string)
        "digest params" {|username="Aladdin", realm="x"|} params
  | _ -> Alcotest.fail "expected Other Digest"

(* Error arms. *)
let of_string_errors () =
  (* no scheme/credentials split *)
  (match A.of_string "Basic" with
  | Error (A.Malformed _) -> ()
  | _ -> Alcotest.fail "bare scheme should be Malformed");
  (match A.of_string "" with
  | Error (A.Malformed _) -> ()
  | _ -> Alcotest.fail "empty should be Malformed");
  (* Basic payload missing the ':' is invalid *)
  match A.of_string ("Basic " ^ b64 "nocolon") with
  | Error A.Invalid_basic -> ()
  | _ -> Alcotest.fail "Basic without ':' should be Invalid_basic"

(* to_string and round-trip. *)
let to_string_roundtrip () =
  Alcotest.(check string)
    "basic encode"
    ("Basic " ^ b64 "u:p")
    (A.to_string (A.Basic { username = "u"; password = "p" }));
  Alcotest.(check string)
    "bearer encode" "Bearer xyz"
    (A.to_string (A.Bearer "xyz"));
  Alcotest.(check string)
    "other encode" "Digest a=b"
    (A.to_string (A.Other { scheme = "Digest"; params = "a=b" }));
  (* round-trip each variant through of_string *)
  let rt a =
    match A.of_string (A.to_string a) with
    | Ok a' -> a'
    | Error e -> Alcotest.failf "round-trip: %s" (A.error_to_string e)
  in
  Alcotest.(check bool)
    "basic rt" true
    (rt (A.Basic { username = "u"; password = "p:q" })
    = A.Basic { username = "u"; password = "p:q" });
  Alcotest.(check bool) "bearer rt" true (rt (A.Bearer "tok") = A.Bearer "tok")

let tests =
  [
    ("of_string_basic", `Quick, of_string_basic);
    ("of_string_bearer_other", `Quick, of_string_bearer_other);
    ("of_string_errors", `Quick, of_string_errors);
    ("to_string_roundtrip", `Quick, to_string_roundtrip);
  ]
