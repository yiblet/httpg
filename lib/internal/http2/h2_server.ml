(* Port of the HTTP/2 subset of go/src/net/http/internal/http2/server.go.
   See h2_server.mli for the Go -> Lwt concurrency mapping. *)

module Body = Api.Body
module Header = Api.Header
module Context = Httpg_base.Context

(* The handler-facing ResponseWriter and Handler now live in Api (Go's api.go). *)
type response_writer = Api.response_writer
type handler = Api.handler

(* Go: defaultMaxStreams = 250 *)
let default_max_concurrent_streams = 250

(* Go's handlerChunkWriteSize (server.go:60): the size of the [bufio.Writer]
   wrapping the [chunkWriter]. A handler [Write] buffers into this writer; once
   it fills, the writer flushes whole chunks down to [chunkWriter.Write], which
   frames a DATA frame. So DATA is emitted as the handler writes (every ~4 KiB
   without an explicit Flush), not held until the handler returns. *)
let handler_chunk_write_size = 4 * 1024

(* Go: maxQueuedControlFrames *)
let max_queued_control_frames = 10000

(* stream state (Go's streamState). *)
type stream_state =
  | State_idle
  | State_open
  | State_half_closed_local
  | State_half_closed_remote
  | State_closed

(* Go's [stream]. The scheduling [sched] record (id, outflow, max_frame_size)
   is the {!H2_writesched.stream} shared by reference with the scheduler. *)
type stream = {
  st_id : int;
  sched : H2_writesched.stream;
      (* carries id + outbound flow + max_frame_size *)
  mutable body : H2_pipe.t option; (* non-nil if expecting DATA *)
  mutable inflow : H2_flow.inflow; (* what the client may POST to us *)
  mutable body_bytes : int64;
  mutable decl_body_bytes : int64; (* -1 if undeclared *)
  mutable state : stream_state;
  mutable reset_queued : bool;
  mutable got_trailer_header : bool;
  mutable wrote_headers : bool;
  mutable close_err : exn option;
  (* closed when the stream transitions to closed (Go's stream.cw). *)
  cw : unit Lwt_condition.t;
  mutable cw_closed : bool;
  mutable trailer : Header.t; (* accumulated trailers *)
  mutable req_trailer : Header.t option; (* handler's Request.Trailer *)
}

(* Result reported back to a handler blocked in writeDataFromHandler /
   writeHeaders: Ok () or the error that closed the stream. *)
type write_result = (unit, exn) result

(* A frame-write request as queued through the serve loop. Mirrors the parts of
   Go's FrameWriteRequest the loop needs, plus the handler's reply condition. *)
type frame_write_req = {
  fw : H2_writesched.frame_write_request;
  (* reply, if a handler is blocked waiting for this frame to be written *)
  reply : write_result Lwt_condition.t option;
}

(* Events posted to the serve loop. This is the Lwt analogue of Go's serve()
   select over readFrameCh / wantWriteFrameCh / wroteFrameCh / bodyReadCh /
   serveMsgCh. *)
type event =
  | Read_frame of H2_frame.frame
  | Read_meta of H2_frame.meta_headers_frame
  | Read_error of exn
  | Want_write_frame of frame_write_req
  | Body_read of stream * int (* handler read n bytes of stream body *)
  | Handler_done

type server_conn = {
  ic : Lwt_io.input_channel;
  oc : Lwt_io.output_channel;
  handler : handler;
  enc : Hpack.encoder; (* response header encoder; owned by serve loop *)
  dec : Hpack.decoder; (* request header decoder; used by reader fiber *)
  events : event Lwt_stream.t;
  push_event : event option -> unit;
  flow : H2_flow.outflow; (* conn-wide outbound flow *)
  mutable conn_inflow : H2_flow.inflow; (* conn-wide inbound flow *)
  write_sched : H2_writesched.t;
  streams : (int, stream) Hashtbl.t;
  adv_max_streams : int;
  adv_max_header_list_size : int;
      (* advertised SETTINGS_MAX_HEADER_LIST_SIZE; also the HPACK decode budget.
       Go's sc.maxHeaderListSize() (server.go:499-505). *)
  mutable saw_first_settings : bool;
  mutable need_to_send_settings_ack : bool;
  mutable unacked_settings : int;
  mutable queued_control_frames : int;
  mutable cur_client_streams : int;
  mutable cur_handlers : int;
  mutable max_client_stream_id : int;
  mutable initial_stream_send_window : int;
  mutable initial_stream_recv_window : int;
  mutable max_frame_size : int;
  (* peer's SETTINGS_MAX_FRAME_SIZE for our writes *)
  (* GOAWAY / shutdown bookkeeping *)
  mutable in_goaway : bool;
  mutable need_to_send_goaway : bool;
  mutable goaway_code : H2_error.err_code;
  mutable serving_done : bool; (* serve loop has ended; unblocks handlers *)
  done_serving : unit Lwt_condition.t;
  (* unstarted handlers queued when over MAX_CONCURRENT_STREAMS.
     A Queue (FIFO) rather than a list with O(n) [@ [..]] append, since under
     a rapid-reset flood this churns hot (CVE-2023-44487). *)
  unstarted : (int * (unit -> unit Lwt.t)) Queue.t;
}

(* ---- helpers ---- *)

let is_pseudo name = String.length name > 0 && name.[0] = ':'

(* The originating HEADERS frame's END_STREAM flag (the meta frame keeps the
   originating frame_header in [fh]). *)
let meta_end_stream (mf : H2_frame.meta_headers_frame) =
  mf.fh.flags land H2.flag_end_stream <> 0

let pseudo_value (fields : Hpack.header_field list) (name : string) : string =
  let full = ":" ^ name in
  let rec go = function
    | [] -> ""
    | (f : Hpack.header_field) :: tl -> if f.name = full then f.value else go tl
  in
  go fields

(* state of a stream id, mirroring serverConn.state. *)
let stream_state sc id =
  match Hashtbl.find_opt sc.streams id with
  | Some st -> (st.state, Some st)
  | None ->
      if id mod 2 = 1 then
        if id <= sc.max_client_stream_id then (State_closed, None)
        else (State_idle, None)
      else (State_idle, None)

(* ---- writing path (serve loop only) ---- *)

(* Schedule a frame write. Go's serverConn.writeFrame: push onto the scheduler
   (unless writing to a closed stream), then drive scheduleFrameWrite. *)
let rec write_frame sc (req : frame_write_req) =
  let wr = req.fw in
  let sid = H2_writesched.stream_id wr in
  let is_reset =
    match wr.write with H2_write.Write_rst_stream _ -> true | _ -> false
  in
  let ignore_write =
    if sid <> 0 then
      match stream_state sc sid with
      | State_closed, _ when not is_reset -> true
      | _ -> false
    else false
  in
  (* 100-continue suppression / wroteHeaders bookkeeping *)
  let ignore_write =
    match (wr.write, wr.stream) with
    | H2_write.Write_res_headers _, Some _ ->
        (match Hashtbl.find_opt sc.streams sid with
        | Some st -> st.wrote_headers <- true
        | None -> ());
        ignore_write
    | H2_write.Write_100_continue _, _ -> (
        match Hashtbl.find_opt sc.streams sid with
        | Some st when st.wrote_headers -> true
        | _ -> ignore_write)
    | _ -> ignore_write
  in
  if ignore_write then (
    (* Notify the waiter so it doesn't hang. *)
    (match req.reply with
    | Some c -> Lwt_condition.broadcast c (Error End_of_file)
    | None -> ());
    Lwt.return_unit)
  else begin
    if H2_writesched.is_control wr then begin
      sc.queued_control_frames <- sc.queued_control_frames + 1
    end;
    H2_writesched.push sc.write_sched wr;
    (* remember the reply for this writer, keyed by physical identity (writer
       values are freshly allocated per request, so [==] is reliable). *)
    (match req.reply with
    | Some c -> pending_replies := (wr.write, c) :: !pending_replies
    | None -> ());
    schedule_frame_write sc
  end

(* Associates a queued writer (by physical identity) with the handler's reply
   condition, so wroteFrame can unblock the handler. Mirrors Go's wr.done. *)
and pending_replies :
    (H2_write.write_framer * write_result Lwt_condition.t) list ref =
  ref []

and reply_to_writer (w : H2_write.write_framer) (r : write_result) =
  let rec extract acc = function
    | [] -> (None, List.rev acc)
    | (w', c) :: tl ->
        if w' == w then (Some c, List.rev_append acc tl)
        else extract ((w', c) :: acc) tl
  in
  let found, rest = extract [] !pending_replies in
  match found with
  | Some c ->
      pending_replies := rest;
      Lwt_condition.broadcast c r
  | None -> ()

(* scheduleFrameWrite: pull the next frame and write it. Because Lwt_io writes
   are awaited inline here (the serve loop is the single writer), this both
   "starts" and "completes" the write before looping, then runs wroteFrame
   bookkeeping. *)
and schedule_frame_write sc : unit Lwt.t =
  let open Lwt.Syntax in
  if sc.need_to_send_goaway then begin
    sc.need_to_send_goaway <- false;
    let* () =
      H2_frame.write_goaway sc.oc sc.max_client_stream_id sc.goaway_code ""
    in
    let* () = Lwt_io.flush sc.oc in
    schedule_frame_write sc
  end
  else if sc.need_to_send_settings_ack then begin
    sc.need_to_send_settings_ack <- false;
    let* () = H2_frame.write_settings_ack sc.oc in
    let* () = Lwt_io.flush sc.oc in
    schedule_frame_write sc
  end
  else if (not sc.in_goaway) || sc.goaway_code = H2_error.NoError then
    match H2_writesched.pop sc.write_sched with
    | Some wr ->
        if H2_writesched.is_control wr then
          sc.queued_control_frames <- sc.queued_control_frames - 1;
        let* () = start_frame_write sc wr in
        schedule_frame_write sc
    | None -> Lwt_io.flush sc.oc
  else Lwt_io.flush sc.oc

(* startFrameWrite + wroteFrame fused: serialize wr to the wire, then do the
   stream-state bookkeeping wroteFrame performs. *)
and start_frame_write sc (wr : H2_writesched.frame_write_request) : unit Lwt.t =
  let open Lwt.Syntax in
  let* result =
    Lwt.catch
      (fun () ->
        let+ () = H2_write.write_frame ~enc:sc.enc sc.oc wr.write in
        Ok ())
      (fun exn -> Lwt.return (Error exn))
  in
  (match result with Error _ -> sc.serving_done <- true | Ok () -> ());
  (* wroteFrame stream-state transitions *)
  (if H2_write.write_ends_stream wr.write then
     match wr.stream with
     | Some s -> (
         match Hashtbl.find_opt sc.streams s.H2_writesched.id with
         | Some st -> (
             match st.state with
             | State_open ->
                 st.state <- State_half_closed_local;
                 (* Section 8.1: send RST_STREAM NO_ERROR after a complete
                    response, like Go. Closes the stream. *)
                 reset_stream sc st H2_error.NoError
             | State_half_closed_remote ->
                 close_stream sc st
                   (Some
                      (H2_error.Stream_error
                         (H2_error.stream_error st.st_id H2_error.NoError)))
             | _ -> ())
         | None -> ())
     | None -> ()
   else
     match wr.write with
     | H2_write.Write_rst_stream { stream_id; _ } -> (
         match Hashtbl.find_opt sc.streams stream_id with
         | Some st -> close_stream sc st None
         | None -> ())
     | H2_write.Write_handler_panic_rst sid -> (
         match Hashtbl.find_opt sc.streams sid with
         | Some st -> close_stream sc st None
         | None -> ())
     | _ -> ());
  reply_to_writer wr.write result;
  Lwt.return_unit

(* resetStream: queue a RST_STREAM (Go's serverConn.resetStream). *)
and reset_stream sc (st : stream) (code : H2_error.err_code) =
  let wr : H2_writesched.frame_write_request =
    {
      write = H2_write.Write_rst_stream { stream_id = st.st_id; code };
      stream = None;
    }
  in
  H2_writesched.push sc.write_sched wr;
  sc.queued_control_frames <- sc.queued_control_frames + 1;
  st.reset_queued <- true

(* closeStream (Go's serverConn.closeStream). *)
and close_stream sc (st : stream) (err : exn option) =
  st.state <- State_closed;
  if st.st_id mod 2 = 1 then sc.cur_client_streams <- sc.cur_client_streams - 1;
  Hashtbl.remove sc.streams st.st_id;
  (match st.body with
  | Some p ->
      (* return buffered unread conn-level flow control *)
      let n = H2_pipe.len p in
      if n > 0 then send_window_update_conn sc n;
      let e = match err with Some e -> e | None -> End_of_file in
      H2_pipe.close_with_error p e
  | None -> ());
  st.close_err <- err;
  if not st.cw_closed then begin
    st.cw_closed <- true;
    Lwt_condition.broadcast st.cw ()
  end;
  H2_writesched.close_stream sc.write_sched st.st_id

(* sendWindowUpdate for the connection-level inflow. *)
and send_window_update_conn sc n =
  let send = H2_flow.inflow_add sc.conn_inflow n in
  if Int32.compare send 0l <> 0 then begin
    let wr : H2_writesched.frame_write_request =
      {
        write =
          H2_write.Write_window_update { stream_id = 0; n = Int32.to_int send };
        stream = None;
      }
    in
    H2_writesched.push sc.write_sched wr;
    sc.queued_control_frames <- sc.queued_control_frames + 1
  end

(* sendWindowUpdate for a stream-level inflow. *)
let send_window_update_stream sc (st : stream) n =
  let send = H2_flow.inflow_add st.inflow n in
  if Int32.compare send 0l <> 0 then begin
    let wr : H2_writesched.frame_write_request =
      {
        write =
          H2_write.Write_window_update
            { stream_id = st.st_id; n = Int32.to_int send };
        stream = Some st.sched;
      }
    in
    H2_writesched.push sc.write_sched wr;
    sc.queued_control_frames <- sc.queued_control_frames + 1
  end

(* goAway (Go's serverConn.goAway). *)
let go_away sc code =
  if not sc.in_goaway then begin
    sc.in_goaway <- true;
    sc.need_to_send_goaway <- true;
    sc.goaway_code <- code
  end

(* ---- response writer construction ---- *)

(* Build the streaming Body fed by the stream's request pipe. Mirrors
   requestBody.Read + noteBodyReadFromHandler. *)
let body_of_pipe sc (st : stream) : Body.t =
  let saw_eof = ref false in
  let next () : string option Lwt.t =
    match st.body with
    | None -> Lwt.return None
    | Some p ->
        if !saw_eof then Lwt.return None
        else
          Lwt.catch
            (fun () ->
              let open Lwt.Syntax in
              let* chunk = H2_pipe.read p (1 lsl 16) in
              let n = String.length chunk in
              (* note body read -> schedule window updates on the serve loop *)
              if n > 0 then sc.push_event (Some (Body_read (st, n)));
              if n = 0 then (
                saw_eof := true;
                Lwt.return None)
              else Lwt.return (Some chunk))
            (fun exn ->
              match exn with
              | End_of_file ->
                  saw_eof := true;
                  Lwt.return None
              | e -> Lwt.fail e)
  in
  Body.of_stream next

(* The response writer state. The serve loop frames everything; the handler
   fiber posts Want_write_frame events and blocks on reply conditions. *)
type rws = {
  rws_stream : stream;
  rws_req : Api.server_request;
  mutable handler_header : Header.t;
  mutable status : int;
  mutable wrote_header : bool; (* WriteHeader called *)
  mutable sent_header : bool; (* HEADERS frame sent *)
  mutable handler_done : bool;
  buf : Buffer.t; (* buffered body bytes between flushes *)
}

(* Send a frame request through the serve loop and block until written. *)
let write_via_loop sc (fw : H2_writesched.frame_write_request) : unit Lwt.t =
  if sc.serving_done then Lwt.fail End_of_file
  else begin
    let reply = Lwt_condition.create () in
    sc.push_event (Some (Want_write_frame { fw; reply = Some reply }));
    let open Lwt.Syntax in
    (* race the reply against the serve loop ending *)
    let wait_reply = Lwt_condition.wait reply in
    let wait_done =
      let+ () = Lwt_condition.wait sc.done_serving in
      Error End_of_file
    in
    let* r = Lwt.pick [ wait_reply; wait_done ] in
    match r with Ok () -> Lwt.return_unit | Error e -> Lwt.fail e
  end

(* writeHeaders from the handler. *)
let write_res_headers sc (rws : rws) ~end_stream ~content_type ~content_length =
  let h = rws.handler_header in
  let wrh : H2_write.write_res_headers =
    {
      rh_stream_id = rws.rws_stream.st_id;
      http_res_code = rws.status;
      h;
      trailers = None;
      rh_end_stream = end_stream;
      date = "";
      content_type;
      content_length;
    }
  in
  let fw : H2_writesched.frame_write_request =
    {
      write = H2_write.Write_res_headers wrh;
      stream = Some rws.rws_stream.sched;
    }
  in
  write_via_loop sc fw

let write_data_from_handler sc (st : stream) (data : string) ~end_stream =
  let fw : H2_writesched.frame_write_request =
    {
      write = H2_write.Write_data { stream_id = st.st_id; data; end_stream };
      stream = Some st.sched;
    }
  in
  write_via_loop sc fw

(* writeChunk: on first chunk, send HEADERS; then DATA. Mirrors
   responseWriterState.writeChunk (subset: HEAD, content-length/type, and
   END_STREAM handling; mid-stream trailers are out of scope). *)
let write_chunk sc (rws : rws) (p : string) : unit Lwt.t =
  let open Lwt.Syntax in
  if not rws.wrote_header then begin
    rws.wrote_header <- true;
    rws.status <- 200
  end;
  let is_head = rws.rws_req.sreq_meth = "HEAD" in
  let* header_ended_stream =
    if not rws.sent_header then begin
      rws.sent_header <- true;
      let snap = rws.handler_header in
      let clen_hdr = Header.get snap "Content-Length" in
      let clen, has_content_length =
        if clen_hdr <> "" then begin
          Header.del snap "Content-Length";
          match int_of_string_opt clen_hdr with
          | Some _ -> (clen_hdr, true)
          | None -> ("", false)
        end
        else ("", false)
      in
      let body_allowed =
        rws.status <> 204 && rws.status <> 304
        && not (rws.status >= 100 && rws.status < 200)
      in
      let clen =
        if
          (not has_content_length) && clen = "" && rws.handler_done
          && body_allowed
          && (String.length p > 0 || not is_head)
        then string_of_int (String.length p)
        else clen
      in
      let has_content_type = Header.has snap "Content-Type" in
      let ctype =
        if (not has_content_type) && body_allowed && String.length p > 0 then
          "text/plain; charset=utf-8"
        else ""
      in
      let end_stream = (rws.handler_done && String.length p = 0) || is_head in
      let* () =
        write_res_headers sc rws ~end_stream ~content_type:ctype
          ~content_length:clen
      in
      Lwt.return end_stream
    end
    else Lwt.return false
  in
  if header_ended_stream then Lwt.return_unit
  else if is_head then Lwt.return_unit
  else if String.length p = 0 && not rws.handler_done then Lwt.return_unit
  else
    let end_stream = rws.handler_done in
    if String.length p > 0 || end_stream then
      write_data_from_handler sc rws.rws_stream p ~end_stream
    else Lwt.return_unit

let new_response_writer sc (st : stream) (req : Api.server_request) :
    response_writer * rws =
  let rws =
    {
      rws_stream = st;
      rws_req = req;
      handler_header = Header.create ();
      status = 0;
      wrote_header = false;
      sent_header = false;
      handler_done = false;
      buf = Buffer.create 256;
    }
  in
  let header () = rws.handler_header in
  let write_header code =
    if not rws.wrote_header then begin
      rws.wrote_header <- true;
      rws.status <- code
    end
  in
  (* Mirror Go's [bufio.Writer.Write] over the [chunkWriter] of size
     [handler_chunk_write_size]: append to the buffer, then while it holds a full
     chunk, frame that chunk's worth of DATA (via [write_chunk]) and keep the
     remainder buffered. This emits DATA as the handler writes (flow-controlled,
     END_STREAM only at handler completion) rather than buffering the whole body. *)
  let rec drain_full_chunks () : unit Lwt.t =
    if Buffer.length rws.buf >= handler_chunk_write_size then begin
      let all = Buffer.contents rws.buf in
      let chunk = String.sub all 0 handler_chunk_write_size in
      let rest =
        String.sub all handler_chunk_write_size
          (String.length all - handler_chunk_write_size)
      in
      Buffer.clear rws.buf;
      Buffer.add_string rws.buf rest;
      let open Lwt.Syntax in
      let* () = write_chunk sc rws chunk in
      drain_full_chunks ()
    end
    else Lwt.return_unit
  in
  let write (data : string) : unit Lwt.t =
    Buffer.add_string rws.buf data;
    drain_full_chunks ()
  in
  let flush () : unit Lwt.t =
    let p = Buffer.contents rws.buf in
    Buffer.clear rws.buf;
    write_chunk sc rws p
  in
  ( {
      Api.rw_header = header;
      rw_write_header = write_header;
      rw_write = write;
      rw_flush = flush;
    },
    rws )

(* runHandler: run the handler, then flush the buffered response and end the
   stream. Mirrors runHandler + handlerDone. *)
let run_handler sc (st : stream) (req : Api.server_request)
    (rw : response_writer) (rws : rws) (h : handler) : unit Lwt.t =
  let open Lwt.Syntax in
  let finish () =
    rws.handler_done <- true;
    (* writeChunk on the remaining buffered bytes, ending the stream. *)
    let p = Buffer.contents rws.buf in
    Buffer.clear rws.buf;
    Lwt.catch (fun () -> write_chunk sc rws p) (fun _ -> Lwt.return_unit)
  in
  let* () =
    Lwt.catch
      (fun () ->
        let* () = h rw req in
        finish ())
      (fun exn ->
        match exn with
        | End_of_file -> Lwt.return_unit (* stream/conn gone *)
        | _ ->
            (* handler panic -> RST_STREAM *)
            let fw : H2_writesched.frame_write_request =
              {
                write = H2_write.Write_handler_panic_rst st.st_id;
                stream = Some st.sched;
              }
            in
            Lwt.catch
              (fun () -> write_via_loop sc fw)
              (fun _ -> Lwt.return_unit))
  in
  sc.push_event (Some Handler_done);
  Lwt.return_unit

(* ---- frame processing (serve loop) ---- *)

(* scheduleHandler: start a handler fiber, or queue one to start as soon as an
   existing handler finishes (server.go:2254-2273). Over the backlog cap
   (4*advMaxStreams) this trips ENHANCE_YOUR_CALM, defending against the
   open+RST_STREAM rapid-reset flood (CVE-2023-44487, server.go:2263). *)
let schedule_handler sc (st : stream) (req : Api.server_request)
    (rw : response_writer) (rws : rws) : (unit, H2_error.err_code) result =
  let start () = run_handler sc st req rw rws sc.handler in
  if sc.cur_handlers < sc.adv_max_streams then begin
    sc.cur_handlers <- sc.cur_handlers + 1;
    Lwt.async start;
    Ok ()
  end
  else if Queue.length sc.unstarted > 4 * sc.adv_max_streams then
    Error H2_error.EnhanceYourCalm
  else begin
    Queue.add (st.st_id, start) sc.unstarted;
    Ok ()
  end

(* handlerDone: a handler finished; start as many queued handlers as the
   concurrency limit allows, in FIFO order, skipping streams that were reset
   before their fiber started (server.go:2275-2297). *)
let handler_done_serve sc =
  sc.cur_handlers <- sc.cur_handlers - 1;
  let rec drain () =
    match Queue.peek_opt sc.unstarted with
    | None -> ()
    | Some (sid, start) ->
        if not (Hashtbl.mem sc.streams sid) then begin
          (* This stream was reset before its fiber had a chance to start. *)
          ignore (Queue.pop sc.unstarted);
          drain ()
        end
        else if sc.cur_handlers >= sc.adv_max_streams then ()
        else begin
          ignore (Queue.pop sc.unstarted);
          sc.cur_handlers <- sc.cur_handlers + 1;
          Lwt.async start;
          drain ()
        end
  in
  drain ()

(* newStream + register with the scheduler. *)
let new_stream sc id state : stream =
  let sched = H2_writesched.make_stream ~max_frame_size:sc.max_frame_size id in
  (* link stream outflow to conn outflow and seed with the send window *)
  H2_flow.set_conn_flow sched.H2_writesched.flow sc.flow;
  ignore
    (H2_flow.add sched.H2_writesched.flow
       (Int32.of_int sc.initial_stream_send_window));
  let inflow = H2_flow.create_inflow () in
  H2_flow.inflow_init inflow (Int32.of_int sc.initial_stream_recv_window);
  let st =
    {
      st_id = id;
      sched;
      body = None;
      inflow;
      body_bytes = 0L;
      decl_body_bytes = -1L;
      state;
      reset_queued = false;
      got_trailer_header = false;
      wrote_headers = false;
      close_err = None;
      cw = Lwt_condition.create ();
      cw_closed = false;
      trailer = Header.create ();
      req_trailer = None;
    }
  in
  Hashtbl.replace sc.streams id st;
  H2_writesched.open_stream sc.write_sched id;
  sc.cur_client_streams <- sc.cur_client_streams + 1;
  st

(* Build the Request.t from the meta-headers frame (subset of
   newWriterAndRequest). The http2-level pseudo-header validation stays here;
   the Cookie/Expect/Trailer/userinfo/:path handling is httpcommon's
   NewServerRequest. *)
let build_request sc (st : stream) (mf : H2_frame.meta_headers_frame) :
    (Api.server_request * bool, H2_error.err_code) result =
  let fields = mf.fields in
  let meth = pseudo_value fields "method" in
  let scheme = pseudo_value fields "scheme" in
  let authority = pseudo_value fields "authority" in
  let path = pseudo_value fields "path" in
  let protocol = pseudo_value fields "protocol" in
  let is_connect = meth = "CONNECT" in
  let bad =
    if is_connect then path <> "" || scheme <> "" || authority = ""
    else meth = "" || path = "" || (scheme <> "https" && scheme <> "http")
  in
  if bad then Error H2_error.ProtocolError
  else begin
    let header = Header.create () in
    List.iter
      (fun (f : Hpack.header_field) ->
        if not (is_pseudo f.name) then
          Header.add header (Header.canonical_header_key f.name) f.value)
      fields;
    let authority =
      if authority = "" then Header.get header "Host" else authority
    in
    let result : Httpg_internal.Httpcommon.server_request_result =
      Httpg_internal.Httpcommon.new_server_request
        ~canonical:Header.canonical_header_key
        {
          sp_method = meth;
          sp_scheme = scheme;
          sp_authority = authority;
          sp_path = path;
          sp_protocol = protocol;
          sp_header = header;
        }
    in
    if result.sr_invalid_reason <> "" then Error H2_error.ProtocolError
    else begin
      let body_open = not (meta_end_stream mf) in
      (* content-length *)
      let content_length =
        match Header.values header "Content-Length" with
        | v :: _ -> (
            match Int64.of_string_opt v with Some cl -> cl | None -> 0L)
        | [] -> if body_open then -1L else 0L
      in
      (* build URL: use path as request-uri; authority is host. *)
      let url =
        let raw =
          if
            scheme <> "" && authority <> ""
            && String.length path > 0
            && path.[0] = '/'
          then scheme ^ "://" ^ authority ^ path
          else path
        in
        Uri.of_string raw
      in
      let req : Api.server_request =
        {
          sreq_meth = meth;
          sreq_url = url;
          sreq_proto = "HTTP/2.0";
          sreq_proto_major = 2;
          sreq_proto_minor = 0;
          sreq_header = header;
          sreq_body = Body.Empty;
          sreq_content_length = content_length;
          sreq_host = authority;
          sreq_trailer =
            (match result.sr_trailer with
            | Some t -> t
            | None -> Header.create ());
          sreq_request_uri = result.sr_request_uri;
          sreq_remote_addr = "";
          sreq_ctx = Context.background;
        }
      in
      if body_open then begin
        let pipe = H2_pipe.create () in
        H2_pipe.set_buffer pipe
          (H2_databuffer.create ~expected:content_length ());
        st.body <- Some pipe;
        st.decl_body_bytes <- content_length;
        req.sreq_body <- body_of_pipe sc st
      end;
      Ok (req, body_open)
    end
  end

let process_headers sc (mf : H2_frame.meta_headers_frame) :
    (unit, H2_error.err_code) result =
  let id = mf.fh.stream_id in
  if id mod 2 <> 1 then Error H2_error.ProtocolError
  else
    match Hashtbl.find_opt sc.streams id with
    | Some st ->
        (* trailers or invalid; we accept trailers minimally by marking
           got_trailer_header and ending the stream's body. *)
        if st.reset_queued then Ok ()
        else if st.state = State_half_closed_remote then begin
          (* STREAM_CLOSED stream error -> RST *)
          reset_stream sc st H2_error.StreamClosed;
          Ok ()
        end
        else begin
          (* process trailer headers: accumulate then endStream *)
          st.got_trailer_header <- true;
          List.iter
            (fun (f : Hpack.header_field) ->
              if not (is_pseudo f.name) then
                Header.add st.trailer
                  (Header.canonical_header_key f.name)
                  f.value)
            mf.fields;
          (match st.body with
          | Some p -> H2_pipe.close_with_error p End_of_file
          | None -> ());
          st.state <- State_half_closed_remote;
          Ok ()
        end
    | None ->
        if id <= sc.max_client_stream_id then Error H2_error.ProtocolError
        else begin
          sc.max_client_stream_id <- id;
          if sc.cur_client_streams + 1 > sc.adv_max_streams then begin
            (* over MAX_CONCURRENT_STREAMS -> refuse this stream *)
            let st_tmp = new_stream sc id State_open in
            reset_stream sc st_tmp H2_error.RefusedStream;
            Ok ()
          end
          else begin
            let state =
              if meta_end_stream mf then State_half_closed_remote
              else State_open
            in
            let st = new_stream sc id state in
            match build_request sc st mf with
            | Error code ->
                reset_stream sc st code;
                Ok ()
            | Ok (req, _) ->
                let rw, rws = new_response_writer sc st req in
                schedule_handler sc st req rw rws
          end
        end

(* stream.endStream: closes the request body pipe (handler sees EOF). *)
let end_stream (st : stream) =
  (match st.body with
  | Some p -> H2_pipe.close_with_error p End_of_file
  | None -> ());
  st.state <- State_half_closed_remote

let process_data sc (fh : H2_frame.frame_header) (df : H2_frame.data_frame) :
    (unit, H2_error.err_code) result =
  let id = fh.stream_id in
  let data = df.data in
  let length = fh.length in
  let state, st_opt = stream_state sc id in
  if id = 0 || state = State_idle then Error H2_error.ProtocolError
  else
    match st_opt with
    | None ->
        (* closed: return conn-level flow control, send STREAM_CLOSED. *)
        if not (H2_flow.inflow_take sc.conn_inflow length) then
          Error H2_error.FlowControlError
        else begin
          send_window_update_conn sc length;
          (* stream error STREAM_CLOSED, but no stream object to reset cleanly;
             we just return ok (frame-level), mirroring Go's countError path is
             a stream error -> resetStream. Send RST. *)
          let wr : H2_writesched.frame_write_request =
            {
              write =
                H2_write.Write_rst_stream
                  { stream_id = id; code = H2_error.StreamClosed };
              stream = None;
            }
          in
          H2_writesched.push sc.write_sched wr;
          sc.queued_control_frames <- sc.queued_control_frames + 1;
          Ok ()
        end
    | Some st ->
        if state <> State_open || st.got_trailer_header || st.reset_queued then
          begin if not (H2_flow.inflow_take sc.conn_inflow length) then
            Error H2_error.FlowControlError
          else begin
            send_window_update_conn sc length;
            if st.reset_queued then Ok ()
            else begin
              reset_stream sc st H2_error.StreamClosed;
              Ok ()
            end
          end
          end
        else begin
          (* declared content-length overflow check *)
          let over =
            st.decl_body_bytes <> -1L
            && Int64.add st.body_bytes (Int64.of_int (String.length data))
               > st.decl_body_bytes
          in
          if over then
            begin if not (H2_flow.inflow_take sc.conn_inflow length) then
              Error H2_error.FlowControlError
            else begin
              send_window_update_conn sc length;
              (match st.body with
              | Some p ->
                  H2_pipe.close_with_error p
                    (Failure
                       "sender tried to send more than declared Content-Length")
              | None -> ());
              reset_stream sc st H2_error.ProtocolError;
              Ok ()
            end
            end
          else
            begin if length > 0 then
              begin if
                not (H2_flow.take_inflows sc.conn_inflow st.inflow length)
              then Error H2_error.FlowControlError
              else begin
                if String.length data > 0 then begin
                  st.body_bytes <-
                    Int64.add st.body_bytes (Int64.of_int (String.length data));
                  match st.body with
                  | Some p -> ignore (H2_pipe.write p data)
                  | None -> ()
                end;
                (* return padding-only flow control immediately *)
                let pad = length - String.length data in
                if pad > 0 then begin
                  send_window_update_conn sc pad;
                  send_window_update_stream sc st pad
                end;
                if df.end_stream then end_stream st;
                Ok ()
              end
              end
            else begin
              if df.end_stream then end_stream st;
              Ok ()
            end
            end
        end

let process_settings sc (sf : H2_frame.settings_frame) :
    (unit, H2_error.err_code) result =
  if sf.ack then begin
    sc.unacked_settings <- sc.unacked_settings - 1;
    if sc.unacked_settings < 0 then Error H2_error.ProtocolError else Ok ()
  end
  else if List.length sf.settings > 100 || H2_frame.settings_has_duplicates sf
  then
    (* server.go:1616-1620: hang up on suspiciously large settings frames or
       those with duplicate entries (f.NumSettings() > 100 || f.HasDuplicates). *)
    Error H2_error.ProtocolError
  else begin
    let err = ref None in
    List.iter
      (fun (s : H2.setting) ->
        match s.id with
        | H2.Header_table_size ->
            Hpack.set_max_dynamic_table_size sc.enc (Int32.to_int s.value)
        | H2.Initial_window_size ->
            let v = Int32.to_int s.value in
            if v > H2_flow.max_window then err := Some H2_error.FlowControlError
            else begin
              let old = sc.initial_stream_send_window in
              sc.initial_stream_send_window <- v;
              let growth = Int32.of_int (v - old) in
              Hashtbl.iter
                (fun _ (st : stream) ->
                  if not (H2_flow.add st.sched.H2_writesched.flow growth) then
                    err := Some H2_error.FlowControlError)
                sc.streams
            end
        | H2.Max_frame_size ->
            sc.max_frame_size <- Int32.to_int s.value;
            Hashtbl.iter
              (fun _ (st : stream) ->
                st.sched.H2_writesched.max_frame_size <- sc.max_frame_size)
              sc.streams
        | H2.Enable_push | H2.Max_concurrent_streams | H2.Max_header_list_size
          ->
            ())
      sf.settings;
    match !err with
    | Some e -> Error e
    | None ->
        sc.need_to_send_settings_ack <- true;
        Ok ()
  end

let process_window_update sc (fh : H2_frame.frame_header)
    (wf : H2_frame.window_update_frame) : (unit, H2_error.err_code) result =
  if fh.stream_id <> 0 then begin
    let state, st_opt = stream_state sc fh.stream_id in
    if state = State_idle then Error H2_error.ProtocolError
    else
      match st_opt with
      | None -> Ok ()
      | Some st ->
          if
            not
              (H2_flow.add st.sched.H2_writesched.flow
                 (Int32.of_int wf.increment))
          then Error H2_error.FlowControlError
          else Ok ()
  end
  else if not (H2_flow.add sc.flow (Int32.of_int wf.increment)) then
    Error H2_error.FlowControlError
  else Ok ()

let process_ping sc (fh : H2_frame.frame_header) (pf : H2_frame.ping_frame) :
    (unit, H2_error.err_code) result =
  if pf.ack then Ok ()
  else if fh.stream_id <> 0 then Error H2_error.ProtocolError
  else begin
    let wr : H2_writesched.frame_write_request =
      { write = H2_write.Write_ping_ack pf.data; stream = None }
    in
    H2_writesched.push sc.write_sched wr;
    sc.queued_control_frames <- sc.queued_control_frames + 1;
    Ok ()
  end

let process_reset_stream sc (fh : H2_frame.frame_header)
    (_rf : H2_frame.rst_stream_frame) : (unit, H2_error.err_code) result =
  let state, st_opt = stream_state sc fh.stream_id in
  if state = State_idle then Error H2_error.ProtocolError
  else begin
    (match st_opt with
    | Some st ->
        close_stream sc st
          (Some
             (H2_error.Stream_error
                (H2_error.stream_error fh.stream_id _rf.error_code)))
    | None -> ());
    Ok ()
  end

let process_goaway sc (_gf : H2_frame.goaway_frame) :
    (unit, H2_error.err_code) result =
  sc.in_goaway <- true;
  Ok ()

(* processFrame dispatch (serve loop). Returns Ok () or the connection-error
   code to GOAWAY with, or `Stream_err for a stream error. *)
type frame_outcome = Ok_frame | Conn_error of H2_error.err_code

let outcome_of_result = function
  | Ok () -> Ok_frame
  | Error code -> Conn_error code

let process_frame sc (f : H2_frame.frame) : frame_outcome =
  (* first frame must be SETTINGS *)
  let first_ok =
    if not sc.saw_first_settings then
      match f with
      | H2_frame.Settings _ ->
          sc.saw_first_settings <- true;
          true
      | _ -> false
    else true
  in
  if not first_ok then Conn_error H2_error.ProtocolError
  else
    match f with
    | H2_frame.Settings (_, sf) -> outcome_of_result (process_settings sc sf)
    | H2_frame.Window_update (fh, wf) ->
        outcome_of_result (process_window_update sc fh wf)
    | H2_frame.Ping (fh, pf) -> outcome_of_result (process_ping sc fh pf)
    | H2_frame.Data (fh, df) -> (
        match process_data sc fh df with
        | Ok () -> Ok_frame
        | Error code -> Conn_error code)
    | H2_frame.RST_stream (fh, rf) ->
        outcome_of_result (process_reset_stream sc fh rf)
    | H2_frame.GoAway (_, gf) -> outcome_of_result (process_goaway sc gf)
    | H2_frame.Push_promise _ -> Conn_error H2_error.ProtocolError
    | H2_frame.Priority _ -> Ok_frame
    | H2_frame.Continuation _ -> Ok_frame (* assembled by read_meta_headers *)
    | H2_frame.Headers _ -> Ok_frame (* handled via Read_meta *)
    | H2_frame.Unknown _ -> Ok_frame

(* ---- reader fiber ---- *)

(* Reads frames from the wire, assembling HEADERS+CONTINUATION into a
   meta-headers frame (Go's readFrames + readMetaFrame). Posts events. *)
let rec read_loop sc : unit Lwt.t =
  let open Lwt.Syntax in
  Lwt.catch
    (fun () ->
      (* Boundary returns [result]; the reader fiber drives GOAWAY/RST by
         raising (caught below and posted as [Read_error]), so convert an
         [Error] back to the raising exception via {!H2_error.to_exception}
         (Resolution #2 — boundary-only conversion; internal loop unchanged). *)
      let* f =
        Lwt.map
          (function Ok f -> f | Error e -> raise (H2_error.to_exception e))
          (H2_frame.read_frame ~max_size:H2.default_max_read_frame_size sc.ic)
      in
      match f with
      | H2_frame.Headers (fh, hf) ->
          (* assemble meta headers; reader owns the decoder *)
          let* mf =
            Lwt.map
              (function
                | Ok mf -> mf | Error e -> raise (H2_error.to_exception e))
              (H2_frame.read_meta_headers
                 ~max_header_list_size:sc.adv_max_header_list_size sc.dec
                 (fh, hf) sc.ic)
          in
          sc.push_event (Some (Read_meta mf));
          read_loop sc
      | _ ->
          sc.push_event (Some (Read_frame f));
          read_loop sc)
    (fun exn ->
      sc.push_event (Some (Read_error exn));
      Lwt.return_unit)

(* ---- serve loop ---- *)

let handle_meta sc (mf : H2_frame.meta_headers_frame) : frame_outcome =
  let first_ok = if not sc.saw_first_settings then false else true in
  if not first_ok then Conn_error H2_error.ProtocolError
  else
    match process_headers sc mf with
    | Ok () -> Ok_frame
    | Error code -> Conn_error code

let rec serve_loop sc : unit Lwt.t =
  let open Lwt.Syntax in
  if sc.serving_done then Lwt.return_unit
  else if sc.queued_control_frames > max_queued_control_frames then
    Lwt.return_unit
  else begin
    let* ev = Lwt_stream.get sc.events in
    match ev with
    | None -> Lwt.return_unit
    | Some ev -> (
        match ev with
        | Read_error exn -> (
            match exn with
            | H2_frame.Frame_too_large ->
                go_away sc H2_error.FrameSizeError;
                let* () = schedule_frame_write sc in
                finish_or_continue sc
            | H2_error.Connection_error code ->
                go_away sc code;
                let* () = schedule_frame_write sc in
                finish_or_continue sc
            | H2_error.Stream_error se ->
                (match Hashtbl.find_opt sc.streams se.stream_id with
                | Some st -> reset_stream sc st se.code
                | None ->
                    let wr : H2_writesched.frame_write_request =
                      {
                        write =
                          H2_write.Write_rst_stream
                            { stream_id = se.stream_id; code = se.code };
                        stream = None;
                      }
                    in
                    H2_writesched.push sc.write_sched wr;
                    sc.queued_control_frames <- sc.queued_control_frames + 1);
                let* () = schedule_frame_write sc in
                serve_loop sc
            | _ ->
                (* EOF / client gone *)
                sc.serving_done <- true;
                Lwt.return_unit)
        | Read_frame f -> (
            (* A synchronous flow-control overflow in inflow_add (e.g. while
               returning conn-level window for this DATA frame) raises a
               modeled Connection_error; catch it here so it routes to GOAWAY
               via the same Conn_error path rather than crashing the fiber. *)
            let outcome =
              try process_frame sc f
              with H2_error.Connection_error code -> Conn_error code
            in
            match outcome with
            | Ok_frame ->
                let* () = schedule_frame_write sc in
                serve_loop sc
            | Conn_error code ->
                go_away sc code;
                let* () = schedule_frame_write sc in
                finish_or_continue sc)
        | Read_meta mf -> (
            match handle_meta sc mf with
            | Ok_frame ->
                let* () = schedule_frame_write sc in
                serve_loop sc
            | Conn_error code ->
                go_away sc code;
                let* () = schedule_frame_write sc in
                finish_or_continue sc)
        | Want_write_frame req ->
            let* () = write_frame sc req in
            serve_loop sc
        | Body_read (st, n) -> (
            (* noteBodyRead: conn-level window update, and stream-level unless
               half-closed/closed. An inflow_add overflow here raises a modeled
               Connection_error; route it to GOAWAY instead of crashing. *)
            let outcome =
              try
                send_window_update_conn sc n;
                if
                  st.state <> State_half_closed_remote
                  && st.state <> State_closed
                then send_window_update_stream sc st n;
                Ok_frame
              with H2_error.Connection_error code -> Conn_error code
            in
            match outcome with
            | Ok_frame ->
                let* () = schedule_frame_write sc in
                serve_loop sc
            | Conn_error code ->
                go_away sc code;
                let* () = schedule_frame_write sc in
                finish_or_continue sc)
        | Handler_done ->
            handler_done_serve sc;
            let* () = schedule_frame_write sc in
            finish_or_continue sc)
  end

(* After GOAWAY or handler completion: if we've drained everything (GOAWAY sent
   and no open streams under graceful), end; otherwise keep serving. *)
and finish_or_continue sc : unit Lwt.t =
  if sc.serving_done then Lwt.return_unit
  else if
    sc.in_goaway
    && sc.goaway_code <> H2_error.NoError
    && not sc.need_to_send_goaway
  then begin
    (* a connection error GOAWAY has been sent; close once writes flushed. *)
    sc.serving_done <- true;
    Lwt.return_unit
  end
  else serve_loop sc

(* readPreface: read exactly the client preface bytes and compare. *)
let read_preface sc : bool Lwt.t =
  let open Lwt.Syntax in
  let buf = Bytes.create H2.client_preface_len in
  Lwt.catch
    (fun () ->
      let* () = Lwt_io.read_into_exactly sc.ic buf 0 H2.client_preface_len in
      Lwt.return (Bytes.to_string buf = H2.client_preface))
    (fun _ -> Lwt.return false)

let serve ?(max_concurrent_streams = default_max_concurrent_streams)
    ?(max_header_bytes = H2.default_max_header_bytes) ic oc ~handler :
    unit Lwt.t =
  let open Lwt.Syntax in
  let events, push_event = Lwt_stream.create () in
  let flow = H2_flow.create_outflow () in
  ignore (H2_flow.add flow (Int32.of_int H2.initial_window_size));
  let conn_inflow = H2_flow.create_inflow () in
  H2_flow.inflow_init conn_inflow (Int32.of_int H2.initial_window_size);
  let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
  let sc =
    {
      ic;
      oc;
      handler;
      enc = Hpack.new_encoder ();
      dec;
      events;
      push_event;
      flow;
      conn_inflow;
      write_sched = H2_writesched.create ();
      streams = Hashtbl.create 16;
      adv_max_streams = max_concurrent_streams;
      adv_max_header_list_size =
        (if max_header_bytes <= 0 then H2.default_max_header_bytes
         else max_header_bytes);
      saw_first_settings = false;
      need_to_send_settings_ack = false;
      unacked_settings = 0;
      queued_control_frames = 0;
      cur_client_streams = 0;
      cur_handlers = 0;
      max_client_stream_id = 0;
      initial_stream_send_window = H2.initial_window_size;
      initial_stream_recv_window = H2.initial_window_size;
      max_frame_size = H2.initial_max_frame_size;
      in_goaway = false;
      need_to_send_goaway = false;
      goaway_code = H2_error.NoError;
      serving_done = false;
      done_serving = Lwt_condition.create ();
      unstarted = Queue.create ();
    }
  in
  (* Send server's initial SETTINGS first (Go sends before reading preface, but
     reading the preface first is also valid; we send then read). *)
  let settings =
    [
      {
        H2.id = H2.Max_frame_size;
        value = Int32.of_int H2.default_max_read_frame_size;
      };
      {
        H2.id = H2.Max_concurrent_streams;
        value = Int32.of_int max_concurrent_streams;
      };
      {
        H2.id = H2.Max_header_list_size;
        value = Int32.of_int sc.adv_max_header_list_size;
      };
      {
        H2.id = H2.Initial_window_size;
        value = Int32.of_int sc.initial_stream_recv_window;
      };
      {
        H2.id = H2.Header_table_size;
        value = Int32.of_int H2.initial_header_table_size;
      };
    ]
  in
  let* () = H2_frame.write_settings sc.oc settings in
  let* () = Lwt_io.flush sc.oc in
  sc.unacked_settings <- sc.unacked_settings + 1;
  let* ok = read_preface sc in
  if not ok then Lwt.return_unit
  else begin
    (* spawn the reader fiber *)
    Lwt.async (fun () -> read_loop sc);
    let* () =
      Lwt.finalize
        (fun () -> serve_loop sc)
        (fun () ->
          (* doneServing: unblock handlers; close all streams. *)
          sc.serving_done <- true;
          Lwt_condition.broadcast sc.done_serving ();
          Hashtbl.iter
            (fun _ (st : stream) ->
              (match st.body with
              | Some p -> H2_pipe.break_with_error p End_of_file
              | None -> ());
              if not st.cw_closed then begin
                st.cw_closed <- true;
                Lwt_condition.broadcast st.cw ()
              end)
            sc.streams;
          Lwt.return_unit)
    in
    Lwt.return_unit
  end
