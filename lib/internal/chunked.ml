(* Port of go/src/net/http/internal/chunked.go: the "chunked" Transfer-Encoding
   wire protocol, over an [Eio.Buf_read.t] (Go's [*bufio.Reader]). *)

(* Typed framing error. Used both at the header / initial-parse boundary
   ([parse_hex_uint]) and mid-stream: a malformed chunk discovered while
   pulling becomes an [Error] element of the reader's result-seq, never a
   raise (per AGENTS.md rule 6 — "Failures are typed data"). *)
type error = Line_too_long | Chunk of string

let error_to_string = function
  | Line_too_long -> "http: chunk line too long"
  | Chunk msg -> msg

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

let remove_chunk_extension (p : string) : string =
  match String.index_opt p ';' with Some i -> String.sub p 0 i | None -> p

(* readChunkLine: read up to and including '\n', validate CRLF termination,
   return the line without the trailing CRLF. A framing failure surfaces as
   [Error]. *)
let read_chunk_line (r : Eio.Buf_read.t) : (string, error) result =
  let ( let* ) = Result.bind in
  let buf = Buffer.create 32 in
  let rec loop () : (string, error) result =
    match Eio.Buf_read.any_char r with
    | exception End_of_file -> Error (Chunk "unexpected EOF")
    | ch ->
        Buffer.add_char buf ch;
        if Buffer.length buf > max_line_length then Error Line_too_long
        else if ch = '\n' then Ok (Buffer.contents buf)
        else loop ()
  in
  let* p = loop () in
  let* () =
    match String.index_opt p '\r' with
    | None -> Error (Chunk "chunked line ends with bare LF")
    | Some idx ->
        if idx <> String.length p - 2 then
          Error (Chunk "invalid CR in chunked line")
        else Ok ()
  in
  let p = String.sub p 0 (String.length p - 2) in
  if String.length p >= max_line_length then Error Line_too_long else Ok p

(* io.ReadFull semantics: short read -> io.ErrUnexpectedEOF. *)
let read_full (r : Eio.Buf_read.t) (n : int) : (string, error) result =
  match Eio.Buf_read.take n r with
  | s -> Ok s
  | exception End_of_file -> Error (Chunk "unexpected EOF")

(* internal.NewChunkedReader as a result-yielding pull: each call returns the
   next decoded chunk ([Some (Ok data)]), the terminating 0-length chunk as
   [None], or a framing failure as [Some (Error e)] — the seq's terminal
   element. Does not consume the trailing CRLF / trailers (the
   body/readTrailer layer's job). *)
let new_chunked_reader (r : Eio.Buf_read.t) :
    unit -> (string, error) result option =
  let ( let* ) = Result.bind in
  let excess = ref 0L in
  let finished = ref false in
  let step () : (string option, error) result =
    let* line = read_chunk_line r in
    excess := Int64.add !excess (Int64.of_int (String.length line + 2));
    let line = remove_chunk_extension (Httpg_base.Textproto.trim_right line) in
    let* n = parse_hex_uint line in
    (* excess -= 16 + 2*n; clamp at 0; cap at 16KiB. *)
    excess := Int64.sub !excess (Int64.add 16L (Int64.mul 2L n));
    if Int64.compare !excess 0L < 0 then excess := 0L;
    if Int64.compare !excess (Int64.of_int (16 * 1024)) > 0 then
      Error (Chunk "chunked encoding contains too much non-data")
    else if Int64.compare n 0L = 0 then begin
      finished := true;
      Ok None
    end
    else
      let* data = read_full r (Int64.to_int n) in
      let* crlf = read_full r 2 in
      if crlf <> "\r\n" then Error (Chunk "malformed chunked encoding")
      else Ok (Some data)
  in
  fun () ->
    if !finished then None
    else
      match step () with
      | Ok None -> None
      | Ok (Some data) -> Some (Ok data)
      | Error e ->
          finished := true;
          Some (Error e)

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
