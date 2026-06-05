(* Port of go/src/net/http/method.go *)

type t = string
(** An HTTP method. Go models these as plain string constants. *)

(* Common HTTP methods.

   Unless otherwise noted, these are defined in RFC 7231 section 4.3. *)

val get : t
val head : t
val post : t
val put : t
val patch : t
val delete : t
val connect : t
val options : t
val trace : t
