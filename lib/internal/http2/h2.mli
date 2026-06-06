(* Port of the constant/setting block of
   go/src/net/http/internal/http2/http2.go and the frame type/flag
   constants from go/src/net/http/internal/http2/frame.go *)

val client_preface : string
(** [client_preface] is the string that must be sent by new connections from
    clients. Mirrors Go's [ClientPreface]. *)

val client_preface_len : int
(** Length in bytes of {!client_preface}. *)

val next_proto_tls : string
(** [next_proto_tls] is the ALPN protocol negotiated during HTTP/2's TLS setup.
    Mirrors Go's [NextProtoTLS]. *)

(** A frame type, as defined in RFC 7540 section 6. Mirrors Go's [FrameType]. *)
type frame_type =
  | Data (* 0x0 *)
  | Headers (* 0x1 *)
  | Priority (* 0x2 *)
  | RST_stream (* 0x3 *)
  | Settings (* 0x4 *)
  | Push_promise (* 0x5 *)
  | Ping (* 0x6 *)
  | Goaway (* 0x7 *)
  | Window_update (* 0x8 *)
  | Continuation (* 0x9 *)

val frame_type_to_int : frame_type -> int
(** Maps a [frame_type] to its 8-bit wire value. *)

val frame_type_of_int : int -> frame_type option
(** Maps an 8-bit wire value to a [frame_type]; returns [None] for unknown
    types. *)

val frame_type_string : frame_type -> string
(** Mirrors Go's [frameName]; unknown types become ["UNKNOWN_FRAME_TYPE_N"]. *)

(* Frame flags. These are bit values that share a single byte; their meaning is
   per frame type, but the numeric values follow Go's [Flags] constants. *)

val flag_end_stream : int
(** END_STREAM (FlagDataEndStream / FlagHeadersEndStream). *)

val flag_end_headers : int
(** END_HEADERS (FlagHeadersEndHeaders / FlagContinuationEndHeaders). *)

val flag_padded : int
(** PADDED (FlagDataPadded / FlagHeadersPadded). *)

val flag_priority : int
(** PRIORITY (FlagHeadersPriority). *)

val flag_ack : int
(** ACK (FlagSettingsAck / FlagPingAck). *)

(** A setting identifier as defined in RFC 7540. Mirrors Go's [SettingID]. *)
type setting_id =
  | Header_table_size (* 0x1 *)
  | Enable_push (* 0x2 *)
  | Max_concurrent_streams (* 0x3 *)
  | Initial_window_size (* 0x4 *)
  | Max_frame_size (* 0x5 *)
  | Max_header_list_size (* 0x6 *)

val setting_id_to_int : setting_id -> int
(** Maps a [setting_id] to its 16-bit wire value. *)

val setting_id_of_int : int -> setting_id option
(** Maps a 16-bit wire value to a [setting_id]; returns [None] for unknown
    settings. *)

val setting_id_string : setting_id -> string
(** Mirrors Go's [settingName]; unknown settings become ["UNKNOWN_SETTING_N"].
*)

val initial_window_size : int
(** SETTINGS_INITIAL_WINDOW_SIZE default (6.9.2). Mirrors Go's
    [initialWindowSize]. *)

val initial_max_frame_size : int
(** SETTINGS_MAX_FRAME_SIZE default (6.5.2). Mirrors Go's [initialMaxFrameSize].
*)

val initial_header_table_size : int
(** SETTINGS_HEADER_TABLE_SIZE default. Mirrors Go's [initialHeaderTableSize].
*)

val default_max_read_frame_size : int
(** Default maximum read frame size. Mirrors Go's [defaultMaxReadFrameSize]. *)

val default_max_header_bytes : int
(** Default for the advertised SETTINGS_MAX_HEADER_LIST_SIZE and the HPACK
    decode budget ([1 lsl 20]). Mirrors Go's [DefaultMaxHeaderBytes]
    (server.go:497). *)

type setting = { id : setting_id; value : int32 }
(** A setting parameter: which setting it is, and its value. Mirrors Go's
    [Setting] struct. *)
