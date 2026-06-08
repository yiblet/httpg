(* Port of go/src/net/http/internal/http2/databuffer.go *)

(* errReadEmpty is returned by Read when no data is available. *)
exception Read_empty

(* Buffer chunks come in a few size classes to minimize overhead for servers
   that typically receive very small request bodies. Go allocates these from
   sync.Pools; OCaml is GC-managed so we just allocate fresh chunks of the
   right size class (the size classes themselves are faithful). *)
let chunk_size_for (size : int64) : int =
  if size <= Int64.of_int (1 lsl 10) then 1 lsl 10
  else if size <= Int64.of_int (2 lsl 10) then 2 lsl 10
  else if size <= Int64.of_int (4 lsl 10) then 4 lsl 10
  else if size <= Int64.of_int (8 lsl 10) then 8 lsl 10
  else 16 lsl 10

let get_data_buffer_chunk (size : int64) : bytes =
  Bytes.create (chunk_size_for size)

(* dataBuffer is a ReadWriter backed by a list of data chunks.
   The buffer is divided into chunks so the server can limit the total memory
   used by a single connection without limiting the request body size on any
   single stream. *)
type t = {
  (* chunks, oldest first. next byte to read is chunks[0][r]; next byte to
     write is chunks[last][w]. Represented as a growable array (mirrors Go's
     [][]byte slice with its append/shift semantics). *)
  mutable chunks : bytes array;
  mutable r : int; (* next byte to read is chunks[0][r] *)
  mutable w : int; (* next byte to write is chunks[len-1][w] *)
  mutable size : int; (* total buffered bytes *)
  mutable expected : int64;
      (* we expect at least this many bytes in future Write calls (ignored if
         <= 0) *)
}

let create ?(expected = 0L) () =
  { chunks = [||]; r = 0; w = 0; size = 0; expected }

(* Len returns the number of bytes of the unread portion of the buffer. *)
let len b = b.size

(* bytesFromFirstChunk returns the readable slice [off, lim) of chunks[0]. *)
let bytes_from_first_chunk b =
  if Array.length b.chunks = 1 then (b.r, b.w)
  else (b.r, Bytes.length b.chunks.(0))

(* Read copies bytes from the buffer into p. It is an error to read when no
   data is available. Returns the number of bytes copied; raises Read_empty
   when the buffer is empty. *)
let read b (p : bytes) (off : int) (plen : int) : int =
  if b.size = 0 then raise Read_empty;
  let ntotal = ref 0 in
  let remaining = ref plen in
  let dst = ref off in
  while !remaining > 0 && b.size > 0 do
    let from_off, from_lim = bytes_from_first_chunk b in
    let avail = from_lim - from_off in
    let n = min !remaining avail in
    Bytes.blit b.chunks.(0) from_off p !dst n;
    dst := !dst + n;
    remaining := !remaining - n;
    ntotal := !ntotal + n;
    b.r <- b.r + n;
    b.size <- b.size - n;
    (* If the first chunk has been consumed, advance to the next chunk. *)
    if b.r = Bytes.length b.chunks.(0) then begin
      let n_chunks = Array.length b.chunks in
      b.chunks <- Array.sub b.chunks 1 (n_chunks - 1);
      b.r <- 0
    end
  done;
  !ntotal

(* lastChunkOrAlloc returns the current last chunk if it has room, else
   allocates a new chunk of an appropriate size class and appends it. *)
let last_chunk_or_alloc b (want : int64) : bytes =
  let n_chunks = Array.length b.chunks in
  if n_chunks <> 0 && b.w < Bytes.length b.chunks.(n_chunks - 1) then
    b.chunks.(n_chunks - 1)
  else begin
    let chunk = get_data_buffer_chunk want in
    b.chunks <- Array.append b.chunks [| chunk |];
    b.w <- 0;
    chunk
  end

(* Write appends p to the buffer. Returns len p. *)
let write b (p : bytes) (off : int) (plen : int) : int =
  let ntotal = plen in
  let remaining = ref plen in
  let src = ref off in
  while !remaining > 0 do
    (* Try to allocate enough to fully copy p plus any additional bytes we
       expect to receive. However, this may allocate less than len(p). *)
    let want =
      if b.expected > Int64.of_int !remaining then b.expected
      else Int64.of_int !remaining
    in
    let chunk = last_chunk_or_alloc b want in
    let room = Bytes.length chunk - b.w in
    let n = min room !remaining in
    Bytes.blit p !src chunk b.w n;
    src := !src + n;
    remaining := !remaining - n;
    b.w <- b.w + n;
    b.size <- b.size + n;
    b.expected <- Int64.sub b.expected (Int64.of_int n)
  done;
  ntotal

(* String helpers used by H2_pipe and tests. *)
let write_string b (s : string) : int =
  write b (Bytes.unsafe_of_string s) 0 (String.length s)

(* read up to n bytes, returning them as a string. Raises Read_empty when
   the buffer is empty (mirrors Go's Read returning errReadEmpty). *)
let read_string b (n : int) : string =
  let buf = Bytes.create n in
  let got = read b buf 0 n in
  Bytes.sub_string buf 0 got
