(* Port of go/src/net/http/internal/chunked.go: the "chunked" Transfer-Encoding
   wire protocol ([Httpg_internal.Chunked]; see net/http/internal). *)

exception Err_line_too_long
(** [internal.ErrLineTooLong]: a chunk line exceeded [max_line_length]. Raised
    {b mid-stream} from the reader thunk. *)

exception Chunk_error of string
(** A malformed-chunk / framing error carrying Go's message text. Raised
    {b mid-stream} from the reader thunk (see {!error}). *)

(** Handleable framing error at the {b header / initial-parse} boundary; the
    exceptions above are the {b mid-stream} analogue. *)
type error = Line_too_long | Chunk of string

val error_to_string : error -> string

val max_line_length : int
(** [internal.maxLineLength] (4096). *)

val parse_hex_uint : string -> (int64, error) result
(** [parseHexUint]: parse a hex chunk length; [Error (Chunk _)] on bad input. *)

val new_chunked_reader : Eio.Buf_read.t -> unit -> string option
(** [internal.NewChunkedReader]: a pull function returning successive decoded
    chunk payloads and finally [None] at the terminating 0-length chunk. Like
    Go's [chunkedReader] it does not consume the trailing CRLF / trailers.

    {b Mid-stream policy:} the thunk {b raises} {!Chunk_error} /
    {!Err_line_too_long} on malformed input discovered after init. *)

val chunked_writer_write : Eio.Buf_write.t -> string -> unit
(** [internal.chunkedWriter.Write]: write [data] as one chunk (hex-length CRLF
    data CRLF). Empty [data] writes nothing. *)

val chunked_writer_close : Eio.Buf_write.t -> unit
(** [internal.chunkedWriter.Close]: write the final ["0\r\n"] chunk. *)
