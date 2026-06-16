(* Port of go/src/net/http/internal/chunked.go: the "chunked" Transfer-Encoding
   wire protocol ([Httpg_internal.Chunked]; see net/http/internal). *)

(** Typed framing error. Used at the {b header / initial-parse} boundary
    ([parse_hex_uint]) and {b mid-stream}: a malformed chunk discovered while
    pulling becomes an [Error] element of {!new_chunked_reader}'s result-seq,
    never a raise. *)
type error = Line_too_long | Chunk of string

val error_to_string : error -> string

val max_line_length : int
(** [internal.maxLineLength] (4096). *)

val parse_hex_uint : string -> (int64, error) result
(** [parseHexUint]: parse a hex chunk length; [Error (Chunk _)] on bad input. *)

val new_chunked_reader : Eio.Buf_read.t -> unit -> (string, error) result option
(** [internal.NewChunkedReader]: a result-yielding pull function returning
    successive decoded chunk payloads ([Some (Ok data)]) and finally [None] at
    the terminating 0-length chunk. Like Go's [chunkedReader] it does not
    consume the trailing CRLF / trailers.

    {b Mid-stream policy:} malformed input discovered after init surfaces as a
    terminal [Some (Error e)] element (the faithful analogue of Go's "a later
    [Read] returns an error"), never a raise. *)

val chunked_writer_write : Eio.Buf_write.t -> string -> unit
(** [internal.chunkedWriter.Write]: write [data] as one chunk (hex-length CRLF
    data CRLF). Empty [data] writes nothing. *)

val chunked_writer_close : Eio.Buf_write.t -> unit
(** [internal.chunkedWriter.Close]: write the final ["0\r\n"] chunk. *)
