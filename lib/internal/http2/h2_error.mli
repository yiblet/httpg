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

(** Unified, handleable HTTP/2 error value surfaced at the public boundaries
    ({!H2_frame.read_frame} / {!H2_frame.read_meta_headers}). The internal
    per-connection event loop continues to drive GOAWAY/RST by raising the
    {!Connection_error}/{!Stream_error} exceptions (and the {!H2_frame}
    frame-build exceptions); {!to_exception}/{!of_exception} bridge between the [result]
    boundary and the raising loop so the loop's machinery is left untouched
    (Result-migration Resolution #2 — boundary-only). *)
type t =
  | Connection of err_code
  | Stream of stream_error
  | Frame_too_large
  | Invalid_stream_id
  | Invalid_dep_stream_id
  | Pad_length_too_large
  | Compression of Hpack.error

(** Carrier exception for an HPACK ({!Hpack.error}) decode failure threaded
    through the raising parse path. *)
exception Compression_error of Hpack.error

(** Installs the {!H2_frame}-owned conversions for the [Frame_too_large] /
    [Invalid_stream_id] / [Invalid_dep_stream_id] / [Pad_length_too_large] arms.
    Called once at {!H2_frame} module init; keeps {!to_exception}/{!of_exception} cycle-free.
    Not for general use. *)
val set_frame_bridge :
  to_exception:(t -> exn option) -> of_exception:(exn -> t option) -> unit

(** [to_exception t] is the exception the internal event loop raises to drive
    GOAWAY/RST/stream-abort for the error [t]. *)
val to_exception : t -> exn

(** [of_exception e] recognizes the exceptions the internal raising paths use and maps
    them to a unified {!t}; [None] for an exception that is not an HTTP/2
    boundary error. *)
val of_exception : exn -> t option
