(* Port of go/src/net/http/transfer.go: HTTP/1.x wire framing -- content-length
   framing, trailers, version-sensitive length/encoding/trailer fixups -- over
   [Eio.Buf_read.t] / [Eio.Buf_write.t]. The chunked codec lives in
   [Httpg_internal.Chunked]; its surface is re-exported here.

   The [read_transfer] inputs are modeled as the [message] record, mirroring the
   fields of Go's [transferReader] that come from a *Request or *Response. *)

(* Typed framing error. Used both at the header / initial-parse boundary
   (returned as [Error] from [read_transfer] / the [Private] helpers) and
   mid-stream: a malformed chunk / short read discovered while pulling the body
   becomes a terminal [Error] element of the body's result-seq (mapped into
   [Body.error] by the read path), never a raise. *)
type error =
  | Line_too_long
  | Chunk of string
  | Bad_content_length of string
  | Unsupported_transfer_encoding of string
  | Bad_header of string * string
  | Unexpected_eof

let error_to_string = function
  | Line_too_long -> "http: chunk line too long"
  | Chunk msg -> msg
  | Bad_content_length cl -> Printf.sprintf "bad Content-Length: %s" cl
  | Unsupported_transfer_encoding te ->
      Printf.sprintf "unsupported transfer encoding: %s" te
  | Bad_header (what, value) -> Printf.sprintf "%s: %s" what value
  | Unexpected_eof -> "unexpected EOF"

(* ------------------------------------------------------------------ *)
(* Small string helpers (ports of the textproto / ascii helpers).     *)
(* ------------------------------------------------------------------ *)

(* textproto.TrimString: trim leading/trailing ' ' and '\t'. *)
let trim_string = Httpg_base.Textproto.trim_string

(* internal/ascii.lower: ASCII A-Z -> a-z, every other byte unchanged. *)
let lower_ascii = Httpg_internal.Ascii.lower

(* internal/ascii.EqualFold. *)
let ascii_equal_fold = Httpg_internal.Ascii.equal_fold

(* httpguts.trimOWS: trim leading/trailing OWS (space and tab) for
   token-boundary trimming. *)
let trim_ows = Httpg_base.Textproto.trim_string

(* httpguts.tokenEqual: ASCII case-insensitive equality, no non-ASCII. *)
let token_equal t1 t2 =
  String.length t1 = String.length t2
  &&
  let ok = ref true in
  String.iteri
    (fun i b ->
      if Char.code b >= 0x80 then ok := false
      else if lower_ascii b <> lower_ascii t2.[i] then ok := false)
    t1;
  !ok

(* httpguts.headerValueContainsToken. *)
let header_value_contains_token v token =
  let rec loop v =
    match String.index_opt v ',' with
    | Some comma ->
        if token_equal (trim_ows (String.sub v 0 comma)) token then true
        else loop (String.sub v (comma + 1) (String.length v - comma - 1))
    | None -> token_equal (trim_ows v) token
  in
  loop v

(* httpguts.HeaderValuesContainsToken. *)
let header_values_contains_token values token =
  List.exists (fun v -> header_value_contains_token v token) values

(* server.go foreachHeaderElement. *)
let foreach_header_element v fn =
  let v = trim_string v in
  if v = "" then ()
  else if not (String.contains v ',') then fn v
  else
    String.split_on_char ',' v
    |> List.iter (fun f ->
        let f = trim_string f in
        if f <> "" then fn f)

(* Chunked codec re-exports (Httpg_internal.Chunked). *)

let max_line_length = Httpg_internal.Chunked.max_line_length

(* Re-export the chunked codec's hex parser. It now returns
   [(int64, Chunked.error) result]; map the codec's error into [Transfer.error]
   so the public surface speaks a single error type. *)
let parse_hex_uint (v : string) : (int64, error) result =
  match Httpg_internal.Chunked.parse_hex_uint v with
  | Ok n -> Ok n
  | Error Httpg_internal.Chunked.Line_too_long -> Error Line_too_long
  | Error (Httpg_internal.Chunked.Chunk msg) -> Error (Chunk msg)

