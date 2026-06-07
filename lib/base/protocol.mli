(* The HTTP protocol version, Go's [Request.Proto]/[ProtoMajor]/[ProtoMinor]
   collapsed into one typed value. *)

type t =
  | Http10  (** "HTTP/1.0" *)
  | Http11  (** "HTTP/1.1" *)
  | Http20  (** "HTTP/2.0" *)
  | Other of int * int  (** any other [major.minor]; never one of the above *)

val to_string : t -> string
(** The wire form, Go's [Request.Proto]: [Http11 -> "HTTP/1.1"],
    [Other (a, b) -> "HTTP/a.b"]. Total. *)

val of_string : string -> t option
(** [ParseHTTPVersion]: parse ["HTTP/X.Y"] (single decimal digits), [None] on a
    malformed version. The three named versions are normalized to their
    constructor, so [Other] only ever holds a non-standard pair. *)

val major : t -> int
(** Go's [ProtoMajor]. *)

val minor : t -> int
(** Go's [ProtoMinor]. *)

val at_least : t -> int -> int -> bool
(** [at_least p major minor] is Go's [ProtoAtLeast]: whether [p] is at least
    [major.minor]. *)

(* Common versions, as aliases of the corresponding constructor. *)

val http10 : t
val http11 : t
val http20 : t
