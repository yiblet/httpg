(* Port of go/src/net/http/internal/ascii/print.go.
   ASCII-only string helpers used across net/http. *)

(* [lower b] is the ASCII-lowercase of [b]: an upper-case letter ['A'..'Z']
   becomes its lower-case form (+32); every other byte (including non-ASCII) is
   returned unchanged. This is the per-byte primitive behind {!equal_fold} and
   {!to_lower}. Note: this is NOT [b lor 0x20] — that maps non-letters too (e.g.
   ['^' -> '~']); callers that want that fast pre-filter must keep [lor 0x20]. *)
val lower : char -> char

(* [hex_val c] decodes a single hexadecimal nibble: ['0'..'9'] -> [Some 0..9],
   ['a'..'f']/['A'..'F'] -> [Some 10..15], and [None] for any non-hex byte. The
   shared per-nibble primitive used by the chunked length parser and the
   URL/path-unescape parsers. *)
val hex_val : char -> int option

(* EqualFold reports whether [s] and [t] are equal, ASCII-case-insensitively.
   Mirrors strings.EqualFold restricted to ASCII (the Unicode "Kelvin sign"
   and friends are NOT folded to their ASCII counterparts). *)
val equal_fold : string -> string -> bool

(* IsPrint returns whether [s] is ASCII and printable according to
   https://tools.ietf.org/html/rfc20#section-4.2 (every byte in ' '..'~'). *)
val is_print : string -> bool

(* Is returns whether [s] is ASCII (every byte <= 0x7f). *)
val is : string -> bool

(* ToLower returns [(lower, true)] with the ASCII-lowercased version of [s]
   when [s] is ASCII and printable, and [("", false)] otherwise. *)
val to_lower : string -> string * bool