(* Map a codec error into [Transfer.error]. *)
let error_of_chunked = function
  | Httpg_internal.Chunked.Line_too_long -> Line_too_long
  | Httpg_internal.Chunked.Chunk msg -> Chunk msg

(* Re-export the codec's reader, mapping its error type into [Transfer.error]
   so the public surface speaks a single error type. *)
let new_chunked_reader (r : Eio.Buf_read.t) :
    unit -> (string, error) result option =
  let next = Httpg_internal.Chunked.new_chunked_reader r in
  fun () ->
    match next () with
    | None -> None
    | Some (Ok _ as ok) -> Some ok
    | Some (Error e) -> Some (Error (error_of_chunked e))

let chunked_writer_write = Httpg_internal.Chunked.chunked_writer_write
let chunked_writer_close = Httpg_internal.Chunked.chunked_writer_close

(* Body-read window for the fixed-length and close-delimited readers. Mirrors
   the 32 KiB default copy buffer Go's [io.Copy]/[io.CopyN] use, so a large body
   is consumed in bounded 32 KiB chunks (memory stays flat regardless of body
   size) with ~8x fewer read iterations/allocations than a 4 KiB window. *)
let copy_buf_size = 32 * 1024

(* ------------------------------------------------------------------ *)
(* transfer.go helpers.                                                *)
(* ------------------------------------------------------------------ *)

(* chunked(te): is "chunked" the (first) transfer encoding? *)
let chunked (te : string list) : bool =
  match te with "chunked" :: _ -> true | _ -> false

(* isIdentity(te). *)
let is_identity (te : string list) : bool =
  match te with [ "identity" ] -> true | _ -> false

(* isTokenBoundary (header.go). *)
let is_token_boundary b = b = ' ' || b = ',' || b = '\t'

(* hasToken(v, token) (header.go): case-insensitive token search on boundaries. *)
let has_token v token =
  let lv = String.length v and lt = String.length token in
  if lt > lv || lt = 0 then false
  else if v = token then true
  else begin
    let eq_fold = Httpg_internal.Ascii.equal_fold in
    let found = ref false in
    let sp = ref 0 in
    while (not !found) && !sp <= lv - lt do
      let b = v.[!sp] in
      let lower_b = Char.chr (Char.code b lor 0x20) in
      if b <> token.[0] && lower_b <> token.[0] then incr sp
      else if !sp > 0 && not (is_token_boundary v.[!sp - 1]) then incr sp
      else begin
        let end_pos = !sp + lt in
        if end_pos <> lv && not (is_token_boundary v.[end_pos]) then incr sp
        else if eq_fold (String.sub v !sp lt) token then found := true
        else incr sp
      end
    done;
    !found
  end

(* noResponseBodyExpected. *)
let no_response_body_expected request_method =
  request_method = Httpg_base.Method.Head

(* bodyAllowedForStatus (RFC 7230 3.3). *)
let body_allowed_for_status status =
  if status >= 100 && status <= 199 then false
  else if status = 204 then false
  else if status = 304 then false
  else true

(* parseContentLength: -1 if unset; [Error (Bad_content_length _)] on invalid.
   This is the header/initial-parse boundary, so it returns [result]. Note: we
   do not model the httplaxcontentlength GODEBUG (default behavior only). *)
let parse_content_length (cl_headers : string list) : (int64, error) result =
  match cl_headers with
  | [] -> Ok (-1L)
  | cl0 :: _ ->
      let cl = trim_string cl0 in
      if cl = "" then Error (Bad_content_length cl)
      else begin
        (* strconv.ParseUint(cl, 10, 63): non-negative, no sign, fits in 63 bits. *)
        let valid_digits = String.for_all (fun c -> c >= '0' && c <= '9') cl in
        if not valid_digits then Error (Bad_content_length cl)
        else
          match Int64.of_string_opt cl with
          (* must fit in 63 bits, i.e. < 2^63. Int64.of_string rejects > max_int64
           already; ParseUint(_, _, 63) additionally forbids the top bit. *)
          | Some n when Int64.compare n 0L >= 0 -> Ok n
          | _ -> Error (Bad_content_length cl)
      end

