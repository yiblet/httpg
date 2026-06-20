(* Port of go/src/net/http/server.go's ServeMux: the HTTP request multiplexer.
   Split out of {!Server} (Go keeps it in the same file); it builds on
   {!Server.handler} and the server.go redirect/error helpers. *)

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

val handle : t -> string -> Server.handler -> (t, error) result
(** Go's [ServeMux.Handle]: register [handler] for [pattern], returning an
    updated mux. Returns [Error (Register _)] on an invalid or conflicting
    pattern.

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

val handle_pattern : t -> Pattern.t -> Server.handler -> (t, error) result
(** Register [handler] for an already-parsed [pattern], returning an updated
    mux. Equivalent to {!handle} but skipping the string parse; still fails with
    [Error (Register _)] on a conflicting pattern. *)

val handler : t -> sw:Eio.Switch.t -> Request.t -> Response.t
(** Go's [ServeMux.ServeHTTP]: dispatch a request to the matching handler. A
    {!t} viewed as a {!Server.handler} ([ServeMux] implements [Handler]). *)
