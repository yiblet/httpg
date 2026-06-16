(* A concrete HTTP message body, the analogue of Go's [io.ReadCloser]. *)

(** A body is a lazy sequence of result-typed chunks. Each forced element is
    [Ok chunk] (more data) or a terminal [Error e] (a mid-stream framing
    failure); the sequence ends after an [Error]. An empty body is the empty
    sequence; an in-memory body is a single-element sequence; a read-path body
    streams lazily from the connection. Mid-stream failure is data — never a
    raise from a pull thunk.

    The old [Empty | String | Stream] distinction is gone; the "known length vs
    streaming" framing decision now lives in the [content_length] field on
    Request/Response. A body produced by a {b read path} (see
    {!Io.read_request}/{!Io.read_response}) pulls bytes lazily from the
    underlying connection; it is never materialized up front. Such a body must
    be consumed to EOF (via {!read_all} or {!drain}) to free the connection:
    reaching the end runs the on-EOF action that reads any chunked trailer and
    releases the connection for keep-alive reuse (Go's [resp.Body.Close]). *)

type error =
  | Malformed_chunk of string  (** malformed chunked framing (Go's message) *)
  | Line_too_long  (** chunk line exceeded the limit (internal.ErrLineTooLong) *)
  | Trailer_too_large  (** suspiciously long trailer after a chunked body *)
  | Unexpected_eof  (** stream ended before the declared length *)
  | Protocol of string  (** other mid-stream protocol failure (message text) *)

val error_to_string : error -> string

type t = (string, error) result Seq.t

val empty : t

val of_string : string -> t
(** [of_string s] is the empty body when [s = ""], else a single [Ok s] chunk. *)

val of_stream : (unit -> string option) -> t
(** [of_stream next] is a streaming body whose chunks come from [next] until it
    returns [None] (io.EOF). [next] must not raise a framing error: every chunk
    is wrapped [Ok]. For a read-path thunk that signals a mid-stream failure,
    use {!of_stream_result}. *)

val of_stream_result : (unit -> (string, error) result option) -> t
(** [of_stream_result next] is a streaming body whose elements come from [next]:
    [Some (Ok s)] is a chunk, [Some (Error e)] is the terminal failure (the body
    ends after it), [None] is clean EOF. The adapter the read paths use to turn
    a raising framing thunk into a terminal [Error] element. *)

type stream = unit -> (string, error) result option

val to_stream : t -> stream
(** Adapt a body to a pull stream: each call forces the next element, [None] at
    EOF. The dual of {!of_stream_result}. *)

val of_seq : string Seq.t -> t
(** [of_seq s] wraps each plain chunk of [s] as [Ok]. *)

val to_seq : t -> t
(** The body as its underlying result-seq (the identity). *)

val of_flow : ?chunk:int -> _ Eio.Flow.source -> t
(** [of_flow src] is a streaming body that reads [src] in chunks (up to [chunk]
    bytes, default 64 KiB) until EOF. [src] must remain open for the body's
    lifetime — typically opened under the switch that will consume the body;
    [of_flow] neither owns nor closes it. *)

val of_lazy_string : string Lazy.t -> t
(** [of_lazy_string s] is a body whose single chunk is [Lazy.force s], forced on
    the first read (so the body is never materialized if it isn't read — e.g. a
    HEAD response or an abandoned write). *)

val append : t -> t -> t
(** [append b1 b2] yields all of [b1] then all of [b2], streaming. *)

val concat : t list -> t
(** [concat bs] yields every body in [bs] in order, streaming. Used to assemble
    a composite body (e.g. the file server's multipart/byteranges output)
    without materializing it. *)

val peek : t -> (string, error) result option * t
(** [peek b] forces the first element, returning it (or [None] at EOF) together
    with a body that re-reads it in full (the forced prefix is memoized, so the
    peek is non-destructive). Use only where a single forced look-ahead is
    acceptable. *)

val is_empty : t -> bool * t
(** [is_empty b] is whether [b] has no content (Go's [Body == nil]), forcing one
    element; the returned body re-reads in full (non-destructive). *)

val read_all : t -> (string, error) result
(** Read the entire body to a string, short-circuiting at the first [Error]. *)

val read_until : t -> int -> (string * t option, error) result
(** [read_until b max] reads the body until EOF or [max] bytes have been read.
    On success the first string is the read bytes, the second is the remainder
    of the body (if any). Short-circuits on a mid-stream [Error]. *)

val drain : ?limit:int -> t -> ([ `Drained | `Too_big ], error) result
(** [drain ?limit b] reads and discards the body until EOF, or until more than
    [limit] bytes have been read. [`Drained] (within [limit] when given)
    positions a kept-alive connection at the next message boundary and reads any
    chunked trailer; [`Too_big] if [limit] was given and more bytes remained;
    [Error] on a mid-stream framing failure. Without [limit] the whole body is
    consumed (always [`Drained] unless an [Error] occurs). *)

val iter : (string -> unit) -> t -> (unit, error) result
(** [iter f b] applies [f] to each successive [Ok] chunk in order until EOF,
    streaming without materializing, short-circuiting on the first [Error]. *)

val fold_left : ('a -> string -> 'a) -> t -> 'a -> ('a, error) result
(** [fold_left f b init] folds [f] over each successive [Ok] chunk in order until
    EOF, streaming, short-circuiting on the first [Error]. *)

val write : Eio.Buf_write.t -> t -> (unit, error) result
(** [write w b] writes the raw body bytes to [w] with no transfer framing,
    short-circuiting on a mid-stream [Error]. *)
