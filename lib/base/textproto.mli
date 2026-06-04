(* Port of go/src/net/textproto canonicalization. See textproto.ml. *)

(* [valid_header_field_byte c] is whether [c] is an RFC 7230 token byte. *)
val valid_header_field_byte : char -> bool

(* [canonical_mime_header_key s] is Go's [textproto.CanonicalMIMEHeaderKey]:
   "host" -> "Host", "content-type" -> "Content-Type". If [s] contains a byte
   that is not a valid header field byte (e.g. a space), it is returned
   unchanged. *)
val canonical_mime_header_key : string -> string
