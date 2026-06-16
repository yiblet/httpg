(* Port of go/src/net/http/internal/http2/frame.go. The per-frame encode/decode
   is pure over strings; thin direct-style wrappers read/write through
   Eio.Buf_read/Eio.Buf_write. Composes H2, H2_error and Hpack. *)

let frame_header_len = 9
let max_frame_size = (1 lsl 24) - 1

(* Frame flag bit values (mirror H2's flag constants, named per Go). *)
let flag_data_end_stream = H2.flag_end_stream (* 0x1 *)
let flag_data_padded = H2.flag_padded (* 0x8 *)
let flag_headers_end_stream = H2.flag_end_stream (* 0x1 *)
let flag_headers_end_headers = H2.flag_end_headers (* 0x4 *)
let flag_headers_padded = H2.flag_padded (* 0x8 *)
let flag_headers_priority = H2.flag_priority (* 0x20 *)
let flag_settings_ack = H2.flag_ack (* 0x1 *)
let flag_ping_ack = H2.flag_ack (* 0x1 *)
let flag_continuation_end_headers = H2.flag_end_headers (* 0x4 *)
let flag_push_promise_end_headers = H2.flag_end_headers (* 0x4 *)
let flag_push_promise_padded = H2.flag_padded (* 0x8 *)
let has flags v = flags land v = v

(* ---- types ---- *)

type frame_header = {
  length : int;
  typ : H2.frame_type;
  flags : int;
  stream_id : int;
}

type priority_param = { stream_dep : int; exclusive : bool; weight : int }
type data_frame = { data : string; end_stream : bool }

type headers_frame = {
  priority : priority_param option;
  header_frag : string;
  end_stream : bool;
  end_headers : bool;
}

type priority_frame = { priority : priority_param }
type rst_stream_frame = { error_code : H2_error.err_code }
type settings_frame = { settings : H2.setting list; ack : bool }

(* Mirrors SettingsFrame.HasDuplicates (frame.go:832-850): reports whether
   the frame contains any repeated setting ID. *)
let settings_has_duplicates (f : settings_frame) : bool =
  let rec loop = function
    | [] -> false
    | (s : H2.setting) :: rest ->
        List.exists (fun (s' : H2.setting) -> s'.id = s.id) rest || loop rest
  in
  loop f.settings

type push_promise_frame = {
  promise_id : int;
  header_frag : string;
  end_headers : bool;
}

type ping_frame = { data : string; ack : bool }

type goaway_frame = {
  last_stream_id : int;
  error_code : H2_error.err_code;
  debug_data : string;
}

type window_update_frame = { increment : int }
type continuation_frame = { header_frag : string; end_headers : bool }
type unknown_frame = { raw_type : int; payload : string }

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

let header_of_frame = function
  | Data (fh, _) -> fh
  | Headers (fh, _) -> fh
  | Priority (fh, _) -> fh
  | RST_stream (fh, _) -> fh
  | Settings (fh, _) -> fh
  | Push_promise (fh, _) -> fh
  | Ping (fh, _) -> fh
  | GoAway (fh, _) -> fh
  | Window_update (fh, _) -> fh
  | Continuation (fh, _) -> fh
  | Unknown (fh, _) -> fh

(* ---- errors ---- *)

(* The read-side payload parsers thread framing violations as
   [(_, H2_error.t) result] values rather than raising — the public read
   boundaries ([read_frame]/[read_meta_headers]) return the threaded result
   directly. The frame-build invariants ([Frame_too_large] on the write path,
   invalid stream / dep ids, oversized pad) are likewise threaded as
   [(unit, H2_error.t) result] by the writers — see the [write_*] functions
   below. The only raises on this path are the Eio/Buf_read boundary
   ([End_of_file] on a short/truncated payload, mirroring Go's
   [io.ErrUnexpectedEOF] contract). *)

(* Go's connError carries a public reason; we map it to a [Connection] error. *)
let conn_error code = H2_error.Connection code

(* A stream-level protocol error for [stream_id]. *)
let stream_protocol_error stream_id =
  H2_error.Stream (H2_error.stream_error stream_id H2_error.ProtocolError)

let ( let* ) = Result.bind

(* ---- stream id validity (mirror validStreamID / validStreamIDOrZero) ---- *)

let valid_stream_id_or_zero id = id land (1 lsl 31) = 0
let valid_stream_id id = id <> 0 && id land (1 lsl 31) = 0

(* ---- pure big-endian helpers ---- *)

let put_uint16 buf v =
  Buffer.add_char buf (Char.chr ((v lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (v land 0xff))

let put_uint32 buf v =
  Buffer.add_char buf (Char.chr ((v lsr 24) land 0xff));
  Buffer.add_char buf (Char.chr ((v lsr 16) land 0xff));
  Buffer.add_char buf (Char.chr ((v lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (v land 0xff))

let get_uint16 s off = (Char.code s.[off] lsl 8) lor Char.code s.[off + 1]

let get_uint32 s off =
  (Char.code s.[off] lsl 24)
  lor (Char.code s.[off + 1] lsl 16)
  lor (Char.code s.[off + 2] lsl 8)
  lor Char.code s.[off + 3]

(* ---- frame header codec ---- *)

let encode_frame_header h =
  let buf = Buffer.create frame_header_len in
  Buffer.add_char buf (Char.chr ((h.length lsr 16) land 0xff));
  Buffer.add_char buf (Char.chr ((h.length lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (h.length land 0xff));
  Buffer.add_char buf (Char.chr (H2.frame_type_to_int h.typ land 0xff));
  Buffer.add_char buf (Char.chr (h.flags land 0xff));
  put_uint32 buf (h.stream_id land 0x7fffffff);
  Buffer.contents buf

(* For decode, we keep the raw type byte so unknown types can pass through.
   We return both the frame_header (with a frame_type) and the raw type. *)
let decode_frame_header_raw s =
  let length =
    (Char.code s.[0] lsl 16) lor (Char.code s.[1] lsl 8) lor Char.code s.[2]
  in
  let raw_type = Char.code s.[3] in
  let flags = Char.code s.[4] in
  let stream_id = get_uint32 s 5 land 0x7fffffff in
  let typ =
    match H2.frame_type_of_int raw_type with Some t -> t | None -> H2.Data
    (* placeholder; unknown handled via raw_type below *)
  in
  ({ length; typ; flags; stream_id }, raw_type)

let decode_frame_header s = fst (decode_frame_header_raw s)

(* ---- pure payload parsers (mirror parse* funcs). Each takes the
   frame_header and the (already padding-inclusive) payload string. ---- *)

let read_byte p =
  if String.length p = 0 then raise End_of_file
  else (String.sub p 1 (String.length p - 1), Char.code p.[0])

let parse_data fh p : (frame, H2_error.t) result =
  if fh.stream_id = 0 then Error (conn_error H2_error.ProtocolError)
  else
    let p, pad_size =
      if has fh.flags flag_data_padded then read_byte p else (p, 0)
    in
    if pad_size > String.length p then Error (conn_error H2_error.ProtocolError)
    else
      let data = String.sub p 0 (String.length p - pad_size) in
      Ok (Data (fh, { data; end_stream = has fh.flags flag_data_end_stream }))

let parse_headers fh p : (frame, H2_error.t) result =
  if fh.stream_id = 0 then Error (conn_error H2_error.ProtocolError)
  else
    let p, pad_length =
      if has fh.flags flag_headers_padded then read_byte p else (p, 0)
    in
    let p, priority =
      if has fh.flags flag_headers_priority then begin
        if String.length p < 4 then raise End_of_file;
        let v = get_uint32 p 0 in
        let stream_dep = v land 0x7fffffff in
        let exclusive = v <> stream_dep in
        let rest = String.sub p 4 (String.length p - 4) in
        let rest, weight = read_byte rest in
        (rest, Some { stream_dep; exclusive; weight })
      end
      else (p, None)
    in
    if String.length p - pad_length < 0 then
      Error (stream_protocol_error fh.stream_id)
    else
      let header_frag = String.sub p 0 (String.length p - pad_length) in
      Ok
        (Headers
           ( fh,
             {
               priority;
               header_frag;
               end_stream = has fh.flags flag_headers_end_stream;
               end_headers = has fh.flags flag_headers_end_headers;
             } ))

let parse_priority fh p : (frame, H2_error.t) result =
  if fh.stream_id = 0 then Error (conn_error H2_error.ProtocolError)
  else if String.length p <> 5 then Error (conn_error H2_error.FrameSizeError)
  else
    let v = get_uint32 p 0 in
    let stream_dep = v land 0x7fffffff in
    Ok
      (Priority
         ( fh,
           {
             priority =
               {
                 weight = Char.code p.[4];
                 stream_dep;
                 exclusive = stream_dep <> v;
               };
           } ))

let parse_rst_stream fh p : (frame, H2_error.t) result =
  if String.length p <> 4 then Error (conn_error H2_error.FrameSizeError)
  else if fh.stream_id = 0 then Error (conn_error H2_error.ProtocolError)
  else
    Ok
      (RST_stream
         (fh, { error_code = H2_error.err_code_of_int (get_uint32 p 0) }))

let parse_settings fh p : (frame, H2_error.t) result =
  if has fh.flags flag_settings_ack && fh.length > 0 then
    Error (conn_error H2_error.FrameSizeError)
  else if fh.stream_id <> 0 then Error (conn_error H2_error.ProtocolError)
  else if String.length p mod 6 <> 0 then
    Error (conn_error H2_error.FrameSizeError)
  else begin
    let n = String.length p / 6 in
    let settings = ref [] in
    let err = ref None in
    let i = ref (n - 1) in
    while !i >= 0 && !err = None do
      let idx = !i in
      let id_int = get_uint16 p (idx * 6) in
      let value = Int32.of_int (get_uint32 p ((idx * 6) + 2)) in
      (* Mirror Go: window-size-too-big -> FLOW_CONTROL_ERROR. *)
      (match H2.setting_id_of_int id_int with
      | Some H2.Initial_window_size ->
          (* compare as unsigned 32-bit against 2^31-1 *)
          let v = get_uint32 p ((idx * 6) + 2) in
          if v > 0x7fffffff then
            err := Some (conn_error H2_error.FlowControlError)
      | _ -> ());
      (match (!err, H2.setting_id_of_int id_int) with
      | None, Some id -> settings := { H2.id; value } :: !settings
      | _ ->
          (* Unknown settings are retained by Go (SettingID is open). We keep the
             parsed list to those we model; unknown ids are dropped from the
             typed list but length validation already passed. *)
          ());
      decr i
    done;
    match !err with
    | Some e -> Error e
    | None ->
        Ok
          (Settings
             (fh, { settings = !settings; ack = has fh.flags flag_settings_ack }))
  end

let parse_ping fh p : (frame, H2_error.t) result =
  if String.length p <> 8 then Error (conn_error H2_error.FrameSizeError)
  else if fh.stream_id <> 0 then Error (conn_error H2_error.ProtocolError)
  else Ok (Ping (fh, { data = p; ack = has fh.flags flag_ping_ack }))

let parse_goaway fh p : (frame, H2_error.t) result =
  if fh.stream_id <> 0 then Error (conn_error H2_error.ProtocolError)
  else if String.length p < 8 then Error (conn_error H2_error.FrameSizeError)
  else
    let last_stream_id = get_uint32 p 0 land 0x7fffffff in
    let error_code = H2_error.err_code_of_int (get_uint32 p 4) in
    let debug_data = String.sub p 8 (String.length p - 8) in
    Ok (GoAway (fh, { last_stream_id; error_code; debug_data }))

let parse_window_update fh p : (frame, H2_error.t) result =
  if String.length p <> 4 then Error (conn_error H2_error.FrameSizeError)
  else
    let inc = get_uint32 p 0 land 0x7fffffff in
    if inc = 0 then
      if fh.stream_id = 0 then Error (conn_error H2_error.ProtocolError)
      else Error (stream_protocol_error fh.stream_id)
    else Ok (Window_update (fh, { increment = inc }))

let parse_continuation fh p : (frame, H2_error.t) result =
  if fh.stream_id = 0 then Error (conn_error H2_error.ProtocolError)
  else
    Ok
      (Continuation
         ( fh,
           {
             header_frag = p;
             end_headers = has fh.flags flag_continuation_end_headers;
           } ))

let parse_push_promise fh p : (frame, H2_error.t) result =
  if fh.stream_id = 0 then Error (conn_error H2_error.ProtocolError)
  else
    let p, pad_length =
      if has fh.flags flag_push_promise_padded then read_byte p else (p, 0)
    in
    if String.length p < 4 then raise End_of_file;
    let promise_id = get_uint32 p 0 land 0x7fffffff in
    let p = String.sub p 4 (String.length p - 4) in
    if pad_length > String.length p then
      Error (conn_error H2_error.ProtocolError)
    else
      let header_frag = String.sub p 0 (String.length p - pad_length) in
      Ok
        (Push_promise
           ( fh,
             {
               promise_id;
               header_frag;
               end_headers = has fh.flags flag_push_promise_end_headers;
             } ))

let parse_payload fh raw_type p : (frame, H2_error.t) result =
  match H2.frame_type_of_int raw_type with
  | Some H2.Data -> parse_data fh p
  | Some H2.Headers -> parse_headers fh p
  | Some H2.Priority -> parse_priority fh p
  | Some H2.RST_stream -> parse_rst_stream fh p
  | Some H2.Settings -> parse_settings fh p
  | Some H2.Push_promise -> parse_push_promise fh p
  | Some H2.Ping -> parse_ping fh p
  | Some H2.Goaway -> parse_goaway fh p
  | Some H2.Window_update -> parse_window_update fh p
  | Some H2.Continuation -> parse_continuation fh p
  | None -> Ok (Unknown (fh, { raw_type; payload = p }))

(* ---- read ---- *)

let read_exactly r n = if n = 0 then "" else Eio.Buf_read.take n r

(* Read a frame.  An over-large declared length is surfaced as
   [Error Frame_too_large] directly. The per-type parsers ([parse_payload])
   thread the {!H2_error.t} as an [Error] value. A clean [End_of_file]
   (truncated payload / connection closed) propagates as an Eio-boundary
   exception, matching Go's [io.ErrUnexpectedEOF]/[io.EOF] contract. *)
let read_frame_or_too_large ?(max_size = max_frame_size) r :
    (frame, H2_error.t) result =
  let fh, raw_type =
    decode_frame_header_raw (read_exactly r frame_header_len)
  in
  if fh.length > max_size then Error H2_error.Frame_too_large
  else parse_payload fh raw_type (read_exactly r fh.length)

(* Public boundary: surface a unified {!H2_error.t} on an HTTP/2 framing error.
   A clean [End_of_file] (connection closed before/between frames) propagates as
   an exception, matching Go's [io.EOF] return contract. *)
let read_frame ?(max_size = max_frame_size) r : (frame, H2_error.t) result =
  read_frame_or_too_large ~max_size r

(* ---- writers ---- *)

(* The frame-build invariants
   ([Frame_too_large]/[Invalid_stream_id]/[Invalid_dep_stream_id]/
   [Pad_length_too_large]) are threaded out of the writers as
   [(unit, H2_error.t) result] rather than raised. *)

(* Build a full frame (header + payload), then one write. *)
let write_frame w typ flags stream_id (payload : string) :
    (unit, H2_error.t) result =
  let length = String.length payload in
  if length >= 1 lsl 24 then Error H2_error.Frame_too_large
  else begin
    let fh = { length; typ; flags; stream_id } in
    Eio.Buf_write.string w (encode_frame_header fh);
    Eio.Buf_write.string w payload;
    Ok ()
  end

let write_data ?pad oc stream_id end_stream data : (unit, H2_error.t) result =
  if not (valid_stream_id stream_id) then Error H2_error.Invalid_stream_id
  else
    match pad with
    | Some p when String.length p > 255 -> Error H2_error.Pad_length_too_large
    | _ ->
        let flags = ref 0 in
        if end_stream then flags := !flags lor flag_data_end_stream;
        (match pad with
        | Some _ -> flags := !flags lor flag_data_padded
        | None -> ());
        let buf = Buffer.create (String.length data + 1) in
        (match pad with
        | Some p ->
            Buffer.add_char buf (Char.chr (String.length p));
            Buffer.add_string buf data;
            Buffer.add_string buf p
        | None -> Buffer.add_string buf data);
        write_frame oc H2.Data !flags stream_id (Buffer.contents buf)

let priority_is_zero p = p.stream_dep = 0 && (not p.exclusive) && p.weight = 0

let write_headers oc ~stream_id ?(end_stream = false) ?(end_headers = false)
    ?(pad_length = 0) ?priority block : (unit, H2_error.t) result =
  if not (valid_stream_id stream_id) then Error H2_error.Invalid_stream_id
  else begin
    let prio =
      match priority with
      | Some p when not (priority_is_zero p) -> Some p
      | _ -> None
    in
    let flags = ref 0 in
    if pad_length <> 0 then flags := !flags lor flag_headers_padded;
    if end_stream then flags := !flags lor flag_headers_end_stream;
    if end_headers then flags := !flags lor flag_headers_end_headers;
    (match prio with
    | Some _ -> flags := !flags lor flag_headers_priority
    | None -> ());
    let buf = Buffer.create (String.length block + pad_length + 6) in
    if pad_length <> 0 then Buffer.add_char buf (Char.chr pad_length);
    let dep_ok =
      match prio with
      | Some p ->
          if not (valid_stream_id_or_zero p.stream_dep) then false
          else begin
            let v =
              if p.exclusive then p.stream_dep lor (1 lsl 31) else p.stream_dep
            in
            put_uint32 buf v;
            Buffer.add_char buf (Char.chr (p.weight land 0xff));
            true
          end
      | None -> true
    in
    if not dep_ok then Error H2_error.Invalid_dep_stream_id
    else begin
      Buffer.add_string buf block;
      Buffer.add_string buf (String.make pad_length '\000');
      write_frame oc H2.Headers !flags stream_id (Buffer.contents buf)
    end
  end

let write_priority oc stream_id p : (unit, H2_error.t) result =
  if not (valid_stream_id stream_id) then Error H2_error.Invalid_stream_id
  else if not (valid_stream_id_or_zero p.stream_dep) then
    Error H2_error.Invalid_dep_stream_id
  else begin
    let buf = Buffer.create 5 in
    let v = if p.exclusive then p.stream_dep lor (1 lsl 31) else p.stream_dep in
    put_uint32 buf v;
    Buffer.add_char buf (Char.chr (p.weight land 0xff));
    write_frame oc H2.Priority 0 stream_id (Buffer.contents buf)
  end

let write_rst_stream oc stream_id code : (unit, H2_error.t) result =
  if not (valid_stream_id stream_id) then Error H2_error.Invalid_stream_id
  else begin
    let buf = Buffer.create 4 in
    put_uint32 buf (H2_error.err_code_to_int code);
    write_frame oc H2.RST_stream 0 stream_id (Buffer.contents buf)
  end

let write_settings oc settings : (unit, H2_error.t) result =
  let buf = Buffer.create (List.length settings * 6) in
  List.iter
    (fun (s : H2.setting) ->
      put_uint16 buf (H2.setting_id_to_int s.H2.id);
      put_uint32 buf (Int32.to_int s.H2.value land 0xffffffff))
    settings;
  write_frame oc H2.Settings 0 0 (Buffer.contents buf)

let write_settings_ack oc : (unit, H2_error.t) result =
  write_frame oc H2.Settings flag_settings_ack 0 ""

let write_ping oc ack data : (unit, H2_error.t) result =
  let flags = if ack then flag_ping_ack else 0 in
  write_frame oc H2.Ping flags 0 data

let write_goaway oc max_stream_id code debug_data : (unit, H2_error.t) result =
  let buf = Buffer.create (8 + String.length debug_data) in
  put_uint32 buf (max_stream_id land 0x7fffffff);
  put_uint32 buf (H2_error.err_code_to_int code);
  Buffer.add_string buf debug_data;
  write_frame oc H2.Goaway 0 0 (Buffer.contents buf)

let write_window_update oc stream_id incr : (unit, H2_error.t) result =
  if incr < 1 || incr > 2147483647 then
    invalid_arg "illegal window increment value";
  let buf = Buffer.create 4 in
  put_uint32 buf incr;
  write_frame oc H2.Window_update 0 stream_id (Buffer.contents buf)

let write_continuation oc stream_id end_headers frag : (unit, H2_error.t) result
    =
  if not (valid_stream_id stream_id) then Error H2_error.Invalid_stream_id
  else begin
    let flags = if end_headers then flag_continuation_end_headers else 0 in
    write_frame oc H2.Continuation flags stream_id frag
  end

let write_push_promise oc ~stream_id ~promise_id ?(end_headers = false)
    ?(pad_length = 0) block : (unit, H2_error.t) result =
  if not (valid_stream_id stream_id) then Error H2_error.Invalid_stream_id
  else if not (valid_stream_id promise_id) then Error H2_error.Invalid_stream_id
  else begin
    let flags = ref 0 in
    if pad_length <> 0 then flags := !flags lor flag_push_promise_padded;
    if end_headers then flags := !flags lor flag_push_promise_end_headers;
    let buf = Buffer.create (String.length block + pad_length + 5) in
    if pad_length <> 0 then Buffer.add_char buf (Char.chr pad_length);
    put_uint32 buf promise_id;
    Buffer.add_string buf block;
    Buffer.add_string buf (String.make pad_length '\000');
    write_frame oc H2.Push_promise !flags stream_id (Buffer.contents buf)
  end

let write_raw oc typ flags stream_id payload : (unit, H2_error.t) result =
  let length = String.length payload in
  if length >= 1 lsl 24 then Error H2_error.Frame_too_large
  else begin
    let buf = Buffer.create (frame_header_len + length) in
    Buffer.add_char buf (Char.chr ((length lsr 16) land 0xff));
    Buffer.add_char buf (Char.chr ((length lsr 8) land 0xff));
    Buffer.add_char buf (Char.chr (length land 0xff));
    Buffer.add_char buf (Char.chr (typ land 0xff));
    Buffer.add_char buf (Char.chr (flags land 0xff));
    put_uint32 buf (stream_id land 0x7fffffff);
    Buffer.add_string buf payload;
    Eio.Buf_write.string oc (Buffer.contents buf);
    Ok ()
  end

(* ===================== read_meta_headers ===================== *)

type meta_headers_frame = {
  fh : frame_header;
  fields : Hpack.header_field list;
  truncated : bool;
}

(* http2.validWireHeaderFieldName (httpguts.IsTokenRune + reject uppercase) and
   httpguts.ValidHeaderFieldValue. Shared with the h1 encoder via Httpcommon
   (httpg_internal); the byte sets are identical, so there is a single home. *)
let valid_wire_header_field_name =
  Httpg_internal.Httpcommon.valid_wire_header_field_name

let valid_header_field_value =
  Httpg_internal.Httpcommon.valid_header_field_value

let header_field_size (hf : Hpack.header_field) = Hpack_tables.size hf
let is_pseudo (hf : Hpack.header_field) = Hpack_tables.is_pseudo hf

(* checkPseudos: validate the pseudo-header fields prefix. Returns
   [Error (Stream …)] (a stream-level error) on invalid. Mirrors Go's
   MetaHeadersFrame.checkPseudos. *)
let check_pseudos stream_id fields : (unit, H2_error.t) result =
  (* pseudo fields are the leading run of is_pseudo. *)
  let rec take_pseudos acc = function
    | hf :: tl when is_pseudo hf -> take_pseudos (hf :: acc) tl
    | _ -> List.rev acc
  in
  let pf = take_pseudos [] fields in
  let is_request = ref false in
  let is_response = ref false in
  let seen = ref [] in
  let err = ref None in
  let process (hf : Hpack.header_field) =
    if !err = None then begin
      (match hf.name with
      | ":method" | ":path" | ":scheme" | ":authority" | ":protocol" ->
          is_request := true
      | ":status" -> is_response := true
      | _ -> err := Some (stream_protocol_error stream_id));
      if !err = None && List.mem hf.name !seen then
        err := Some (stream_protocol_error stream_id);
      seen := hf.name :: !seen
    end
  in
  List.iter process pf;
  (match !err with
  | None when !is_request && !is_response ->
      err := Some (stream_protocol_error stream_id)
  | _ -> ());
  match !err with Some e -> Error e | None -> Ok ()

let read_meta_headers ?(max_size = max_frame_size)
    ?(max_header_list_size = H2.default_max_header_bytes) dec
    (hf_fh, (hf : headers_frame)) ic : (meta_headers_frame, H2_error.t) result =
  let stream_id = hf_fh.stream_id in
  let remain_size = ref max_header_list_size in
  let saw_regular = ref false in
  (* invalid: pseudo/field error to surface after the block. *)
  let invalid = ref false in
  let fields = ref [] in
  let truncated = ref false in
  Hpack.set_emit_enabled dec true;
  Hpack.set_max_string_length dec max_header_list_size;
  Hpack.set_emit_func dec (fun (f : Hpack.header_field) ->
      if not (valid_header_field_value f.value) then invalid := true;
      if is_pseudo f then begin
        if !saw_regular then invalid := true
      end
      else begin
        saw_regular := true;
        if not (valid_wire_header_field_name f.name) then invalid := true
      end;
      if !invalid then Hpack.set_emit_enabled dec false
      else begin
        let size = header_field_size f in
        if size > !remain_size then begin
          Hpack.set_emit_enabled dec false;
          truncated := true;
          remain_size := 0
        end
        else begin
          remain_size := !remain_size - size;
          fields := f :: !fields
        end
      end);
  (* hc loop: process current fragment, then read CONTINUATIONs. *)
  let last_header_stream = ref stream_id in
  ignore last_header_stream;
  (* The loop threads a [unit result]: framing / connection / stream /
     compression violations are surfaced as [Error] values (an over-large
     CONTINUATION from {!read_frame_or_too_large}; the HPACK decode failure as a
     Compression error; an out-of-order/foreign-stream frame as ProtocolError).
     A clean [End_of_file] (a CONTINUATION never arriving) propagates as an
     Eio-boundary exception. *)
  let rec loop frag ended : (unit, H2_error.t) result =
    (* "too much" check: fragment more than twice remaining bytes. *)
    if String.length frag > 2 * !remain_size then
      Error (conn_error H2_error.ProtocolError)
    else if !invalid then Error (conn_error H2_error.ProtocolError)
    else begin
      (* Feed the fragment to the HPACK decoder; a decode failure surfaces the
         underlying {!Hpack.error} via the Compression arm (Go wraps it in a
         CompressionError). *)
      let* () =
        match Hpack.write_result dec frag with
        | Ok _ -> Ok ()
        | Error e -> Error (H2_error.Compression e)
      in
      if ended then Ok ()
      else
        (* read next frame; it MUST be a CONTINUATION on the same stream. *)
        match read_frame_or_too_large ~max_size ic with
        | Error _ as e -> e
        | Ok (Continuation (cfh, cf)) ->
            if cfh.stream_id <> stream_id then
              Error (conn_error H2_error.ProtocolError)
            else loop cf.header_frag cf.end_headers
        | Ok other ->
            let ofh = header_of_frame other in
            ignore ofh;
            Error (conn_error H2_error.ProtocolError)
    end
  in
  let* () = loop hf.header_frag hf.end_headers in
  let* () =
    match Hpack.close_result dec with
    | Ok () -> Ok ()
    | Error e -> Error (H2_error.Compression e)
  in
  let result_fields = List.rev !fields in
  let* () =
    if !invalid then Error (stream_protocol_error stream_id) else Ok ()
  in
  let* () = check_pseudos stream_id result_fields in
  Ok { fh = hf_fh; fields = result_fields; truncated = !truncated }

module Private = struct
  let encode_frame_header = encode_frame_header
  let decode_frame_header = decode_frame_header
  let write_priority = write_priority
end