(* fixLength: determine the expected body length per RFC 7230 3.3.
   [header] is mutated (dedup / delete Content-Length) exactly as Go does.
   Returns [result]: header-parse boundary errors (conflicting / invalid
   Content-Length) surface as [Error]. *)
let fix_length ~is_response ~status ~request_method ~(header : Header.t)
    ~chunked:is_chunked : (int64 * Header.t, error) result =
  let open Result in
  let is_request = not is_response in
  let content_lens = Header.values header "Content-Length" in

  (* Hardening against request smuggling: collapse duplicate Content-Length. *)
  let dup_check : (Header.t * string list, error) result =
    if List.length content_lens > 1 then begin
      match content_lens with
      | first0 :: rest ->
          let first = trim_string first0 in
          let conflict = List.exists (fun ct -> first <> trim_string ct) rest in
          if conflict then
            Error
              (Chunk
                 (Printf.sprintf
                    "http: message cannot contain multiple Content-Length \
                     headers; got %s"
                    (String.concat " " content_lens)))
          else
            let header = Header.set header "Content-Length" first in
            Ok (header, Header.values header "Content-Length")
      | [] -> Ok (header, content_lens)
    end
    else Ok (header, content_lens)
  in
  bind dup_check (fun (header, content_lens) ->
      (* Reject invalid Content-Length; compute n if present. *)
      let parsed_n : (int64, error) result =
        if content_lens <> [] then parse_content_length content_lens else Ok 0L
      in
      bind parsed_n (fun n ->
          if is_response && no_response_body_expected request_method then
            Ok (0L, header)
          else if status / 100 = 1 then Ok (0L, header)
          else if status = 204 || status = 304 then Ok (0L, header)
          else if is_chunked then Ok (-1L, Header.del header "Content-Length")
          else if content_lens <> [] then Ok (n, header)
          else
            Ok
              ( (if is_request then 0L else -1L),
                Header.del header "Content-Length" )))

(* shouldClose: whether to hang up after this message. Version-sensitive.
   [remove_close_header] mutates [header] to drop a Connection: close. *)
let should_close ~major ~minor ~(header : Header.t) ~remove_close_header :
    bool * Header.t =
  if major < 1 then (true, header)
  else
    let conv = Header.values header "Connection" in
    let has_close = header_values_contains_token conv "close" in
    if major = 1 && minor = 0 then
      (has_close || not (header_values_contains_token conv "keep-alive"), header)
    else
      let header =
        if has_close && remove_close_header then Header.del header "Connection"
        else header
      in
      (has_close, header)

(* fixTrailer: parse the Trailer header into a trailer Header. Only meaningful
   for chunked encoding. Returns [Ok None] when there is no usable trailer;
   [Error (Bad_header _)] on a forbidden trailer key (header-parse boundary). *)
let fix_trailer ~(header : Header.t) ~chunked:is_chunked :
    (Header.t option * Header.t, error) result =
  match Header.values header "Trailer" with
  | [] -> Ok (None, header)
  | vv ->
      if not is_chunked then Ok (None, header)
      else begin
        let header = Header.del header "Trailer" in
        let trailer = ref (Header.create ()) in
        let err = ref None in
        List.iter
          (fun v ->
            foreach_header_element v (fun key ->
                let key = Header.canonical_header_key key in
                (match key with
                | "Transfer-Encoding" | "Trailer" | "Content-Length" ->
                    if !err = None then
                      err := Some (Bad_header ("bad trailer key", key))
                | _ -> ());
                (* trailer[key] = nil : record the key with no values. *)
                trailer := Header.set_values !trailer key []))
          vv;
        match !err with
        | Some e -> Error e
        | None ->
            Ok
              ( (if Header.is_empty !trailer then None else Some !trailer),
                header )
      end

