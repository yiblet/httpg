(* Port of go/src/net/http/internal/http2/frame.go: the Framer, FrameHeader,
   and all frame types. The byte-level encode/decode of each frame is a set of
   pure functions over strings/bytes; thin direct-style wrappers read/write
   through [Eio.Buf_read]/[Eio.Buf_write]. Composes {!H2}, {!H2_error} and
   {!Hpack}. *)

type frame_header = {
  length : int;  (** payload length, not including the 9-byte header *)
  typ : H2.frame_type;
  flags : int;
  stream_id : int;
}
(** The 9-byte header at the start of every HTTP/2 frame. Mirrors Go's
    [FrameHeader]. [stream_id] always has the reserved high bit masked off. *)

type priority_param = {
  stream_dep : int;
  exclusive : bool;
  weight : int;  (** zero-indexed weight *)
}
(** Stream prioritization parameters (RFC 7540). Mirrors the exported fields of
    Go's [PriorityParam]. *)

type data_frame = { data : string; end_stream : bool }
(** A parsed/owned DATA frame. [data] excludes any pad-length byte and padding
    suffix. Mirrors Go's [DataFrame]. *)

type headers_frame = {
  priority : priority_param option;  (** Some iff the PRIORITY flag is set *)
  header_frag : string;
  end_stream : bool;
  end_headers : bool;
}
(** A parsed HEADERS frame. [header_frag] is the header-block fragment with any
    padding stripped. Mirrors Go's [HeadersFrame]. *)

type priority_frame = { priority : priority_param }
(** Mirrors Go's [PriorityFrame]. *)

type rst_stream_frame = { error_code : H2_error.err_code }
(** Mirrors Go's [RSTStreamFrame]. *)

type settings_frame = { settings : H2.setting list; ack : bool }
(** Mirrors Go's [SettingsFrame]. [ack] is true for an empty SETTINGS ACK; then
    [settings] is empty. *)

val settings_has_duplicates : settings_frame -> bool
(** [settings_has_duplicates f] reports whether [f] contains any repeated
    setting ID. Mirrors Go's [SettingsFrame.HasDuplicates] (frame.go:832). *)

type push_promise_frame = {
  promise_id : int;
  header_frag : string;
  end_headers : bool;
}
(** Mirrors Go's [PushPromiseFrame] (parse path only). *)

type ping_frame = { data : string; ack : bool }
(** Mirrors Go's [PingFrame]. [data] is always exactly 8 bytes. *)

type goaway_frame = {
  last_stream_id : int;
  error_code : H2_error.err_code;
  debug_data : string;
}
(** Mirrors Go's [GoAwayFrame]. *)

type window_update_frame = { increment : int }
(** Mirrors Go's [WindowUpdateFrame]. [increment] never has the high bit set. *)

type continuation_frame = { header_frag : string; end_headers : bool }
(** Mirrors Go's [ContinuationFrame]. *)

type unknown_frame = { raw_type : int; payload : string }
(** Mirrors Go's [UnknownFrame] (and any frame type with no specific parser,
    e.g. PRIORITY_UPDATE). [raw_type] is the wire type byte. *)

(** A decoded frame: the header plus a per-type payload. Mirrors Go's [Frame]
    interface and its concrete implementations. *)
type frame =
  | Data of frame_header * data_frame
  | Headers of frame_header * headers_frame
  | Priority of frame_header * priority_frame
  | RST_stream of frame_header * rst_stream_frame
  | Settings of frame_header * settings_frame
  | Push_promise of frame_header * push_promise_frame
  | Ping of frame_header * ping_frame
  | GoAway of frame_header * goaway_frame
  | Window_update of frame_header * window_update_frame
  | Continuation of frame_header * continuation_frame
  | Unknown of frame_header * unknown_frame

val header_of_frame : frame -> frame_header
(** Returns the {!frame_header} of any frame. Mirrors Go's [Frame.Header]. *)

(* ---- errors (mirrors frame.go) ---- *)

exception Frame_too_large
(** Raised by {!write_data}/{!write_headers}/… for a frame larger than the
    24-bit length field permits. Mirrors Go's [ErrFrameTooLarge]. On the
    {b read} path this is surfaced as {!H2_error.Frame_too_large} via
    {!read_frame}'s [result]; on the {b write} path (frame builders) it remains
    a raise (a programmer/usage error — building an over-large frame). *)

exception Invalid_stream_id
(** Raised by the writers when given an invalid (zero / high-bit-set) stream ID
    without illegal writes enabled. Mirrors Go's [errStreamID]. A write-side
    invariant (kept as a raise). *)

exception Invalid_dep_stream_id
(** Mirrors Go's [errDepStreamID]. A write-side invariant (kept as a raise). *)

exception Pad_length_too_large
(** Mirrors Go's [errPadLength]. A write-side invariant (kept as a raise). *)

(* ---- reading ---- *)

val read_frame : ?max_size:int -> Eio.Buf_read.t -> (frame, H2_error.t) result
(** [read_frame ?max_size r] reads the next frame from [r]: the 9-byte header,
    then the payload, validating the length against [max_size] (default
    [H2.max_frame_size] = 2^24-1) and the per-type constraints. Returns [Error]
    with the unified {!H2_error.t} faithfully to Go's parsers (FRAME_SIZE_ERROR
    / PROTOCOL_ERROR on stream-id rules → [Connection _] / [Stream _]; a
    declared length over [max_size] → [Frame_too_large]). Strips padding for
    DATA/HEADERS. Mirrors Go's [Framer.ReadFrame]. A clean EOF (connection
    closed before/between frames) propagates as [End_of_file], mirroring Go's
    [io.EOF] return. *)

val max_frame_size : int
(** Maximum legal frame size (2^24 - 1). Mirrors Go's [maxFrameSize]. *)

(* ---- writers (each performs exactly one write to the channel) ---- *)

val write_data : ?pad:string -> Eio.Buf_write.t -> int -> bool -> string -> unit
(** Mirrors Go's [WriteData]/[WriteDataPadded]. [pad], if given, is appended
    verbatim and its length must be <= 255; passing [Some ""] sets the PADDED
    bit with zero padding. *)

val write_headers :
  Eio.Buf_write.t ->
  stream_id:int ->
  ?end_stream:bool ->
  ?end_headers:bool ->
  ?pad_length:int ->
  ?priority:priority_param ->
  string ->
  unit
(** Mirrors Go's [WriteHeaders] / [HeadersFrameParam]. *)

val write_rst_stream : Eio.Buf_write.t -> int -> H2_error.err_code -> unit
(** Mirrors Go's [WriteRSTStream]. *)

val write_settings : Eio.Buf_write.t -> H2.setting list -> unit
(** Mirrors Go's [WriteSettings] (ACK bit clear). *)

val write_settings_ack : Eio.Buf_write.t -> unit
(** Mirrors Go's [WriteSettingsAck]. *)

val write_ping : Eio.Buf_write.t -> bool -> string -> unit
(** Mirrors Go's [WritePing]. [data] must be exactly 8 bytes. *)

val write_goaway : Eio.Buf_write.t -> int -> H2_error.err_code -> string -> unit
(** Mirrors Go's [WriteGoAway]. *)

val write_window_update : Eio.Buf_write.t -> int -> int -> unit
(** Mirrors Go's [WriteWindowUpdate]; [incr] must be in 1..2^31-1. *)

val write_continuation : Eio.Buf_write.t -> int -> bool -> string -> unit
(** Mirrors Go's [WriteContinuation]. *)

val write_push_promise :
  Eio.Buf_write.t ->
  stream_id:int ->
  promise_id:int ->
  ?end_headers:bool ->
  ?pad_length:int ->
  string ->
  unit
(** Mirrors Go's [WritePushPromise] / [PushPromiseParam]. *)

val write_raw : Eio.Buf_write.t -> int -> int -> int -> string -> unit
(** Mirrors Go's [WriteRawFrame]: write an arbitrary frame type with the given
    flags, stream id and payload, with no validation. *)

(* ---- meta headers (HEADERS + CONTINUATION assembly) ---- *)

type meta_headers_frame = {
  fh : frame_header;  (** the originating HEADERS frame's header *)
  fields : Hpack.header_field list;
  truncated : bool;  (** the MAX_HEADER_LIST_SIZE limit was hit *)
}
(** The result of {!read_meta_headers}: the merged HEADERS+CONTINUATION block
    decoded into header fields. Mirrors Go's [MetaHeadersFrame]. *)

val read_meta_headers :
  ?max_size:int ->
  ?max_header_list_size:int ->
  Hpack.decoder ->
  frame_header * headers_frame ->
  Eio.Buf_read.t ->
  (meta_headers_frame, H2_error.t) result
(** [read_meta_headers ?max_size ?max_header_list_size dec hf ic] consumes the
    HEADERS frame [hf] (already read from [ic]) plus zero or more CONTINUATION
    frames until END_HEADERS, decoding the assembled block via [dec]
    ([Hpack.decoder]) into a header-field list. Enforces END_HEADERS continuity
    (a CONTINUATION must be on the same stream, no interleaving) per Go's
    [checkFrameOrder]/[readMetaFrame], validates pseudo-header ordering and
    field names/values, and returns [Error] with the unified {!H2_error.t}
    faithfully ([Connection _] / [Stream _], and [Compression e] wrapping the
    underlying {!Hpack.error} on a header-block decode failure). Mirrors Go's
    [Framer.readMetaFrame]. [max_header_list_size] caps the decoded header-list
    size and is also wired to the decoder's per-string cap via
    [Hpack.set_max_string_length] (Go's
    [SetMaxStringLength(maxHeaderStringLen())] where
    [maxHeaderStringLen() == maxHeaderListSize()], frame.go:1697-1722); it
    defaults to {!H2.default_max_header_bytes} ([1 lsl 20], Go's
    [DefaultMaxHeaderBytes]). A fragment more than twice the remaining budget,
    or a list exceeding the budget, is rejected as a connection [ProtocolError].
    A clean EOF (a CONTINUATION never arriving) propagates as [End_of_file]. *)

module Private : sig
  (** Helpers exposed only for the ported white-box tests; not part of the
      public API. *)

  val encode_frame_header : frame_header -> string
  (** [encode_frame_header h] renders the 9-byte frame header. Mirrors the
      header portion of Go's [startWrite]/[endWrite]. *)

  val decode_frame_header : string -> frame_header
  (** [decode_frame_header s] parses a 9-byte header from the first 9 bytes of
      [s] (masking the reserved stream-id high bit). Mirrors Go's
      [readFrameHeader]. *)

  val write_priority : Eio.Buf_write.t -> int -> priority_param -> unit
  (** Mirrors Go's [WritePriority]. *)
end
