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

val write : Eio.Buf_write.t -> t -> unit
(** [write w b] writes the raw body bytes to [w] with no transfer framing. *)
