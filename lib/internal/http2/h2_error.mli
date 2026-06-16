(* Port of go/src/net/http/internal/http2/errors.go *)

(** An [err_code] is an unsigned 32-bit error code as defined in the HTTP/2
    spec. Mirrors Go's [ErrCode]. *)
type err_code =
  | NoError (* 0x0 *)
  | ProtocolError (* 0x1 *)
  | InternalError (* 0x2 *)
  | FlowControlError (* 0x3 *)
  | SettingsTimeout (* 0x4 *)
  | StreamClosed (* 0x5 *)
  | FrameSizeError (* 0x6 *)
  | RefusedStream (* 0x7 *)
  | Cancel (* 0x8 *)
  | CompressionError (* 0x9 *)
  | ConnectError (* 0xa *)
  | EnhanceYourCalm (* 0xb *)
  | InadequateSecurity (* 0xc *)
  | HTTP11Required (* 0xd *)
  | Unknown of int
      (** error code outside the known set, carrying its raw value *)

val err_code_to_int : err_code -> int
(** Maps an [err_code] to its 32-bit wire value. *)

val err_code_of_int : int -> err_code
(** Maps a 32-bit wire value to an [err_code]; unknown values become
    [Unknown v]. *)

type stream_error = { stream_id : int; code : err_code; cause : exn option }
(** [StreamError] is an error that only affects one stream within an HTTP/2
    connection. Mirrors Go's [StreamError] struct. [cause] is optional
    additional detail. *)

val stream_error : int -> err_code -> stream_error
(** Mirrors Go's [streamError] constructor (no cause). *)

(** Unified, handleable HTTP/2 error value. It is produced and consumed purely
    as a [result]/value across the whole h2 stack — there is no carrier
    exception and no exception<->value bridge: {!t} is the single typed h2
    error.

    The {!H2_frame} read boundaries ({!H2_frame.read_frame} /
    {!H2_frame.read_meta_headers}) and writers return it; the per-connection
    read loops dispatch the [Error] by value (GOAWAY for a {!Connection} error,
    RST_STREAM for a {!Stream} error); the server's [Read_error] event and the
    transport's reader-done channel carry the value.

    [Frame_too_large] is both a write-side build invariant and the read-side
    result for an over-large inbound frame (mirrors Go's [ErrFrameTooLarge]).
    [Invalid_stream_id], [Invalid_dep_stream_id] and [Pad_length_too_large] are
    write-side build invariants only. *)
type t =
  | Connection of err_code
  | Stream of stream_error
  | Frame_too_large
  | Invalid_stream_id
  | Invalid_dep_stream_id
  | Pad_length_too_large
  | Compression of Hpack.error

module Private : sig
  (** Helpers exposed only for the ported white-box tests; not part of the
      public API. *)

  val err_code_string : err_code -> string
  (** Mirrors Go's [(ErrCode).String]: the [errCodeName] map, falling back to
      ["unknown error code 0xN"] for unknown codes. *)
end
