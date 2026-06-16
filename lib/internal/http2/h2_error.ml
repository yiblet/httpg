(* Port of go/src/net/http/internal/http2/errors.go *)

type err_code =
  | NoError
  | ProtocolError
  | InternalError
  | FlowControlError
  | SettingsTimeout
  | StreamClosed
  | FrameSizeError
  | RefusedStream
  | Cancel
  | CompressionError
  | ConnectError
  | EnhanceYourCalm
  | InadequateSecurity
  | HTTP11Required
  | Unknown of int

let err_code_to_int = function
  | NoError -> 0x0
  | ProtocolError -> 0x1
  | InternalError -> 0x2
  | FlowControlError -> 0x3
  | SettingsTimeout -> 0x4
  | StreamClosed -> 0x5
  | FrameSizeError -> 0x6
  | RefusedStream -> 0x7
  | Cancel -> 0x8
  | CompressionError -> 0x9
  | ConnectError -> 0xa
  | EnhanceYourCalm -> 0xb
  | InadequateSecurity -> 0xc
  | HTTP11Required -> 0xd
  | Unknown v -> v

let err_code_of_int = function
  | 0x0 -> NoError
  | 0x1 -> ProtocolError
  | 0x2 -> InternalError
  | 0x3 -> FlowControlError
  | 0x4 -> SettingsTimeout
  | 0x5 -> StreamClosed
  | 0x6 -> FrameSizeError
  | 0x7 -> RefusedStream
  | 0x8 -> Cancel
  | 0x9 -> CompressionError
  | 0xa -> ConnectError
  | 0xb -> EnhanceYourCalm
  | 0xc -> InadequateSecurity
  | 0xd -> HTTP11Required
  | v -> Unknown v

(* Mirrors Go's errCodeName map; unknown codes fall back to the
   "unknown error code 0x%x" form. *)
let err_code_string = function
  | NoError -> "NO_ERROR"
  | ProtocolError -> "PROTOCOL_ERROR"
  | InternalError -> "INTERNAL_ERROR"
  | FlowControlError -> "FLOW_CONTROL_ERROR"
  | SettingsTimeout -> "SETTINGS_TIMEOUT"
  | StreamClosed -> "STREAM_CLOSED"
  | FrameSizeError -> "FRAME_SIZE_ERROR"
  | RefusedStream -> "REFUSED_STREAM"
  | Cancel -> "CANCEL"
  | CompressionError -> "COMPRESSION_ERROR"
  | ConnectError -> "CONNECT_ERROR"
  | EnhanceYourCalm -> "ENHANCE_YOUR_CALM"
  | InadequateSecurity -> "INADEQUATE_SECURITY"
  | HTTP11Required -> "HTTP_1_1_REQUIRED"
  | Unknown v -> Printf.sprintf "unknown error code 0x%x" v

type stream_error = { stream_id : int; code : err_code; cause : exn option }

let stream_error id code = { stream_id = id; code; cause = None }

(* Unified, handleable HTTP/2 error value. It is produced and consumed purely as
   a [result]/value across the whole h2 stack: {!H2_frame}'s read boundaries
   ([read_frame]/[read_meta_headers]) and writers return it, the per-connection
   read loops dispatch the [Error] by value (GOAWAY for a connection error,
   RST_STREAM for a stream error), the server's [Read_error] event and the
   transport's reader-done channel carry the value, never an exception. There is
   no carrier exception and no exception<->value bridge: [t] is the single,
   typed h2 error.

   [Frame_too_large] is both a write-side build invariant (an over-large frame
   the writer refuses) and the read-side result for an over-large inbound frame
   (mirrors Go's [ErrFrameTooLarge]). [Invalid_stream_id],
   [Invalid_dep_stream_id] and [Pad_length_too_large] are write-side build
   invariants only. *)
type t =
  | Connection of err_code
  | Stream of stream_error
  | Frame_too_large
  | Invalid_stream_id
  | Invalid_dep_stream_id
  | Pad_length_too_large
  | Compression of Hpack.error

module Private = struct
  let err_code_string = err_code_string
end
