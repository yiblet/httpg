(* Port of go/src/net/url/url.go [Values] (= map[string][]string) and
   ParseQuery. Mirrors Go's map with a Hashtbl per the project rule. *)

(** Go's [url.Values]: a map from key to an ordered list of values. *)
type t = (string, string list) Hashtbl.t

(** A fresh, empty [Values]. *)
val create : unit -> t

(** [Values.Get]: the first value for the key, or "". *)
val get : t -> string -> string

(** [Values.Set]: replace any existing values for the key. *)
val set : t -> string -> string -> unit

(** [Values.Add]: append a value to the key's list. *)
val add : t -> string -> string -> unit

(** [Values.Del]: delete the key. *)
val del : t -> string -> unit

(** [Values.Has]: whether the key is present. *)
val has : t -> string -> bool

(** All values for the key (Go's [v[key]]); [] when absent. *)
val find : t -> string -> string list

(** Number of distinct keys ([len(v)]). *)
val length : t -> int

(** [copyValues ~dst ~src] (request.go): append each src value to dst. *)
val copy_values : dst:t -> src:t -> unit

(** [QueryUnescape]: percent-decode a query component ('+' -> space). *)
val query_unescape : string -> string

(** [QueryEscape]: percent-encode a query component (space -> '+'). *)
val query_escape : string -> string

(** [ParseQuery query]: a non-nil map plus the first decode error, if any. *)
val parse_query : string -> t * (unit, string) result

(** [parseQuery m query]: parse into an existing map (Go's internal helper). *)
val parse_query_into : t -> string -> (unit, string) result

(** [Values.Encode]: "k=v&..." sorted by key. *)
val encode : t -> string
