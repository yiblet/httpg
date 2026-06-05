(* Port of go/src/net/http/routing_tree.go.

   A decision tree for fast matching of requests to patterns. The root
   branches on host, the next level on method, and the remaining levels on
   consecutive path segments. The handler is kept polymorphic ([_]) since the
   server is not wired yet (Ticket 9). *)

type 'h t

val create : unit -> 'h t
(** [create ()] returns an empty root node. *)

val add_pattern : 'h t -> Pattern.t -> 'h -> unit
(** [add_pattern root p h] adds pattern [p] and its handler [h] to the tree
    (Go's [routingNode.addPattern]). *)

val match_ :
  'h t ->
  host:string ->
  method_:string ->
  path:string ->
  ((Pattern.t * 'h) * string list) option
(** [match_ root ~host ~method_ ~path] returns the matching leaf node's pattern
    and handler together with the wildcard match values in pattern order, or
    [None] (Go's [routingNode.match]). *)

val matching_methods :
  'h t -> host:string -> path:string -> (string, bool) Hashtbl.t -> unit
(** [matching_methods root ~host ~path set] adds to [set] every method that
    would match (Go's [routingNode.matchingMethods]). *)

val first_segment : string -> string * string
(** [first_segment path] splits [path] into its first segment and the rest (Go's
    [firstSegment]). The path must begin with "/". *)

val print : 'h t -> Buffer.t -> unit
(** [print root buf] writes the Go [routingNode.print] textual rendering of the
    tree, used by the add-pattern test. *)
