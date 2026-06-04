(* Port of go/src/net/http/pattern.go.

   Patterns for ServeMux routing (Go 1.22+ enhanced mux): an optional method,
   an optional host, and a path of slash-separated segments where each segment
   is a literal or a wildcard ([{name}], [{name...}], or [{$}]). *)

(* A segment is a pattern piece that matches one or more path segments, or a
   trailing slash.

   - If [wild] is false it matches a literal segment, or, if [s = "/"], a
     trailing slash.
   - If [wild] is true and [multi] is false it matches a single path segment
     ([s] is the wildcard name).
   - If both [wild] and [multi] are true it matches all remaining path
     segments ([s] is the wildcard name, possibly empty for a trailing
     slash). *)
type segment = {
  s : string;  (** literal, or wildcard name, or "/" for "/{$}". *)
  wild : bool;
  multi : bool;  (** "..." wildcard *)
}

type t = {
  str : string;  (** original string *)
  method_ : string;
  host : string;
  segments : segment list;
}

(** A parse failure (Go's [parsePattern] error cases). The [int] in the
    offset-bearing arms is the byte offset into the original pattern string
    (Go's "at offset N" prefix); the [string] is the offending fragment. *)
type error =
  | Empty_pattern  (** the empty string *)
  | Invalid_method of string  (** the bad method token *)
  | Missing_path of int  (** host/path missing the leading '/' (offset) *)
  | Host_has_brace of int  (** host contains '{' (missing initial '/'?) *)
  | Unclean_path of int  (** non-CONNECT pattern with an unclean path *)
  | Bad_wildcard of int * string  (** malformed wildcard segment (offset, why) *)
  | Duplicate_wildcard of int * string  (** repeated wildcard name (offset, name) *)

(** Render [error] as Go's faithful "at offset N: ..." message. *)
val error_to_string : error -> string

(** [parse s] parses a string into a pattern (Go's [parsePattern]). *)
val parse : string -> (t, error) result

(** [to_string p] is the original pattern string (Go's [pattern.String]). *)
val to_string : t -> string

(** [last_segment p] returns the final segment. *)
val last_segment : t -> segment

(* The relationship between two patterns p1 and p2. *)
type relationship =
  | Equivalent  (** both match the same requests *)
  | More_general  (** p1 matches everything p2 does & more *)
  | More_specific  (** p2 matches everything p1 does & more *)
  | Disjoint  (** there is no request that both match *)
  | Overlaps  (** both match some request, but neither is more specific *)

val relationship_to_string : relationship -> string

(** Go's [inverseRelationship]. *)
val inverse_relationship : relationship -> relationship

(** Go's [pattern.conflictsWith]: whether there is a request both match but
    where neither is higher precedence. *)
val conflicts_with : t -> t -> bool

(** Go's [pattern.comparePathsAndMethods]. *)
val compare_paths_and_methods : t -> t -> relationship

(** Go's [pattern.compareMethods]. *)
val compare_methods : t -> t -> relationship

(** Go's pattern.comparePaths. *)
val compare_paths : t -> t -> relationship

(** Go's [describeConflict]: explanation of why two patterns conflict. *)
val describe_conflict : t -> t -> string

(** Go's [commonPath]: a path both p1 and p2 match (assumes one exists). *)
val common_path : t -> t -> string

(** Go's [differencePath]: a path p1 matches and p2 doesn't (assumes one
    exists). *)
val difference_path : t -> t -> string

(** Go's [pathUnescape]: percent-decode, falling back to the original on
    invalid escaping. Shared with the routing tree. *)
val path_unescape : string -> string

(** Go's [cleanPath]/[path.Clean]: lexically clean a path, eliminating [.] and
    [..] elements. Shared with [ServeMux] path canonicalization. *)
val path_clean : string -> string
