(* Port of go/src/net/http/transfer.go and
   go/src/net/http/internal/chunked.go: HTTP/1.x wire framing. *)

exception Err_line_too_long
(** internal.ErrLineTooLong: a chunk header / line exceeded [max_line_length].
    Retained for the {b mid-stream} body thunk (which keeps raising on a framing
    error discovered after {!read_transfer} returned [Ok]); the handleable
    boundary error is {!error} below. *)

exception Chunk_error of string
(** A malformed-chunk or framing error, carrying Go's message text. Retained for
    the {b mid-stream} body thunk (see {!error}). *)

exception Bad_string_error of string * string
(** [badStringError(what, value)]: rendered as ["what: value"]. Retained for the
    {b mid-stream} trailer-read raise in {!read_transfer} (see {!error}). *)

(** Handleable framing error at the {b header / initial-parse} boundary
    (Result-migration Ticket 4). The exceptions above are the {b mid-stream}
    analogue: errors discovered inside a {!Body.t} [Stream] thunk {b after}
    {!read_transfer} returned [Ok] keep {b raising} (the faithful analogue of
    Go's "a later [Read] returns an error" — see {!read_transfer}). Only the
    initial-parse boundary returns [result]. *)
type error =
  | Line_too_long
  | Chunk of string  (** from {!Chunk_error} (malformed chunk / framing) *)
  | Bad_content_length of string
      (** invalid / conflicting Content-Length value *)
  | Unsupported_transfer_encoding of string
  | Bad_header of string * string  (** was [Bad_string_error (what, value)] *)
  | Unexpected_eof

val error_to_string : error -> string
(** Render an {!error} as its Go message text. *)

val max_line_length : int
(** [internal.maxLineLength] (4096). *)

(* --- Chunked codec (internal/chunked.go). --- *)

val parse_hex_uint : string -> (int64, error) result
(** [parseHexUint]: parse a hex chunk length. Returns [Error (Chunk _)] /
    [Error Line_too_long] on bad input (header/initial-parse boundary). *)

val new_chunked_reader : Eio.Buf_read.t -> unit -> string option
(** [internal.NewChunkedReader]: a pull function returning successive decoded
    chunk payloads and finally [None] at the terminating 0-length chunk. Raises
    {!Chunk_error} / {!Err_line_too_long} on malformed input. *)

val chunked_writer_write : Eio.Buf_write.t -> string -> unit
(** [internal.chunkedWriter.Write]: write [data] as one chunk. Empty [data]
    writes nothing. *)

val chunked_writer_close : Eio.Buf_write.t -> unit
(** [internal.chunkedWriter.Close]: write the final ["0\r\n"] chunk. *)

(* --- transfer.go helpers. --- *)

val chunked : string list -> bool
(** [chunked te]: is ["chunked"] the first transfer encoding? *)

val is_identity : string list -> bool
(** [is_identity te]: is [te] exactly [["identity"]]? *)

val no_response_body_expected : Httpg_base.Method.t -> bool
(** [noResponseBodyExpected]: true iff the request method is [Head]. *)

val body_allowed_for_status : int -> bool
(** [bodyAllowedForStatus] (RFC 7230 3.3): 1xx, 204 and 304 forbid a body. *)

val parse_content_length : string list -> (int64, error) result
(** [parseContentLength]: [Ok (-1L)] if unset, else the parsed value;
    [Error (Bad_content_length _)] on an invalid value. *)

val fix_length :
  is_response:bool ->
  status:int ->
  request_method:Httpg_base.Method.t ->
  header:Header.t ->
  chunked:bool ->
  (int64, error) result
(** [fixLength]: the expected body length per RFC 7230 3.3. Version-sensitive
    via [chunked]. Mutates [header] (dedup / delete Content-Length) as Go does.
    [Error] on conflicting / invalid Content-Length (header-parse boundary). *)

val should_close :
  major:int -> minor:int -> header:Header.t -> remove_close_header:bool -> bool
(** [shouldClose]: whether to hang up after the message. Version-sensitive:
    HTTP/1.0 closes unless [keep-alive]; HTTP/1.1 keeps alive unless [close].
    [remove_close_header] mutates [header] to drop a [Connection: close]. *)

val fix_trailer :
  header:Header.t -> chunked:bool -> (Header.t option, error) result
(** [fixTrailer]: parse the [Trailer] header into a trailer header (keys with
    empty value lists). Returns [Ok None] when not chunked or no usable trailer.
    Mutates [header] (deletes [Trailer]). [Error (Bad_header _)] on a forbidden
    trailer key. *)

val parse_transfer_encoding :
  major:int -> minor:int -> header:Header.t -> (bool, error) result
(** [parse_transfer_encoding]: returns whether the message is chunked. HTTP/1.0
    ignores Transfer-Encoding (Issue 12785). Mutates [header] (deletes
    Transfer-Encoding). [Error (Unsupported_transfer_encoding _)] /
    [Error (Chunk _)] for unsupported / too-many encodings. *)

(* --- read_transfer. --- *)

type message = {
  is_response : bool;
  header : Header.t;
  status_code : Httpg_base.Status.t;
  request_method : Httpg_base.Method.t;
  proto : Httpg_base.Protocol.t;
  close : bool;
}
(** The subset of *Request / *Response fields driving transfer reading,
    mirroring Go's [transferReader] inputs. [header] is mutated in place. *)

type result = {
  body : Body.t;
  content_length : int64;
  is_chunked : bool;
  result_close : bool;
  trailer : Header.t option;
}
(** The decoded framing, the [transferReader] outputs unified back. *)

val read_transfer : message -> Eio.Buf_read.t -> (result, error) Stdlib.result
(** [read_transfer msg r] is [readTransfer]: parse framing from [r] and produce
    the body reader and derived fields.

    Header / initial-parse framing errors short-circuit as [Error error].
    {b Mid-stream policy (Resolution #1):} the returned {!result.body}, a
    {!Body.t} [Stream], {b raises} {!Chunk_error} / {!Err_line_too_long} on a
    malformed body discovered {b after} this returned [Ok] — the faithful
    analogue of Go's later-[Read]-error model. *)

(* --- write_body. --- *)

type transfer_writer = {
  tw_method : Httpg_base.Method.t;
  mutable tw_body : Body.t;
  tw_response_to_head : bool;
  mutable tw_content_length : int64;
  mutable tw_transfer_encoding : string list;
  tw_trailer : Header.t option;
  tw_is_response : bool;
  tw_at_least_http11 : bool;
  tw_close : bool;  (** mirrors transferWriter.Close *)
  tw_header : Header.t;  (** the message Header (for the Connection check) *)
}
(** The sanitized writer triple, mirroring the body-writing subset of
    [transferWriter]. *)

val make_transfer_writer :
  ?is_response:bool ->
  ?method_:Httpg_base.Method.t ->
  ?response_to_head:bool ->
  ?trailer:Header.t option ->
  ?at_least_http11:bool ->
  ?close:bool ->
  ?header:Header.t ->
  body:Body.t ->
  content_length:int64 ->
  transfer_encoding:string list ->
  unit ->
  transfer_writer
(** [make_transfer_writer ...] is [newTransferWriter]'s sanitization of the
    (Body, ContentLength, TransferEncoding) triple (the pure part; no
    probeRequestBody async byte-sniffing). *)

val should_send_content_length : transfer_writer -> bool
(** [should_send_content_length t] is [transferWriter.shouldSendContentLength].
*)

val write_transfer_header : Eio.Buf_write.t -> transfer_writer -> unit
(** [transferWriter.writeHeader]: write the Connection / Content-Length /
    Transfer-Encoding / Trailer header lines that derive from the sanitized
    field triple. Raises {!Bad_string_error} on an invalid Trailer key. *)

val has_token : string -> string -> bool
(** [has_token v token] is Go's [hasToken] (case-insensitive token search). *)

val write_body : Eio.Buf_write.t -> transfer_writer -> unit
(** [transferWriter.writeBody]: write the body (chunked, fixed content-length,
    or unknown-length) and any trailers. Raises {!Chunk_error} on a
    ContentLength/body-length mismatch. *)
