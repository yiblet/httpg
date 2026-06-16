(* Port of the client subset of go/src/net/http/internal/http2/transport.go and
   client_conn_pool.go. See h2_transport.mli for the goroutine -> Eio fiber
   mapping. *)

module F = H2_frame
module Body = Api.Body
module Header = Api.Header

(* The frame writers thread their build invariants as [(unit, H2_error.t)
   result] (ticket 013). The transport's stream / dep ids and frame sizes are
   built from valid client state, so those invariants are unreachable here;
   [must_write] turns the impossible [Error] into the programming bug it would
   be (and lets the control-frame call sites stay unit-typed). *)
let must_write : (unit, H2_error.t) result -> unit = function
  | Ok () -> ()
  | Error _ -> invalid_arg "H2_transport: frame-build invariant violated (bug)"

(* Handleable failures surfaced by [round_trip] as an [Error] arm (the external
   boundary of the decoupled h2 client). These are produced and carried as
   VALUES across the per-connection fibers (ticket 014): the read-loop /
   body-pump / cleanup fibers set [cc.reader_err] / [cs.abort_err] to an
   [error], and the request fiber's [await_response] reads that value back —
   there is no carrier exception threaded across the fiber boundary. *)
type error =
  | Conn_closed
  | Conn_unusable
  | Got_goaway of H2_error.err_code
  | Malformed_response of string
  | Request_canceled
  | Request_invalid of string
  | Request_header_list_size

let error_to_string = function
  | Conn_closed -> "h2: client connection closed"
  | Conn_unusable -> "h2: client connection unusable"
  | Got_goaway c ->
      Printf.sprintf "h2: server sent GOAWAY (%s)"
        (H2_error.Private.err_code_string c)
  | Malformed_response s -> Printf.sprintf "h2: malformed response: %s" s
  | Request_canceled -> "h2: request canceled"
  | Request_invalid s -> Printf.sprintf "h2: invalid request: %s" s
  | Request_header_list_size ->
      "h2: request header list larger than peer's advertised limit"

(* Body-pump fiber unwind, PRIVATE to this module (never declared in the .mli).
   The forked body-writer fiber ([write_request_body]) signals an aborted write
   to itself by raising this; its own [try…with] catches it and exits the fiber.
   The handleable cause is already recorded on [cs.abort_err] as an [error]
   value before the raise, so nothing crosses the fiber boundary AS an
   exception — this is purely a local non-local exit out of the writer fiber. *)
exception Body_write_aborted

(* Pipe-break cause attached to a stream's response body pipe ([cs.buf_pipe])
   when the stream is aborted (RST_STREAM / GOAWAY / unclean teardown) while a
   client is reading the response body. {!H2_pipe} carries the close cause as an
   [exn]; on the next body read it is raised, carrying the handleable {!error}.
   It crosses the read-loop -> response-body-reader boundary only through the
   pipe (an Eio-style channel). PRIVATE to this module (never in the .mli);
   [None] cause (clean EOF) uses [End_of_file] as before. *)
exception Pipe_aborted of error

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
  mutable abort_err : error option; (* set on stream error / RST / GOAWAY *)
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
  mutable reader_err : error option;
      (* set when the read loop ends with a modeled error (None = clean EOF) *)
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

(* abort a stream: set abort_err (an [error] value) once, forget it, wake
   waiters. *)
let abort_stream cc cs (err : error) =
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
        cs.abort_err <- Some Request_canceled;
        (* break the response pipe so a parked body reader unblocks; no-op if
           already closed. *)
        H2_pipe.break_with_error cs.buf_pipe (Pipe_aborted Request_canceled)
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
      must_write
        (if first then
           F.write_headers cc.w ~stream_id ~end_stream ~end_headers chunk
         else F.write_continuation cc.w stream_id end_headers chunk);
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
   httpcommon.EncodeHeaders (Go encodeAndWriteHeaders, sans wmu plumbing). The
   underlying [Httpcommon.encode_headers] already returns a [result]; thread it
   so an invalid request becomes an [Error] without an internal raise/catch
   bridge (it propagates up through the HEADERS-write mutex closure as a
   [result]). *)
