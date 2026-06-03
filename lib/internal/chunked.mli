(* Port of go/src/net/http/internal/chunked.go: the wire protocol for HTTP's
   "chunked" Transfer-Encoding. This is the private [internal] package analogue
   ([Gohttp_internal.Chunked]); see net/http/internal. *)

(** [internal.ErrLineTooLong]: a chunk header / line exceeded [max_line_length]. *)
exception Err_line_too_long

(** A malformed-chunk or framing error, carrying Go's message text (the various
    [errors.New(...)] values in chunked.go). *)
exception Chunk_error of string

(** [internal.maxLineLength] (4096). *)
val max_line_length : int

(** [parseHexUint]: parse a hex chunk length. Raises {!Chunk_error}. *)
val parse_hex_uint : string -> int64

(** [new_chunked_reader ic] is [internal.NewChunkedReader]: a pull function
    returning successive decoded chunk payloads and finally [None] at the
    terminating 0-length chunk. Like Go's [chunkedReader], it does not consume
    the trailing CRLF / trailers after the 0-chunk. Raises {!Chunk_error} /
    {!Err_line_too_long} on malformed input. *)
val new_chunked_reader : Lwt_io.input_channel -> unit -> string option Lwt.t

(** [chunked_writer_write oc data] is [internal.chunkedWriter.Write]: writes
    [data] as one chunk (hex-length CRLF data CRLF). Empty [data] writes nothing
    (it would look like EOF). *)
val chunked_writer_write : Lwt_io.output_channel -> string -> unit Lwt.t

(** [chunked_writer_close oc] is [internal.chunkedWriter.Close]: writes the
    final ["0\r\n"] chunk; it does not write the trailing CRLF after trailers. *)
val chunked_writer_close : Lwt_io.output_channel -> unit Lwt.t
