(* Port of go/src/net/http/internal/chunked.go: the wire protocol for HTTP's
   "chunked" Transfer-Encoding.

   Go uses a [*bufio.Reader] over an [io.Reader]; here the IO substrate is an
   [Lwt_io.input_channel] (the analogue of [bufio.Reader] for the line/byte
   reads the chunked reader needs). *)

exception Err_line_too_long
(* internal.ErrLineTooLong *)

exception Chunk_error of string
(* malformed-chunk / framing errors carrying Go's message *)

let max_line_length = 4096

(* parseHexUint. Returns the value; raises Chunk_error on bad input. *)
let parse_hex_uint (v : string) : int64 =
  if String.length v = 0 then raise (Chunk_error "empty hex number for chunk length");
  let n = ref 0L in
  String.iteri
    (fun i c ->
      let d =
        if c >= '0' && c <= '9' then Char.code c - Char.code '0'
        else if c >= 'a' && c <= 'f' then Char.code c - Char.code 'a' + 10
        else if c >= 'A' && c <= 'F' then Char.code c - Char.code 'A' + 10
        else raise (Chunk_error "invalid byte in chunk length")
      in
      if i = 16 then raise (Chunk_error "http chunk length too large");
      n := Int64.logor (Int64.shift_left !n 4) (Int64.of_int d))
    v;
  !n

let is_ows_b b = b = ' ' || b = '\t'

let trim_trailing_whitespace (b : string) : string =
  let n = ref (String.length b) in
  while !n > 0 && is_ows_b b.[!n - 1] do decr n done;
  String.sub b 0 !n

(* removeChunkExtension: drop everything from the first ';'. *)
let remove_chunk_extension (p : string) : string =
  match String.index_opt p ';' with
  | Some i -> String.sub p 0 i
  | None -> p

(* readChunkLine: read up to and including '\n', validate CRLF termination,
   return the line without the trailing CRLF. Raises on EOF / bare LF / bad CR
   / over-length. *)
let read_chunk_line (ic : Lwt_io.input_channel) : string Lwt.t =
  let buf = Buffer.create 32 in
  let rec loop () =
    Lwt.bind
      (Lwt.catch
         (fun () -> Lwt.map (fun c -> Some c) (Lwt_io.read_char ic))
         (function End_of_file -> Lwt.return None | e -> Lwt.fail e))
      (fun c ->
        match c with
        | None ->
          (* io.EOF before '\n' -> io.ErrUnexpectedEOF. *)
          raise (Chunk_error "unexpected EOF")
        | Some ch ->
          Buffer.add_char buf ch;
          if Buffer.length buf > max_line_length then raise Err_line_too_long;
          if ch = '\n' then Lwt.return (Buffer.contents buf) else loop ())
  in
  Lwt.map
    (fun p ->
      (* Verify CRLF termination, reject bare LF / stray CR. *)
      (match String.index_opt p '\r' with
      | None -> raise (Chunk_error "chunked line ends with bare LF")
      | Some idx -> if idx <> String.length p - 2 then raise (Chunk_error "invalid CR in chunked line"));
      let p = String.sub p 0 (String.length p - 2) in
      if String.length p >= max_line_length then raise Err_line_too_long;
      p)
    (loop ())

(* Read exactly [n] bytes; raise Chunk_error "unexpected EOF" on short read
   (io.ReadFull semantics mapping io.EOF -> io.ErrUnexpectedEOF). *)
let read_full (ic : Lwt_io.input_channel) (n : int) : string Lwt.t =
  let b = Bytes.create n in
  Lwt.catch
    (fun () ->
      Lwt.map (fun () -> Bytes.to_string b) (Lwt_io.read_into_exactly ic b 0 n))
    (function End_of_file -> raise (Chunk_error "unexpected EOF") | e -> Lwt.fail e)

(* A chunked reader as a Body.t-style stream: each pull returns the decoded
   bytes of the next chunk, or None at the terminating 0-length chunk. This
   models internal.NewChunkedReader / io.ReadAll over it. We track excess
   overhead exactly as Go does. *)
let new_chunked_reader (ic : Lwt_io.input_channel) : unit -> string option Lwt.t =
  let excess = ref 0L in
  let finished = ref false in
  fun () ->
    if !finished then Lwt.return None
    else
      Lwt.catch (fun () ->
      Lwt.bind (read_chunk_line ic) (fun line ->
          excess := Int64.add !excess (Int64.of_int (String.length line + 2));
          let line = trim_trailing_whitespace line in
          let line = remove_chunk_extension line in
          let n = parse_hex_uint line in
          (* excess -= 16 + 2*n; clamp at 0; cap at 16KiB. *)
          excess := Int64.sub !excess (Int64.add 16L (Int64.mul 2L n));
          if Int64.compare !excess 0L < 0 then excess := 0L;
          if Int64.compare !excess (Int64.of_int (16 * 1024)) > 0 then
            raise (Chunk_error "chunked encoding contains too much non-data");
          if Int64.compare n 0L = 0 then begin
            (* internal.chunkedReader stops at the 0-length chunk (io.EOF). It
               does NOT consume the trailing CRLF / trailers -- that is the
               http body/readTrailer layer's job. *)
            finished := true;
            Lwt.return None
          end
          else begin
            let len = Int64.to_int n in
            Lwt.bind (read_full ic len) (fun data ->
                (* trailing CRLF after the chunk data *)
                Lwt.bind (read_full ic 2) (fun crlf ->
                    if crlf <> "\r\n" then raise (Chunk_error "malformed chunked encoding");
                    Lwt.return (Some data)))
          end))
        Lwt.fail

(* internal.NewChunkedWriter: write each (non-empty) string as one chunk; the
   final 0-length chunk is written by [chunked_writer_close]. *)
let chunked_writer_write (oc : Lwt_io.output_channel) (data : string) : unit Lwt.t =
  if String.length data = 0 then Lwt.return_unit
  else
    Lwt.bind (Lwt_io.write oc (Printf.sprintf "%x\r\n" (String.length data))) (fun () ->
        Lwt.bind (Lwt_io.write oc data) (fun () -> Lwt_io.write oc "\r\n"))

let chunked_writer_close (oc : Lwt_io.output_channel) : unit Lwt.t =
  Lwt_io.write oc "0\r\n"
