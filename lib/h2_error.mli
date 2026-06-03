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
  | Unknown of int  (** error code outside the known set, carrying its raw value *)

(** Maps an [err_code] to its 32-bit wire value. *)
val err_code_to_int : err_code -> int

(** Maps a 32-bit wire value to an [err_code]; unknown values become
    [Unknown v]. *)
val err_code_of_int : int -> err_code

(** Mirrors Go's [(ErrCode).String]: the [errCodeName] map, falling back to
    ["unknown error code 0xN"] for unknown codes. *)
val err_code_string : err_code -> string

(** [ConnectionError] is an error that results in the termination of the entire
    connection. Mirrors Go's [ConnectionError]. *)
exception Connection_error of err_code

(** [StreamError] is an error that only affects one stream within an HTTP/2
    connection. Mirrors Go's [StreamError] struct. [cause] is optional
    additional detail. *)
type stream_error = { stream_id : int; code : err_code; cause : exn option }

exception Stream_error of stream_error

(** Mirrors Go's [streamError] constructor (no cause). *)
val stream_error : int -> err_code -> stream_error

(** Mirrors Go's [ConnectionError(code)] construction; returns the exception
    value. *)
val conn_error : err_code -> exn
