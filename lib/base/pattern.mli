(* Port of go/src/net/http/pattern.go.

   Patterns for ServeMux routing (Go 1.22+ enhanced mux): an optional method,
   an optional host, and a path of slash-separated segments where each segment
   is a literal or a wildcard ([{name}], [{name...}], or [{$}]). *)

(** A segment is a pattern piece that matches one or more path segments, or a
    trailing slash. Go uses a single [{s; wild; multi}] struct; the variant
    rules out the impossible "multi but not wild" combination. *)
module Segment : sig
  type t =
    | Lit of string  (** a literal element, or ["/"] for the ["/{$}"] end. *)
    | Wild of string  (** [{name}]: matches one path segment. *)
    | Multi of string
        (** [{name...}]: matches all remaining segments ([""] for a trailing
            slash). *)

  val is_wild : t -> bool
  (** [true] for [Wild] and [Multi] (Go's [segment.wild]). *)

  val is_multi : t -> bool
  (** [true] only for [Multi] (Go's [segment.multi]). *)

  val text : t -> string
  (** The carried string — literal text or wildcard name (Go's [segment.s]). *)
end

type t

val host : t -> string option
val segments : t -> Segment.t list
val method_ : t -> Method.t option

(** A parse failure (Go's [parsePattern] error cases). The [int] in the
    offset-bearing arms is the byte offset into the original pattern string
    (Go's "at offset N" prefix); the [string] is the offending fragment. *)
type error =
  | Empty_pattern  (** the empty string *)
  | Invalid_method of string  (** the bad method token *)
  | Missing_path of int  (** host/path missing the leading '/' (offset) *)
  | Host_has_brace of int  (** host contains ['{'] (missing initial '/'?) *)
  | Unclean_path of int  (** non-CONNECT pattern with an unclean path *)
  | Bad_wildcard of int * string
      (** malformed wildcard segment (offset, why) *)
  | Duplicate_wildcard of int * string
      (** repeated wildcard name (offset, name) *)

val error_to_string : error -> string
(** Render [error] as Go's faithful "at offset N: ..." message. *)

val parse : string -> (t, error) result
(** [parse s] parses a string into a pattern (Go's [parsePattern]). *)

val to_string : t -> string
(** [to_string p] is the original pattern string (Go's [pattern.String]). *)

val last_segment : t -> Segment.t
(** [last_segment p] returns the final segment. *)

(* The relationship between two patterns p1 and p2. *)
type relationship =
  | Equivalent  (** both match the same requests *)
  | More_general  (** p1 matches everything p2 does & more *)
  | More_specific  (** p2 matches everything p1 does & more *)
  | Disjoint  (** there is no request that both match *)
  | Overlaps  (** both match some request, but neither is more specific *)

val conflicts_with : t -> t -> bool
(** Go's [pattern.conflictsWith]: whether there is a request both match but
    where neither is higher precedence. *)

val describe_conflict : t -> t -> string
(** Go's [describeConflict]: explanation of why two patterns conflict. *)

val path_unescape : string -> string
(** Go's [pathUnescape]: percent-decode, falling back to the original on invalid
    escaping. Shared with the routing tree. *)

val path_clean : string -> string
(** Go's [path.Clean]: lexically clean a path, eliminating [.] and [..] elements
    and repeated slashes. Does not preserve a trailing slash. *)

val clean_path : string -> string
(** Go's [cleanPath] (server.go): like {!path_clean} but preserves a trailing
    slash, which is meaningful for routing. Used to reject non-CONNECT patterns
    whose path can never match, and shared with [ServeMux] path
    canonicalization. *)

(** A combinator EDSL for building patterns directly in OCaml, as an alternative
    to {!parse}-ing a string literal. A pattern built here carries no
    original-string field, so {!to_string} renders its canonical form.

    A path is assembled right-to-left with {!(^/)} and must terminate in one of
    the [segments]-typed [end_*] finalizers; {!(&/)} finishes a host-less
    pattern and {!(@/)} one with a {!host}. For example,
    [get &/ lit "items" ^/ end_slash] builds [GET /items/{$}]. *)
module Builder : sig
  type segments = Segment.t list
  (** A path: a segment list, terminated by an [end_*] finalizer. *)

  val any : Method.t option
  (** Matches any method (Go's empty method). *)

  val get : Method.t option
  val head : Method.t option
  val post : Method.t option
  val put : Method.t option
  val patch : Method.t option
  val delete : Method.t option
  val connect : Method.t option
  val options : Method.t option
  val trace : Method.t option

  val method_ : Method.t -> Method.t option
  (** Lift an arbitrary method into a matcher. *)

  val host : string -> Method.t option -> Method.t option * string option
  (** [host h m] pairs method matcher [m] with host [h], for use with {!(@/)}.
  *)

  val lit : string -> Segment.t
  (** A literal path element. *)

  val wild : string -> Segment.t
  (** A [{name}] wildcard matching one path segment. *)

  val end_lit : string -> segments
  (** Terminate a path with a literal element. *)

  val end_wild : string -> segments
  (** Terminate a path with a [{name}] single-segment wildcard. *)

  val end_spread : string -> segments
  (** Terminate a path with a trailing [{name...}] wildcard matching all
      remaining segments. *)

  val end_subtree : segments
  (** Terminate a path with a trailing-slash subtree (a [Multi ""]). *)

  val end_slash : segments
  (** Terminate a path with the [/{$}] exact-match marker. *)

  val build : Method.t option * string option * segments -> t
  (** Assemble a (method, host, path) triple into a pattern. *)

  val ( ^/ ) : Segment.t -> segments -> segments
  (** Prepend a segment onto a path (right-associative). *)

  val ( &/ ) : Method.t option -> segments -> t
  (** [m &/ path] builds a host-less pattern. *)

  val ( @/ ) : Method.t option * string option -> segments -> t
  (** [host h m @/ path] builds a pattern carrying a host. *)
end

module Private : sig
  (** Helpers exposed only for the ported white-box tests; not part of the
      public API. *)

  val relationship_to_string : relationship -> string

  val inverse_relationship : relationship -> relationship
  (** Go's [inverseRelationship]. *)

  val compare_methods : t -> t -> relationship
  (** Go's [pattern.compareMethods]. *)

  val compare_paths : t -> t -> relationship
  (** Go's pattern.comparePaths. *)

  val common_path : t -> t -> string
  (** Go's [commonPath]: a path both p1 and p2 match (assumes one exists). *)

  val difference_path : t -> t -> string
  (** Go's [differencePath]: a path p1 matches and p2 doesn't (assumes one
      exists). *)

  val to_string_canonical : t -> string

  val make :
    method_:Method.t option -> host:string option -> Segment.t list -> t
  (** Construct a pattern from its components, for the ported tests. The
      original-string field is left absent, so {!to_string} renders the
      canonical form. *)

  val prepend_segments : Segment.t list -> t -> t
  (** [prepend_segments ss p] returns a pattern with segments [ss @ p.segments].
      The original-string field is left absent, so {!to_string} renders the
      canonical form. *)

  val subtree_segments : t -> Segment.t list option
  (** [subtree_segments p] returns the segments (exluding the last element). if
      the final segment is a [Multi ""]. *)
end
