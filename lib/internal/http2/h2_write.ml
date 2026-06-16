(* Port of go/src/net/http/internal/http2/write.go. *)

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

type write_push_promise = {
  pp_stream_id : int;
  pp_promised_id : int;
  pp_method : Httpg_base.Method.t;
  pp_scheme : string;
  pp_authority : string;
  pp_path : string;
  pp_h : Api.Header.t;
}

type write_framer =
  | Write_settings of H2.setting list
  | Write_settings_ack
  | Write_goaway of { max_stream_id : int; code : H2_error.err_code }
  | Write_data of { stream_id : int; data : string; end_stream : bool }
  | Write_handler_panic_rst of int
  | Write_rst_stream of { stream_id : int; code : H2_error.err_code }
  | Write_ping of string
  | Write_ping_ack of string
  | Write_window_update of { stream_id : int; n : int }
  | Write_res_headers of write_res_headers
  | Write_push_promise of write_push_promise
  | Write_100_continue of int

(* writeEndsStream. RST_STREAM returns false: it closes the whole stream. *)
let write_ends_stream = function
  | Write_data { end_stream; _ } -> end_stream
  | Write_res_headers { rh_end_stream; _ } -> rh_end_stream
  | _ -> false

(* The flow-control byte count: len(wd.p) for DATA, 0 otherwise. *)
let data_size = function Write_data { data; _ } -> String.length data | _ -> 0

(* http2.httpCodeString. *)
let httpcode_string code =
  match code with 200 -> "200" | 404 -> "404" | _ -> string_of_int code

(* http2.validWireHeaderFieldName, httpguts.ValidHeaderFieldValue and
   httpcommon.LowerHeader now live in Httpg_internal.Httpcommon. *)
let valid_wire_header_field_name =
  Httpg_internal.Httpcommon.valid_wire_header_field_name

let valid_header_field_value =
  Httpg_internal.Httpcommon.valid_header_field_value

let lower_header = Httpg_internal.Httpcommon.lower_header

(* encKV: encode one header field. *)
let enc_kv enc k v =
  Hpack.write_field enc { name = k; value = v; sensitive = false }

(* encodeHeaders: when [keys] is None, iterate sorted keys (Go's sorterPool).
   For each (k, values), lower-case + validate the name, skip invalid; for
   each value, validate it, and only allow transfer-encoding: trailers. *)
let encode_headers enc h keys =
  let keys =
    match keys with
    | Some ks -> ks
    | None ->
        let ks = List.map fst (Api.Header.to_list h) in
        List.sort String.compare ks
  in
  List.iter
    (fun k ->
      let vv = Api.Header.values h k in
      let k, ascii = lower_header k in
      if ascii && valid_wire_header_field_name k then begin
        let is_te = k = "transfer-encoding" in
        List.iter
          (fun v ->
            if valid_header_field_value v then
              if (not is_te) || v = "trailers" then enc_kv enc k v)
          vv
      end)
    keys

let split_max_frame_size = 16384

(* splitHeaderBlock: split [block] into <= maxFrameSize fragments and call [fn]
   for each, with first/last flags. *)
let split_header_block block fn =
  let max_frame_size = split_max_frame_size in
  let len = String.length block in
  let rec loop pos first =
    if pos >= len then ()
    else begin
      let frag_len = min (len - pos) max_frame_size in
      let frag = String.sub block pos frag_len in
      let next = pos + frag_len in
      let last = next >= len in
      fn frag first last;
      loop next false
    end
  in
  loop 0 true

(* Encode a header block from a sequence of WriteField calls into a string. *)
let encode_block enc f =
  let buf = Buffer.create 256 in
  Hpack.set_writer enc (fun s -> Buffer.add_string buf s);
  f ();
  Buffer.contents buf

(* Apply [fn] over each fragment of [split_header_block], short-circuiting on
   the first frame-build [Error] (Go's splitHeaderBlock returns on the first
   writer error). *)
let split_header_block_result block fn : (unit, H2_error.t) result =
  let result = ref (Ok ()) in
  (try
     split_header_block block (fun frag first last ->
         match fn frag first last with
         | Ok () -> ()
         | Error _ as e ->
             result := e;
             raise Exit)
   with Exit -> ());
  !result

let write_res_headers_frame oc enc (w : write_res_headers) :
    (unit, H2_error.t) result =
  let block =
    encode_block enc (fun () ->
        if w.http_res_code <> 0 then
          enc_kv enc ":status" (httpcode_string w.http_res_code);
        encode_headers enc w.h w.trailers;
        if w.content_type <> "" then enc_kv enc "content-type" w.content_type;
        if w.content_length <> "" then
          enc_kv enc "content-length" w.content_length;
        if w.date <> "" then enc_kv enc "date" w.date)
  in
  if String.length block = 0 && w.trailers = None then
    failwith "unexpected empty hpack";
  split_header_block_result block (fun frag first last ->
      if first then
        H2_frame.write_headers oc ~stream_id:w.rh_stream_id
          ~end_stream:w.rh_end_stream ~end_headers:last frag
      else H2_frame.write_continuation oc w.rh_stream_id last frag)

let write_push_promise_frame oc enc (w : write_push_promise) :
    (unit, H2_error.t) result =
  let block =
    encode_block enc (fun () ->
        enc_kv enc ":method" (Httpg_base.Method.to_string w.pp_method);
        enc_kv enc ":scheme" w.pp_scheme;
        enc_kv enc ":authority" w.pp_authority;
        enc_kv enc ":path" w.pp_path;
        encode_headers enc w.pp_h None)
  in
  if String.length block = 0 then failwith "unexpected empty hpack";
  split_header_block_result block (fun frag first last ->
      if first then
        H2_frame.write_push_promise oc ~stream_id:w.pp_stream_id
          ~promise_id:w.pp_promised_id ~end_headers:last frag
      else H2_frame.write_continuation oc w.pp_stream_id last frag)

let write_frame ~enc oc w : (unit, H2_error.t) result =
  match w with
  | Write_settings settings -> H2_frame.write_settings oc settings
  | Write_settings_ack -> H2_frame.write_settings_ack oc
  | Write_goaway { max_stream_id; code } ->
      (* Go ignores the flush error; we just write the GOAWAY. *)
      H2_frame.write_goaway oc max_stream_id code ""
  | Write_data { stream_id; data; end_stream } ->
      H2_frame.write_data oc stream_id end_stream data
  | Write_handler_panic_rst stream_id ->
      H2_frame.write_rst_stream oc stream_id H2_error.InternalError
  | Write_rst_stream { stream_id; code } ->
      H2_frame.write_rst_stream oc stream_id code
  | Write_ping data -> H2_frame.write_ping oc false data
  | Write_ping_ack data -> H2_frame.write_ping oc true data
  | Write_window_update { stream_id; n } ->
      H2_frame.write_window_update oc stream_id n
  | Write_res_headers w -> write_res_headers_frame oc enc w
  | Write_push_promise w -> write_push_promise_frame oc enc w
  | Write_100_continue stream_id ->
      let block = encode_block enc (fun () -> enc_kv enc ":status" "100") in
      H2_frame.write_headers oc ~stream_id ~end_stream:false ~end_headers:true
        block
