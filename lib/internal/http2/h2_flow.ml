(* Port of go/src/net/http/internal/http2/flow.go *)

(* inflowMinRefresh is the minimum number of bytes we'll send for a
   flow control window update. *)
let inflow_min_refresh = 4 lsl 10

(* "A sender MUST NOT allow a flow-control window to exceed 2^31-1 octets."
   RFC 7540 Section 6.9.1. *)
let max_window = (1 lsl 31) - 1

(* inflow accounts for an inbound flow control window.
   It tracks both the latest window sent to the peer (used for enforcement)
   and the accumulated unsent window. *)
type inflow = {
  mutable avail : int32;
  mutable unsent : int32;
}

let create_inflow () = { avail = 0l; unsent = 0l }

(* init sets the initial window. *)
let inflow_init f n = f.avail <- n

(* add adds n bytes to the window, with a maximum window size of max,
   indicating that the peer can now send us more data.
   It returns the number of bytes to send in a WINDOW_UPDATE frame to the peer.
   Window updates are accumulated and sent when the unsent capacity
   is at least inflowMinRefresh or will at least double the peer's available
   window. *)
let inflow_add f n =
  if n < 0 then invalid_arg "negative update";
  let unsent = Int64.add (Int64.of_int32 f.unsent) (Int64.of_int n) in
  if Int64.add unsent (Int64.of_int32 f.avail) > Int64.of_int max_window then
    invalid_arg "flow control update exceeds maximum window size";
  f.unsent <- Int64.to_int32 unsent;
  if f.unsent < Int32.of_int inflow_min_refresh && f.unsent < f.avail then
    (* If there aren't at least inflowMinRefresh bytes of window to send,
       and this update won't at least double the window, buffer the update
       for later. *)
    0l
  else begin
    f.avail <- Int32.add f.avail f.unsent;
    f.unsent <- 0l;
    Int64.to_int32 unsent
  end

(* take attempts to take n bytes from the peer's flow control window.
   It reports whether the window has available capacity. n is a uint32. *)
let inflow_take f n =
  (* n is treated as an unsigned 32-bit value, compared against avail. *)
  if Int64.of_int n > Int64.of_int32 f.avail then false
  else begin
    f.avail <- Int32.sub f.avail (Int32.of_int n);
    true
  end

(* takeInflows attempts to take n bytes from two inflows,
   typically connection-level and stream-level flows.
   It reports whether both windows have available capacity. *)
let take_inflows f1 f2 n =
  if Int64.of_int n > Int64.of_int32 f1.avail
     || Int64.of_int n > Int64.of_int32 f2.avail
  then false
  else begin
    f1.avail <- Int32.sub f1.avail (Int32.of_int n);
    f2.avail <- Int32.sub f2.avail (Int32.of_int n);
    true
  end

(* outflow is the outbound flow control window's size. *)
type outflow = {
  (* n is the number of DATA bytes we're allowed to send.
     An outflow is kept both on a conn and a per-stream. *)
  mutable n : int32;
  (* conn points to the shared connection-level outflow that is
     shared by all streams on that conn. It is None for the outflow
     that's on the conn directly. *)
  mutable conn : outflow option;
}

let create_outflow () = { n = 0l; conn = None }

let set_conn_flow f cf = f.conn <- Some cf

let available f =
  let n = f.n in
  match f.conn with
  | Some c when c.n < n -> c.n
  | _ -> n

let take f n =
  if n > available f then invalid_arg "internal error: took too much";
  f.n <- Int32.sub f.n n;
  match f.conn with
  | Some c -> c.n <- Int32.sub c.n n
  | None -> ()

(* add adds n bytes (positive or negative) to the flow control window.
   It returns false if the sum would exceed 2^31-1. *)
let add f n =
  let sum = Int32.add f.n n in
  if (sum > n) = (f.n > 0l) then begin
    f.n <- sum;
    true
  end
  else false
