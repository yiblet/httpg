(* Port of go/src/net/http/internal/http2/write.go: the [writeFramer] frame
   writer values (the concrete types implementing Go's [writeFramer]
   interface) plus the function that serializes a writer to the wire via the
   Ticket-4 {!H2_frame} writers. Composes {!H2}, {!H2_frame}, {!H2_error},
   {!Header}, {!Hpack}.

   Go represents each writer as a distinct struct implementing [writeFramer];
   here they are the constructors of a single {!write_framer} variant. The
   serialization (Go's [writeFrame] method) is the {!write_frame} function. *)

type write_res_headers = {
  rh_stream_id : int;
  http_res_code : int;
  h : Api.Header.t;
  trailers : string list option;
  rh_end_stream : bool;
  date : string;
  content_type : string;
  content_length : string;
}
(** A request to write a set of HTTP response headers or trailers, mirroring
    Go's [writeResHeaders] struct. [http_res_code] = 0 means no [:status] line.
    [trailers] = [Some keys] selects which keys of [h] to write (Go's
    [trailers []string]); [None] means write all. *)

type write_push_promise = {
  pp_stream_id : int;
  pp_promised_id : int;
  pp_method : Httpg_base.Method.t;
  pp_scheme : string;
  pp_authority : string;
  pp_path : string;
  pp_h : Api.Header.t;
}
(** A request to write a PUSH_PROMISE (+CONTINUATION) frame, mirroring Go's
    [writePushPromise]. The promised stream id is resolved before scheduling
    (Go's [allocatePromisedID] runs on the serve goroutine), so here it is a
    plain field. *)

(** The concrete frame-writer values. Each constructor mirrors a Go type that
    implements the [writeFramer] interface in write.go. *)
type write_framer =
  | Write_settings of H2.setting list  (** Go [writeSettings] *)
  | Write_settings_ack  (** Go [writeSettingsAck] *)
  | Write_goaway of { max_stream_id : int; code : H2_error.err_code }
      (** Go [writeGoAway] *)
  | Write_data of { stream_id : int; data : string; end_stream : bool }
      (** Go [writeData] *)
  | Write_handler_panic_rst of int  (** Go [handlerPanicRST]; the stream id *)
  | Write_rst_stream of { stream_id : int; code : H2_error.err_code }
      (** Go's [StreamError] used as a writeFramer (resetStream path) *)
  | Write_ping of string  (** Go [writePing]; 8 bytes of opaque data *)
  | Write_ping_ack of string  (** Go [writePingAck]; echoes the 8 ping bytes *)
  | Write_window_update of { stream_id : int; n : int }
      (** Go [writeWindowUpdate]; [stream_id] = 0 for conn-level *)
  | Write_res_headers of write_res_headers  (** Go [writeResHeaders] *)
  | Write_push_promise of write_push_promise  (** Go [writePushPromise] *)
  | Write_100_continue of int
      (** Go [write100ContinueHeadersFrame]; the stream id *)

val write_ends_stream : write_framer -> bool
(** [write_ends_stream w] reports whether [w] writes a frame that transitions
    the stream to half-closed (local). False for RST_STREAM (which closes the
    whole stream). Mirrors Go's [writeEndsStream]. *)

val data_size : write_framer -> int
(** [data_size w] is the number of flow-control bytes consumed to write [w],
    which is 0 for non-DATA frames. Mirrors the [len(wd.p)] used by Go's
    [FrameWriteRequest.DataSize]/[Consume]. *)

val httpcode_string : int -> string
(** [httpcode_string code] mirrors Go's [httpCodeString]. *)

val encode_headers : Hpack.encoder -> Api.Header.t -> string list option -> unit
(** [encode_headers enc h keys] encodes the header map [h] into the HPACK
    encoder [enc], in sorted-key order (or, if [keys = Some ks], only those
    keys, in the given order). Lower-cases names, skips non-ASCII / invalid
    names and values, and only emits [transfer-encoding: trailers]. Mirrors Go's
    [encodeHeaders]. *)

val write_frame :
  enc:Hpack.encoder ->
  Eio.Buf_write.t ->
  write_framer ->
  (unit, H2_error.t) result
(** [write_frame ~enc oc w] serializes [w] to the channel [oc] using the
    {!H2_frame} writers, encoding any header block with [enc]. Header writers
    split large blocks into a HEADERS/PUSH_PROMISE frame plus CONTINUATION
    frames so each fragment fits the minimum max-frame-size (16384). Mirrors the
    [writeFrame] methods in write.go (with [splitHeaderBlock]). [enc] is only
    consulted by the header-writing variants. Returns [Error] with the
    underlying {!H2_frame} frame-build invariant rather than raising. *)

val split_max_frame_size : int
(** The fixed fragment size used by {!write_frame} when splitting header blocks.
    Mirrors the [maxFrameSize] const in Go's [splitHeaderBlock] (16384). *)