(* parseTransferEncoding equivalent: set whether chunked, version-sensitive.
   Mutates [header] (deletes Transfer-Encoding). Returns
   [Error (Unsupported_transfer_encoding _)] / [Error (Chunk _)] for unsupported
   / too-many encodings (the unsupportedTEError analogue). HTTP/1.0 ignores
   Transfer-Encoding entirely (Issue 12785). *)
let parse_transfer_encoding ~major ~minor ~(header : Header.t) :
    (bool * Header.t, error) result =
  match Header.values header "Transfer-Encoding" with
  | [] -> Ok (false, header)
  | raw ->
      let header = Header.del header "Transfer-Encoding" in
      let proto_at_least m n = major > m || (major = m && minor >= n) in
      if not (proto_at_least 1 1) then Ok (false, header)
      else if List.length raw <> 1 then
        Error
          (Chunk
             (Printf.sprintf "too many transfer encodings: %s"
                (String.concat " " (List.map (Printf.sprintf "%S") raw))))
      else
        let only = List.hd raw in
        if not (ascii_equal_fold only "chunked") then
          Error (Unsupported_transfer_encoding only)
        else Ok (true, header)

(* ------------------------------------------------------------------ *)
(* read_transfer: the transferReader logic.                            *)
(* ------------------------------------------------------------------ *)

