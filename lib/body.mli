(* A concrete HTTP message body, the analogue of Go's [io.ReadCloser]. *)

(** [Empty] is [http.NoBody]; [String s] an in-memory body; [Stream next] a
    streaming reader whose [next ()] yields successive chunks and finally [None]
    (io.EOF).

    A body produced by a {b read path} (see {!Io.read_request}/
    {!Io.read_response}) is a [Stream] pulling bytes lazily from the underlying
    connection; it is never materialized up front. Such a body must be consumed
    to EOF (via {!read_all} or {!drain}) to free the connection: reaching [None]
    runs the on-EOF action that reads any chunked trailer and releases the
    connection for keep-alive reuse (Go's [resp.Body.Close]). *)
type t = Empty | String of string | Stream of (unit -> string option)

val empty : t
val of_string : string -> t
val of_stream : (unit -> string option) -> t

val of_lazy_string : string Lazy.t -> t
(** [of_lazy_string s] is a body whose single chunk is [Lazy.force s], forced on
    the first read (so the body is never materialized if it isn't read — e.g. a
    HEAD response or an abandoned write). Unlike {!of_stream} the whole body is
    one chunk; use {!of_stream} for chunked/large output. *)

val append : t -> t -> t
(** [append b1 b2] is a body that yields all of [b1] then all of [b2], streaming
    (it never materializes a [Stream] operand). *)

val concat : t list -> t
(** [concat bs] yields every body in [bs] in order, streaming. Used to assemble
    a composite body (e.g. the file server's multipart/byteranges output)
    without materializing it. *)

val read_all : t -> string
(** Read the entire body to a string. *)

val drain : ?limit:int -> t -> [ `Drained | `Too_big ]
(** [drain ?limit b] reads and discards the body until EOF, or until more than
    [limit] bytes have been read. [`Drained] (within [limit] when given)
    positions a kept-alive connection at the next message boundary and reads any
    chunked trailer; [`Too_big] if [limit] was given and more bytes remained.
    Without [limit] the whole body is consumed (always [`Drained]). *)

val iter : (string -> unit) -> t -> unit
(** [iter f b] applies [f] to each successive chunk in order until EOF,
    streaming without materializing ([Empty] yields no calls; [String s] one
    call [f s]; a [Stream] one call per chunk). *)

val fold : (string -> 'a -> 'a) -> t -> 'a -> 'a
(** [fold f b init] folds [f] over each successive chunk in order until EOF,
    streaming without materializing (same chunk sequence as {!iter}). *)

val write : Eio.Buf_write.t -> t -> unit
(** [write w b] writes the raw body bytes to [w] with no transfer framing. *)
