(* Port of go/src/net/http/header.go (and the textproto canonicalization /
   MIMEHeader methods it delegates to). *)

(** A [t] represents the key-value pairs in an HTTP header, i.e. Go's
    [Header map[string][]string]. It is a hash map keyed by canonical key (one
    value slice per key), exposed transparently like Go's public map type. Keys
    are expected to be in canonical form as produced by {!canonical_header_key}.
    Iteration order is unspecified (as in Go); {!write} sorts keys. *)
type t = (string, string list) Hashtbl.t

(** An empty header. *)
val create : unit -> t

(** [of_list pairs] builds a header from raw [(key, values)] entries, storing
    keys verbatim (no canonicalization), mirroring a Go map literal. Used mainly
    to reproduce test tables. *)
val of_list : (string * string list) list -> t

(** All [(key, values)] entries in unspecified order. *)
val to_list : t -> (string * string list) list

(** Port of [textproto.CanonicalMIMEHeaderKey]: capitalize the first letter and
    any letter following a '-', lower-case the rest (ASCII only). If [s]
    contains a space or an invalid header field byte, it is returned
    unchanged. *)
val canonical_header_key : string -> string

(** [add h key value] appends to any existing values for the canonicalized key
    (Go's [Header.Add]). *)
val add : t -> string -> string -> unit

(** [set h key value] replaces existing values with the single [value]
    (Go's [Header.Set]). *)
val set : t -> string -> string -> unit

(** [get h key] returns the first value for the canonicalized key, or "" if
    absent (Go's [Header.Get]). *)
val get : t -> string -> string

(** [values h key] returns all values for the key, or [[]] if absent
    (Go's [Header.Values]). *)
val values : t -> string -> string list

(** [del h key] removes the canonicalized key (Go's [Header.Del]). *)
val del : t -> string -> unit

(** Whether the canonicalized key is defined. *)
val has : t -> string -> bool

(** A deep copy of the header (Go's [Header.Clone]). *)
val clone : t -> t

(** [write h buf] writes the header to [buf] as sorted [Key: value\r\n] lines
    (Go's [Header.Write]). *)
val write : t -> Buffer.t -> unit

(** [write_subset h buf ~exclude] is [write] but skips canonical keys present
    in [exclude] (Go's [Header.WriteSubset]). *)
val write_subset : t -> Buffer.t -> exclude:string list -> unit