let encode_request_headers cc (req : Api.client_request) (acl : int) :
    (string, Httpg_internal.Httpcommon.error) result =
  let url = req.creq_url in
  let host =
    if req.creq_host <> "" then req.creq_host
    else
      match Uri.host url with
      | Some h -> (
          match Uri.port url with
          | Some p -> Printf.sprintf "%s:%d" h p
          | None -> h)
      | None -> ""
  in
  let hc_req : HC.request =
    {
      url_scheme = (match Uri.scheme url with Some s -> s | None -> "");
      url_host = host;
      request_uri = request_uri_of url;
      url_opaque = "";
      meth = req.creq_meth;
      host = req.creq_host;
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
  match
    HC.encode_headers ~canonical:Header.canonical_header_key param
      (fun name value ->
        Hpack.write_field cc.henc { name; value; sensitive = false })
  with
  | Ok (_ : HC.encode_headers_result) -> Ok (Buffer.contents buf)
  | Error e -> Error e

(* ---- request body writing (Go writeRequestBody + awaitFlowControl) ---- *)

(* await [1, min(maxBytes, maxFrameSize)] flow control tokens. *)
let rec await_flow_control cc cs max_bytes : int =
  (* Runs in the forked body-pump fiber. On conn-close / stream-abort it records
     the [error] on [cs.abort_err] (so [await_response] sees it) and unwinds the
     writer fiber via the module-private [Body_write_aborted]. *)
  if cc.closed then begin
    (match cs.abort_err with
    | Some _ -> ()
    | None ->
        cs.abort_err <-
          Some (match cc.reader_err with Some e -> e | None -> Conn_closed));
    raise Body_write_aborted
  end
  else
    match cs.abort_err with
    | Some _ -> raise Body_write_aborted
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
          must_write (F.write_data cc.w cs.id send_end piece);
          Eio.Buf_write.flush cc.w);
      loop next
    end
  in
  if len > 0 then loop 0

