(* Port of go/src/net/http/internal/ascii/print.go.
   ASCII-only string helpers used across net/http. *)

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
