(* Port of go/src/net/http/method.go *)

(** An HTTP method. The common methods of RFC 7231 section 4.3 are first-class;
    everything else (including the empty string) is {!Custom}. Methods are
    case-sensitive and never normalized. *)
type t =
  | Get
  | Head
  | Post
  | Put
  | Patch  (** RFC 5789 *)
  | Delete
  | Connect
  | Options
  | Trace
  | Custom of string
      (** Any other method token, e.g. ["PRI"], ["PROPFIND"], ["SEARCH"], or the
          empty string (which means GET for a client request, or "any method"
          for a routing pattern). *)

val to_string : t -> string
(** The wire form: [Get -> "GET"], …, [Custom s -> s]. Total. *)

val of_string : string -> t
(** Map a wire method to its variant: ["GET" -> Get], …; every other string
    (including ["get"], ["PRI"], and [""]) maps to {!Custom}. Total, and the
    inverse of {!to_string}: [to_string (of_string s) = s] for all [s]. *)

(* Common HTTP methods (RFC 7231 section 4.3 unless noted), kept as aliases of
   the corresponding variant for ergonomics. *)

val get : t
val head : t
val post : t
val put : t
val patch : t (* RFC 5789 *)
val delete : t
val connect : t
val options : t
val trace : t
