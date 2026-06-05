(* A concrete HTTP message body over Lwt, the analogue of Go's
   [io.ReadCloser] body field. *)

(** [Empty] is the analogue of [http.NoBody]; [String s] an in-memory body;
    [Stream next] a streaming reader whose [next ()] yields successive chunks
    and finally [None] (the analogue of [io.EOF]).

    A body produced by a {b read path} — a server request body or a client
    response body (see {!Io.read_request}/{!Io.read_response}) — is a [Stream]
    that pulls bytes lazily {b from the underlying connection}; it is never
    materialized up front. Such a body must be consumed to EOF (via {!read_all}
    or {!drain}) to free the connection: reading to [None] runs the on-EOF
    action that reads any chunked trailer and releases the connection for
    keep-alive reuse (Go's [resp.Body.Close]). Until then the connection is held
    and is not reused. A handler/caller that returns without draining the body
    leaves it to the framework to drain (server side) or simply forgoes reuse
    (client side). *)
type t = Empty | String of string | Stream of (unit -> string option Lwt.t)

val empty : t
(** The empty body. *)

val of_string : string -> t
(** [of_string s] is [String s]. *)

val of_stream : (unit -> string option Lwt.t) -> t
(** [of_stream next] is [Stream next]. *)

val read_all : t -> string Lwt.t
(** Read the entire body to a string. *)

val drain : ?limit:int -> t -> [ `Drained | `Too_big ] Lwt.t
(** [drain ?limit b] reads and discards the body until EOF, or until more than
    [limit] bytes have been read. Returns [`Drained] if the body reached EOF
    (within [limit] when given) — a kept-alive connection is then positioned at
    the next message boundary (and any chunked trailer is read) and may be
    reused — or [`Too_big] if [limit] was given and more bytes remained unread.

    With no [limit] the whole body is consumed and the result is always
    [`Drained] — the analogue of Go's [io.Copy(io.Discard, body)]. With [limit]
    it is the analogue of the bounded discards Go uses to keep a connection
    alive: [finishRequest]'s
    [io.CopyN(io.Discard, body, maxPostHandlerReadBytes+1)] (server.go) and the
    redirect loop's [maxBodySlurpSize] slurp (client.go); past the bound the
    caller closes the connection instead of reading an unbounded amount.
    [Empty]/[String] are no-ops unless they themselves exceed [limit]. *)

val iter : (string -> unit Lwt.t) -> t -> unit Lwt.t
(** [iter f b] applies [f] to each successive chunk of the body, in order, until
    EOF. [Empty] yields no calls; [String s] yields exactly one call [f s]; a
    [Stream] yields one call per chunk until it returns [None]. This streams the
    body without materializing it (the analogue of Go's [io.Copy] pulling from a
    body reader chunk-by-chunk). *)

val write : Lwt_io.output_channel -> t -> unit Lwt.t
(** [write oc b] writes the raw body bytes to [oc] with no transfer framing. *)
