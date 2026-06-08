(* Port of the constant/setting block of
   go/src/net/http/internal/http2/http2.go and the frame type/flag
   constants from go/src/net/http/internal/http2/frame.go *)

let client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
let client_preface_len = String.length client_preface
let next_proto_tls = "h2"

type frame_type =
  | Data
  | Headers
  | Priority
  | RST_stream
  | Settings
  | Push_promise
  | Ping
  | Goaway
  | Window_update
  | Continuation

let frame_type_to_int = function
  | Data -> 0x0
  | Headers -> 0x1
  | Priority -> 0x2
  | RST_stream -> 0x3
  | Settings -> 0x4
  | Push_promise -> 0x5
  | Ping -> 0x6
  | Goaway -> 0x7
  | Window_update -> 0x8
  | Continuation -> 0x9

let frame_type_of_int = function
  | 0x0 -> Some Data
  | 0x1 -> Some Headers
  | 0x2 -> Some Priority
  | 0x3 -> Some RST_stream
  | 0x4 -> Some Settings
  | 0x5 -> Some Push_promise
  | 0x6 -> Some Ping
  | 0x7 -> Some Goaway
  | 0x8 -> Some Window_update
  | 0x9 -> Some Continuation
  | _ -> None

(* Mirrors Go's frameName map; unknown frame types fall back to the
   "UNKNOWN_FRAME_TYPE_%d" form. *)
let frame_type_string = function
  | Data -> "DATA"
  | Headers -> "HEADERS"
  | Priority -> "PRIORITY"
  | RST_stream -> "RST_STREAM"
  | Settings -> "SETTINGS"
  | Push_promise -> "PUSH_PROMISE"
  | Ping -> "PING"
  | Goaway -> "GOAWAY"
  | Window_update -> "WINDOW_UPDATE"
  | Continuation -> "CONTINUATION"

(* Frame flag bit values (see frame.go). *)
let flag_end_stream = 0x1
let flag_end_headers = 0x4
let flag_padded = 0x8
let flag_priority = 0x20
let flag_ack = 0x1

type setting_id =
  | Header_table_size
  | Enable_push
  | Max_concurrent_streams
  | Initial_window_size
  | Max_frame_size
  | Max_header_list_size

let setting_id_to_int = function
  | Header_table_size -> 0x1
  | Enable_push -> 0x2
  | Max_concurrent_streams -> 0x3
  | Initial_window_size -> 0x4
  | Max_frame_size -> 0x5
  | Max_header_list_size -> 0x6

let setting_id_of_int = function
  | 0x1 -> Some Header_table_size
  | 0x2 -> Some Enable_push
  | 0x3 -> Some Max_concurrent_streams
  | 0x4 -> Some Initial_window_size
  | 0x5 -> Some Max_frame_size
  | 0x6 -> Some Max_header_list_size
  | _ -> None

(* Mirrors Go's settingName map; unknown settings fall back to the
   "UNKNOWN_SETTING_%d" form. *)
let setting_id_string = function
  | Header_table_size -> "HEADER_TABLE_SIZE"
  | Enable_push -> "ENABLE_PUSH"
  | Max_concurrent_streams -> "MAX_CONCURRENT_STREAMS"
  | Initial_window_size -> "INITIAL_WINDOW_SIZE"
  | Max_frame_size -> "MAX_FRAME_SIZE"
  | Max_header_list_size -> "MAX_HEADER_LIST_SIZE"

let initial_window_size = 65535
let initial_max_frame_size = 16384
let initial_header_table_size = 4096
let default_max_read_frame_size = 1 lsl 20

(* Go: DefaultMaxHeaderBytes (server.go:497), the default for the server's
   advertised SETTINGS_MAX_HEADER_LIST_SIZE and the HPACK decode budget. *)
let default_max_header_bytes = 1 lsl 20

type setting = { id : setting_id; value : int32 }

module Private = struct
  let next_proto_tls = next_proto_tls
  let frame_type_string = frame_type_string
  let setting_id_string = setting_id_string
end
