(* Port of the HTTP/2 subset of go/src/net/http/internal/http2/server.go.
   See h2_server.mli for the Go goroutine -> Eio fiber concurrency mapping. *)

module Body = Api.Body
module Header = Api.Header

type response_writer = Api.response_writer
type handler = Api.handler

(* Re-raise unhandleable exceptions per the project error policy: programming
   bugs (Assert_failure, Match_failure, Invalid_argument, Stack_overflow,
   Out_of_memory) and Eio fiber cancellation must propagate, never be recovered.
   Used to narrow the broad recover()-style catch-alls below so they only swallow
   genuinely-handleable handler failures (Go's runHandler recover()), not bugs. *)
let reraise_unhandleable : exn -> unit = function
  | ( Assert_failure _ | Match_failure _ | Invalid_argument _ | Stack_overflow
    | Out_of_memory | Eio.Cancel.Cancelled _ ) as e ->
      raise e
  | _ -> ()

(* Go: defaultMaxStreams = 250 *)
let default_max_concurrent_streams = 250

(* Go's handlerChunkWriteSize (server.go:60): a handler [Write] buffers into a
   [bufio.Writer] of this size; once it fills, whole chunks flush down to
   [chunkWriter.Write], framing DATA as the handler writes (every ~4 KiB without
   an explicit Flush), not held until the handler returns. *)
let handler_chunk_write_size = 4 * 1024

(* Go: maxQueuedControlFrames *)
let max_queued_control_frames = 10000

(* Go's serve-loop timer durations (server.go:58-59, :1331). [first_settings] /
   [preface] bound the initial handshake; [go_away] is the post-GOAWAY linger
   before close (~1 RTT so the peer can read the GOAWAY before the FIN). *)
let first_settings_timeout = 2.0
let preface_timeout = 10.0
let go_away_timeout = 1.0

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
  mutable body : H2_pipe.t option; (* non-nil if expecting DATA *)
  mutable inflow : H2_flow.inflow; (* what the client may POST to us *)
  mutable body_bytes : int64;
  mutable decl_body_bytes : int64; (* -1 if undeclared *)
  mutable state : stream_state;
  mutable reset_queued : bool;
  mutable got_trailer_header : bool;
  mutable wrote_headers : bool;
  mutable close_err : exn option;
  mutable trailer : Header.t; (* accumulated trailers *)
  mutable req_trailer : Header.t option; (* handler's Request.Trailer *)
}

(* Result reported back to a handler blocked in writeDataFromHandler /
   writeHeaders: Ok () or the error that closed the stream. *)
type write_result = (unit, exn) result

(* A frame-write request as queued through the serve loop. Mirrors the parts of
   Go's FrameWriteRequest the loop needs, plus the handler's reply mailbox (a
   cap-1 Eio.Stream standing in for Go's wr.done channel). *)
type frame_write_req = {
  fw : H2_writesched.frame_write_request;
  reply : write_result Eio.Stream.t option;
}

(* Events posted to the serve loop. The Eio analogue of Go's serve() select over
   readFrameCh / wantWriteFrameCh / wroteFrameCh / bodyReadCh / serveMsgCh. *)
type event =
  | Read_frame of H2_frame.frame
  | Read_meta of H2_frame.meta_headers_frame
  | Read_error of exn
  | Want_write_frame of frame_write_req
  | Body_read of stream * int (* handler read n bytes of stream body *)
  | Handler_done
  (* serveMsgCh timer/shutdown messages (server.go:943-956,1313). *)
  | Settings_timer (* firstSettingsTimeout fired: no SETTINGS in time *)
  | Idle_timer (* IdleTimeout fired: graceful GOAWAY *)
  | Read_timer (* ReadTimeout fired: close the connection *)
  | Shutdown_timer (* goAwayTimeout linger elapsed: close *)
  | Graceful_shutdown (* Server.Shutdown: start graceful GOAWAY drain *)

(* A re-armable serve-loop timer (Go's time.Timer used with Reset/Stop). A
   dedicated fiber sleeps until [deadline] then posts an event; [reset] bumps the
   deadline and wakes the fiber, [stop] disarms it. Deadline [infinity] parks. *)
type timer = { mutable deadline : float; wake : Eio.Condition.t }

type server_conn = {
  r : Eio.Buf_read.t;
  w : Eio.Buf_write.t;
  sw : Eio.Switch.t; (* connection switch; reader + handler fibers fork here *)
  handler : handler;
  enc : Hpack.encoder; (* response header encoder; owned by serve loop *)
  dec : Hpack.decoder; (* request header decoder; used by reader fiber *)
  events : event Eio.Stream.t;
  flow : H2_flow.outflow; (* conn-wide outbound flow *)
  mutable conn_inflow : H2_flow.inflow; (* conn-wide inbound flow *)
  write_sched : H2_writesched.t;
  streams : (int, stream) Hashtbl.t;
  adv_max_streams : int;
  adv_max_header_list_size : int;
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
  done_serving : Eio.Condition.t;
  (* serveMsgCh timer state (server.go:469-472,1352): a clock (None disables all
     timers, like Go's zero IdleTimeout/ReadTimeout), the configured durations,
     and re-armable timers driving Idle/Read; [shutdown_timer] is the one-shot
     goAwayTimeout linger. [shutdown_once] makes a graceful stop idempotent. *)
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
  idle_timeout : float; (* 0. = off *)
  read_timeout : float; (* 0. = off (Go's ReadTimeout/SendPingTimeout shape) *)
  mutable idle_timer : timer option;
  mutable read_timer : timer option;
  mutable shutdown_timer_armed : bool;
  mutable shutdown_once : bool;
  (* Queued writers awaiting a write result, keyed by physical identity (writer
     values are freshly allocated per request, so [==] is reliable). Per-conn,
     not a module global, so concurrent connections don't share state. *)
  mutable pending_replies :
    (H2_write.write_framer * write_result Eio.Stream.t) list;
  (* unstarted handlers queued when over MAX_CONCURRENT_STREAMS. A FIFO Queue:
     under a rapid-reset flood this churns hot (CVE-2023-44487). *)
  unstarted : (int * (unit -> unit)) Queue.t;
}

(* Post an event to the serve loop. *)
let push sc ev = Eio.Stream.add sc.events ev

(* curOpenStreams (server.go:507): no push streams, so just client streams. *)
let cur_open_streams sc = sc.cur_client_streams

(* ---- serve-loop timers (Go's time.AfterFunc + Reset/Stop on serveMsgCh) ---- *)

(* Re-arm [t] to fire [secs] from now (Go's timer.Reset). *)
let timer_reset sc t secs =
  (match sc.clock with
  | Some clock -> t.deadline <- Eio.Time.now clock +. secs
  | None -> ());
  Eio.Condition.broadcast t.wake

(* Disarm [t] (Go's timer.Stop): park until reset. *)
let timer_stop t =
  t.deadline <- infinity;
  Eio.Condition.broadcast t.wake

(* The timer fiber: sleep until [deadline], then [post]; re-arm on [wake]. Loops
   so Reset/Stop just adjust the deadline. Bounded by the conn switch. *)
let run_timer sc t (post : unit -> unit) : [ `Stop_daemon ] =
  match sc.clock with
  | None -> `Stop_daemon (* no clock: timer inert, like Go's zero timeout *)
  | Some clock ->
      let rec loop () =
        if sc.serving_done then `Stop_daemon
        else begin
          if t.deadline = infinity then Eio.Condition.await_no_mutex t.wake
          else
            Eio.Fiber.first
              (fun () -> Eio.Time.sleep_until clock t.deadline)
              (fun () -> Eio.Condition.await_no_mutex t.wake);
          (* Fire only if the (possibly reset) deadline has actually passed. *)
          if (not sc.serving_done) && Eio.Time.now clock >= t.deadline then begin
            t.deadline <- infinity;
            post ()
          end;
          loop ()
        end
      in
      loop ()

(* ---- helpers ---- *)

let is_pseudo name = String.length name > 0 && name.[0] = ':'

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

(* Deliver a write result to a waiting handler (Go's wr.done). Cap-1 mailbox,
   added exactly once, so never blocks the serve loop. *)
let reply_to_writer sc (w : H2_write.write_framer) (r : write_result) =
  let rec extract acc = function
    | [] -> (None, List.rev acc)
    | (w', c) :: tl ->
        if w' == w then (Some c, List.rev_append acc tl)
        else extract ((w', c) :: acc) tl
  in
  let found, rest = extract [] sc.pending_replies in
  match found with
  | Some c ->
      sc.pending_replies <- rest;
      Eio.Stream.add c r
  | None -> ()

(* Go's serverConn.writeFrame: push onto the scheduler (unless writing to a
   closed stream), then drive scheduleFrameWrite. *)
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
  if ignore_write then
    match req.reply with
    | Some c -> Eio.Stream.add c (Error End_of_file)
    | None -> ()
  else begin
    if H2_writesched.is_control wr then
      sc.queued_control_frames <- sc.queued_control_frames + 1;
    H2_writesched.push sc.write_sched wr;
    (match req.reply with
    | Some c -> sc.pending_replies <- (wr.write, c) :: sc.pending_replies
    | None -> ());
    schedule_frame_write sc
  end

(* scheduleFrameWrite: pull the next frame and write it. Buf_write writes are
   synchronous, so this both starts and completes each write before looping,
   then runs wroteFrame bookkeeping. *)
and schedule_frame_write sc : unit =
  if sc.need_to_send_goaway then begin
    sc.need_to_send_goaway <- false;
    H2_frame.write_goaway sc.w sc.max_client_stream_id sc.goaway_code "";
    Eio.Buf_write.flush sc.w;
    schedule_frame_write sc
  end
  else if sc.need_to_send_settings_ack then begin
    sc.need_to_send_settings_ack <- false;
    H2_frame.write_settings_ack sc.w;
    Eio.Buf_write.flush sc.w;
    schedule_frame_write sc
  end
  else if (not sc.in_goaway) || sc.goaway_code = H2_error.NoError then
    match H2_writesched.pop sc.write_sched with
    | Some wr ->
        if H2_writesched.is_control wr then
          sc.queued_control_frames <- sc.queued_control_frames - 1;
        start_frame_write sc wr;
        schedule_frame_write sc
    | None -> Eio.Buf_write.flush sc.w
  else Eio.Buf_write.flush sc.w

(* startFrameWrite + wroteFrame fused: serialize wr to the wire, then do the
   stream-state bookkeeping wroteFrame performs. *)
and start_frame_write sc (wr : H2_writesched.frame_write_request) : unit =
  let result =
    try
      H2_write.write_frame ~enc:sc.enc sc.w wr.write;
      Ok ()
    with exn ->
      (* server.go: a write err is fatal to the conn (forwarded); bug-class
         exns / Cancelled propagate rather than being repackaged as a result. *)
      reraise_unhandleable exn;
      sc.serving_done <- true;
      Error exn
  in
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
  reply_to_writer sc wr.write result

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
  (* last stream done: re-arm the idle timer (server.go:1576-1578). *)
  (if cur_open_streams sc = 0 then
     match sc.idle_timer with
     | Some t when sc.idle_timeout > 0. -> timer_reset sc t sc.idle_timeout
     | _ -> ());
  (match st.body with
  | Some p ->
      (* return buffered unread conn-level flow control *)
      let n = H2_pipe.len p in
      if n > 0 then send_window_update_conn sc n;
      let e = match err with Some e -> e | None -> End_of_file in
      H2_pipe.close_with_error p e
  | None -> ());
  st.close_err <- err;
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

(* goAway (server.go:1339): if already in GOAWAY, only upgrade a prior NO_ERROR
   (graceful) to the new error code; otherwise begin the GOAWAY. *)
let go_away sc code =
  if sc.in_goaway then
    begin if sc.goaway_code = H2_error.NoError then sc.goaway_code <- code
    end
  else begin
    sc.in_goaway <- true;
    sc.need_to_send_goaway <- true;
    sc.goaway_code <- code
  end

(* startGracefulShutdownInternal (server.go:1334): GOAWAY with NO_ERROR. *)
let start_graceful_shutdown_internal sc = go_away sc H2_error.NoError

(* ---- response writer construction ---- *)

(* Build the streaming Body fed by the stream's request pipe. Mirrors
   requestBody.Read + noteBodyReadFromHandler. *)
let body_of_pipe sc (st : stream) : Body.t =
  let saw_eof = ref false in
  let next () : string option =
    match st.body with
    | None -> None
    | Some p -> (
        if !saw_eof then None
        else
          match H2_pipe.read p (1 lsl 16) with
          | chunk ->
              let n = String.length chunk in
              (* note body read -> schedule window updates on the serve loop *)
              if n > 0 then push sc (Body_read (st, n));
              if n = 0 then (
                saw_eof := true;
                None)
              else Some chunk
          | exception End_of_file ->
              saw_eof := true;
              None)
  in
  Body.of_stream next

(* The response writer state. The serve loop frames everything; the handler
   fiber posts Want_write_frame events and blocks on its reply mailbox. *)
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

(* Send a frame request through the serve loop and block until written, racing
   the reply against the serve loop ending (Go's select over wr.done / done
   serving). [Fiber.first] cancels the loser. *)
let write_via_loop sc (fw : H2_writesched.frame_write_request) : unit =
  if sc.serving_done then raise End_of_file
  else begin
    let reply = Eio.Stream.create 1 in
    push sc (Want_write_frame { fw; reply = Some reply });
    let r =
      Eio.Fiber.first
        (fun () -> Eio.Stream.take reply)
        (fun () ->
          Eio.Condition.await_no_mutex sc.done_serving;
          Error End_of_file)
    in
    match r with Ok () -> () | Error e -> raise e
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
let write_chunk sc (rws : rws) (p : string) : unit =
  if not rws.wrote_header then begin
    rws.wrote_header <- true;
    rws.status <- 200
  end;
  let is_head = rws.rws_req.sreq_meth = Httpg_base.Method.Head in
  let header_ended_stream =
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
      write_res_headers sc rws ~end_stream ~content_type:ctype
        ~content_length:clen;
      end_stream
    end
    else false
  in
  if header_ended_stream then ()
  else if is_head then ()
  else if String.length p = 0 && not rws.handler_done then ()
  else
    let end_stream = rws.handler_done in
    if String.length p > 0 || end_stream then
      write_data_from_handler sc rws.rws_stream p ~end_stream

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
     remainder buffered. Emits DATA as the handler writes (flow-controlled,
     END_STREAM only at handler completion) rather than buffering the whole body. *)
  let rec drain_full_chunks () : unit =
    if Buffer.length rws.buf >= handler_chunk_write_size then begin
      let all = Buffer.contents rws.buf in
      let chunk = String.sub all 0 handler_chunk_write_size in
      let rest =
        String.sub all handler_chunk_write_size
          (String.length all - handler_chunk_write_size)
      in
      Buffer.clear rws.buf;
      Buffer.add_string rws.buf rest;
      write_chunk sc rws chunk;
      drain_full_chunks ()
    end
  in
  let write (data : string) : unit =
    Buffer.add_string rws.buf data;
    drain_full_chunks ()
  in
  let flush () : unit =
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
    (rw : response_writer) (rws : rws) (h : handler) : unit =
  let finish () =
    rws.handler_done <- true;
    let p = Buffer.contents rws.buf in
    Buffer.clear rws.buf;
    try write_chunk sc rws p with e -> reraise_unhandleable e
  in
  (try
     h rw req;
     finish ()
   with
  | End_of_file -> () (* stream/conn gone *)
  | e -> (
      (* Bugs and cancellation must propagate (error policy); only a genuinely
         handleable handler failure becomes RST_STREAM (Go's runHandler
         recover()). *)
      reraise_unhandleable e;
      let fw : H2_writesched.frame_write_request =
        {
          write = H2_write.Write_handler_panic_rst st.st_id;
          stream = Some st.sched;
        }
      in
      try write_via_loop sc fw with e -> reraise_unhandleable e));
  push sc Handler_done

(* ---- frame processing (serve loop) ---- *)

(* scheduleHandler: fork a handler fiber, or queue one to start as soon as an
   existing handler finishes (server.go:2254-2273). Over the backlog cap
   (4*advMaxStreams) this trips ENHANCE_YOUR_CALM, defending against the
   open+RST_STREAM rapid-reset flood (CVE-2023-44487, server.go:2263). *)
(* Fork a handler as a daemon so that when the serve loop ends, an in-flight
   handler still blocked on a write (waiting for a serve-loop reply that will
   never come, because the loop has wound down) is cancelled rather than
   deadlocking the connection switch. A handler that completes returns
   [`Stop_daemon] and simply stops. *)
let fork_handler sc start =
  Eio.Fiber.fork_daemon ~sw:sc.sw (fun () ->
      start ();
      `Stop_daemon)

let schedule_handler sc (st : stream) (req : Api.server_request)
    (rw : response_writer) (rws : rws) : (unit, H2_error.err_code) result =
  let start () = run_handler sc st req rw rws sc.handler in
  if sc.cur_handlers < sc.adv_max_streams then begin
    sc.cur_handlers <- sc.cur_handlers + 1;
    fork_handler sc start;
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
          fork_handler sc start;
          drain ()
        end
  in
  drain ()

(* newStream + register with the scheduler. *)
let new_stream sc id state : stream =
  let sched = H2_writesched.make_stream ~max_frame_size:sc.max_frame_size id in
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
      trailer = Header.create ();
      req_trailer = None;
    }
  in
  Hashtbl.replace sc.streams id st;
  H2_writesched.open_stream sc.write_sched id;
  sc.cur_client_streams <- sc.cur_client_streams + 1;
  (* a new stream is in flight: stop the idle timer (server.go:1903). *)
  (match sc.idle_timer with
  | Some t -> timer_stop t
  | None -> ());
  st

(* Build the Request from the meta-headers frame (subset of newWriterAndRequest).
   The http2-level pseudo-header validation stays here; Cookie/Expect/Trailer/
   userinfo/:path handling is httpcommon's NewServerRequest. *)
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
          sp_method = Httpg_base.Method.of_string meth;
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
      let content_length =
        match Header.values header "Content-Length" with
        | v :: _ -> (
            match Int64.of_string_opt v with Some cl -> cl | None -> 0L)
        | [] -> if body_open then -1L else 0L
      in
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
          sreq_meth = Httpg_base.Method.of_string meth;
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
        if st.reset_queued then Ok ()
        else if st.state = State_half_closed_remote then begin
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

(* processFrame dispatch (serve loop). Ok_frame or the connection-error code to
   GOAWAY with. *)
type frame_outcome = Ok_frame | Conn_error of H2_error.err_code

let outcome_of_result = function
  | Ok () -> Ok_frame
  | Error code -> Conn_error code

(* server.go:1438-1450: discard frames for streams started after the GOAWAY
   last-stream-id (or all frames after an error GOAWAY), still returning
   conn-level flow control for DATA. [Some outcome] means handled (discarded). *)
let discard_after_goaway sc (f : H2_frame.frame) : frame_outcome option =
  let fh = H2_frame.header_of_frame f in
  if
    sc.in_goaway
    && (sc.goaway_code <> H2_error.NoError
       || fh.stream_id > sc.max_client_stream_id)
  then begin
    (match f with
    | H2_frame.Data (fh, _) ->
        if H2_flow.inflow_take sc.conn_inflow fh.length then
          send_window_update_conn sc fh.length
    | _ -> ());
    Some Ok_frame
  end
  else None

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
    match discard_after_goaway sc f with
    | Some o -> o
    | None -> (
        match f with
        | H2_frame.Settings (_, sf) ->
            outcome_of_result (process_settings sc sf)
        | H2_frame.Window_update (fh, wf) ->
            outcome_of_result (process_window_update sc fh wf)
        | H2_frame.Ping (fh, pf) -> outcome_of_result (process_ping sc fh pf)
        | H2_frame.Data (fh, df) -> outcome_of_result (process_data sc fh df)
        | H2_frame.RST_stream (fh, rf) ->
            outcome_of_result (process_reset_stream sc fh rf)
        | H2_frame.GoAway (_, gf) -> outcome_of_result (process_goaway sc gf)
        | H2_frame.Push_promise _ -> Conn_error H2_error.ProtocolError
        | H2_frame.Priority _ -> Ok_frame
        | H2_frame.Continuation _ ->
            Ok_frame (* assembled by read_meta_headers *)
        | H2_frame.Headers _ -> Ok_frame (* handled via Read_meta *)
        | H2_frame.Unknown _ -> Ok_frame)

(* ---- reader fiber ---- *)

(* Reads frames from the wire, assembling HEADERS+CONTINUATION into a
   meta-headers frame (Go's readFrames + readMetaFrame). Posts events, then stops
   the daemon. The boundary returns [result]; the loop converts [Error] to the
   raising exception (posted as [Read_error]). A Buf_read [Buffer_limit_exceeded]
   (a frame larger than the buffer cap can hold) is mapped to a FRAME_SIZE
   connection error rather than escaping unmapped (F019; in practice [read_frame]
   rejects an over-[max_size] frame first). Runs as a daemon fiber so it is
   auto-cancelled when the serve loop finishes. *)
let read_loop sc : [ `Stop_daemon ] =
  let unwrap = function
    | Ok x -> x
    | Error e -> raise (H2_error.to_exception e)
  in
  let rec loop () =
    let f =
      unwrap (H2_frame.read_frame ~max_size:H2.default_max_read_frame_size sc.r)
    in
    (match f with
    | H2_frame.Headers (fh, hf) ->
        let mf =
          unwrap
            (H2_frame.read_meta_headers
               ~max_header_list_size:sc.adv_max_header_list_size sc.dec (fh, hf)
               sc.r)
        in
        push sc (Read_meta mf)
    | _ -> push sc (Read_frame f));
    loop ()
  in
  (try loop () with
  | Eio.Buf_read.Buffer_limit_exceeded ->
      push sc (Read_error H2_frame.Frame_too_large)
  (* server.go:692-711: forward the framer err as a connection read error; but
     bug-class exns / Cancelled propagate (Go's reader has no panic recovery). *)
  | exn ->
      reraise_unhandleable exn;
      push sc (Read_error exn));
  `Stop_daemon

(* ---- serve loop ---- *)

let handle_meta sc (mf : H2_frame.meta_headers_frame) : frame_outcome =
  if not sc.saw_first_settings then Conn_error H2_error.ProtocolError
  else if
    (* refuse new streams after GOAWAY (server.go:1441). *)
    sc.in_goaway
    && (sc.goaway_code <> H2_error.NoError
       || mf.fh.stream_id > sc.max_client_stream_id)
  then Ok_frame
  else
    match process_headers sc mf with
    | Ok () -> Ok_frame
    | Error code -> Conn_error code

(* server.go:903-907, run after every loop iteration: once a GOAWAY has been
   written, arm the goAwayTimeout linger — immediately for an error code, but for
   a graceful NO_ERROR only once all open streams have drained. With no clock the
   linger is inert, so close as soon as the GOAWAY is flushed (preserving the
   pre-timer behaviour). [maybe_finish] returns whether the loop should end. *)
let maybe_finish sc : bool =
  let sent_goaway = sc.in_goaway && not sc.need_to_send_goaway in
  let graceful_complete =
    sc.goaway_code = H2_error.NoError && cur_open_streams sc = 0
  in
  if sent_goaway && (sc.goaway_code <> H2_error.NoError || graceful_complete)
  then
    begin match (sc.clock, sc.shutdown_timer_armed) with
    | Some clock, false ->
        sc.shutdown_timer_armed <- true;
        let t =
          {
            deadline = Eio.Time.now clock +. go_away_timeout;
            wake = Eio.Condition.create ();
          }
        in
        Eio.Fiber.fork_daemon ~sw:sc.sw (fun () ->
            run_timer sc t (fun () -> push sc Shutdown_timer));
        false (* keep serving until the linger fires *)
    | None, _ -> true (* no clock: close once flushed *)
    | Some _, true -> false (* linger already armed *)
    end
  else false

let rec serve_loop sc : unit =
  if sc.serving_done then ()
  else if sc.queued_control_frames > max_queued_control_frames then ()
  else begin
    let keep_serving =
      match Eio.Stream.take sc.events with
      | Read_error exn -> (
          match exn with
          | H2_frame.Frame_too_large ->
              go_away sc H2_error.FrameSizeError;
              true
          | H2_error.Connection_error code ->
              go_away sc code;
              true
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
              true
          | _ ->
              (* EOF / client gone *)
              sc.serving_done <- true;
              false)
      | Read_frame f -> (
          (* read timer resets on every received frame (server.go:858). *)
          (match sc.read_timer with
          | Some t when sc.read_timeout > 0. -> timer_reset sc t sc.read_timeout
          | _ -> ());
          (* A synchronous flow-control overflow in inflow_add raises a modeled
             Connection_error; route it to GOAWAY rather than crashing. *)
          let outcome =
            try process_frame sc f
            with H2_error.Connection_error code -> Conn_error code
          in
          match outcome with
          | Ok_frame -> true
          | Conn_error code ->
              go_away sc code;
              true)
      | Read_meta mf -> (
          (match sc.read_timer with
          | Some t when sc.read_timeout > 0. -> timer_reset sc t sc.read_timeout
          | _ -> ());
          match handle_meta sc mf with
          | Ok_frame -> true
          | Conn_error code ->
              go_away sc code;
              true)
      | Want_write_frame req ->
          write_frame sc req;
          true
      | Body_read (st, n) -> (
          (* noteBodyRead: conn-level window update, and stream-level unless
             half-closed/closed. An inflow_add overflow routes to GOAWAY. *)
          let outcome =
            try
              send_window_update_conn sc n;
              if
                st.state <> State_half_closed_remote && st.state <> State_closed
              then send_window_update_stream sc st n;
              Ok_frame
            with H2_error.Connection_error code -> Conn_error code
          in
          match outcome with
          | Ok_frame -> true
          | Conn_error code ->
              go_away sc code;
              true)
      | Handler_done ->
          handler_done_serve sc;
          true
      | Settings_timer ->
          (* server.go:865-867: no SETTINGS in time -> close. *)
          if not sc.saw_first_settings then sc.serving_done <- true;
          true
      | Idle_timer ->
          (* server.go:868-870: idle -> graceful GOAWAY. *)
          start_graceful_shutdown_internal sc;
          true
      | Read_timer ->
          (* server.go:871-872 handlePingTimer fallback: we don't send PINGs, so
             a read-idle timeout closes the connection. *)
          sc.serving_done <- true;
          true
      | Shutdown_timer ->
          (* server.go:873-875: GOAWAY linger elapsed -> close. *)
          sc.serving_done <- true;
          true
      | Graceful_shutdown ->
          (* server.go:876-877: Server.Shutdown reached this conn. *)
          if not sc.shutdown_once then begin
            sc.shutdown_once <- true;
            start_graceful_shutdown_internal sc
          end;
          true
    in
    if keep_serving && not sc.serving_done then begin
      schedule_frame_write sc;
      if not (maybe_finish sc) then serve_loop sc
    end
  end

(* readPreface: read exactly the client preface bytes and compare. *)
let read_preface sc : bool =
  match Eio.Buf_read.take H2.client_preface_len sc.r with
  | s -> s = H2.client_preface
  | exception _ -> false

let serve ?(max_concurrent_streams = default_max_concurrent_streams)
    ?(max_header_bytes = H2.default_max_header_bytes) ?clock
    ?(idle_timeout = 0.) ?(read_timeout = 0.) ?graceful r w ~handler : unit =
  Eio.Switch.run @@ fun sw ->
  let flow = H2_flow.create_outflow () in
  ignore (H2_flow.add flow (Int32.of_int H2.initial_window_size));
  let conn_inflow = H2_flow.create_inflow () in
  H2_flow.inflow_init conn_inflow (Int32.of_int H2.initial_window_size);
  let dec = Hpack.new_decoder H2.initial_header_table_size (fun _ -> ()) in
  let sc =
    {
      r;
      w;
      sw;
      handler;
      enc = Hpack.new_encoder ();
      dec;
      events = Eio.Stream.create max_int;
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
      done_serving = Eio.Condition.create ();
      clock =
        Option.map
          (fun c -> (c :> float Eio.Time.clock_ty Eio.Resource.t))
          clock;
      idle_timeout;
      read_timeout;
      idle_timer = None;
      read_timer = None;
      shutdown_timer_armed = false;
      shutdown_once = false;
      pending_replies = [];
      unstarted = Queue.create ();
    }
  in
  (* Send the server's initial SETTINGS, then read the client preface. *)
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
  H2_frame.write_settings sc.w settings;
  Eio.Buf_write.flush sc.w;
  sc.unacked_settings <- sc.unacked_settings + 1;
  (* readPreface under prefaceTimeout (server.go:798,:1029); no clock -> unbounded. *)
  let preface_ok =
    match sc.clock with
    | Some clock -> (
        try
          Eio.Time.with_timeout_exn clock preface_timeout (fun () ->
              read_preface sc)
        with Eio.Time.Timeout -> false)
    | None -> read_preface sc
  in
  if preface_ok then begin
    (* Arm the serve-loop timers (server.go:809-823). Each runs in a fiber under
       the conn switch, posting a serveMsgCh-style event; auto-cancelled when the
       switch exits. firstSettings is one-shot; idle/read are re-armable. *)
    (match sc.clock with
    | Some clock ->
        let st =
          {
            deadline = Eio.Time.now clock +. first_settings_timeout;
            wake = Eio.Condition.create ();
          }
        in
        Eio.Fiber.fork_daemon ~sw (fun () ->
            run_timer sc st (fun () ->
                if not sc.saw_first_settings then push sc Settings_timer));
        if idle_timeout > 0. then begin
          let it =
            {
              deadline = Eio.Time.now clock +. idle_timeout;
              wake = Eio.Condition.create ();
            }
          in
          sc.idle_timer <- Some it;
          Eio.Fiber.fork_daemon ~sw (fun () ->
              run_timer sc it (fun () -> push sc Idle_timer))
        end;
        if read_timeout > 0. then begin
          let rt =
            {
              deadline = Eio.Time.now clock +. read_timeout;
              wake = Eio.Condition.create ();
            }
          in
          sc.read_timer <- Some rt;
          Eio.Fiber.fork_daemon ~sw (fun () ->
              run_timer sc rt (fun () -> push sc Read_timer))
        end
    | None -> ());
    (* startGracefulShutdown (server.go:1311): a resolved [graceful] promise
       posts the gracefulShutdownMsg to the serve loop, idempotently. *)
    (match graceful with
    | Some p ->
        Eio.Fiber.fork_daemon ~sw (fun () ->
            Eio.Promise.await p;
            if not sc.serving_done then push sc Graceful_shutdown;
            `Stop_daemon)
    | None -> ());
    (* The reader is a daemon: when the serve loop and all handler fibers
       finish, it is auto-cancelled (interrupting its blocked Buf_read) and the
       switch exits — Go's doneServing. *)
    Eio.Fiber.fork_daemon ~sw (fun () -> read_loop sc);
    Fun.protect
      (fun () -> serve_loop sc)
      ~finally:(fun () ->
        (* doneServing: unblock handlers blocked on a write, then break all
           request pipes so a handler reading a body sees EOF immediately. *)
        sc.serving_done <- true;
        Eio.Condition.broadcast sc.done_serving;
        Hashtbl.iter
          (fun _ (st : stream) ->
            match st.body with
            | Some p -> H2_pipe.break_with_error p End_of_file
            | None -> ())
          sc.streams)
  end
