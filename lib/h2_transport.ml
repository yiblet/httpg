(* Port of the client subset of go/src/net/http/internal/http2/transport.go and
   client_conn_pool.go. See h2_transport.mli for the goroutine -> Lwt mapping. *)

let ( let* ) = Lwt.bind

module F = H2_frame

(* errClientConnClosed / errClientConnGotGoAway / aborts, as exceptions. *)
exception Client_conn_closed
exception Conn_got_goaway of H2_error.err_code
exception Stream_aborted of exn
exception Malformed_response of string

(* ---- clientStream (mirrors Go's clientStream) ---- *)

type client_stream = {
  id : int;
  (* response payload pipe, fed by DATA frames (Go cs.bufPipe). *)
  buf_pipe : H2_pipe.t;
  (* per-stream outbound + inbound flow control (Go cs.flow / cs.inflow). *)
  flow : H2_flow.outflow;
  inflow : H2_flow.inflow;
  mutable bytes_remain : int;  (* -1 means unknown; declared Content-Length. *)
  (* response: set when headers received, resolves resp_recv. *)
  mutable res : Body.t Response.t option;
  resp_recv : unit Lwt_condition.t;  (* broadcast when [res] is set *)
  mutable resp_recv_done : bool;
  peer_closed : unit Lwt_condition.t;  (* broadcast on END_STREAM *)
  mutable peer_closed_done : bool;
  (* abort: set + broadcast on stream error / RST / GOAWAY. *)
  mutable abort_err : exn option;
  abort : unit Lwt_condition.t;
  mutable past_headers : bool;  (* got the first MetaHeadersFrame *)
  mutable read_closed : bool;  (* peer sent END_STREAM *)
  mutable read_aborted : bool;  (* read loop reset the stream *)
  mutable is_head : bool;
}

(* ---- ClientConn (mirrors Go's ClientConn) ---- *)

type client_conn = {
  ic : Lwt_io.input_channel;
  oc : Lwt_io.output_channel;
  (* write mutex (Go cc.wmu); held while writing to [oc]. *)
  wmu : Lwt_mutex.t;
  (* HPACK request encoder; reused across requests (Go cc.henc). *)
  henc : Hpack.encoder;
  (* HPACK response decoder, shared by read_meta_headers (Go cc.fr.ReadMetaHeaders). *)
  hdec : Hpack.decoder;
  (* conn-level flow control (Go cc.flow / cc.inflow). *)
  conn_flow : H2_flow.outflow;
  conn_inflow : H2_flow.inflow;
  (* broadcast on flow / closed changes (Go cc.cond). *)
  cond : unit Lwt_condition.t;
  streams : (int, client_stream) Hashtbl.t;
  mutable next_stream_id : int;
  mutable max_frame_size : int;
  mutable max_concurrent_streams : int;
  mutable initial_window_size : int;  (* peer's SETTINGS_INITIAL_WINDOW_SIZE *)
  mutable initial_stream_recv_window : int;  (* our advertised per-stream window *)
  mutable closed : bool;
  mutable closing : bool;
  mutable goaway : F.goaway_frame option;
  mutable want_settings_ack : bool;
  mutable seen_settings : bool;
  seen_settings_cond : unit Lwt_condition.t;
  (* resolved when the read loop ends (Go cc.readerDone). *)
  mutable reader_err : exn option;
  reader_done : unit Lwt_condition.t;
  mutable reader_done_set : bool;
  (* serializes new-request stream-id allocation + HEADERS write (Go reqHeaderMu). *)
  req_header_mu : Lwt_mutex.t;
}

let default_max_concurrent_streams = 250

(* ---- small helpers ---- *)

let broadcast_done c flag set =
  if not flag then (
    set ();
    Lwt_condition.broadcast c ())

(* abort a stream: set abort_err once, broadcast abort + cond. *)
let abort_stream cc cs err =
  (match cs.abort_err with
  | Some _ -> ()
  | None ->
      cs.abort_err <- Some err;
      Lwt_condition.broadcast cs.abort ());
  Lwt_condition.broadcast cc.cond ()

(* resolve the response-headers-received signal. *)
let signal_resp_recv cs =
  broadcast_done cs.resp_recv cs.resp_recv_done (fun () ->
      cs.resp_recv_done <- true)

let signal_peer_closed cs =
  broadcast_done cs.peer_closed cs.peer_closed_done (fun () ->
      cs.peer_closed_done <- true)

(* ---- writing (Go cc.wmu-guarded helpers; we serialize with Lwt_mutex) ---- *)

(* write the HEADERS block, splitting into CONTINUATION frames by max_frame_size
   (Go cc.writeHeaders). Caller holds [wmu]. *)
let write_headers_block cc ~stream_id ~end_stream (hdrs : string) =
  let max = cc.max_frame_size in
  let len = String.length hdrs in
  let rec loop pos first =
    if pos >= len then Lwt.return_unit
    else
      let chunk_len = min max (len - pos) in
      let chunk = String.sub hdrs pos chunk_len in
      let next = pos + chunk_len in
      let end_headers = next >= len in
      let* () =
        if first then
          F.write_headers cc.oc ~stream_id ~end_stream ~end_headers chunk
        else F.write_continuation cc.oc stream_id end_headers chunk
      in
      loop next false
  in
  let* () = loop 0 true in
  Lwt_io.flush cc.oc

(* ---- request header encoding (Go httpcommon.EncodeHeaders subset) ---- *)

let ascii_eq_fold a b = String.lowercase_ascii a = String.lowercase_ascii b

(* RequestURI of the request URL: path?query (or "/" if empty). *)
let request_uri_of (u : Uri.t) : string =
  let path = Uri.path u in
  let path = if path = "" then "/" else path in
  match Uri.verbatim_query u with Some q -> path ^ "?" ^ q | None -> path

(* actualContentLength: Body.String -> its length; Empty -> 0; Stream -> the
   request's declared content_length (-1 unknown). *)
let actual_content_length (req : Body.t Request.t) =
  match req.Request.body with
  | Body.Empty -> 0
  | Body.String s -> String.length s
  | Body.Stream _ -> Int64.to_int req.Request.content_length

(* Enumerate the (lower-cased) header fields to encode, in Go's order. *)
let enumerate_headers (req : Body.t Request.t) (acl : int) (f : string -> string -> unit) =
  let url = req.Request.url in
  let host =
    if req.Request.host <> "" then req.Request.host
    else match Uri.host url with Some h ->
      (match Uri.port url with Some p -> Printf.sprintf "%s:%d" h p | None -> h)
    | None -> ""
  in
  let meth = if req.Request.meth = "" then "GET" else req.Request.meth in
  let is_normal_connect = meth = "CONNECT" in
  f ":authority" host;
  f ":method" meth;
  if not is_normal_connect then begin
    f ":path" (request_uri_of url);
    f ":scheme" (match Uri.scheme url with Some s -> s | None -> "");
  end;
  (* regular fields *)
  let did_ua = ref false in
  List.iter
    (fun (k, vv) ->
      if ascii_eq_fold k "host" || ascii_eq_fold k "content-length" then ()
      else if
        ascii_eq_fold k "connection" || ascii_eq_fold k "proxy-connection"
        || ascii_eq_fold k "transfer-encoding" || ascii_eq_fold k "upgrade"
        || ascii_eq_fold k "keep-alive"
      then ()
      else if ascii_eq_fold k "user-agent" then begin
        did_ua := true;
        match vv with
        | [] -> ()
        | v :: _ -> if v <> "" then f k v
      end
      else List.iter (fun v -> f k v) vv)
    (Header.to_list req.Request.header);
  (* content-length: Go's shouldSendReqContentLength. *)
  let send_cl =
    match meth with
    | "GET" | "HEAD" | "DELETE" | "OPTIONS" | "PROPFIND" | "TRACE" ->
        false (* only when > 0 *)
    | _ -> acl >= 0
  in
  if (send_cl && acl > 0) || (acl > 0) then f "content-length" (string_of_int acl);
  if not !did_ua then f "user-agent" Request.default_user_agent

(* Lower-case a header name (Go LowerHeader). *)
let lower_header = String.lowercase_ascii

(* encode the request headers into a single HPACK block (Go encodeAndWriteHeaders
   without the wmu plumbing). *)
let encode_request_headers cc (req : Body.t Request.t) (acl : int) : string =
  let buf = Buffer.create 256 in
  Hpack.set_writer cc.henc (fun s -> Buffer.add_string buf s);
  enumerate_headers req acl (fun name value ->
      let name = lower_header name in
      Hpack.write_field cc.henc { name; value; sensitive = false });
  Buffer.contents buf

(* ---- request body writing (Go writeRequestBody + awaitFlowControl) ---- *)

(* await [1, min(maxBytes, maxFrameSize)] flow control tokens. *)
let rec await_flow_control cc cs max_bytes : int Lwt.t =
  if cc.closed then Lwt.fail Client_conn_closed
  else
    match cs.abort_err with
    | Some e -> Lwt.fail e
    | None ->
        let avail = Int32.to_int (H2_flow.available cs.flow) in
        if avail > 0 then begin
          let take = min avail max_bytes in
          let take = min take cc.max_frame_size in
          H2_flow.take cs.flow (Int32.of_int take);
          Lwt.return take
        end
        else
          let* () = Lwt_condition.wait cc.cond in
          await_flow_control cc cs max_bytes

(* write a chunk of the request body honoring flow control. *)
let write_data_chunk cc cs ~end_stream (data : string) : unit Lwt.t =
  let len = String.length data in
  let rec loop pos =
    if pos >= len then
      (* the whole chunk is sent; END_STREAM is attached on the final byte run,
         but if data was empty we still may need an empty END_STREAM frame. *)
      Lwt.return_unit
    else
      let* allowed = await_flow_control cc cs (len - pos) in
      let next = pos + allowed in
      let last = next >= len in
      let send_end = end_stream && last in
      let piece = String.sub data pos allowed in
      let* () =
        Lwt_mutex.with_lock cc.wmu (fun () ->
            let* () = F.write_data cc.oc cs.id send_end piece in
            Lwt_io.flush cc.oc)
      in
      loop next
  in
  if len = 0 then Lwt.return_unit else loop 0

(* send the request body then the terminating END_STREAM. *)
let write_request_body cc cs (req : Body.t Request.t) : unit Lwt.t =
  let send_empty_end () =
    Lwt_mutex.with_lock cc.wmu (fun () ->
        let* () = F.write_data cc.oc cs.id true "" in
        Lwt_io.flush cc.oc)
  in
  match req.Request.body with
  | Body.Empty -> Lwt.return_unit (* END_STREAM already on HEADERS *)
  | Body.String s ->
      if String.length s = 0 then Lwt.return_unit
      else write_data_chunk cc cs ~end_stream:true s
  | Body.Stream next ->
      let rec pump () =
        let* chunk = next () in
        match chunk with
        | None -> send_empty_end ()
        | Some "" -> pump ()
        | Some data ->
            (* peek ahead: we don't know if this is the last chunk, so never set
               END_STREAM on a streamed chunk; send a trailing empty DATA. *)
            let* () = write_data_chunk cc cs ~end_stream:false data in
            pump ()
      in
      pump ()

(* ---- response construction (Go handleResponse) ---- *)

let build_response cc cs (mf : F.meta_headers_frame) ~stream_ended :
    Body.t Response.t =
  ignore cc;
  let status = ref "" in
  let header = Header.create () in
  List.iter
    (fun (hf : Hpack.header_field) ->
      if String.length hf.name > 0 && hf.name.[0] = ':' then (
        if hf.name = ":status" then status := hf.value)
      else
        let key = Header.canonical_header_key hf.name in
        Header.add header key hf.value)
    mf.fields;
  if !status = "" then raise (Malformed_response "missing status pseudo header");
  let status_code =
    match int_of_string_opt !status with
    | Some n -> n
    | None -> raise (Malformed_response "malformed non-numeric status pseudo header")
  in
  (* Content-Length. *)
  let content_length =
    match Header.values header "Content-Length" with
    | [ cl ] -> (
        match Int64.of_string_opt cl with Some n -> n | None -> -1L)
    | [] -> if stream_ended && not cs.is_head then 0L else -1L
    | _ -> -1L
  in
  cs.bytes_remain <- Int64.to_int content_length;
  let body =
    if cs.is_head || stream_ended then Body.Empty
    else begin
      (* streaming body fed by DATA frames via buf_pipe. *)
      H2_pipe.set_buffer cs.buf_pipe
        (H2_databuffer.create ~expected:content_length ());
      Body.of_stream (fun () ->
          Lwt.catch
            (fun () ->
              let* s = H2_pipe.read cs.buf_pipe 4096 in
              if s = "" then Lwt.return None else Lwt.return (Some s))
            (function
              | End_of_file -> Lwt.return None
              | e -> Lwt.fail e))
    end
  in
  {
    Response.status = !status ^ " " ^ Status.status_text status_code;
    status_code;
    proto = "HTTP/2.0";
    proto_major = 2;
    proto_minor = 0;
    header;
    body;
    content_length;
    transfer_encoding = [];
    close = false;
    uncompressed = false;
    trailer = None;
    request = None;
  }

(* ---- read loop (Go clientConnReadLoop) ---- *)

let stream_by_id cc id =
  match Hashtbl.find_opt cc.streams id with
  | Some cs when not cs.read_aborted -> Some cs
  | _ -> None

let end_stream cc cs =
  if not cs.read_closed then begin
    cs.read_closed <- true;
    H2_pipe.close_with_error cs.buf_pipe End_of_file;
    signal_peer_closed cs;
    Lwt_condition.broadcast cc.cond ()
  end

let end_stream_error cc cs err =
  cs.read_aborted <- true;
  abort_stream cc cs err

(* WINDOW_UPDATE writer (Go cc.fr.WriteWindowUpdate under wmu). *)
let send_window_update cc ~stream_id ~incr =
  if incr > 0 then
    Lwt_mutex.with_lock cc.wmu (fun () ->
        let* () = F.write_window_update cc.oc stream_id incr in
        Lwt_io.flush cc.oc)
  else Lwt.return_unit

let process_headers cc (mf : F.meta_headers_frame) : unit Lwt.t =
  let id = mf.fh.stream_id in
  match stream_by_id cc id with
  | None -> Lwt.return_unit (* canceled/unknown stream; ignore *)
  | Some cs ->
      if cs.read_closed then (
        end_stream_error cc cs
          (Stream_aborted (Failure "headers after END_STREAM"));
        Lwt.return_unit)
      else if mf.truncated then (
        end_stream_error cc cs (Stream_aborted (Failure "response header list too large"));
        Lwt.return_unit)
      else if cs.past_headers then
        (* trailers: just end the stream (we don't surface trailers here). *)
        let stream_ended =
          (* a HEADERS marking trailers must carry END_STREAM *)
          true
        in
        let () = ignore stream_ended in
        let () = end_stream cc cs in
        Lwt.return_unit
      else begin
        cs.past_headers <- true;
        (* Did the HEADERS frame carry END_STREAM? read_meta_headers preserves
           the original HEADERS flags in mf.fh; END_STREAM is flag 0x1. *)
        let stream_ended = mf.fh.flags land H2.flag_end_stream <> 0 in
        match
          try Ok (build_response cc cs mf ~stream_ended)
          with e -> Error e
        with
        | Error e ->
            end_stream_error cc cs (Stream_aborted e);
            Lwt.return_unit
        | Ok res ->
            let status_code = res.Response.status_code in
            if status_code >= 100 && status_code <= 199 then begin
              (* 1xx informational: ignore and wait for the real headers. *)
              cs.past_headers <- false;
              Lwt.return_unit
            end
            else begin
              cs.res <- Some res;
              signal_resp_recv cs;
              if stream_ended then end_stream cc cs;
              Lwt.return_unit
            end
      end

let process_data cc (fh : F.frame_header) (df : F.data_frame) : unit Lwt.t =
  let id = fh.stream_id in
  let length = fh.length in
  match stream_by_id cc id with
  | None ->
      if id >= cc.next_stream_id then Lwt.fail (H2_error.Connection_error H2_error.FlowControlError)
      else if length > 0 then begin
        (* return flow control for a canceled stream. *)
        let ok = H2_flow.inflow_take cc.conn_inflow length in
        let conn_add = H2_flow.inflow_add cc.conn_inflow length in
        if not ok then Lwt.fail (H2_error.Connection_error H2_error.FlowControlError)
        else send_window_update cc ~stream_id:0 ~incr:(Int32.to_int conn_add)
      end
      else Lwt.return_unit
  | Some cs ->
      if cs.read_closed then (
        end_stream_error cc cs (Stream_aborted (Failure "DATA after END_STREAM"));
        Lwt.return_unit)
      else if not cs.past_headers then (
        end_stream_error cc cs (Stream_aborted (Failure "DATA before HEADERS"));
        Lwt.return_unit)
      else begin
        let data = df.data in
        let* () =
          if length > 0 then begin
            if not (H2_flow.take_inflows cc.conn_inflow cs.inflow length) then
              Lwt.fail (H2_error.Connection_error H2_error.FlowControlError)
            else begin
              (* padding refund: length includes padding stripped from [data]. *)
              let refund = ref (length - String.length data) in
              let did_reset = ref false in
              (if String.length data > 0 then
                 try ignore (H2_pipe.write cs.buf_pipe data)
                 with _ ->
                   did_reset := true;
                   refund := !refund + String.length data);
              let send_conn =
                Int32.to_int (H2_flow.inflow_add cc.conn_inflow !refund)
              in
              let send_stream =
                if !did_reset then 0
                else Int32.to_int (H2_flow.inflow_add cs.inflow !refund)
              in
              let* () = send_window_update cc ~stream_id:0 ~incr:send_conn in
              send_window_update cc ~stream_id:id ~incr:send_stream
            end
          end
          else Lwt.return_unit
        in
        if df.end_stream then end_stream cc cs;
        Lwt.return_unit
      end

let process_settings cc (sf : F.settings_frame) : unit Lwt.t =
  if sf.ack then begin
    if cc.want_settings_ack then (cc.want_settings_ack <- false; Lwt.return_unit)
    else Lwt.fail (H2_error.Connection_error H2_error.ProtocolError)
  end
  else begin
    let seen_mcs = ref false in
    List.iter
      (fun (s : H2.setting) ->
        match s.id with
        | H2.Max_frame_size -> cc.max_frame_size <- Int32.to_int s.value
        | H2.Max_concurrent_streams ->
            cc.max_concurrent_streams <- Int32.to_int s.value;
            seen_mcs := true
        | H2.Initial_window_size ->
            let v = Int32.to_int s.value in
            let delta = v - cc.initial_window_size in
            Hashtbl.iter
              (fun _ cs -> ignore (H2_flow.add cs.flow (Int32.of_int delta)))
              cc.streams;
            cc.initial_window_size <- v;
            Lwt_condition.broadcast cc.cond ()
        | H2.Header_table_size ->
            Hpack.set_max_dynamic_table_size cc.henc (Int32.to_int s.value)
        | H2.Enable_push | H2.Max_header_list_size -> ())
      sf.settings;
    if not cc.seen_settings then begin
      if not !seen_mcs then
        cc.max_concurrent_streams <- default_max_concurrent_streams;
      cc.seen_settings <- true;
      Lwt_condition.broadcast cc.seen_settings_cond ()
    end;
    (* ACK the SETTINGS. *)
    Lwt_mutex.with_lock cc.wmu (fun () ->
        let* () = F.write_settings_ack cc.oc in
        Lwt_io.flush cc.oc)
  end

let process_window_update cc (fh : F.frame_header) (wf : F.window_update_frame)
    : unit Lwt.t =
  let id = fh.stream_id in
  if id = 0 then begin
    if not (H2_flow.add cc.conn_flow (Int32.of_int wf.increment)) then
      Lwt.fail (H2_error.Connection_error H2_error.FlowControlError)
    else (Lwt_condition.broadcast cc.cond (); Lwt.return_unit)
  end
  else
    match stream_by_id cc id with
    | None -> Lwt.return_unit
    | Some cs ->
        if not (H2_flow.add cs.flow (Int32.of_int wf.increment)) then (
          end_stream_error cc cs (Stream_aborted (Failure "flow control"));
          Lwt.return_unit)
        else (Lwt_condition.broadcast cc.cond (); Lwt.return_unit)

let process_reset_stream cc (fh : F.frame_header) (rf : F.rst_stream_frame) :
    unit Lwt.t =
  match stream_by_id cc fh.stream_id with
  | None -> Lwt.return_unit
  | Some cs ->
      let serr =
        Stream_aborted (H2_error.Stream_error (H2_error.stream_error fh.stream_id rf.error_code))
      in
      abort_stream cc cs serr;
      cs.read_aborted <- true;
      H2_pipe.close_with_error cs.buf_pipe serr;
      Lwt.return_unit

let process_ping cc (pf : F.ping_frame) : unit Lwt.t =
  if pf.ack then Lwt.return_unit
  else
    Lwt_mutex.with_lock cc.wmu (fun () ->
        let* () = F.write_ping cc.oc true pf.data in
        Lwt_io.flush cc.oc)

let process_goaway cc (gf : F.goaway_frame) : unit Lwt.t =
  cc.goaway <- Some gf;
  let last = gf.last_stream_id in
  Hashtbl.iter
    (fun sid cs ->
      if sid > last then
        let err =
          if sid = 1 && gf.error_code <> H2_error.NoError then
            Stream_aborted (Conn_got_goaway gf.error_code)
          else Stream_aborted (Conn_got_goaway gf.error_code)
        in
        abort_stream cc cs err)
    cc.streams;
  Lwt.return_unit

let signal_reader_done cc err =
  cc.reader_err <- err;
  cc.closed <- true;
  if not cc.reader_done_set then (
    cc.reader_done_set <- true;
    Lwt_condition.broadcast cc.reader_done ());
  (* unblock all flow waiters / abort pending streams. *)
  let e = match err with Some e -> e | None -> Client_conn_closed in
  Hashtbl.iter (fun _ cs -> abort_stream cc cs (Stream_aborted e)) cc.streams;
  Lwt_condition.broadcast cc.cond ()

(* the read loop fiber: read frames, dispatch. Mirrors Go's readLoop+run. *)
let rec read_loop cc ~got_settings : unit Lwt.t =
  let* result =
    Lwt.catch
      (fun () ->
        (* HEADERS need read_meta_headers assembly; peek the frame header by
           reading a full frame, then for HEADERS assemble continuations. *)
        let* f = F.read_frame cc.ic in
        Lwt.return (`Frame f))
      (fun e -> Lwt.return (`Error e))
  in
  match result with
  | `Error End_of_file ->
      signal_reader_done cc None;
      Lwt.return_unit
  | `Error (H2_error.Stream_error se) ->
      (* stream-level frame error: reset that stream, keep going. *)
      (match stream_by_id cc se.stream_id with
      | Some cs ->
          end_stream_error cc cs (Stream_aborted (H2_error.Stream_error se))
      | None -> ());
      read_loop cc ~got_settings
  | `Error e ->
      signal_reader_done cc (Some e);
      Lwt.return_unit
  | `Frame f -> (
      (* enforce: first frame must be SETTINGS. *)
      let is_settings = match f with F.Settings _ -> true | _ -> false in
      if (not got_settings) && not is_settings then (
        signal_reader_done cc (Some (H2_error.Connection_error H2_error.ProtocolError));
        Lwt.return_unit)
      else
        let got_settings = got_settings || is_settings in
        let* proc =
          Lwt.catch
            (fun () ->
              let* () =
                match f with
                | F.Headers (fh, hf) ->
                    (* assemble HEADERS (+CONTINUATION) via read_meta_headers. *)
                    let* mf = F.read_meta_headers cc.hdec (fh, hf) cc.ic in
                    (* preserve END_STREAM flag from the HEADERS frame. *)
                    let mf = { mf with F.fh = { mf.F.fh with flags = fh.flags } } in
                    process_headers cc mf
                | F.Data (fh, df) -> process_data cc fh df
                | F.Settings (_, sf) -> process_settings cc sf
                | F.Window_update (fh, wf) -> process_window_update cc fh wf
                | F.RST_stream (fh, rf) -> process_reset_stream cc fh rf
                | F.Ping (_, pf) -> process_ping cc pf
                | F.GoAway (_, gf) -> process_goaway cc gf
                | F.Push_promise _ ->
                    Lwt.fail (H2_error.Connection_error H2_error.ProtocolError)
                | F.Priority _ | F.Continuation _ | F.Unknown _ ->
                    Lwt.return_unit
              in
              Lwt.return (Ok ()))
            (fun e -> Lwt.return (Error e))
        in
        match proc with
        | Ok () -> read_loop cc ~got_settings
        | Error (H2_error.Connection_error _ as e) ->
            signal_reader_done cc (Some e);
            Lwt.return_unit
        | Error e ->
            signal_reader_done cc (Some e);
            Lwt.return_unit)

(* ---- new_client_conn ---- *)

let new_client_conn ic oc : client_conn Lwt.t =
  let initial_stream_recv_window = 4 lsl 20 (* 4 MiB, Go default per-stream *) in
  let conn_recv_window = 1 lsl 30 (* 1 GiB, Go MaxReceiveBufferPerConnection *) in
  let henc = Hpack.new_encoder () in
  (* response decoder: emit is replaced by read_meta_headers per call. *)
  let hdec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
  let conn_flow = H2_flow.create_outflow () in
  ignore (H2_flow.add conn_flow (Int32.of_int H2.initial_window_size));
  let conn_inflow = H2_flow.create_inflow () in
  H2_flow.inflow_init conn_inflow
    (Int32.of_int (conn_recv_window + H2.initial_window_size));
  let cc =
    {
      ic;
      oc;
      wmu = Lwt_mutex.create ();
      henc;
      hdec;
      conn_flow;
      conn_inflow;
      cond = Lwt_condition.create ();
      streams = Hashtbl.create 16;
      next_stream_id = 1;
      max_frame_size = 16 lsl 10;
      max_concurrent_streams = 100;
      initial_window_size = H2.initial_window_size;
      initial_stream_recv_window;
      closed = false;
      closing = false;
      goaway = None;
      want_settings_ack = true;
      seen_settings = false;
      seen_settings_cond = Lwt_condition.create ();
      reader_err = None;
      reader_done = Lwt_condition.create ();
      reader_done_set = false;
      req_header_mu = Lwt_mutex.create ();
    }
  in
  (* write preface + initial SETTINGS + WINDOW_UPDATE (Go newClientConn). *)
  let initial_settings =
    [
      { H2.id = H2.Enable_push; value = 0l };
      { H2.id = H2.Initial_window_size; value = Int32.of_int initial_stream_recv_window };
      { H2.id = H2.Max_frame_size; value = Int32.of_int (1 lsl 20) };
    ]
  in
  let* () = Lwt_io.write oc H2.client_preface in
  let* () = F.write_settings oc initial_settings in
  let* () = F.write_window_update oc 0 conn_recv_window in
  let* () = Lwt_io.flush oc in
  (* start the read loop. *)
  Lwt.async (fun () ->
      Lwt.catch
        (fun () -> read_loop cc ~got_settings:false)
        (fun e ->
          signal_reader_done cc (Some e);
          Lwt.return_unit));
  (* wait until we've seen the server's SETTINGS (or the reader died). *)
  let rec wait_seen () =
    if cc.seen_settings then Lwt.return_unit
    else if cc.closed then
      Lwt.fail (match cc.reader_err with Some e -> e | None -> Client_conn_closed)
    else
      let p1 = Lwt_condition.wait cc.seen_settings_cond in
      let p2 = Lwt_condition.wait cc.reader_done in
      let* () = Lwt.choose [ p1; p2 ] in
      wait_seen ()
  in
  let* () = wait_seen () in
  Lwt.return cc

(* ---- round_trip ---- *)

let make_stream cc id ~is_head =
  let flow = H2_flow.create_outflow () in
  ignore (H2_flow.add flow (Int32.of_int cc.initial_window_size));
  let inflow = H2_flow.create_inflow () in
  H2_flow.inflow_init inflow (Int32.of_int cc.initial_stream_recv_window);
  {
    id;
    buf_pipe = H2_pipe.create ();
    flow;
    inflow;
    bytes_remain = -1;
    res = None;
    resp_recv = Lwt_condition.create ();
    resp_recv_done = false;
    peer_closed = Lwt_condition.create ();
    peer_closed_done = false;
    abort_err = None;
    abort = Lwt_condition.create ();
    past_headers = false;
    read_closed = false;
    read_aborted = false;
    is_head;
  }

(* wait for either the response headers, an abort, or the reader to die. *)
let await_response cc cs : Body.t Response.t Lwt.t =
  let rec loop () =
    match cs.res with
    | Some res -> Lwt.return res
    | None -> (
        match cs.abort_err with
        | Some e -> Lwt.fail e
        | None ->
            if cc.closed then
              Lwt.fail (match cc.reader_err with Some e -> e | None -> Client_conn_closed)
            else
              let* () =
                Lwt.choose
                  [
                    Lwt_condition.wait cs.resp_recv;
                    Lwt_condition.wait cs.abort;
                    Lwt_condition.wait cc.reader_done;
                  ]
              in
              loop ())
  in
  loop ()

let round_trip cc (req : Body.t Request.t) : Body.t Response.t Lwt.t =
  if cc.closed || cc.closing then
    Lwt.fail (match cc.reader_err with Some e -> e | None -> Client_conn_closed)
  else begin
    let is_head = req.Request.meth = "HEAD" in
    let acl = actual_content_length req in
    let has_body = acl <> 0 in
    (* allocate stream id + write HEADERS under req_header_mu (Go reqHeaderMu). *)
    let* cs =
      Lwt_mutex.with_lock cc.req_header_mu (fun () ->
          let id = cc.next_stream_id in
          cc.next_stream_id <- cc.next_stream_id + 2;
          let cs = make_stream cc id ~is_head in
          Hashtbl.replace cc.streams id cs;
          let hdrs = encode_request_headers cc req acl in
          let end_stream = not has_body in
          let* () =
            Lwt_mutex.with_lock cc.wmu (fun () ->
                write_headers_block cc ~stream_id:id ~end_stream hdrs)
          in
          Lwt.return cs)
    in
    (* write the request body (if any), in a separate fiber so we can read the
       response concurrently (Go runs doRequest in its own goroutine). *)
    if has_body then
      Lwt.async (fun () ->
          Lwt.catch
            (fun () -> write_request_body cc cs req)
            (fun e ->
              abort_stream cc cs (Stream_aborted e);
              Lwt.return_unit));
    (* await the response headers. *)
    let* res = await_response cc cs in
    Lwt.return res
  end

let close cc : unit Lwt.t =
  cc.closing <- true;
  signal_reader_done cc None;
  Lwt.catch (fun () -> Lwt_io.close cc.oc) (fun _ -> Lwt.return_unit)

(* Whether the connection is closed / no longer usable (Go's [closed] / the
   negation of [canTakeNewRequest]). Exposed so a transport pool can drop dead
   connections. *)
let is_closed cc = cc.closed || cc.closing

(* ---- minimal connection pool (client_conn_pool.go subset) ---- *)

type t = { conns : (string, client_conn list) Hashtbl.t }

let create () = { conns = Hashtbl.create 8 }

(* authority key for a request: host[:port] (Go authorityAddr). *)
let authority_of (req : Body.t Request.t) =
  let url = req.Request.url in
  let host = match Uri.host url with Some h -> h | None -> req.Request.host in
  match Uri.port url with
  | Some p -> Printf.sprintf "%s:%d" host p
  | None -> host

let get_usable t authority =
  match Hashtbl.find_opt t.conns authority with
  | None -> None
  | Some conns ->
      List.find_opt (fun cc -> not (cc.closed || cc.closing)) conns

let round_trip_pooled t ~connect (req : Body.t Request.t) :
    Body.t Response.t Lwt.t =
  let authority = authority_of req in
  let* cc =
    match get_usable t authority with
    | Some cc -> Lwt.return cc
    | None ->
        let* ic, oc = connect authority in
        let* cc = new_client_conn ic oc in
        let existing =
          match Hashtbl.find_opt t.conns authority with Some l -> l | None -> []
        in
        Hashtbl.replace t.conns authority (cc :: existing);
        Lwt.return cc
  in
  round_trip cc req
