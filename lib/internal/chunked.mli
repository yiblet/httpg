(* Port of go/src/net/http/internal/chunked.go: the wire protocol for HTTP's
   "chunked" Transfer-Encoding. This is the private [internal] package analogue
   ([Gohttp_internal.Chunked]); see net/http/internal. *)

(** [internal.ErrLineTooLong]: a chunk header / line exceeded [max_line_length].
    Retained for the {b mid-stream} reader thunk (which keeps raising, per the
    Result-migration mid-stream policy) and for the [*_exn] shims. *)
exception Err_line_too_long

(** A malformed-chunk or framing error, carrying Go's message text (the various
    [errors.New(...)] values in chunked.go). Retained for the {b mid-stream}
    reader thunk and the [*_exn] shims (see {!error}). *)
exception Chunk_error of string

(** Handleable framing error at the {b header / initial-parse} boundary. The
    exceptions above are the {b mid-stream} analogue (raised from inside the
    {!new_chunked_reader} thunk after init has returned [Ok], mirroring Go's
    "a later [Read] returns an error"). *)
type error =
  | Line_too_long
  | Chunk of string

(** Render an {!error} as its Go message text. *)
val error_to_string : error -> string

(** [internal.maxLineLength] (4096). *)
val max_line_length : int

(** [parseHexUint]: parse a hex chunk length. Returns [Error (Chunk _)] on bad
    input (header/initial-parse boundary). *)
val parse_hex_uint : string -> (int64, error) result

(** Shim: {!parse_hex_uint} raising {!Chunk_error} (used by the mid-stream
    reader thunk and not-yet-migrated callers). *)
val parse_hex_uint_exn : string -> int64

(** [new_chunked_reader ic] is [internal.NewChunkedReader]: a pull function
    returning successive decoded chunk payloads and finally [None] at the
    terminating 0-length chunk. Like Go's [chunkedReader], it does not consume
    the trailing CRLF / trailers after the 0-chunk.

    {b Mid-stream policy:} the reader thunk {b raises} {!Chunk_error} /
    {!Err_line_too_long} on malformed input discovered after init (the faithful
    analogue of Go's later-[Read]-error). Only the initial-parse boundary
    surfaces {!error} (via {!parse_hex_uint}). *)
val new_chunked_reader : Lwt_io.input_channel -> unit -> string option Lwt.t

(** [chunked_writer_write oc data] is [internal.chunkedWriter.Write]: writes
    [data] as one chunk (hex-length CRLF data CRLF). Empty [data] writes nothing
    (it would look like EOF). *)
val chunked_writer_write : Lwt_io.output_channel -> string -> unit Lwt.t

(** [chunked_writer_close oc] is [internal.chunkedWriter.Close]: writes the
    final ["0\r\n"] chunk; it does not write the trailing CRLF after trailers. *)
val chunked_writer_close : Lwt_io.output_channel -> unit Lwt.t
