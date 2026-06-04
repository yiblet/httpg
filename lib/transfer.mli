(* Port of go/src/net/http/transfer.go and
   go/src/net/http/internal/chunked.go: HTTP/1.x wire framing. *)

(** internal.ErrLineTooLong: a chunk header / line exceeded [max_line_length].
    Retained for the {b mid-stream} body thunk (which keeps raising on a framing
    error discovered after {!read_transfer} returned [Ok]); the handleable
    boundary error is {!error} below. *)
exception Err_line_too_long

(** A malformed-chunk or framing error, carrying Go's message text. Retained for
    the {b mid-stream} body thunk (see {!error}). *)
exception Chunk_error of string

(** [badStringError(what, value)]: rendered as ["what: value"]. Retained for the
    {b mid-stream} trailer-read raise in {!read_transfer} (see {!error}). *)
exception Bad_string_error of string * string

(** Handleable framing error at the {b header / initial-parse} boundary
    (Result-migration Ticket 4). The exceptions above are the {b mid-stream}
    analogue: errors discovered inside a {!Body.t} [Stream] thunk {b after}
    {!read_transfer} returned [Ok] keep {b raising} (the faithful analogue of
    Go's "a later [Read] returns an error" — see {!read_transfer}). Only the
    initial-parse boundary returns [result]. *)
type error =
  | Line_too_long
  | Chunk of string  (** from {!Chunk_error} (malformed chunk / framing) *)
  | Bad_content_length of string  (** invalid / conflicting Content-Length value *)
  | Unsupported_transfer_encoding of string
  | Bad_header of string * string  (** was [Bad_string_error (what, value)] *)
  | Unexpected_eof

(** Render an {!error} as its Go message text. *)
val error_to_string : error -> string

(** [internal.maxLineLength] (4096). *)
val max_line_length : int

(* --- Chunked codec (internal/chunked.go). --- *)

(** [parseHexUint]: parse a hex chunk length. Returns [Error (Chunk _)] /
    [Error Line_too_long] on bad input (header/initial-parse boundary). *)
val parse_hex_uint : string -> (int64, error) result

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

(** [parseContentLength]: [Ok (-1L)] if unset, else the parsed value;
    [Error (Bad_content_length _)] on an invalid value. *)
val parse_content_length : string list -> (int64, error) result

(** [fixLength]: the expected body length per RFC 7230 3.3. Version-sensitive
    via [chunked]. Mutates [header] (dedup / delete Content-Length) as Go does.
    [Error] on conflicting / invalid Content-Length (header-parse boundary). *)
val fix_length :
  is_response:bool ->
  status:int ->
  request_method:string ->
  header:Header.t ->
  chunked:bool ->
  (int64, error) result

(** [shouldClose]: whether to hang up after the message. Version-sensitive:
    HTTP/1.0 closes unless [keep-alive]; HTTP/1.1 keeps alive unless [close].
    [remove_close_header] mutates [header] to drop a [Connection: close]. *)
val should_close :
  major:int -> minor:int -> header:Header.t -> remove_close_header:bool -> bool

(** [fixTrailer]: parse the [Trailer] header into a trailer header (keys with
    empty value lists). Returns [Ok None] when not chunked or no usable trailer.
    Mutates [header] (deletes [Trailer]). [Error (Bad_header _)] on a forbidden
    trailer key. *)
val fix_trailer : header:Header.t -> chunked:bool -> (Header.t option, error) result

(** [parse_transfer_encoding]: returns whether the message is chunked.
    HTTP/1.0 ignores Transfer-Encoding (Issue 12785). Mutates [header] (deletes
    Transfer-Encoding). [Error (Unsupported_transfer_encoding _)] /
    [Error (Chunk _)] for unsupported / too-many encodings. *)
val parse_transfer_encoding : major:int -> minor:int -> header:Header.t -> (bool, error) result

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
    produce the body reader and derived fields.

    Header / initial-parse framing errors short-circuit as
    [Error error]. {b Mid-stream policy (Resolution #1):} the returned
    {!result.body}, a {!Body.t} [Stream], {b raises} {!Chunk_error} /
    {!Err_line_too_long} on a malformed body discovered {b after} this returned
    [Ok] — the faithful analogue of Go's later-[Read]-error model. Only this
    boundary returns [result]; the stream thunk is {b not} result-ified. *)
val read_transfer :
  message -> Lwt_io.input_channel -> (result, error) Stdlib.result Lwt.t

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
  tw_close : bool;  (** mirrors transferWriter.Close *)
  tw_header : Header.t;  (** the message Header (for the Connection check) *)
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
  ?close:bool ->
  ?header:Header.t ->
  body:Body.t ->
  content_length:int64 ->
  transfer_encoding:string list ->
  unit ->
  transfer_writer

(** [should_send_content_length t] is [transferWriter.shouldSendContentLength]. *)
val should_send_content_length : transfer_writer -> bool

(** [write_transfer_header oc t] is [transferWriter.writeHeader]: write the
    Connection / Content-Length / Transfer-Encoding / Trailer header lines that
    derive from the sanitized field triple. Raises {!Bad_string_error} on an
    invalid Trailer key. *)
val write_transfer_header : Lwt_io.output_channel -> transfer_writer -> unit Lwt.t

(** [has_token v token] is Go's [hasToken] (case-insensitive token search). *)
val has_token : string -> string -> bool

(** [write_body oc t] is [transferWriter.writeBody]: write the body (chunked,
    fixed content-length, or unknown-length) and any trailers to [oc]. Raises
    {!Chunk_error} on a ContentLength/body-length mismatch. *)
val write_body : Lwt_io.output_channel -> transfer_writer -> unit Lwt.t
