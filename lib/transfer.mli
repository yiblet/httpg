(* Port of go/src/net/http/transfer.go and
   go/src/net/http/internal/chunked.go: HTTP/1.x wire framing. *)

(** internal.ErrLineTooLong: a chunk header / line exceeded [max_line_length]. *)
exception Err_line_too_long

(** A malformed-chunk or framing error, carrying Go's message text. *)
exception Chunk_error of string

(** [badStringError(what, value)]: rendered as ["what: value"]. *)
exception Bad_string_error of string * string

(** [internal.maxLineLength] (4096). *)
val max_line_length : int

(* --- Chunked codec (internal/chunked.go). --- *)

(** [parseHexUint]: parse a hex chunk length. Raises {!Chunk_error}. *)
val parse_hex_uint : string -> int64

(** [new_chunked_reader ic] is [internal.NewChunkedReader]: a pull function
    returning successive decoded chunk payloads and finally [None] at the
    terminating 0-length chunk. Raises {!Chunk_error} / {!Err_line_too_long} on
    malformed input. *)
val new_chunked_reader : Lwt_io.input_channel -> unit -> string option Lwt.t

(** [chunked_writer_write oc data] writes [data] as one chunk
    (hex-length CRLF data CRLF). Empty [data] writes nothing (it would look like
    EOF). Mirrors [internal.chunkedWriter.Write]. *)
val chunked_writer_write : Lwt_io.output_channel -> string -> unit Lwt.t

(** [chunked_writer_close oc] writes the final ["0\r\n"] chunk
    ([internal.chunkedWriter.Close]); it does not write the trailing CRLF after
    trailers. *)
val chunked_writer_close : Lwt_io.output_channel -> unit Lwt.t

(* --- transfer.go helpers. --- *)

(** [chunked te]: is ["chunked"] the first transfer encoding? *)
val chunked : string list -> bool

(** [is_identity te]: is [te] exactly [["identity"]]? *)
val is_identity : string list -> bool

(** [noResponseBodyExpected]: true iff the request method is ["HEAD"]. *)
val no_response_body_expected : string -> bool

(** [bodyAllowedForStatus] (RFC 7230 3.3): 1xx, 204 and 304 forbid a body. *)
val body_allowed_for_status : int -> bool

(** [parseContentLength]: [-1] if unset, else the parsed value. Raises
    {!Bad_string_error} on an invalid value. *)
val parse_content_length : string list -> int64

(** [fixLength]: the expected body length per RFC 7230 3.3. Version-sensitive
    via [chunked]. Mutates [header] (dedup / delete Content-Length) as Go does. *)
val fix_length :
  is_response:bool ->
  status:int ->
  request_method:string ->
  header:Header.t ->
  chunked:bool ->
  int64

(** [shouldClose]: whether to hang up after the message. Version-sensitive:
    HTTP/1.0 closes unless [keep-alive]; HTTP/1.1 keeps alive unless [close].
    [remove_close_header] mutates [header] to drop a [Connection: close]. *)
val should_close :
  major:int -> minor:int -> header:Header.t -> remove_close_header:bool -> bool

(** [fixTrailer]: parse the [Trailer] header into a trailer header (keys with
    empty value lists). Returns [None] when not chunked or no usable trailer.
    Mutates [header] (deletes [Trailer]). Raises {!Bad_string_error} on a bad
    trailer key. *)
val fix_trailer : header:Header.t -> chunked:bool -> Header.t option

(** [parse_transfer_encoding]: returns whether the message is chunked.
    HTTP/1.0 ignores Transfer-Encoding (Issue 12785). Mutates [header] (deletes
    Transfer-Encoding). Raises {!Chunk_error} for unsupported encodings. *)
val parse_transfer_encoding : major:int -> minor:int -> header:Header.t -> bool

(* --- read_transfer. --- *)

(** The subset of *Request / *Response fields driving transfer reading,
    mirroring Go's [transferReader] inputs. [header] is mutated in place. *)
type message = {
  is_response : bool;
  header : Header.t;
  status_code : int;
  request_method : string;
  proto_major : int;
  proto_minor : int;
  close : bool;
}

(** The decoded framing, the [transferReader] outputs unified back. *)
type result = {
  body : Body.t;
  content_length : int64;
  is_chunked : bool;
  result_close : bool;
  trailer : Header.t option;
}

(** [read_transfer msg ic] is [readTransfer]: parse framing from [ic] and
    produce the body reader and derived fields. *)
val read_transfer : message -> Lwt_io.input_channel -> result Lwt.t

(* --- write_body. --- *)

(** The sanitized writer triple, mirroring the body-writing subset of
    [transferWriter]. *)
type transfer_writer = {
  tw_method : string;
  mutable tw_body : Body.t;
  tw_response_to_head : bool;
  mutable tw_content_length : int64;
  mutable tw_transfer_encoding : string list;
  tw_trailer : Header.t option;
  tw_is_response : bool;
  tw_at_least_http11 : bool;
}

(** [make_transfer_writer ...] is [newTransferWriter]'s sanitization of the
    (Body, ContentLength, TransferEncoding) triple (the pure part; no
    probeRequestBody async byte-sniffing). *)
val make_transfer_writer :
  ?is_response:bool ->
  ?method_:string ->
  ?response_to_head:bool ->
  ?trailer:Header.t option ->
  ?at_least_http11:bool ->
  body:Body.t ->
  content_length:int64 ->
  transfer_encoding:string list ->
  unit ->
  transfer_writer

(** [write_body oc t] is [transferWriter.writeBody]: write the body (chunked,
    fixed content-length, or unknown-length) and any trailers to [oc]. Raises
    {!Chunk_error} on a ContentLength/body-length mismatch. *)
val write_body : Lwt_io.output_channel -> transfer_writer -> unit Lwt.t
