(* Port of go/src/net/http/internal/http2/writesched.go +
   writesched_roundrobin.go. *)

type stream = { id : int; flow : H2_flow.outflow; mutable max_frame_size : int }

let make_stream ?(max_frame_size = H2.initial_max_frame_size) id =
  { id; flow = H2_flow.create_outflow (); max_frame_size }

type frame_write_request = {
  write : H2_write.write_framer;
  stream : stream option;
}

(* FrameWriteRequest.StreamID. *)
let stream_id wr =
  match wr.stream with
  | Some s -> s.id
  | None -> (
      (* resetStream doesn't set stream; the StreamError-as-writer carries
         its own id. *)
      match wr.write with
      | H2_write.Write_rst_stream { stream_id; _ } -> stream_id
      | H2_write.Write_handler_panic_rst stream_id -> stream_id
      | _ -> 0)

(* FrameWriteRequest.isControl. *)
let is_control wr = wr.stream = None

(* FrameWriteRequest.DataSize. *)
let data_size wr = H2_write.data_size wr.write
let max_int32 = 0x7fffffff

(* FrameWriteRequest.Consume. *)
let consume wr n =
  let empty = { write = H2_write.Write_settings_ack; stream = None } in
  match wr.write with
  | H2_write.Write_data { stream_id; data; end_stream }
    when String.length data > 0 ->
      let st =
        match wr.stream with
        | Some s -> s
        | None -> failwith "writeData without stream"
      in
      (* allowed = min(n, stream.flow.available()), capped by maxFrameSize. *)
      let avail = Int32.to_int (H2_flow.available st.flow) in
      let allowed = min n avail in
      let allowed =
        if st.max_frame_size < allowed then st.max_frame_size else allowed
      in
      if allowed <= 0 then (empty, empty, 0)
      else if String.length data > allowed then begin
        H2_flow.take st.flow (Int32.of_int allowed);
        let consumed =
          {
            stream = wr.stream;
            write =
              H2_write.Write_data
                {
                  stream_id;
                  data = String.sub data 0 allowed;
                  (* len(data) > allowed, so endStream must be false here. *)
                  end_stream = false;
                };
          }
        in
        let rest =
          {
            stream = wr.stream;
            write =
              H2_write.Write_data
                {
                  stream_id;
                  data = String.sub data allowed (String.length data - allowed);
                  end_stream;
                };
          }
        in
        (consumed, rest, 2)
      end
      else begin
        (* Consumed whole. *)
        H2_flow.take st.flow (Int32.of_int (String.length data));
        (wr, empty, 1)
      end
  | _ ->
      (* Non-DATA frames (and empty DATA) are always consumed whole. *)
      (wr, empty, 1)

(* ---- writeQueue: two-stage queue with ring links ---- *)

type write_queue = {
  mutable curr : frame_write_request array;
  mutable next_q : frame_write_request array;
  mutable curr_pos : int;
  mutable prev : write_queue option;
  mutable next : write_queue option;
}

let new_write_queue () =
  { curr = [||]; next_q = [||]; curr_pos = 0; prev = None; next = None }

let wq_empty q = Array.length q.curr - q.curr_pos + Array.length q.next_q = 0
let wq_push q wr = q.next_q <- Array.append q.next_q [| wr |]

let wq_shift q =
  if wq_empty q then failwith "invalid use of queue";
  if q.curr_pos >= Array.length q.curr then begin
    (* swap stages: curr <- next, next <- emptied curr *)
    q.curr <- q.next_q;
    q.curr_pos <- 0;
    q.next_q <- [||]
  end;
  let wr = q.curr.(q.curr_pos) in
  q.curr_pos <- q.curr_pos + 1;
  wr

let wq_peek q =
  if q.curr_pos < Array.length q.curr then Some q.curr.(q.curr_pos)
  else if Array.length q.next_q > 0 then Some q.next_q.(0)
  else None

(* Set the element at the current peek position (used by consume's split). *)
let wq_set_peek q wr =
  if q.curr_pos < Array.length q.curr then q.curr.(q.curr_pos) <- wr
  else q.next_q.(0) <- wr

(* writeQueue.consume. *)
let wq_consume q n =
  if wq_empty q then (None, false)
  else
    match wq_peek q with
    | None -> (None, false)
    | Some wr -> (
        let consumed, rest, numresult = consume wr n in
        match numresult with
        | 0 -> (None, false)
        | 1 ->
            ignore (wq_shift q);
            (Some consumed, true)
        | _ ->
            wq_set_peek q rest;
            (Some consumed, true))

(* ---- round-robin scheduler ---- *)

type t = {
  control : write_queue;
  streams : (int, write_queue) Hashtbl.t;
  mutable head : write_queue option;
}

let create () =
  { control = new_write_queue (); streams = Hashtbl.create 16; head = None }

let open_stream ws stream_id =
  if Hashtbl.mem ws.streams stream_id then
    failwith (Printf.sprintf "stream %d already opened" stream_id);
  let q = new_write_queue () in
  Hashtbl.replace ws.streams stream_id q;
  match ws.head with
  | None ->
      ws.head <- Some q;
      q.next <- Some q;
      q.prev <- Some q
  | Some head ->
      (* Insert before head, i.e. at the end of the ring. *)
      let tail = match head.prev with Some p -> p | None -> head in
      q.prev <- Some tail;
      q.next <- Some head;
      tail.next <- Some q;
      head.prev <- Some q

let close_stream ws stream_id =
  match Hashtbl.find_opt ws.streams stream_id with
  | None -> ()
  | Some q ->
      (match q.next with
      | Some n when n == q ->
          (* Only open stream. *)
          ws.head <- None
      | _ -> (
          let prev = match q.prev with Some p -> p | None -> q in
          let next = match q.next with Some n -> n | None -> q in
          prev.next <- Some next;
          next.prev <- Some prev;
          match ws.head with
          | Some h when h == q -> ws.head <- Some next
          | _ -> ()));
      Hashtbl.remove ws.streams stream_id

let adjust_stream _ws _stream_id = ()

let push ws wr =
  if is_control wr then wq_push ws.control wr
  else
    match Hashtbl.find_opt ws.streams (stream_id wr) with
    | None ->
        (* Closed stream. wr must not be HEADERS or DATA. *)
        if data_size wr > 0 then failwith "add DATA on non-open stream";
        wq_push ws.control wr
    | Some q -> wq_push q wr

let pop ws =
  (* Control and RST_STREAM frames first. *)
  if not (wq_empty ws.control) then Some (wq_shift ws.control)
  else
    match ws.head with
    | None -> None
    | Some start ->
        let rec loop q =
          match wq_consume q max_int32 with
          | Some wr, true ->
              ws.head <- q.next;
              Some wr
          | _ ->
              let nxt = match q.next with Some n -> n | None -> q in
              if nxt == start then None else loop nxt
        in
        loop start
