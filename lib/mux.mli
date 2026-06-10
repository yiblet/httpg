(* Port of go/src/net/http/server.go's ServeMux: the HTTP request multiplexer.
   Split out of {!Server} (Go keeps it in the same file); it builds on
   {!Server.handler} and the server.go redirect/error helpers. *)

type t
(** Go's [ServeMux]: an HTTP request multiplexer backed by the routing tree. *)

val create : unit -> t
(** Go's [NewServeMux]. *)

(** A handleable registration error: an invalid or conflicting pattern (Go's
    [register] error). Carries Go's message text. *)
type error = Register of string

val error_to_string : error -> string
(** Render an {!type-error} as its Go message text. *)

val handle : t -> string -> Server.handler -> (unit, error) result
(** Go's [ServeMux.Handle]: register [handler] for [pattern]. Returns
    [Error (Register _)] on an invalid or conflicting pattern. *)

val serve_http : t -> sw:Eio.Switch.t -> Request.t -> Response.t
(** Go's [ServeMux.ServeHTTP]: dispatch a request to the matching handler. *)

val handler : t -> Server.handler
(** A {!t} viewed as a {!Server.handler} (Go's [ServeMux] implements [Handler]).
*)