(* send the request body then the terminating END_STREAM. *)
let write_request_body cc cs (req : Api.client_request) : unit =
  let send_empty_end () =
    Eio.Mutex.use_rw ~protect:false cc.wmu (fun () ->
        must_write (F.write_data cc.w cs.id true "");
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

(* Build the response, or an [Error (Malformed_response …)] on a bad status
   pseudo-header (Go's handleResponse error returns). Runs in the read-loop
   fiber; [process_headers] routes an [Error] through [end_stream_error]. *)
let build_response cc cs (mf : F.meta_headers_frame) ~stream_ended :
    (Api.client_response, error) result =
  let ( let* ) = Result.bind in
  let status = ref "" in
  let header = Header.create () in
  List.iter
    (fun (hf : Hpack.header_field) ->
      if String.length hf.name > 0 && hf.name.[0] = ':' then (
        if hf.name = ":status" then status := hf.value)
      else Header.add header (Header.canonical_header_key hf.name) hf.value)
    mf.fields;
  let* status_code =
    if !status = "" then
      Error (Malformed_response "missing status pseudo header")
    else
      match int_of_string_opt !status with
      | Some n -> Ok n
      | None ->
          Error
            (Malformed_response "malformed non-numeric status pseudo header")
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
  let* status =
    match Httpg_base.Status.of_int_result status_code with
    | Ok status -> Ok status
    | Error _ -> Error (Malformed_response "malformed status code")
  in
  (* status text, proto, and request back-pointer are filled by the public
     Transport shim (Go's http2RoundTrip). *)
  Ok
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
        must_write (F.write_window_update cc.w stream_id incr);
        Eio.Buf_write.flush cc.w)

let process_headers cc (mf : F.meta_headers_frame) : unit =
  let id = mf.fh.stream_id in
  match stream_by_id cc id with
  | None -> () (* canceled/unknown stream; ignore *)
  | Some cs ->
      if cs.read_closed then
        end_stream_error cc cs (Malformed_response "headers after END_STREAM")
      else if mf.truncated then
        end_stream_error cc cs
          (Malformed_response "response header list too large")
      else if cs.past_headers then
        (* trailers: a HEADERS marking trailers carries END_STREAM. *)
        end_stream cc cs
      else begin
        cs.past_headers <- true;
        (* read_meta_headers preserves the HEADERS flags in mf.fh. *)
        let stream_ended = mf.fh.flags land H2.flag_end_stream <> 0 in
        match build_response cc cs mf ~stream_ended with
        | Error err -> end_stream_error cc cs err
        | Ok res ->
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

(* The connection-level [process_*] family threads modeled protocol violations
   as [(unit, H2_error.t) result] up to [read_loop], which dispatches the
   [Error] by value to [signal_reader_done] (no raise/re-catch round trip).
   [inflow_add]'s [Error] flow-control code is lifted into that connection
   error here (ticket 008). *)
let ( let* ) = Result.bind
let conn_err code : (unit, H2_error.t) result = Error (H2_error.Connection code)

(* lift [inflow_add]'s [(int32, err_code) result] into the connection-error
   monad, mapping a flow-control overflow to a connection-level [Error]. *)
let inflow_add f n : (int32, H2_error.t) result =
  match H2_flow.inflow_add f n with
  | Ok v -> Ok v
  | Error code -> Error (H2_error.Connection code)

let process_data cc (fh : F.frame_header) (df : F.data_frame) :
    (unit, H2_error.t) result =
  let id = fh.stream_id in
  let length = fh.length in
  match stream_by_id cc id with
  | None ->
      if id >= cc.next_stream_id then conn_err H2_error.FlowControlError
      else if length > 0 then begin
        (* return flow control for a canceled stream. *)
        let ok = H2_flow.inflow_take cc.conn_inflow length in
        let* conn_add = inflow_add cc.conn_inflow length in
        if not ok then conn_err H2_error.FlowControlError
        else begin
          send_window_update cc ~stream_id:0 ~incr:(Int32.to_int conn_add);
          Ok ()
        end
      end
      else Ok ()
  | Some cs ->
      if cs.read_closed then begin
        end_stream_error cc cs (Malformed_response "DATA after END_STREAM");
        Ok ()
      end
      else if not cs.past_headers then begin
        end_stream_error cc cs (Malformed_response "DATA before HEADERS");
        Ok ()
      end
      else begin
        let data = df.data in
        let* () =
          if length > 0 then
            if not (H2_flow.take_inflows cc.conn_inflow cs.inflow length) then
              conn_err H2_error.FlowControlError
            else begin
              (* padding refund: length includes padding stripped from [data]. *)
              let refund = ref (length - String.length data) in
              let did_reset = ref false in
              (if String.length data > 0 then
                 match H2_pipe.write cs.buf_pipe data with
                 | Ok _ -> ()
                 | Error _ ->
                     did_reset := true;
                     refund := !refund + String.length data);
              let* conn_add = inflow_add cc.conn_inflow !refund in
              let send_conn = Int32.to_int conn_add in
              let* stream_add =
                if !did_reset then Ok 0l else inflow_add cs.inflow !refund
              in
              let send_stream = Int32.to_int stream_add in
              send_window_update cc ~stream_id:0 ~incr:send_conn;
              send_window_update cc ~stream_id:id ~incr:send_stream;
              Ok ()
            end
          else Ok ()
        in
        if df.end_stream then end_stream cc cs;
        Ok ()
      end

let process_settings cc (sf : F.settings_frame) : (unit, H2_error.t) result =
  if sf.ack then
    if cc.want_settings_ack then begin
      cc.want_settings_ack <- false;
      Ok ()
    end
    else conn_err H2_error.ProtocolError
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
        must_write (F.write_settings_ack cc.w);
        Eio.Buf_write.flush cc.w);
    Ok ()
  end

let process_window_update cc (fh : F.frame_header) (wf : F.window_update_frame)
    : (unit, H2_error.t) result =
  let id = fh.stream_id in
  if id = 0 then
    if not (H2_flow.add cc.conn_flow (Int32.of_int wf.increment)) then
      conn_err H2_error.FlowControlError
    else begin
      Eio.Condition.broadcast cc.cond;
      Ok ()
    end
  else begin
    (match stream_by_id cc id with
    | None -> ()
    | Some cs ->
        if not (H2_flow.add cs.flow (Int32.of_int wf.increment)) then
          end_stream_error cc cs (Malformed_response "flow control")
        else Eio.Condition.broadcast cc.cond);
    Ok ()
  end

let process_reset_stream cc (fh : F.frame_header) (rf : F.rst_stream_frame) :
    unit =
  match stream_by_id cc fh.stream_id with
  | None -> ()
  | Some cs ->
      (* the peer reset the stream: surface it as a handleable response failure
         carrying the RST code (Go's clientStream sees a StreamError). *)
      let err =
        Malformed_response
          (Printf.sprintf "stream reset by peer (%s)"
             (H2_error.Private.err_code_string rf.error_code))
      in
      abort_stream cc cs err;
      cs.read_aborted <- true;
      H2_pipe.close_with_error cs.buf_pipe (Pipe_aborted err)

let process_ping cc (pf : F.ping_frame) : unit =
  if pf.ack then begin
    (* clear pendingResets on any PING ACK (transport.go:1500-1502 comment). *)
    if cc.pending_resets > 0 then begin
      cc.pending_resets <- 0;
      Eio.Condition.broadcast cc.cond
    end
  end
  else
    Eio.Mutex.use_rw ~protect:false cc.wmu (fun () ->
        must_write (F.write_ping cc.w true pf.data);
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
  List.iter (fun cs -> abort_stream cc cs (Got_goaway gf.error_code)) victims

(* mark the conn closed, record the reader error (an [error] value; [None] =
   clean EOF), abort pending streams. *)
let signal_reader_done cc (err : error option) =
  cc.reader_err <- err;
  cc.closed <- true;
  let e = match err with Some e -> e | None -> Conn_closed in
  (* snapshot: abort_stream mutates cc.streams via forget_stream. *)
  let all = Hashtbl.fold (fun _ cs acc -> cs :: acc) cc.streams [] in
  List.iter (fun cs -> abort_stream cc cs e) all;
  Eio.Condition.broadcast cc.cond

(* dispatch one frame (transport.go clientConnReadLoop.processFrame). The
   connection-level [process_*] thread their modeled violations as [Error];
   the stream-affecting handlers ([process_headers]/[process_reset_stream]) and
   the side-effect-only ones ([process_ping]/[process_goaway]) stay unit and are
   wrapped [Ok ()] here. *)
let process_frame cc (f : F.frame) : (unit, H2_error.t) result =
  match f with
  | F.Headers (fh, hf) -> (
      (* assemble HEADERS+CONTINUATION; preserve the HEADERS flags. *)
      match F.read_meta_headers cc.hdec (fh, hf) cc.r with
      | Error e -> Error e
      | Ok mf ->
          let mf = { mf with F.fh = { mf.F.fh with flags = fh.flags } } in
          process_headers cc mf;
          Ok ())
  | F.Data (fh, df) -> process_data cc fh df
  | F.Settings (_, sf) -> process_settings cc sf
  | F.Window_update (fh, wf) -> process_window_update cc fh wf
  | F.RST_stream (fh, rf) ->
      process_reset_stream cc fh rf;
      Ok ()
  | F.Ping (_, pf) ->
      process_ping cc pf;
      Ok ()
  | F.GoAway (_, gf) ->
      process_goaway cc gf;
      Ok ()
  | F.Push_promise _ -> conn_err H2_error.ProtocolError
  | F.Priority _ | F.Continuation _ | F.Unknown _ -> Ok ()

(* the read-loop fiber: read frames, dispatch. Mirrors Go's readLoop+run.
   Returns once the conn is closed (EOF or fatal error); the caller forks it
   into [cc.sw] and signals reader-done. *)
let read_loop cc : unit =
  let got_settings = ref false in
  (* A stream-level framing error ([H2_error.Stream]) resets just that stream and
     keeps the loop going; any connection-level framing error is terminal — the
     conn is dead, so awaiting streams see [Conn_closed]. The carried
     [H2_error.t] is dispatched purely by value (no carrier exception). *)
  let on_read_error (e : H2_error.t) : [ `Continue | `Done of error ] =
    match e with
    | H2_error.Stream se ->
        (match stream_by_id cc se.stream_id with
        | Some cs ->
            let err =
              Malformed_response
                (Printf.sprintf "stream error (%s)"
                   (H2_error.Private.err_code_string se.code))
            in
            end_stream_error cc cs err
        | None -> ());
        `Continue
    | _ -> `Done Conn_closed
  in
  let rec loop () =
    match F.read_frame ~max_size:H2.default_max_read_frame_size cc.r with
    (* The framing boundary returns a [result]; dispatch the [Error] by value.
       Eio's own raises at the read boundary still escape and are contained here:
       a clean [End_of_file] is a clean close; a [Buffer_limit_exceeded]
       (over-cap frame, F019) terminates the conn. *)
    | exception End_of_file -> signal_reader_done cc None
    | exception Eio.Buf_read.Buffer_limit_exceeded ->
        signal_reader_done cc (Some Conn_closed)
    | exception e -> raise e (* bug-class / Eio.Cancel: propagate (daemon). *)
    | Error e -> (
        match on_read_error e with
        | `Continue -> loop ()
        | `Done err -> signal_reader_done cc (Some err))
    | Ok f ->
        (* enforce: first frame must be SETTINGS. *)
        let is_settings = match f with F.Settings _ -> true | _ -> false in
        if (not !got_settings) && not is_settings then
          signal_reader_done cc (Some Conn_closed)
        else begin
          got_settings := !got_settings || is_settings;
          match process_frame cc f with
          | Ok () -> loop ()
          (* Modeled protocol violations are dispatched by value: a stream-level
             error resets just that stream and the loop continues; any
             connection-level error is terminal. *)
          | Error e -> (
              match on_read_error e with
              | `Continue -> loop ()
              | `Done err -> signal_reader_done cc (Some err))
          (* An over-cap CONTINUATION escaping read_meta_headers as Buffer_limit
             terminates the conn; bug-class / Cancel propagate. *)
          | exception Eio.Buf_read.Buffer_limit_exceeded ->
              signal_reader_done cc (Some Conn_closed)
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
  must_write (F.write_settings w initial_settings);
  must_write (F.write_window_update w 0 conn_recv_window);
  Eio.Buf_write.flush w;
  (* start the read loop as a daemon: cancelled when the conn switch ends.
     Eio-boundary catch: a read-side IO failure (TCP reset, etc.) means the conn
     is dead -> record [Conn_closed]; bug-class exns and [Eio.Cancel] propagate
     out of the daemon (the residual floor). *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try read_loop cc with
      | ( Eio.Cancel.Cancelled _ | Assert_failure _ | Match_failure _
        | Invalid_argument _ | Stack_overflow | Out_of_memory ) as e ->
          raise e
      | _ -> signal_reader_done cc (Some Conn_closed));
      `Stop_daemon);
  (* wait until the server's SETTINGS is seen (or the reader died). *)
  let rec wait_seen () =
    if cc.seen_settings then ()
    else if cc.closed then
      raise
        (Failure
           (error_to_string
              (match cc.reader_err with Some e -> e | None -> Conn_closed)))
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

(* wait for the response headers, an abort, or the reader to die. Runs in the
   request fiber itself; it reads the [error] VALUE set by the read-loop /
   body-pump / cleanup fibers (no carrier exception crosses the boundary) and
   returns it as an [Error]. [Eio.Condition.await_no_mutex] still raises
   [Eio.Cancel.Cancelled] on a cancelled request scope — that propagates. *)
let await_response cc cs : (Api.client_response, error) result =
  let rec loop () =
    match cs.res with
    | Some res -> Ok res
    | None -> (
        match cs.abort_err with
        | Some err -> Error err
        | None ->
            if cc.closed then
              Error
                (match cc.reader_err with Some e -> e | None -> Conn_closed)
            else (
              Eio.Condition.await_no_mutex cc.cond;
              loop ()))
  in
  loop ()

(* awaitOpenSlotForStreamLocked (transport.go:1537): block until the concurrency
   count is below the peer's MAX_CONCURRENT_STREAMS. Caller holds req_header_mu,
   so the count check and the table insert that follows are switch-free between
   waiters (slots free via the read loop's forget_stream broadcast). *)
let rec await_open_slot cc : (unit, [ `Conn_unusable ]) result =
  (* Conn died while we waited for a slot; nothing written yet (transport.go
     :530 errClientConnUnusable). Returned by value so it propagates out of the
     HEADERS-write mutex closure as a [result] rather than a raise/catch. *)
  if cc.closed || cc.closing then Error `Conn_unusable
  else if current_request_count cc < cc.max_concurrent_streams then Ok ()
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

(* Map an [Httpcommon.encode_headers] failure to the matching request [error].
   Threaded out of [encode_request_headers] as a [result] (no raise). *)
let error_of_encode (e : Httpg_internal.Httpcommon.error) : error =
  match e with
  | HC.Invalid_request s -> Request_invalid s
  | HC.Header_list_size -> Request_header_list_size

let round_trip ?sw cc (req : Api.client_request) :
    (Api.client_response, error) result =
  (* errClientConnUnusable (transport.go:530): conn dead before we wrote
     anything, so the request is untouched and replayable on a fresh dial.
     Returned by value (no raise) so the transport pool's evict + fresh-dial
     retry branches on [Error Conn_unusable]. *)
  if cc.closed || cc.closing then Error Conn_unusable
  else begin
    let is_head = req.creq_meth = Httpg_base.Method.Head in
    let acl = actual_content_length req in
    let has_body = acl <> 0 in
    (* await a slot + allocate stream id + write HEADERS under req_header_mu (Go
       reqHeaderMu); the slot wait + table insert are atomic per waiter. The
       closure value is the result that [Eio.Mutex.use_rw] returns: a slot-wait
       conn-death and an encode rejection propagate out of the mutex as [Error]
       (no raise to escape the mutex). *)
    let cs_result : (client_stream, error) result =
      Eio.Mutex.use_rw ~protect:false cc.req_header_mu (fun () ->
          (* consume any reservation made by [reserve_new_request] before the
             slot wait, mirroring decrStreamReservationsLocked (transport.go
             :1270). *)
          decr_stream_reservations cc;
          match await_open_slot cc with
          | Error `Conn_unusable -> Error Conn_unusable
          | Ok () -> (
              let id = cc.next_stream_id in
              cc.next_stream_id <- cc.next_stream_id + 2;
              let cs = make_stream cc id ~is_head in
              Hashtbl.replace cc.streams id cs;
              (* wire caller-done teardown the instant the stream exists, before
                 any cancellation point (the HEADERS flush below), so an early
                 cancel still forgets it (transport.go:1217). *)
              (match sw with
              | Some s ->
                  Eio.Switch.on_release s (fun () ->
                      cleanup_write_request cc cs)
              | None -> ());
              match encode_request_headers cc req acl with
              | Error e ->
                  (* Encode rejected the request: nothing was written, so forget
                     the just-allocated stream and surface the typed error. *)
                  cleanup_write_request cc cs;
                  Error (error_of_encode e)
              | Ok hdrs ->
                  let end_stream = not has_body in
                  if end_stream then cs.sent_end_stream <- true;
                  Eio.Mutex.use_rw ~protect:false cc.wmu (fun () ->
                      write_headers_block cc ~stream_id:id ~end_stream hdrs);
                  Ok cs))
    in
    match cs_result with
    | Error _ as e -> e
    | Ok cs ->
        (* Fork the request-body pump so the response can be read concurrently
           (Go's doRequest goroutine); it lives on the conn switch. It must NOT
           fork onto the caller's [sw], or [Switch.run sw] would block waiting
           for a parked writer to finish. Instead cleanup_write_request, run on
           [sw] release (caller done: early return / undrained body / cancel —
           F020), aborts the stream: that sets abort_err, so a writer parked in
           await_flow_control wakes and exits, and forgets the stream — no writer
           fiber or table entry lingers past the caller's interest
           (transport.go:1217 cleanupWriteRequest). *)
        if has_body then
          Eio.Fiber.fork ~sw:cc.sw (fun () ->
              try write_request_body cc cs req with
              (* The body-pump fiber records its handleable cause on
                 [cs.abort_err] as an [error] VALUE (in [await_flow_control] /
                 here) — nothing crosses the fiber boundary as an exception.
                 [Body_write_aborted] is its own non-local exit (cause already
                 recorded). [Eio.Cancel] propagates (teardown); any other IO
                 failure means the write died, so record [Conn_closed]. *)
              | Body_write_aborted -> ()
              | ( Eio.Cancel.Cancelled _ | Assert_failure _ | Match_failure _
                | Invalid_argument _ | Stack_overflow | Out_of_memory ) as e ->
                  raise e
              | _ -> abort_stream cc cs Conn_closed);
        (* [await_response] returns the [error] VALUE set by another fiber
           ([cs.abort_err] / [cc.reader_err]) as an [Error] — no carrier
           exception. [Eio.Cancel] from a cancelled request scope still
           propagates out of [await_response]'s condition wait. *)
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
