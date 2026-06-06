(* Port of go/src/net/http/mapping.go.

   A [mapping] is a collection of key-value pairs where the keys are unique.
   It picks a representation that makes [find] most efficient: a slice while
   there are few pairs, switching to a hash map above [max_slice] pairs. *)

type ('k, 'v) t

val create : unit -> ('k, 'v) t
(** [create ()] returns an empty mapping (Go's zero-value mapping). *)

val max_slice : int
(** Maximum number of pairs for which the slice representation is used (Go's
    [maxSlice], = 8). *)

val add : ('k, 'v) t -> 'k -> 'v -> unit
(** [add m k v] adds the key-value pair to the mapping (Go's [add]). Keys are
    assumed unique by callers. *)

val find : ('k, 'v) t -> 'k -> 'v option
(** [find m k] returns [Some v] if [k] is present, [None] otherwise (Go's
    [find]). *)

val each_pair : ('k, 'v) t -> ('k -> 'v -> bool) -> unit
(** [each_pair m f] calls [f k v] for each pair. If [f] returns [false],
    iteration stops immediately (Go's [eachPair]). *)

val using_map : ('k, 'v) t -> bool
(** [using_map m] reports whether [m] is currently in its map representation
    (i.e. Go's [m.m != nil]). Exposed for the threshold-switch test. *)
