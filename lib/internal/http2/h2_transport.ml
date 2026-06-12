(* Port of the client subset of go/src/net/http/internal/http2/transport.go and
   client_conn_pool.go. See h2_transport.mli for the goroutine -> Eio fiber
   mapping. *)

module F = H2_frame
module Body = Api.Body
module Header = Api.Header

(* errClientConnClosed / errClientConnGotGoAway / aborts, as exceptions. *)
exception Client_conn_closed
exception Conn_got_goaway of H2_error.err_code

(* errClientConnUnusable (transport.go:530): a pooled conn raced into
   closed/closing before this request wrote anything to the wire. Distinct so the
   transport pool can evict + retry on a fresh dial (Go's shouldRetryRequest),
   knowing the request is unmodified. *)
exception Conn_unusable
exception Stream_aborted of exn
exception Malformed_response of string

(* errRequestCanceled (transport.go): the caller abandoned the request (early
   return / undrained response / cancelled scope) before a clean close. *)
exception Request_canceled

(* ---- clientStream (mirrors Go's clientStream) ---- *)

type client_stream = {
  id : int;
  buf_pipe : H2_pipe.t; (* response payload (Go cs.bufPipe) *)
  flow : H2_flow.outflow; (* per-stream outbound flow (Go cs.flow) *)
  inflow : H2_flow.inflow; (* per-stream inbound flow (Go cs.inflow) *)
  mutable bytes_remain : int; (* -1 unknown; declared Content-Length *)
  mutable res : Api.client_response option;
  mutable resp_recv_done : bool;
  mutable peer_closed_done : bool;
  mutable abort_err : exn option; (* set on stream error / RST / GOAWAY *)
  mutable past_headers : bool; (* got the first MetaHeadersFrame *)
  mutable read_closed : bool; (* peer sent END_STREAM *)
  mutable read_aborted : bool; (* read loop reset the stream *)
  mutable is_head : bool;
  mutable sent_end_stream : bool;
      (* writer sent our END_STREAM (Go sentEndStream) *)
  mutable cleaned : bool; (* cleanup_write_request ran (idempotency guard) *)
  mutable body_is_stream : bool;
      (* response body is a drainable Stream whose EOF frees the slot; if false
         (Empty body) end_stream frees the slot directly *)
}

(* ---- ClientConn (mirrors Go's ClientConn) ---- *)

type client_conn = {
  r : Eio.Buf_read.t;
  w : Eio.Buf_write.t;
  sw : Eio.Switch.t; (* reader + body-writer fibers fork here *)
  wmu : Eio.Mutex.t; (* held while writing to [w] (Go cc.wmu) *)
  henc : Hpack.encoder; (* request encoder (Go cc.henc) *)
  hdec : Hpack.decoder; (* response decoder, used by read loop *)
  conn_flow : H2_flow.outflow; (* conn-level flow (Go cc.flow) *)
  conn_inflow : H2_flow.inflow; (* conn-level inflow (Go cc.inflow) *)
  (* Single condition broadcast on every state change (flow, response, abort,
     closed). Waiters re-check predicates after each wake (Go cc.cond). *)
  cond : Eio.Condition.t;
  streams : (int, client_stream) Hashtbl.t;
  mutable streams_reserved : int;
      (* slots reserved before id assignment (transport.go:161) *)
  mutable pending_resets : int;
      (* RST_STREAMs awaiting PING ACK (transport.go:196) *)
  mutable next_stream_id : int;
  mutable max_frame_size : int;
  mutable max_concurrent_streams : int;
  mutable initial_window_size : int; (* peer's SETTINGS_INITIAL_WINDOW_SIZE *)
  mutable initial_stream_recv_window : int;
      (* our advertised per-stream window *)
  mutable closed : bool;
  mutable closing : bool;
  mutable goaway : F.goaway_frame option;
  mutable want_settings_ack : bool;
  mutable seen_settings : bool;
  mutable reader_err : exn option; (* set when the read loop ends *)
  req_header_mu : Eio.Mutex.t; (* serializes stream-id alloc + HEADERS write *)
}

let default_max_concurrent_streams = 250

(* ---- small helpers ---- *)

(* currentRequestCountLocked (transport.go:885): concurrency slots in use =
   live streams + reserved slots + reset streams awaiting a PING ACK. *)
let current_request_count cc =
  Hashtbl.length cc.streams + cc.streams_reserved + cc.pending_resets

(* forgetStreamID (transport.go:1875): drop the stream from the table, freeing a
   concurrency slot, and wake any request fiber waiting for one. *)
let forget_stream cc id =
  if Hashtbl.mem cc.streams id then begin
    Hashtbl.remove cc.streams id;
    Eio.Condition.broadcast cc.cond
  end

(* abort a stream: set abort_err once, forget it, wake waiters. *)
let abort_stream cc cs err =
  (match cs.abort_err with Some _ -> () | None -> cs.abort_err <- Some err);
  forget_stream cc cs.id;
  Eio.Condition.broadcast cc.cond

(* cleanupWriteRequest (transport.go:1217): the caller is done with the stream
   (response drained, abandoned early, or its scope cancelled). Idempotent. If
   the exchange did not close cleanly (we never sent END_STREAM, or the peer has
   not), abort the stream — this unblocks a body-writer parked in
   await_flow_control (it re-checks abort_err) and breaks the response pipe — and
   forget it. A cleanly half-closed stream was already forgotten by [end_stream];
   here we only drop any straggling table entry. *)
let cleanup_write_request cc cs =
  if not cs.cleaned then begin
    cs.cleaned <- true;
    let clean = cs.sent_end_stream && cs.read_closed in
    (match (clean, cs.abort_err) with
    | false, None ->
        let err = Stream_aborted Request_canceled in
        cs.abort_err <- Some err;
        H2_pipe.break_with_error cs.buf_pipe err (* no-op if already closed *)
    | _ -> ());
    (* An unclean teardown is the analogue of Go's RST_STREAM-with-PING path: we
       keep the slot counted against the limit (as a pending reset) until a PING
       ACK confirms the peer is alive, throttling requests on a dead conn
       (transport.go:1494-1510). A clean exchange frees its slot outright. *)
    if not clean then cc.pending_resets <- cc.pending_resets + 1;
    forget_stream cc cs.id;
    Eio.Condition.broadcast cc.cond
  end

let signal_resp_recv cc cs =
  if not cs.resp_recv_done then (
    cs.resp_recv_done <- true;
    Eio.Condition.broadcast cc.cond)

let signal_peer_closed cc cs =
  if not cs.peer_closed_done then (
    cs.peer_closed_done <- true;
    Eio.Condition.broadcast cc.cond)

(* ---- writing (Go cc.wmu-guarded helpers; serialized with [wmu]) ---- *)

(* write the HEADERS block, splitting into CONTINUATION frames by max_frame_size
   (Go cc.writeHeaders). Caller holds [wmu]. *)
let write_headers_block cc ~stream_id ~end_stream (hdrs : string) =
  let max = cc.max_frame_size in
  let len = String.length hdrs in
  let rec loop pos first =
    if pos < len then begin
      let chunk_len = min max (len - pos) in
      let chunk = String.sub hdrs pos chunk_len in
      let next = pos + chunk_len in
      let end_headers = next >= len in
      if first then
        F.write_headers cc.w ~stream_id ~end_stream ~end_headers chunk
      else F.write_continuation cc.w stream_id end_headers chunk;
      loop next false
    end
  in
  loop 0 true;
  Eio.Buf_write.flush cc.w

(* ---- request header encoding (Go httpcommon.EncodeHeaders) ---- *)

module HC = Httpg_internal.Httpcommon

(* RequestURI of the request URL: path?query (or "/" if empty). *)
let request_uri_of (u : Uri.t) : string =
  let path = Uri.path u in
  let path = if path = "" then "/" else path in
  match Uri.verbatim_query u with Some q -> path ^ "?" ^ q | None -> path

(* actualContentLength: String -> length; Empty -> 0; Stream -> declared. *)
let actual_content_length (req : Api.client_request) =
  match req.creq_body with
  | Body.Empty -> 0
  | Body.String s -> String.length s
  | Body.Stream _ -> Int64.to_int req.creq_content_length

(* encode the request headers into a single HPACK block via
   httpcommon.EncodeHeaders (Go encodeAndWriteHeaders, sans wmu plumbing). *)
let encode_request_headers cc (req : Api.client_request) (acl : int) : string =
  let url = req.creq_url in
  let host =
    match req.creq_host with
    | Some h when h <> "" -> h
    | _ -> (
        match Uri.host url with
        | Some h -> (
            match Uri.port url with
            | Some p -> Printf.sprintf "%s:%d" h p
            | None -> h)
        | None -> "")
  in
   (* TODO: change HC.request host to allow for string *)
  let hc_req : HC.request =
    {
      url_scheme = (match Uri.scheme url with Some s -> s | None -> "");
      url_host = host;
      request_uri = request_uri_of url;
      url_opaque = "";
      meth = req.creq_meth;
      host = Option.value ~default:"" req.creq_host;
      header = req.creq_header;
      trailer = req.creq_trailer;
      actual_content_length = Int64.of_int acl;
    }
  in
  let param : HC.encode_headers_param =
    {
      request = hc_req;
      (* no transparent gzip; peer MAX_HEADER_LIST_SIZE not tracked yet. *)
      add_gzip_header = false;
      peer_max_header_list_size = 0L;
      default_user_agent = Api.default_user_agent;
    }
  in
  let buf = Buffer.create 256 in
  Hpack.set_writer cc.henc (fun s -> Buffer.add_string buf s);
  let (_ : HC.encode_headers_result) =
    HC.encode_headers ~canonical:Header.canonical_header_key param
      (fun name value ->
        Hpack.write_field cc.henc { name; value; sensitive = false })
  in
  Buffer.contents buf

(* ---- request body writing (Go writeRequestBody + awaitFlowControl) ---- *)

(* await [1, min(maxBytes, maxFrameSize)] flow control tokens. *)
let rec await_flow_control cc cs max_bytes : int =
  if cc.closed then raise Client_conn_closed
  else
    match cs.abort_err with
    | Some e -> raise e
    | None ->
        let avail = Int32.to_int (H2_flow.available cs.flow) in
        if avail > 0 then begin
          let take = min (min avail max_bytes) cc.max_frame_size in
          H2_flow.take cs.flow (Int32.of_int take);
          take
        end
        else (
          Eio.Condition.await_no_mutex cc.cond;
          await_flow_control cc cs max_bytes)

(* write a chunk of the request body honoring flow control. *)
let write_data_chunk cc cs ~end_stream (data : string) : unit =
  let len = String.length data in
  let rec loop pos =
    if pos < len then begin
      let allowed = await_flow_control cc cs (len - pos) in
      let next = pos + allowed in
      let send_end = end_stream && next >= len in
      let piece = String.sub data pos allowed in
      Eio.Mutex.use_rw ~protect:false cc.wmu (fun () ->
          F.write_data cc.w cs.id send_end piece;
          Eio.Buf_write.flush cc.w);
      loop next
    end
  in
  if len > 0 then loop 0

(* send the request body then the terminating END_STREAM. *)
let write_request_body cc cs (req : Api.client_request) : unit =
  let send_empty_end () =
    Eio.Mutex.use_rw ~protect:false cc.wmu (fun () ->
        F.write_data cc.w cs.id true "";
        Eio.Buf_write.flush cc.w)
  in
  (match req.creq_body with
  | Body.Empty -> () (* END_STREAM already on HEADERS *)
  | Body.String s ->
      if String.length s > 0 then write_data_chunk cc cs ~end_stream:true s
  | Body.Stream next ->
      let rec pump () =
        match next () with
        | None -> send_empty_end ()
        | Some "" -> pump ()
        | Some data ->
            (* never set END_STREAM on a streamed chunk; send a trailing empty
               DATA frame to terminate. *)
            write_data_chunk cc cs ~end_stream:false data;
            pump ()
      in
      pump ());
  cs.sent_end_stream <- true

(* ---- response construction (Go handleResponse) ---- *)

let build_response cc cs (mf : F.meta_headers_frame) ~stream_ended :
    Api.client_response =
  let status = ref "" in
  let header = Header.create () in
  List.iter
    (fun (hf : Hpack.header_field) ->
      if String.length hf.name > 0 && hf.name.[0] = ':' then (
        if hf.name = ":status" then status := hf.value)
      else Header.add header (Header.canonical_header_key hf.name) hf.value)
    mf.fields;
  if !status = "" then raise (Malformed_response "missing status pseudo header");
  let status_code =
    match int_of_string_opt !status with
    | Some n -> n
    | None ->
        raise (Malformed_response "malformed non-numeric status pseudo header")
  in
  let content_length =
    match Header.values header "Content-Length" with
    | [ cl ] -> ( match Int64.of_string_opt cl with Some n -> n | None -> -1L)
    | [] -> if stream_ended && not cs.is_head then 0L else -1L
    | _ -> -1L
  in
  cs.bytes_remain <- Int64.to_int content_length;
  let body =
    if cs.is_head || stream_ended then Body.Empty
    else begin
      cs.body_is_stream <- true;
      H2_pipe.set_buffer cs.buf_pipe
        (H2_databuffer.create ~expected:content_length ());
      (* free the concurrency slot only once the body is fully read (EOF) — Go's
         forgetStreamID runs in cleanupWriteRequest after the body close, not at
         peer END_STREAM (transport.go:1523). *)
      Body.of_stream (fun () ->
          match H2_pipe.read cs.buf_pipe 4096 with
          | "" ->
              cleanup_write_request cc cs;
              None
          | s -> Some s
          | exception End_of_file ->
              cleanup_write_request cc cs;
              None)
    end
  in
  let status =
    match Httpg_base.Status.of_int_result status_code with
    | Ok status -> status
    | Error _ -> raise (Malformed_response "malformed status code")
  in
  (* status text, proto, and request back-pointer are filled by the public
     Transport shim (Go's http2RoundTrip). *)
  {
    Api.cres_status_code = status;
    cres_content_length = content_length;
    cres_uncompressed = false;
    cres_header = header;
    cres_trailer = Api.Header.create ();
    cres_body = body;
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
    signal_peer_closed cc cs;
    (* Peer half-closed (response fully received). For a streaming body the slot
       frees when the body reaches EOF (build_response); an Empty-body response
       (HEAD / stream-ended-on-headers) has nothing to drain, so its slot frees
       here — both routes end in cleanupWriteRequest's forgetStreamID
       (transport.go:1523). *)
    if not cs.body_is_stream then cleanup_write_request cc cs;
    Eio.Condition.broadcast cc.cond
  end

let end_stream_error cc cs err =
  cs.read_aborted <- true;
  abort_stream cc cs err

(* WINDOW_UPDATE writer (Go cc.fr.WriteWindowUpdate under wmu). *)
let send_window_update cc ~stream_id ~incr =
  if incr > 0 then
    Eio.Mutex.use_rw ~protect:false cc.wmu (fun () ->
        F.write_window_update cc.w stream_id incr;
        Eio.Buf_write.flush cc.w)

let process_headers cc (mf : F.meta_headers_frame) : unit =
  let id = mf.fh.stream_id in
  match stream_by_id cc id with
  | None -> () (* canceled/unknown stream; ignore *)
  | Some cs ->
      if cs.read_closed then
        end_stream_error cc cs
          (Stream_aborted (Failure "headers after END_STREAM"))
      else if mf.truncated then
        end_stream_error cc cs
          (Stream_aborted (Failure "response header list too large"))
      else if cs.past_headers then
        (* trailers: a HEADERS marking trailers carries END_STREAM. *)
        end_stream cc cs
      else begin
        cs.past_headers <- true;
        (* read_meta_headers preserves the HEADERS flags in mf.fh. *)
        let stream_ended = mf.fh.flags land H2.flag_end_stream <> 0 in
        match build_response cc cs mf ~stream_ended with
        | exception e -> end_stream_error cc cs (Stream_aborted e)
        | res ->
            let status_code =
              res.Api.cres_status_code |> Httpg_base.Status.to_int
            in
            if status_code >= 100 && status_code <= 199 then
              (* 1xx informational: ignore and await the real headers. *)
              cs.past_headers <- false
            else begin
              cs.res <- Some res;
              signal_resp_recv cc cs;
              if stream_ended then end_stream cc cs
            end
      end

let process_data cc (fh : F.frame_header) (df : F.data_frame) : unit =
  let id = fh.stream_id in
  let length = fh.length in
  match stream_by_id cc id with
  | None ->
      if id >= cc.next_stream_id then
        raise (H2_error.Connection_error H2_error.FlowControlError)
      else if length > 0 then begin
        (* return flow control for a canceled stream. *)
        let ok = H2_flow.inflow_take cc.conn_inflow length in
        let conn_add = H2_flow.inflow_add cc.conn_inflow length in
        if not ok then
          raise (H2_error.Connection_error H2_error.FlowControlError)
        else send_window_update cc ~stream_id:0 ~incr:(Int32.to_int conn_add)
      end
  | Some cs ->
      if cs.read_closed then
        end_stream_error cc cs
          (Stream_aborted (Failure "DATA after END_STREAM"))
      else if not cs.past_headers then
        end_stream_error cc cs (Stream_aborted (Failure "DATA before HEADERS"))
      else begin
        let data = df.data in
        if length > 0 then begin
          if not (H2_flow.take_inflows cc.conn_inflow cs.inflow length) then
            raise (H2_error.Connection_error H2_error.FlowControlError);
          (* padding refund: length includes padding stripped from [data]. *)
          let refund = ref (length - String.length data) in
          let did_reset = ref false in
          if String.length data > 0 then (
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
          send_window_update cc ~stream_id:0 ~incr:send_conn;
          send_window_update cc ~stream_id:id ~incr:send_stream
        end;
        if df.end_stream then end_stream cc cs
      end

let process_settings cc (sf : F.settings_frame) : unit =
  if sf.ack then
    begin if cc.want_settings_ack then cc.want_settings_ack <- false
    else raise (H2_error.Connection_error H2_error.ProtocolError)
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
            Eio.Condition.broadcast cc.cond
        | H2.Header_table_size ->
            Hpack.set_max_dynamic_table_size cc.henc (Int32.to_int s.value)
        | H2.Enable_push | H2.Max_header_list_size -> ())
      sf.settings;
    if not cc.seen_settings then begin
      if not !seen_mcs then
        cc.max_concurrent_streams <- default_max_concurrent_streams;
      cc.seen_settings <- true;
      Eio.Condition.broadcast cc.cond
    end;
    Eio.Mutex.use_rw ~protect:false cc.wmu (fun () ->
        F.write_settings_ack cc.w;
        Eio.Buf_write.flush cc.w)
  end

let process_window_update cc (fh : F.frame_header) (wf : F.window_update_frame)
    : unit =
  let id = fh.stream_id in
  if id = 0 then
    begin if not (H2_flow.add cc.conn_flow (Int32.of_int wf.increment)) then
      raise (H2_error.Connection_error H2_error.FlowControlError)
    else Eio.Condition.broadcast cc.cond
    end
  else
    match stream_by_id cc id with
    | None -> ()
    | Some cs ->
        if not (H2_flow.add cs.flow (Int32.of_int wf.increment)) then
          end_stream_error cc cs (Stream_aborted (Failure "flow control"))
        else Eio.Condition.broadcast cc.cond

let process_reset_stream cc (fh : F.frame_header) (rf : F.rst_stream_frame) :
    unit =
  match stream_by_id cc fh.stream_id with
  | None -> ()
  | Some cs ->
      let serr =
        Stream_aborted
          (H2_error.Stream_error
             (H2_error.stream_error fh.stream_id rf.error_code))
      in
      abort_stream cc cs serr;
      cs.read_aborted <- true;
      H2_pipe.close_with_error cs.buf_pipe serr

let process_ping cc (pf : F.ping_frame) : unit =
  if pf.ack then
    (* clear pendingResets on any PING ACK (transport.go:1500-1502 comment). *)
    begin if cc.pending_resets > 0 then begin
      cc.pending_resets <- 0;
      Eio.Condition.broadcast cc.cond
    end
    end
  else
    Eio.Mutex.use_rw ~protect:false cc.wmu (fun () ->
        F.write_ping cc.w true pf.data;
        Eio.Buf_write.flush cc.w)

let process_goaway cc (gf : F.goaway_frame) : unit =
  cc.goaway <- Some gf;
  let last = gf.last_stream_id in
  (* snapshot: abort_stream mutates cc.streams via forget_stream. *)
  let victims =
    Hashtbl.fold
      (fun sid cs acc -> if sid > last then cs :: acc else acc)
      cc.streams []
  in
  List.iter
    (fun cs ->
      abort_stream cc cs (Stream_aborted (Conn_got_goaway gf.error_code)))
    victims

(* mark the conn closed, record the reader error, abort pending streams. *)
let signal_reader_done cc err =
  cc.reader_err <- err;
  cc.closed <- true;
  let e = match err with Some e -> e | None -> Client_conn_closed in
  (* snapshot: abort_stream mutates cc.streams via forget_stream. *)
  let all = Hashtbl.fold (fun _ cs acc -> cs :: acc) cc.streams [] in
  List.iter (fun cs -> abort_stream cc cs (Stream_aborted e)) all;
  Eio.Condition.broadcast cc.cond

(* dispatch one frame (transport.go clientConnReadLoop.processFrame). *)
let process_frame cc (f : F.frame) : unit =
  match f with
  | F.Headers (fh, hf) ->
      (* assemble HEADERS+CONTINUATION; preserve the HEADERS flags. *)
      let mf =
        match F.read_meta_headers cc.hdec (fh, hf) cc.r with
        | Ok mf -> mf
        | Error e -> raise (H2_error.to_exception e)
      in
      let mf = { mf with F.fh = { mf.F.fh with flags = fh.flags } } in
      process_headers cc mf
  | F.Data (fh, df) -> process_data cc fh df
  | F.Settings (_, sf) -> process_settings cc sf
  | F.Window_update (fh, wf) -> process_window_update cc fh wf
  | F.RST_stream (fh, rf) -> process_reset_stream cc fh rf
  | F.Ping (_, pf) -> process_ping cc pf
  | F.GoAway (_, gf) -> process_goaway cc gf
  | F.Push_promise _ -> raise (H2_error.Connection_error H2_error.ProtocolError)
  | F.Priority _ | F.Continuation _ | F.Unknown _ -> ()

(* the read-loop fiber: read frames, dispatch. Mirrors Go's readLoop+run.
   Returns once the conn is closed (EOF or fatal error); the caller forks it
   into [cc.sw] and signals reader-done. *)
let read_loop cc : unit =
  let got_settings = ref false in
  let rec loop () =
    match
      match F.read_frame ~max_size:H2.default_max_read_frame_size cc.r with
      | Ok f -> f
      | Error e -> raise (H2_error.to_exception e)
    with
    | exception End_of_file -> signal_reader_done cc None
    (* F019: an over-cap frame escaping read_frame as Buffer_limit_exceeded maps
       to a FRAME_SIZE connection error. *)
    | exception Eio.Buf_read.Buffer_limit_exceeded ->
        signal_reader_done cc
          (Some (H2_error.Connection_error H2_error.FrameSizeError))
    | exception H2_error.Stream_error se ->
        (* stream-level frame error: reset that stream, keep going. *)
        (match stream_by_id cc se.stream_id with
        | Some cs ->
            end_stream_error cc cs (Stream_aborted (H2_error.Stream_error se))
        | None -> ());
        loop ()
    | exception e -> signal_reader_done cc (Some e)
    | f ->
        (* enforce: first frame must be SETTINGS. *)
        let is_settings = match f with F.Settings _ -> true | _ -> false in
        if (not !got_settings) && not is_settings then
          signal_reader_done cc
            (Some (H2_error.Connection_error H2_error.ProtocolError))
        else begin
          got_settings := !got_settings || is_settings;
          match process_frame cc f with
          | () -> loop ()
          | exception Eio.Buf_read.Buffer_limit_exceeded ->
              signal_reader_done cc
                (Some (H2_error.Connection_error H2_error.FrameSizeError))
          | exception e -> signal_reader_done cc (Some e)
        end
  in
  loop ()

(* ---- new_client_conn ---- *)

let new_client_conn ~sw r w : client_conn =
  let initial_stream_recv_window =
    4 lsl 20
    (* 4 MiB, Go default per-stream *)
  in
  let conn_recv_window =
    1 lsl 30
    (* 1 GiB, Go MaxReceiveBufferPerConnection *)
  in
  let conn_flow = H2_flow.create_outflow () in
  ignore (H2_flow.add conn_flow (Int32.of_int H2.initial_window_size));
  let conn_inflow = H2_flow.create_inflow () in
  H2_flow.inflow_init conn_inflow
    (Int32.of_int (conn_recv_window + H2.initial_window_size));
  let cc =
    {
      r;
      w;
      sw;
      wmu = Eio.Mutex.create ();
      henc = Hpack.new_encoder ();
      (* response decoder: emit replaced by read_meta_headers per call. *)
      hdec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ());
      conn_flow;
      conn_inflow;
      cond = Eio.Condition.create ();
      streams = Hashtbl.create 16;
      streams_reserved = 0;
      pending_resets = 0;
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
      reader_err = None;
      req_header_mu = Eio.Mutex.create ();
    }
  in
  (* write preface + initial SETTINGS + WINDOW_UPDATE (Go newClientConn). *)
  let initial_settings =
    [
      { H2.id = H2.Enable_push; value = 0l };
      {
        H2.id = H2.Initial_window_size;
        value = Int32.of_int initial_stream_recv_window;
      };
      { H2.id = H2.Max_frame_size; value = Int32.of_int (1 lsl 20) };
    ]
  in
  Eio.Buf_write.string w H2.client_preface;
  F.write_settings w initial_settings;
  F.write_window_update w 0 conn_recv_window;
  Eio.Buf_write.flush w;
  (* start the read loop as a daemon: cancelled when the conn switch ends. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try read_loop cc with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> signal_reader_done cc (Some e));
      `Stop_daemon);
  (* wait until the server's SETTINGS is seen (or the reader died). *)
  let rec wait_seen () =
    if cc.seen_settings then ()
    else if cc.closed then
      raise
        (match cc.reader_err with Some e -> e | None -> Client_conn_closed)
    else (
      Eio.Condition.await_no_mutex cc.cond;
      wait_seen ())
  in
  wait_seen ();
  cc

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
    resp_recv_done = false;
    peer_closed_done = false;
    abort_err = None;
    past_headers = false;
    read_closed = false;
    read_aborted = false;
    is_head;
    sent_end_stream = false;
    cleaned = false;
    body_is_stream = false;
  }

(* wait for the response headers, an abort, or the reader to die. *)
let await_response cc cs : Api.client_response =
  let rec loop () =
    match cs.res with
    | Some res -> res
    | None -> (
        match cs.abort_err with
        | Some e -> raise e
        | None ->
            if cc.closed then
              raise
                (match cc.reader_err with
                | Some e -> e
                | None -> Client_conn_closed)
            else (
              Eio.Condition.await_no_mutex cc.cond;
              loop ()))
  in
  loop ()

(* awaitOpenSlotForStreamLocked (transport.go:1537): block until the concurrency
   count is below the peer's MAX_CONCURRENT_STREAMS. Caller holds req_header_mu,
   so the count check and the table insert that follows are switch-free between
   waiters (slots free via the read loop's forget_stream broadcast). *)
let rec await_open_slot cc =
  (* Conn died while we waited for a slot; nothing written yet (transport.go
     :530 errClientConnUnusable). *)
  if cc.closed || cc.closing then raise Conn_unusable
  else if current_request_count cc < cc.max_concurrent_streams then ()
  else (
    Eio.Condition.await_no_mutex cc.cond;
    await_open_slot cc)

(* ReserveNewRequest (transport.go:744): reserve a concurrency slot so a pooled
   conn can be handed out without overshooting MAX_CONCURRENT_STREAMS. The
   reservation is decremented by the next [round_trip]. Returns false if the conn
   can't take a new request. *)
let reserve_new_request cc =
  if cc.closed || cc.closing then false
  else if current_request_count cc >= cc.max_concurrent_streams then false
  else begin
    cc.streams_reserved <- cc.streams_reserved + 1;
    true
  end

(* decrStreamReservationsLocked (transport.go:1093). *)
let decr_stream_reservations cc =
  if cc.streams_reserved > 0 then cc.streams_reserved <- cc.streams_reserved - 1

let round_trip ?sw cc (req : Api.client_request) : Api.client_response =
  (* errClientConnUnusable (transport.go:530): conn dead before we wrote
     anything, so the request is untouched and replayable on a fresh dial. *)
  if cc.closed || cc.closing then raise Conn_unusable
  else begin
    let is_head = req.creq_meth = Httpg_base.Method.Head in
    let acl = actual_content_length req in
    let has_body = acl <> 0 in
    (* await a slot + allocate stream id + write HEADERS under req_header_mu (Go
       reqHeaderMu); the slot wait + table insert are atomic per waiter. *)
    let cs =
      Eio.Mutex.use_rw ~protect:false cc.req_header_mu (fun () ->
          (* consume any reservation made by [reserve_new_request] before the
             slot wait, mirroring decrStreamReservationsLocked (transport.go
             :1270). *)
          decr_stream_reservations cc;
          await_open_slot cc;
          let id = cc.next_stream_id in
          cc.next_stream_id <- cc.next_stream_id + 2;
          let cs = make_stream cc id ~is_head in
          Hashtbl.replace cc.streams id cs;
          (* wire caller-done teardown the instant the stream exists, before any
             cancellation point (the HEADERS flush below), so an early cancel
             still forgets it (transport.go:1217). *)
          (match sw with
          | Some s ->
              Eio.Switch.on_release s (fun () -> cleanup_write_request cc cs)
          | None -> ());
          let hdrs = encode_request_headers cc req acl in
          let end_stream = not has_body in
          if end_stream then cs.sent_end_stream <- true;
          Eio.Mutex.use_rw ~protect:false cc.wmu (fun () ->
              write_headers_block cc ~stream_id:id ~end_stream hdrs);
          cs)
    in
    (* Fork the request-body pump so the response can be read concurrently (Go's
       doRequest goroutine); it lives on the conn switch. It must NOT fork onto
       the caller's [sw], or [Switch.run sw] would block waiting for a parked
       writer to finish. Instead cleanup_write_request, run on [sw] release
       (caller done: early return / undrained body / cancel — F020), aborts the
       stream: that sets abort_err, so a writer parked in await_flow_control wakes
       and exits, and forgets the stream — no writer fiber or table entry lingers
       past the caller's interest (transport.go:1217 cleanupWriteRequest). *)
    if has_body then
      Eio.Fiber.fork ~sw:cc.sw (fun () ->
          try write_request_body cc cs req with
          | Eio.Cancel.Cancelled _ -> ()
          | e -> abort_stream cc cs (Stream_aborted e));
    await_response cc cs
  end

let close cc : unit =
  cc.closing <- true;
  signal_reader_done cc None

(* Whether the conn is closed / no longer usable (Go [closed] / negation of
   canTakeNewRequest). Exposed so a transport pool can drop dead conns. *)
let is_closed cc = cc.closed || cc.closing

(* Number of live streams in the table (Go's len(cc.streams)); for tests
   asserting cleanup/forget leaves no entry lingering. *)
let live_stream_count cc = Hashtbl.length cc.streams
