(* Port of the canonicalization subset of go/src/net/textproto/reader.go
   ([CanonicalMIMEHeaderKey] and the helpers it uses). Lives in the foundation
   library so both net/http's [Header] and the HTTP/2 stack can canonicalize
   header names without depending on the public httpg library. *)

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

(* OWS (optional whitespace) is space and tab only — Go's
   [textproto.TrimString] / [httpguts.trimOWS], deliberately *not*
   [strings.TrimSpace] (which also strips '\n'/'\r'/'\012'). Trimming newlines
   here would let header injection cross lines, so keep it space+tab. *)
let is_ows c = c = ' ' || c = '\t'

(* textproto.TrimString: trim leading and trailing ' ' and '\t'. *)
let trim_string s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && is_ows s.[!i] do
    incr i
  done;
  let j = ref (n - 1) in
  while !j >= !i && is_ows s.[!j] do
    decr j
  done;
  String.sub s !i (!j - !i + 1)

(* Trailing-only OWS trim (' ' and '\t'); Go's chunked [removeChunkExtension]
   strips trailing OWS before the chunk-extension cut. *)
let trim_right s =
  let n = ref (String.length s) in
  while !n > 0 && is_ows s.[!n - 1] do
    decr n
  done;
  String.sub s 0 !n

(* Generic leading trim over a character set: strips every prefix byte that
   appears in [chars] (Go's [strings.TrimLeft]). *)
let trim_left ~chars s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && String.contains chars s.[!i] do
    incr i
  done;
  String.sub s !i (n - !i)
