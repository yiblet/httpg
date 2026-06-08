(* Port of go/src/net/textproto canonicalization. See textproto.ml. *)

(* [valid_header_field_byte c] is whether [c] is an RFC 7230 token byte. *)
val valid_header_field_byte : char -> bool

(* [canonical_mime_header_key s] is Go's [textproto.CanonicalMIMEHeaderKey]:
   "host" -> "Host", "content-type" -> "Content-Type". If [s] contains a byte
   that is not a valid header field byte (e.g. a space), it is returned
   unchanged. *)
val canonical_mime_header_key : string -> string

(* [trim_string s] strips leading and trailing OWS (space and tab) from [s].
   This is Go's [textproto.TrimString] / [httpguts.trimOWS]; it deliberately
   does NOT strip '\n'/'\r'/'\012' the way [String.trim] would. *)
val trim_string : string -> string

(* [trim_right s] strips trailing OWS (space and tab) from [s] only. Used where
   Go trims trailing OWS before a cut (e.g. chunked [removeChunkExtension]). *)
val trim_right : string -> string

(* [trim_left ~chars s] strips every leading byte of [s] that occurs in [chars]
   (Go's [strings.TrimLeft]). *)
val trim_left : chars:string -> string -> string

(* [cut s sep] is Go's [strings.Cut]: it splits [s] around the first occurrence
   of the byte [sep], returning [(before, after, true)]; when [sep] is absent it
   returns [(s, "", false)]. *)
val cut : string -> char -> string * string * bool
