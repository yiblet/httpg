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

(* Unified, handleable HTTP/2 error value surfaced at the public boundaries
   (H2_frame.read_frame / read_meta_headers). The internal per-connection event
   loop still drives GOAWAY/RST by raising the [Connection_error]/[Stream_error]
   exceptions (and the H2_frame frame-build exceptions); [to_exception]/[of_exception] bridge
   the two worlds so the loop is left untouched.

   The [Frame_too_large], [Invalid_stream_id], [Invalid_dep_stream_id] and
   [Pad_length_too_large] arms correspond to the same-named exceptions declared
   in {!H2_frame}; H2_frame's [read_frame] maps those (and the connection/stream
   exceptions) into [t] at its boundary, and [to_exception] maps them back via the
   bridge functions H2_frame installs. *)
type t =
  | Connection of err_code
  | Stream of stream_error
  | Frame_too_large
  | Invalid_stream_id
  | Invalid_dep_stream_id
  | Pad_length_too_large
  | Compression of Hpack.error

(* Carrier exception for an HPACK decode failure threaded through the raising
   parse path (mirrors Go wrapping a CompressionError). *)
exception Compression_error of Hpack.error

(* Bridge hooks for the frame-build invariant exceptions ([Frame_too_large],
   [Invalid_stream_id], [Invalid_dep_stream_id], [Pad_length_too_large]), which
   are owned by {!H2_frame}. To keep [to_exception]/[of_exception] cycle-free, H2_frame
   installs the conversions for those four arms at module init via
   [set_frame_bridge]. The connection / stream / compression arms are handled
   directly here. *)
let frame_to_exception : (t -> exn option) ref = ref (fun _ -> None)
let frame_of_exception : (exn -> t option) ref = ref (fun _ -> None)

let set_frame_bridge ~to_exception ~of_exception =
  frame_to_exception := to_exception;
  frame_of_exception := of_exception

let to_exception : t -> exn = function
  | Connection code -> Connection_error code
  | Stream se -> Stream_error se
  | Compression e -> Compression_error e
  | ( Frame_too_large | Invalid_stream_id | Invalid_dep_stream_id
    | Pad_length_too_large ) as t -> (
      match !frame_to_exception t with
      | Some e -> e
      | None -> Failure "H2_error.to_exception: frame bridge not installed")

let of_exception : exn -> t option = function
  | Connection_error code -> Some (Connection code)
  | Stream_error se -> Some (Stream se)
  | Compression_error e -> Some (Compression e)
  | e -> !frame_of_exception e
