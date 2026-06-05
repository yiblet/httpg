(* Port of go/src/net/url/url.go [Values] (= map[string][]string) and
   ParseQuery. Mirrors Go's map with a Hashtbl per the project rule. *)

type t = (string, string list) Hashtbl.t
(** Go's [url.Values]: a map from key to an ordered list of values. *)

val create : unit -> t
(** A fresh, empty [Values]. *)

val get : t -> string -> string
(** [Values.Get]: the first value for the key, or "". *)

val set : t -> string -> string -> unit
(** [Values.Set]: replace any existing values for the key. *)

val add : t -> string -> string -> unit
(** [Values.Add]: append a value to the key's list. *)

val del : t -> string -> unit
(** [Values.Del]: delete the key. *)

val has : t -> string -> bool
(** [Values.Has]: whether the key is present. *)

val find : t -> string -> string list
(** All values for the key (Go's [v[key]]); [] when absent. *)

val length : t -> int
(** Number of distinct keys ([len(v)]). *)

val copy_values : dst:t -> src:t -> unit
(** [copyValues ~dst ~src] (request.go): append each src value to dst. *)

val query_unescape : string -> string
(** [QueryUnescape]: percent-decode a query component ('+' -> space). *)

val query_escape : string -> string
(** [QueryEscape]: percent-encode a query component (space -> '+'). *)

(** A query-parse failure (Go's [ParseQuery] error cases). [Invalid_escape]
    carries the offending escape fragment; it is declared for fidelity with Go's
    [QueryUnescape] error, though this port's [query_unescape] (via the [uri]
    lib) does not currently surface bad-escape errors. *)
type error = Invalid_semicolon_separator | Invalid_escape of string

val error_to_string : error -> string
(** Render [error] as Go's faithful message. *)

val parse_query : string -> t * (unit, error) result
(** [ParseQuery query]: a non-nil map plus the first decode error, if any. *)

val parse_query_into : t -> string -> (unit, error) result
(** [parseQuery m query]: parse into an existing map (Go's internal helper). *)

val encode : t -> string
(** [Values.Encode]: "k=v&..." sorted by key. *)
