(* Port of the canonicalization subset of go/src/net/textproto/reader.go
   ([CanonicalMIMEHeaderKey] and the helpers it uses). Lives in the foundation
   library so both net/http's [Header] and the HTTP/2 stack can canonicalize
   header names without depending on the public gohttp library. *)

(* validHeaderFieldByte: RFC 7230 token characters.
   tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
           "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA *)
let valid_header_field_byte c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_' | '`'
  | '|' | '~' ->
      true
  | _ -> false

let to_lower = Char.code 'a' - Char.code 'A'

(* canonicalMIMEHeaderKey for the case where [s] is known to contain only valid
   header field bytes: upper-case the first letter and any letter after '-',
   lower-case the rest. ASCII only. *)
let canonicalize_valid s =
  let b = Bytes.of_string s in
  let upper = ref true in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let c =
      if !upper && c >= 'a' && c <= 'z' then Char.chr (Char.code c - to_lower)
      else if (not !upper) && c >= 'A' && c <= 'Z' then
        Char.chr (Char.code c + to_lower)
      else c
    in
    Bytes.set b i c;
    upper := c = '-'
  done;
  Bytes.unsafe_to_string b

(* textproto.CanonicalMIMEHeaderKey. If [s] contains a space or invalid header
   field bytes, it is returned unchanged. *)
let canonical_mime_header_key s =
  let len = String.length s in
  let rec scan i upper =
    if i >= len then s
    else
      let c = s.[i] in
      if not (valid_header_field_byte c) then s
      else if upper && c >= 'a' && c <= 'z' then canonicalize_valid s
      else if (not upper) && c >= 'A' && c <= 'Z' then canonicalize_valid s
      else scan (i + 1) (c = '-')
  in
  scan 0 true
