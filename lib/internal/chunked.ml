(* Port of go/src/net/http/internal/chunked.go: the "chunked" Transfer-Encoding
   wire protocol, over an [Eio.Buf_read.t] (Go's [*bufio.Reader]). *)

exception Err_line_too_long (* internal.ErrLineTooLong *)
exception Chunk_error of string (* malformed-chunk / framing, Go's message *)

(* Handleable framing error (header / initial-parse boundary). The exceptions
   above are the mid-stream analogue: the reader thunk keeps raising. *)
type error = Line_too_long | Chunk of string

let error_to_string = function
  | Line_too_long -> "http: chunk line too long"
  | Chunk msg -> msg

let exn_of_error = function
  | Line_too_long -> Err_line_too_long
  | Chunk msg -> Chunk_error msg

let max_line_length = 4096

(* parseHexUint. *)
let parse_hex_uint (v : string) : (int64, error) result =
  if String.length v = 0 then Error (Chunk "empty hex number for chunk length")
  else begin
    let n = ref 0L in
    let err = ref None in
    (try
       String.iteri
         (fun i c ->
           let d =
             match Ascii.hex_val c with
             | Some d -> d
             | None ->
                 err := Some (Chunk "invalid byte in chunk length");
                 raise Exit
           in
           if i = 16 then begin
             err := Some (Chunk "http chunk length too large");
             raise Exit
           end;
           n := Int64.logor (Int64.shift_left !n 4) (Int64.of_int d))
         v
     with Exit -> ());
    match !err with Some e -> Error e | None -> Ok !n
  end

(* Mid-stream raising helper: a bad chunk size found after reader init keeps
   raising (the analogue of Go's "a later Read returns an error"). *)
let parse_hex_uint_or_raise (v : string) : int64 =
  match parse_hex_uint v with Ok n -> n | Error e -> raise (exn_of_error e)

let remove_chunk_extension (p : string) : string =
  match String.index_opt p ';' with Some i -> String.sub p 0 i | None -> p

(* readChunkLine: read up to and including '\n', validate CRLF termination,
   return the line without the trailing CRLF. *)
let read_chunk_line (r : Eio.Buf_read.t) : string =
  let buf = Buffer.create 32 in
  let rec loop () =
    match Eio.Buf_read.any_char r with
    | exception End_of_file -> raise (Chunk_error "unexpected EOF")
    | ch ->
        Buffer.add_char buf ch;
        if Buffer.length buf > max_line_length then raise Err_line_too_long;
        if ch = '\n' then Buffer.contents buf else loop ()
  in
  let p = loop () in
  (match String.index_opt p '\r' with
  | None -> raise (Chunk_error "chunked line ends with bare LF")
  | Some idx ->
      if idx <> String.length p - 2 then
        raise (Chunk_error "invalid CR in chunked line"));
  let p = String.sub p 0 (String.length p - 2) in
  if String.length p >= max_line_length then raise Err_line_too_long;
  p

(* io.ReadFull semantics: short read -> io.ErrUnexpectedEOF. *)
let read_full (r : Eio.Buf_read.t) (n : int) : string =
  match Eio.Buf_read.take n r with
  | s -> s
  | exception End_of_file -> raise (Chunk_error "unexpected EOF")

(* internal.NewChunkedReader as a pull function: each call returns the next
   decoded chunk's bytes, or None at the terminating 0-length chunk. Does not
   consume the trailing CRLF / trailers (the body/readTrailer layer's job). *)
let new_chunked_reader (r : Eio.Buf_read.t) : unit -> string option =
  let excess = ref 0L in
  let finished = ref false in
  fun () ->
    if !finished then None
    else begin
      let line = read_chunk_line r in
      excess := Int64.add !excess (Int64.of_int (String.length line + 2));
      let line =
        remove_chunk_extension (Httpg_base.Textproto.trim_right line)
      in
      let n = parse_hex_uint_or_raise line in
      (* excess -= 16 + 2*n; clamp at 0; cap at 16KiB. *)
      excess := Int64.sub !excess (Int64.add 16L (Int64.mul 2L n));
      if Int64.compare !excess 0L < 0 then excess := 0L;
      if Int64.compare !excess (Int64.of_int (16 * 1024)) > 0 then
        raise (Chunk_error "chunked encoding contains too much non-data");
      if Int64.compare n 0L = 0 then begin
        finished := true;
        None
      end
      else begin
        let data = read_full r (Int64.to_int n) in
        if read_full r 2 <> "\r\n" then
          raise (Chunk_error "malformed chunked encoding");
        Some data
      end
    end

(* internal.NewChunkedWriter: write each non-empty string as one chunk; the
   final 0-length chunk comes from [chunked_writer_close]. *)
let chunked_writer_write (w : Eio.Buf_write.t) (data : string) : unit =
  if String.length data <> 0 then begin
    Eio.Buf_write.string w (Printf.sprintf "%x\r\n" (String.length data));
    Eio.Buf_write.string w data;
    Eio.Buf_write.string w "\r\n"
  end

let chunked_writer_close (w : Eio.Buf_write.t) : unit =
  Eio.Buf_write.string w "0\r\n"
