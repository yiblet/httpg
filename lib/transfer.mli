(* Port of go/src/net/http/transfer.go and
   go/src/net/http/internal/chunked.go: HTTP/1.x wire framing. *)

(** Typed framing error. Returned as [Error] at the {b header / initial-parse}
    boundary (from {!read_transfer} and the {!Private} helpers); mid-stream, a
    framing failure discovered while pulling the {!Body.t} surfaces as a
    terminal {!Body.error} element of the body's result-seq (mapped from this
    type by the read path), never a raise. *)
type error =
  | Line_too_long
  | Chunk of string  (** malformed chunk / framing (Go's message) *)
  | Bad_content_length of string
      (** invalid / conflicting Content-Length value *)
  | Unsupported_transfer_encoding of string
  | Bad_header of string * string
      (** a forbidden header key in a context that rejects it (e.g. an invalid
          Trailer key), rendered as ["what: value"] *)
  | Unexpected_eof

val error_to_string : error -> string
(** Render an {!error} as its Go message text. *)

val max_line_length : int
(** [internal.maxLineLength] (4096). *)

(* --- Chunked codec (internal/chunked.go). --- *)

val parse_hex_uint : string -> (int64, error) result
(** [parseHexUint]: parse a hex chunk length. Returns [Error (Chunk _)] /
    [Error Line_too_long] on bad input (header/initial-parse boundary). *)

val new_chunked_reader : Eio.Buf_read.t -> unit -> (string, error) result option
(** [internal.NewChunkedReader]: a result-yielding pull function returning
    successive decoded chunk payloads ([Some (Ok data)]) and finally [None] at
    the terminating 0-length chunk. Malformed input surfaces as a terminal
    [Some (Error e)] element, never a raise. *)

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

val should_close :
  major:int ->
  minor:int ->
  header:Header.t ->
  remove_close_header:bool ->
  bool * Header.t
(** [shouldClose]: whether to hang up after the message, with the (possibly
    updated) header. Version-sensitive: HTTP/1.0 closes unless [keep-alive];
    HTTP/1.1 keeps alive unless [close]. [remove_close_header] drops a
    [Connection: close] from the returned header. *)

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
  streaming : bool;
      (** whether [body] is a live stream reader (vs a statically-empty body):
          the read paths interpose the chunked-trailer adapter only on a
          streaming body *)
  content_length : int64;
  is_chunked : bool;
  result_close : bool;
  trailer : Header.t option;
  header : Header.t;
      (** the message header after framing keys have been consumed *)
}
(** The decoded framing, the [transferReader] outputs unified back. *)

val read_transfer : message -> Eio.Buf_read.t -> (result, error) Stdlib.result
(** [read_transfer msg r] is [readTransfer]: parse framing from [r] and produce
    the body reader and derived fields.

    Header / initial-parse framing errors short-circuit as [Error error].
    {b Mid-stream policy:} the returned {!result.body} is a {!Body.t} whose
    stream surfaces a malformed body discovered {b after} this returned [Ok] as
    a terminal {!Body.error} element (typed data) — the faithful analogue of
    Go's later-[Read]-error model, never a raise. *)

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

val write_transfer_header :
  Eio.Buf_write.t -> transfer_writer -> (unit, error) Stdlib.result
(** [transferWriter.writeHeader]: write the Connection / Content-Length /
    Transfer-Encoding / Trailer header lines that derive from the sanitized
    field triple. Returns [Error (Bad_header _)] on an invalid Trailer key. *)

val has_token : string -> string -> bool
(** [has_token v token] is Go's [hasToken] (case-insensitive token search). *)

val write_body : Eio.Buf_write.t -> transfer_writer -> unit
(** [transferWriter.writeBody]: write the body (chunked, fixed content-length,
    or unknown-length) and any trailers. A ContentLength/body-length mismatch,
    or a mid-stream failure of the caller-supplied write-side body, is a caller
    contract violation and raises [Invalid_argument] (an unhandleable bug, per
    AGENTS.md rule 5 — not a modeled wire-read [error]). *)

module Private : sig
  (** Helpers exposed only for the ported white-box tests; not part of the
      public API. *)

  val parse_content_length : string list -> (int64, error) Stdlib.result
  (** [parseContentLength]: [Ok (-1L)] if unset, else the parsed value;
      [Error (Bad_content_length _)] on an invalid value. *)

  val fix_length :
    is_response:bool ->
    status:int ->
    request_method:Httpg_base.Method.t ->
    header:Header.t ->
    chunked:bool ->
    (int64 * Header.t, error) Stdlib.result
  (** [fixLength]: the expected body length per RFC 7230 3.3. Version-sensitive
      via [chunked]. Returns the length and the header with framing keys
      consumed (dedup / delete Content-Length), as Go does. [Error] on
      conflicting / invalid Content-Length (header-parse boundary). *)

  val fix_trailer :
    header:Header.t ->
    chunked:bool ->
    (Header.t option * Header.t, error) Stdlib.result
  (** [fixTrailer]: parse the [Trailer] header into a trailer header (keys with
      empty value lists), returning it and the header with [Trailer] deleted.
      [Ok (None, _)] when not chunked or no usable trailer.
      [Error (Bad_header _)] on a forbidden trailer key. *)

  val parse_transfer_encoding :
    major:int ->
    minor:int ->
    header:Header.t ->
    (bool * Header.t, error) Stdlib.result
  (** [parse_transfer_encoding]: returns whether the message is chunked and the
      header with Transfer-Encoding consumed. HTTP/1.0 ignores Transfer-Encoding
      (Issue 12785). [Error (Unsupported_transfer_encoding _)] /
      [Error (Chunk _)] for unsupported / too-many encodings. *)
end
