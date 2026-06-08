(* Port of go/src/net/http/header.go (and the textproto canonicalization /
   MIMEHeader methods it delegates to). *)

type t
(** A [t] represents the key-value pairs in an HTTP header, i.e. Go's
    [Header map[string][]string]. Unlike Go's mutable map, [t] is a
    {b persistent} map keyed by canonical key (one value list per key): the
    mutating helpers ({!add}/{!set}/{!del}) return a new header and sharing is
    structural, so copy-on-write is free. Keys are expected to be in canonical
    form as produced by {!canonical_header_key}. Iteration is in sorted key
    order; {!write} relies on that. *)

val create : unit -> t
(** An empty header. *)

val of_list : (string * string list) list -> t
(** [of_list pairs] builds a header from [(key, values)] entries (keys
    canonicalized; later duplicates overwrite earlier ones). Used mainly to
    reproduce test tables. *)

val to_list : t -> (string * string list) list
(** All [(key, values)] entries in sorted (canonical) key order. *)

val canonical_header_key : string -> string
(** Port of [textproto.CanonicalMIMEHeaderKey]: capitalize the first letter and
    any letter following a '-', lower-case the rest (ASCII only). If [s]
    contains a space or an invalid header field byte, it is returned unchanged.
*)

val add : t -> string -> string -> t
(** [add h key value] returns [h] with [value] appended to any existing values
    for the canonicalized key (Go's [Header.Add]). *)

val set : t -> string -> string -> t
(** [set h key value] returns [h] with existing values replaced by the single
    [value] (Go's [Header.Set]). *)

val set_values : t -> string -> string list -> t
(** [set_values h key vs] returns [h] with the whole value list for the
    canonicalized key replaced by [vs] (which may be [[]] — e.g. to record a
    trailer key). *)

val get : t -> string -> string
(** [get h key] returns the first value for the canonicalized key, or "" if
    absent (Go's [Header.Get]). *)

val values : t -> string -> string list
(** [values h key] returns all values for the key, or [[]] if absent (Go's
    [Header.Values]). *)

val del : t -> string -> t
(** [del h key] returns [h] without the canonicalized key (Go's [Header.Del]).
*)

val has : t -> string -> bool
(** Whether the canonicalized key is defined. *)

val is_empty : t -> bool
(** Whether the header has no entries. *)

val cardinal : t -> int
(** Number of distinct (canonical) keys. *)

val iter : (string -> string list -> unit) -> t -> unit
(** Iterate over [(key, values)] entries in sorted key order. *)

val fold : (string -> string list -> 'a -> 'a) -> t -> 'a -> 'a
(** Fold over [(key, values)] entries in sorted key order. *)

val valid_header_field_name : string -> bool
(** Whether [s] is a valid HTTP/1.x header field name: a non-empty RFC 7230
    token (Go's [httpguts.ValidHeaderFieldName], httplex.go:196-206). Used on
    the write path to drop invalid keys and on the read path to reject inbound
    requests bearing a non-token header name (server.go:1053-1055). *)

val write : t -> Buffer.t -> unit
(** [write h buf] writes the header to [buf] as sorted [Key: value\r\n] lines
    (Go's [Header.Write]). *)

val write_subset : t -> Buffer.t -> exclude:string list -> unit
(** [write_subset h buf ~exclude] is [write] but skips canonical keys present in
    [exclude] (Go's [Header.WriteSubset]). *)