(* The subset of *Request / *Response fields that drive transfer reading.
   Mirrors Go's transferReader inputs. [header] is mutated in place. *)
type message = {
  is_response : bool;
  header : Header.t;
  status_code : Httpg_base.Status.t; (* responses; requests use 200 *)
  request_method : Httpg_base.Method.t;
  proto : Httpg_base.Protocol.t;
  close : bool; (* request: rr.Close; response: shouldClose-derived *)
}

(* The decoded framing result, the transferReader outputs unified back onto the
   message (Go writes these into the Request/Response struct). *)
type result = {
  body : Body.t;
  streaming : bool;
      (** whether [body] is a live stream reader (vs a statically-empty body):
          the read paths only interpose the chunked-trailer/EOF adapter on a
          streaming body, never on a known-empty one (a HEAD / no-body chunked
          response must not trigger a spurious trailer read) *)
  content_length : int64;
  is_chunked : bool;
  result_close : bool;
  trailer : Header.t option;
  header : Header.t;
      (** the message header after framing keys (Content-Length /
          Transfer-Encoding / Connection / Trailer) have been consumed *)
}

(* Map a framing [error] into a [Body.error] at the point the read path builds
   the body. Body sits BELOW Transfer (layering), so the mapping happens here,
   where the streaming body is constructed. *)
let body_error_of (e : error) : Body.error =
  match e with
  | Line_too_long -> Body.Line_too_long
  | Chunk msg -> Body.Malformed_chunk msg
  | Unexpected_eof -> Body.Unexpected_eof
  | Bad_content_length _ | Unsupported_transfer_encoding _ | Bad_header _ ->
      Body.Protocol (error_to_string e)

(* read_transfer: header/initial-parse framing errors short-circuit as [Error];
   the resulting body's stream surfaces mid-stream framing failures as a
   terminal [Body.error] element (typed data, never a raise). *)
let read_transfer (msg : message) (r : Eio.Buf_read.t) :
    (result, error) Stdlib.result =
  let ( let* ) = Result.bind in
  let header = msg.header in
  let request_method = msg.request_method in
  (* Default to HTTP/1.1 when proto is 0.0. *)
  let major, minor =
    match msg.proto with
    | Httpg_base.Protocol.Other (0, 0) -> (1, 1)
    | p -> (Httpg_base.Protocol.major p, Httpg_base.Protocol.minor p)
  in
  let status = Httpg_base.Status.to_int msg.status_code in
  let is_response = msg.is_response in

  (* Close: for responses it's shouldClose-derived (caller passes it via
     should_close); for requests it's rr.Close. We re-derive for responses to
     match Go's readTransfer, which calls shouldClose for *Response. *)
  let close, header =
    if is_response then
      should_close ~major ~minor ~header ~remove_close_header:true
    else (msg.close, header)
  in

  let* is_chunked, header = parse_transfer_encoding ~major ~minor ~header in
  let* real_length, header =
    fix_length ~is_response ~status ~request_method ~header ~chunked:is_chunked
  in
  let* content_length =
    if is_response && request_method = Httpg_base.Method.Head then
      parse_content_length (Header.values header "Content-Length")
    else Ok real_length
  in
  let* trailer, header = fix_trailer ~header ~chunked:is_chunked in

  (* Unbounded-body -> close, for responses. *)
  let close =
    if
      is_response
      && Int64.compare real_length (-1L) = 0
      && (not is_chunked)
      && body_allowed_for_status status
    then true
    else close
  in

  (* Read up to [want] buffered bytes from [r], reading the flow only if empty.
     Returns "" at EOF. Bounded windows keep memory flat for large bodies. *)
  let read_some want =
    match Eio.Buf_read.ensure r 1 with
    | exception End_of_file -> ""
    | () ->
        let avail = Eio.Buf_read.buffered_bytes r in
        Eio.Buf_read.take (min want avail) r
  in

  (* Prepare body reader. The streaming pulls produce their mid-stream framing
     failures as a terminal [Body.error] element ([Body.of_stream_result]); a
     malformed chunk / short read is data in the stream, not a raise. *)
  let streaming = ref true in
  let body : Body.t =
    if is_chunked then
      if
        is_response
        && (no_response_body_expected request_method
           || not (body_allowed_for_status status))
      then begin
        streaming := false;
        Body.empty
      end
      else
        let next = new_chunked_reader r in
        Body.of_stream_result (fun () ->
            match next () with
            | None -> None
            | Some (Ok _ as ok) -> Some ok
            | Some (Error e) -> Some (Error (body_error_of e)))
    else if Int64.compare real_length 0L = 0 then begin
      streaming := false;
      Body.empty
    end
    else if Int64.compare real_length 0L > 0 then begin
      (* LimitReader(r, realLength): read exactly real_length bytes. *)
      let remaining = ref real_length in
      Body.of_stream_result (fun () ->
          if Int64.compare !remaining 0L <= 0 then None
          else
            let want = min copy_buf_size (Int64.to_int !remaining) in
            let s = read_some want in
            if s = "" then begin
              remaining := 0L;
              Some (Error Body.Unexpected_eof) (* ErrUnexpectedEOF *)
            end
            else begin
              remaining := Int64.sub !remaining (Int64.of_int (String.length s));
              Some (Ok s)
            end)
    end
    else if close then
      (* realLength < 0 and closing (HTTP/1.0 close-delimited): read until EOF. *)
      Body.of_stream (fun () ->
          let s = read_some copy_buf_size in
          if s = "" then None else Some s)
    else begin
      streaming := false;
      Body.empty (* persistent connection, no length -> no body *)
    end
  in
  Ok
    {
      body;
      streaming = !streaming;
      content_length;
      is_chunked;
      result_close = close;
      trailer;
      header;
    }

(* ------------------------------------------------------------------ *)
(* write_body: the transferWriter body-writing logic.                  *)
(* ------------------------------------------------------------------ *)

(* The sanitized writer triple, mirroring transferWriter (the fields needed to
   write a body). Construct with [make_transfer_writer]. *)
type transfer_writer = {
  tw_method : Httpg_base.Method.t;
  mutable tw_body : Body.t;
  tw_response_to_head : bool;
  mutable tw_content_length : int64; (* -1 unknown, 0 none *)
  mutable tw_transfer_encoding : string list;
  tw_trailer : Header.t option;
  tw_is_response : bool;
  tw_at_least_http11 : bool;
  tw_close : bool;
  tw_header : Header.t;
}

(* requestMethodUsuallyLacksBody (request.go:1578). *)
let request_method_usually_lacks_body = function
  | Httpg_base.Method.Get | Head | Delete | Options
  | Custom ("PROPFIND" | "SEARCH") ->
      true
  | _ -> false

(* probeRequestBody (transfer.go): pull one chunk to see whether the body has
   content. Returns the possibly-pulled chunk to re-prepend, or None at EOF.
   Unlike Go we don't bound the wait with a channel — a streaming body thunk
   that blocks would block here too, but Go's blocking is the same hazard. *)
let probe_request_body (body : Body.t ref) : bool =
  (* Peek the first chunk via [Seq.uncons] (this is the probe — forcing the
     first element is the whole point). Skip leading empty [Ok ""] chunks the
     way Go skips zero-length reads; a terminal [Error] is treated as
     content-present (left in place for the consumer to surface). *)
  let rec peek (s : Body.t) : bool =
    match Seq.uncons s with
    | None ->
        body := Body.empty;
        false
    | Some (Ok "", rest) -> peek rest
    | Some ((Ok _ as elem), rest) ->
        (* Re-prepend the peeked chunk so the body still reads in full. *)
        body := Seq.cons elem rest;
        true
    | Some ((Error _ as elem), rest) ->
        (* Surface the failure to the eventual consumer; treat as present. *)
        body := Seq.cons elem rest;
        true
  in
  peek !body

(* shouldSendChunkedRequestBody (transfer.go:152): only for cl<0, non-CONNECT.
   Body-lacking methods (GET/HEAD/...) are probed so a content-less ReadCloser
   isn't sent as a spurious chunked GET (Issue 18257); all other methods chunk. *)
let should_send_chunked_request_body ~method_ (body : Body.t ref) : bool =
  if method_ = Httpg_base.Method.Connect then false
  else if request_method_usually_lacks_body method_ then probe_request_body body
  else true

(* newTransferWriter's Body/ContentLength/TransferEncoding sanitization. Ports
   transfer.go:96 chunked auto-select for unknown-length request bodies. *)
let make_transfer_writer ?(is_response = false)
    ?(method_ = Httpg_base.Method.Get) ?(response_to_head = false)
    ?(trailer = None) ?(at_least_http11 = true) ?(close = false) ?header
    ~(body : Body.t) ~(content_length : int64)
    ~(transfer_encoding : string list) () : transfer_writer =
  let header = match header with Some h -> h | None -> Header.create () in
  let te = ref transfer_encoding in
  let cl = ref content_length in
  let body = ref body in
  (* transfer.go:96: cl<0, no explicit TE, request -> auto-select chunked
     (probing body-lacking methods). Mutates [body] via the probe. *)
  if
    (not is_response)
    && Int64.compare !cl 0L < 0
    && !te = []
    && should_send_chunked_request_body ~method_ body
  then te := [ "chunked" ];
  (* Go's [Body == nil]: the flat [Body.t] no longer carries this in its shape,
     so we peek one element (non-destructive — [body] re-reads in full). The
     probe above may already have peeked. *)
  let body_is_nil, peeked = Body.is_empty !body in
  body := peeked;
  if response_to_head then begin
    body := Body.empty;
    if chunked !te then cl := -1L
  end
  else begin
    if (not at_least_http11) || body_is_nil then te := [];
    if chunked !te then cl := -1L else if body_is_nil then cl := 0L
  end;
  let trailer = if chunked !te then trailer else None in
  {
    tw_method = method_;
    tw_body = !body;
    tw_response_to_head = response_to_head;
    tw_content_length = !cl;
    tw_transfer_encoding = !te;
    tw_trailer = trailer;
    tw_is_response = is_response;
    tw_at_least_http11 = at_least_http11;
    tw_close = close;
    tw_header = header;
  }

(* shouldSendContentLength (transfer.go). *)
let should_send_content_length (t : transfer_writer) : bool =
  if chunked t.tw_transfer_encoding then false
  else if Int64.compare t.tw_content_length 0L > 0 then true
  else if Int64.compare t.tw_content_length 0L < 0 then false
  else if
    t.tw_method = Httpg_base.Method.Post
    || t.tw_method = Put || t.tw_method = Patch
  then true
  else if
    Int64.compare t.tw_content_length 0L = 0
    && is_identity t.tw_transfer_encoding
  then
    if t.tw_method = Httpg_base.Method.Get || t.tw_method = Head then false
    else true
  else false

(* transferWriter.writeHeader: write Connection/Content-Length/Transfer-Encoding/
   Trailer header lines derived from the sanitized triple. Returns
   [Error (Bad_header _)] on an invalid Trailer key. *)
let write_transfer_header (w : Eio.Buf_write.t) (t : transfer_writer) :
    (unit, error) Stdlib.result =
  let out = Eio.Buf_write.string w in
  if
    t.tw_close
    && not
         (match Header.get t.tw_header "Connection" with
         | Some v -> has_token v "close"
         | None -> false)
  then out "Connection: close\r\n";
  if should_send_content_length t then
    out (Printf.sprintf "Content-Length: %Ld\r\n" t.tw_content_length)
  else if chunked t.tw_transfer_encoding then
    out "Transfer-Encoding: chunked\r\n";
  match t.tw_trailer with
  | None -> Ok ()
  | Some tr -> (
      let err = ref None in
      let keys =
        Header.fold
          (fun k _ acc ->
            let k = Header.canonical_header_key k in
            (match k with
            | "Transfer-Encoding" | "Trailer" | "Content-Length" ->
                if !err = None then
                  err := Some (Bad_header ("invalid Trailer key", k))
            | _ -> ());
            k :: acc)
          tr []
      in
      match !err with
      | Some e -> Error e
      | None ->
          if keys <> [] then
            out
              ("Trailer: "
              ^ String.concat "," (List.sort String.compare keys)
              ^ "\r\n");
          Ok ())

(* writeBody: write the body (and trailers) to [w] in wire format.
   A ContentLength/body-length mismatch is the {b caller} having declared a
   length its body does not match — a contract violation (Go returns this as an
   error from [transferWriter.writeBody]; here, the write path is unit-returning
   and the caller owns the body it supplied), so it is an unhandleable
   [Invalid_argument] (AGENTS.md rule 5: bugs / invariant violations raise). A
   mid-stream [Body.error] on a {b write-side} body is likewise a broken
   caller-supplied body, not a wire-read failure, so it too is [Invalid_argument]. *)
let write_body (w : Eio.Buf_write.t) (t : transfer_writer) : unit =
  let force = function
    | Ok () -> ()
    | Error e -> invalid_arg ("http: write body: " ^ Body.error_to_string e)
  in
  let body_is_nil, body = Body.is_empty t.tw_body in
  let body_present = (not t.tw_response_to_head) && not body_is_nil in
  let after_body () =
    if (not t.tw_response_to_head) && chunked t.tw_transfer_encoding then begin
      (match t.tw_trailer with
      | Some tr ->
          let buf = Buffer.create 64 in
          Header.write tr buf;
          Eio.Buf_write.string w (Buffer.contents buf)
      | None -> ());
      Eio.Buf_write.string w "\r\n"
    end
  in
  if not body_present then after_body ()
  else if chunked t.tw_transfer_encoding then begin
    force (Body.iter (fun chunk -> chunked_writer_write w chunk) body);
    chunked_writer_close w;
    after_body ()
  end
  else if Int64.compare t.tw_content_length (-1L) = 0 then begin
    force (Body.write w body);
    (* unknown length: copy entire body *)
    after_body ()
  end
  else begin
    (* Fixed length (Go's io.CopyN): count bytes and verify against ContentLength. *)
    let n = ref 0L in
    force
      (Body.iter
         (fun chunk ->
           n := Int64.add !n (Int64.of_int (String.length chunk));
           Eio.Buf_write.string w chunk)
         body);
    if Int64.compare t.tw_content_length !n <> 0 then
      invalid_arg
        (Printf.sprintf "http: ContentLength=%Ld with Body length %Ld"
           t.tw_content_length !n);
    after_body ()
  end

module Private = struct
  let parse_content_length = parse_content_length
  let fix_length = fix_length
  let fix_trailer = fix_trailer
  let parse_transfer_encoding = parse_transfer_encoding
end
