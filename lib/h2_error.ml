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

exception Connection_error of err_code

type stream_error = { stream_id : int; code : err_code; cause : exn option }

exception Stream_error of stream_error

let stream_error id code = { stream_id = id; code; cause = None }
let conn_error code = Connection_error code
