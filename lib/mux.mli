(* Port of go/src/net/http/server.go's ServeMux: the HTTP request multiplexer.
   Split out of {!Server} (Go keeps it in the same file); it builds on
   {!Server.handler} and the server.go redirect/error helpers. *)

module StringMap : Map.S with type key = string
(** Wildcard captures from a routing match, keyed by wildcard name. Go surfaces
    these through [Request.PathValue]; here they are handed to the registered
    builder ({!type-path_handler}). Values are the matched path segments
    ([string StringMap.t]). *)

type path_handler = string StringMap.t -> Server.handler
(** What {!handle} registers: given the wildcard captures resolved for the
    matched pattern, produce the {!Server.handler} for the request. A route with
    no wildcards simply ignores the (empty) map. *)

type t
(** Go's [ServeMux]: an HTTP request multiplexer backed by the routing tree.
    Immutable: {!handle} returns an updated mux rather than mutating in place.
*)

val empty : t
(** The empty mux (cf. Go's [NewServeMux]). *)

(** A handleable registration error: an invalid or conflicting pattern (Go's
    [register] error). Carries Go's message text. *)
type error = Register of string

val error_to_string : error -> string
(** Render an {!type-error} as its Go message text. *)

val handle : string -> path_handler -> t -> (t, error) result
(** Go's [ServeMux.Handle]: register [path_handler] for [pattern], returning an
    updated mux. The mux is the last argument so registrations chain with [|>].
    Returns [Error (Register _)] on an invalid or conflicting pattern. On a
    match the mux applies [path_handler] to the wildcard captures (see
    {!type-path_handler}) to obtain the request handler.

    A pattern looks like [[METHOD ][HOST]/[PATH]]; all three parts are optional,
    so ["/"] is valid. If a method is present it must be followed by whitespace.
    A pattern with no method matches every method ([GET] also matches [HEAD]); a
    pattern with no host matches every host. Literal parts match
    case-sensitively.

    Path segments may be wildcards:
    - [{name}] matches a single segment (up to the next literal ["/"]).
    - [{name...}] matches the remaining path including slashes, and may appear
      only as the final segment.
    - [{$}] matches only the end of the URL, so ["/{$}"] matches only ["/"]
      whereas ["/"] matches every path.

    A wildcard must be a whole segment (preceded by ["/"] and followed by ["/"]
    or end of string); ["/b_{bucket}"] is invalid. A trailing slash acts as an
    anonymous [{...}] wildcard, matching the subtree.

    When several patterns match, the most specific (matching a strict subset of
    another's requests) wins; if neither is more specific the patterns conflict
    and registration fails, except that a pattern with a host beats an
    otherwise-conflicting pattern without one. *)

val handle_pattern : Pattern.t -> path_handler -> t -> (t, error) result
(** Register [path_handler] for an already-parsed [pattern], returning an
    updated mux. Equivalent to {!handle} but skipping the string parse; still
    fails with [Error (Register _)] on a conflicting pattern. *)

val add_middleware : Middleware.t -> t -> t
(** [add_middleware m mux] returns a mux that wraps every matched handler in
    [m]. Middlewares apply to all routes regardless of whether they were
    registered before or after this call: the chain is built at dispatch time
    over the accumulated list. [m] is prepended, so the first-added middleware
    is the outermost (runs first on the way in). The mux is last so middleware
    registrations chain with [|>]. *)

val mount_pattern : Pattern.t -> nested:t -> t -> (t, error) result
(** [mount_pattern pattern ~nested mux] mounts the [nested] mux under the
    already-parsed subtree [pattern] (which must end in a trailing-slash [{...}]
    segment). Every pattern registered in [nested] is re-registered in the
    returned mux with the subtree prefix prepended, each wrapped in [nested]'s
    own middlewares so they survive the mount. Mounting only prepends path
    segments, so [pattern] must carry no method or host. The mux is last so
    mounts chain with [|>]. Fails with [Error (Register _)] if [pattern] has a
    method or host, is not a subtree pattern (no trailing [{...}] segment), or a
    resulting pattern conflicts. *)

val mount : string -> nested:t -> t -> (t, error) result
(** Like {!mount_pattern} but parses the subtree pattern from a string first. *)

val handler : t -> sw:Eio.Switch.t -> Request.t -> Response.t
(** Go's [ServeMux.ServeHTTP]: dispatch a request to the matching handler. A
    {!t} viewed as a {!Server.handler} ([ServeMux] implements [Handler]). *)
