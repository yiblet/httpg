(* Port of go/src/net/http/transfer.go and go/src/net/http/internal/chunked.go:
   the HTTP/1.x wire framing -- chunked transfer-encoding codec, content-length
   framing, trailers -- plus the version-sensitive length/encoding/trailer
   fixups.

   Request/Response structs do not exist yet (Ticket 6), so the [read_transfer]
   inputs are modeled as the [message] record below, mirroring the fields of
   Go's [transferReader] that come from a *Request or *Response. *)

(* The chunked codec now lives in the private internal package
   (Gohttp_internal.Chunked, mirroring net/http/internal). Re-export its
   exceptions so [transfer.ml]'s own framing code and dependent modules/tests
   keep referring to [Transfer.Chunk_error] / [Transfer.Err_line_too_long] with
   the same identity the codec raises. *)
exception Err_line_too_long = Gohttp_internal.Chunked.Err_line_too_long
(* internal.ErrLineTooLong *)

exception Chunk_error = Gohttp_internal.Chunked.Chunk_error
(* malformed-chunk / framing errors carrying Go's message *)

exception Bad_string_error of string * string
(* badStringError(what, value) -> "what: value" *)

let bad_string_error what value = Bad_string_error (what, value)

(* Handleable framing error variant for the header / initial-parse boundary.
   The legacy exceptions above stay for the mid-stream Body.Stream thunks,
   which keep raising, per Resolution #1. *)
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
  | Unsupported_transfer_encoding te -> Printf.sprintf "unsupported transfer encoding: %s" te
  | Bad_header (what, value) -> Printf.sprintf "%s: %s" what value
  | Unexpected_eof -> "unexpected EOF"

(* ------------------------------------------------------------------ *)
(* Small string helpers (ports of the textproto / ascii helpers).     *)
(* ------------------------------------------------------------------ *)

(* textproto.TrimString: trim leading/trailing ' ' and '\t'. *)
let trim_string s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && (s.[!i] = ' ' || s.[!i] = '\t') do
    incr i
  done;
  let j = ref (n - 1) in
  while !j >= !i && (s.[!j] = ' ' || s.[!j] = '\t') do
    decr j
  done;
  String.sub s !i (!j - !i + 1)

let lower_ascii b =
  if b >= 'A' && b <= 'Z' then Char.chr (Char.code b + 32) else b

(* internal/ascii.EqualFold. *)
let ascii_equal_fold = Gohttp_internal.Ascii.equal_fold

(* httpguts.isOWS for token-boundary trimming. *)
let is_ows b = b = ' ' || b = '\t'

let trim_ows x =
  let n = String.length x in
  let i = ref 0 in
  while !i < n && is_ows x.[!i] do incr i done;
  let j = ref (n - 1) in
  while !j >= !i && is_ows x.[!j] do decr j done;
  String.sub x !i (!j - !i + 1)

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

(* ------------------------------------------------------------------ *)
(* Chunked codec (go/src/net/http/internal/chunked.go).                *)
(*                                                                      *)
(* The codec now lives in the private internal package                  *)
(* [Gohttp_internal.Chunked] (mirroring net/http/internal). [transfer.ml]*)
(* delegates to it and re-exports its surface so the public             *)
(* [Transfer.*] API stays stable for dependents (io.ml, body.ml) and    *)
(* tests.                                                               *)
(* ------------------------------------------------------------------ *)

let max_line_length = Gohttp_internal.Chunked.max_line_length

(* Re-export the chunked codec's hex parser. It now returns
   [(int64, Chunked.error) result]; map the codec's error into [Transfer.error]
   so the public surface speaks a single error type. *)
let parse_hex_uint (v : string) : (int64, error) result =
  match Gohttp_internal.Chunked.parse_hex_uint v with
  | Ok n -> Ok n
  | Error Gohttp_internal.Chunked.Line_too_long -> Error Line_too_long
  | Error (Gohttp_internal.Chunked.Chunk msg) -> Error (Chunk msg)

let new_chunked_reader = Gohttp_internal.Chunked.new_chunked_reader
let chunked_writer_write = Gohttp_internal.Chunked.chunked_writer_write
let chunked_writer_close = Gohttp_internal.Chunked.chunked_writer_close

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
    let eq_fold = Gohttp_internal.Ascii.equal_fold in
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
let no_response_body_expected request_method = request_method = "HEAD"

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
let fix_length ~is_response ~status ~request_method ~(header : Header.t) ~chunked:is_chunked :
    (int64, error) result =
  let open Result in
  let is_request = not is_response in
  let content_lens = ref (Header.values header "Content-Length") in

  (* Hardening against request smuggling: collapse duplicate Content-Length. *)
  let dup_check : (unit, error) result =
    if List.length !content_lens > 1 then begin
      match !content_lens with
      | first0 :: rest ->
        let first = trim_string first0 in
        let conflict =
          List.exists (fun ct -> first <> trim_string ct) rest
        in
        if conflict then
          Error
            (Chunk
               (Printf.sprintf
                  "http: message cannot contain multiple Content-Length headers; got %s"
                  (String.concat " " !content_lens)))
        else begin
          Header.del header "Content-Length";
          Header.add header "Content-Length" first;
          content_lens := Header.values header "Content-Length";
          Ok ()
        end
      | [] -> Ok ()
    end
    else Ok ()
  in
  bind dup_check (fun () ->
      (* Reject invalid Content-Length; compute n if present. *)
      let parsed_n : (int64, error) result =
        if !content_lens <> [] then parse_content_length !content_lens else Ok 0L
      in
      bind parsed_n (fun n ->
          if is_response && no_response_body_expected request_method then Ok 0L
          else if status / 100 = 1 then Ok 0L
          else if status = 204 || status = 304 then Ok 0L
          else if is_chunked then begin
            Header.del header "Content-Length";
            Ok (-1L)
          end
          else if !content_lens <> [] then Ok n
          else begin
            Header.del header "Content-Length";
            Ok (if is_request then 0L else -1L)
          end))

(* shouldClose: whether to hang up after this message. Version-sensitive.
   [remove_close_header] mutates [header] to drop a Connection: close. *)
let should_close ~major ~minor ~(header : Header.t) ~remove_close_header : bool =
  if major < 1 then true
  else
    let conv = Header.values header "Connection" in
    let has_close = header_values_contains_token conv "close" in
    if major = 1 && minor = 0 then
      has_close || not (header_values_contains_token conv "keep-alive")
    else begin
      if has_close && remove_close_header then Header.del header "Connection";
      has_close
    end

(* fixTrailer: parse the Trailer header into a trailer Header. Only meaningful
   for chunked encoding. Returns [Ok None] when there is no usable trailer;
   [Error (Bad_header _)] on a forbidden trailer key (header-parse boundary). *)
let fix_trailer ~(header : Header.t) ~chunked:is_chunked : (Header.t option, error) result =
  match Header.values header "Trailer" with
  | [] -> Ok None
  | vv ->
    if not is_chunked then Ok None
    else begin
      Header.del header "Trailer";
      let trailer = Header.create () in
      let err = ref None in
      List.iter
        (fun v ->
          foreach_header_element v (fun key ->
              let key = Header.canonical_header_key key in
              (match key with
              | "Transfer-Encoding" | "Trailer" | "Content-Length" ->
                if !err = None then err := Some (Bad_header ("bad trailer key", key))
              | _ -> ());
              (* trailer[key] = nil : record the key with no values. *)
              Hashtbl.replace trailer key []))
        vv;
      match !err with
      | Some e -> Error e
      | None -> Ok (if Hashtbl.length trailer = 0 then None else Some trailer)
    end

(* parseTransferEncoding equivalent: set whether chunked, version-sensitive.
   Mutates [header] (deletes Transfer-Encoding). Raises Chunk_error for
   unsupported encodings (the unsupportedTEError analogue). HTTP/1.0 ignores
   Transfer-Encoding entirely (Issue 12785). *)
let parse_transfer_encoding ~major ~minor ~(header : Header.t) : (bool, error) result =
  match Header.values header "Transfer-Encoding" with
  | [] -> Ok false
  | raw ->
    Header.del header "Transfer-Encoding";
    let proto_at_least m n = major > m || (major = m && minor >= n) in
    if not (proto_at_least 1 1) then Ok false
    else if List.length raw <> 1 then
      Error
        (Chunk
           (Printf.sprintf "too many transfer encodings: %s"
              (String.concat " " (List.map (Printf.sprintf "%S") raw))))
    else
      let only = List.hd raw in
      if not (ascii_equal_fold only "chunked") then
        Error (Unsupported_transfer_encoding only)
      else Ok true

(* ------------------------------------------------------------------ *)
(* read_transfer: the transferReader logic.                            *)
(* ------------------------------------------------------------------ *)

(* The subset of *Request / *Response fields that drive transfer reading.
   Mirrors Go's transferReader inputs. [header] is mutated in place. *)
type message = {
  is_response : bool;
  header : Header.t;
  status_code : int; (* responses; requests use 200 *)
  request_method : string;
  proto_major : int;
  proto_minor : int;
  close : bool; (* request: rr.Close; response: shouldClose-derived *)
}

(* The decoded framing result, the transferReader outputs unified back onto the
   message (Go writes these into the Request/Response struct). *)
type result = {
  body : Body.t;
  content_length : int64;
  is_chunked : bool;
  result_close : bool;
  trailer : Header.t option;
}

(* read_transfer composes the header/initial-parse steps via Lwt_result so the
   first framing error short-circuits as [Error error]; the resulting body's
   [Body.Stream] thunk keeps raising on mid-stream errors (Resolution #1). *)
let read_transfer (msg : message) (ic : Lwt_io.input_channel) :
    (result, error) Stdlib.result Lwt.t =
  let open Lwt_result.Syntax in
  let header = msg.header in
  let request_method = msg.request_method in
  (* Default to HTTP/1.1 when proto is 0.0. *)
  let major, minor =
    if msg.proto_major = 0 && msg.proto_minor = 0 then (1, 1)
    else (msg.proto_major, msg.proto_minor)
  in
  let status = msg.status_code in
  let is_response = msg.is_response in

  (* Close: for responses it's shouldClose-derived (caller passes it via
     should_close); for requests it's rr.Close. We re-derive for responses to
     match Go's readTransfer, which calls shouldClose for *Response. *)
  let close =
    if is_response then should_close ~major ~minor ~header ~remove_close_header:true
    else msg.close
  in

  let* is_chunked = Lwt_result.lift (parse_transfer_encoding ~major ~minor ~header) in

  let* real_length =
    Lwt_result.lift (fix_length ~is_response ~status ~request_method ~header ~chunked:is_chunked)
  in
  let* content_length =
    if is_response && request_method = "HEAD" then
      Lwt_result.lift (parse_content_length (Header.values header "Content-Length"))
    else Lwt_result.return real_length
  in

  let* trailer = Lwt_result.lift (fix_trailer ~header ~chunked:is_chunked) in

  (* Unbounded-body -> close, for responses. *)
  let close =
    if is_response && Int64.compare real_length (-1L) = 0 && (not is_chunked)
       && body_allowed_for_status status
    then true
    else close
  in

  (* Prepare body reader. *)
  let body : Body.t =
    if is_chunked then
      if is_response && (no_response_body_expected request_method || not (body_allowed_for_status status))
      then Body.Empty
      else Body.Stream (new_chunked_reader ic)
    else if Int64.compare real_length 0L = 0 then Body.Empty
    else if Int64.compare real_length 0L > 0 then begin
      (* LimitReader(r, realLength): read exactly real_length bytes. *)
      let remaining = ref real_length in
      Body.Stream
        (fun () ->
          if Int64.compare !remaining 0L <= 0 then Lwt.return None
          else
            let want = min copy_buf_size (Int64.to_int !remaining) in
            let b = Bytes.create want in
            Lwt.bind
              (Lwt.catch
                 (fun () -> Lwt_io.read_into ic b 0 want)
                 (function End_of_file -> Lwt.return 0 | e -> Lwt.fail e))
              (fun got ->
                if got = 0 then begin
                  (* Early EOF: ErrUnexpectedEOF in Go. *)
                  remaining := 0L;
                  raise (Chunk_error "unexpected EOF")
                end
                else begin
                  remaining := Int64.sub !remaining (Int64.of_int got);
                  Lwt.return (Some (Bytes.sub_string b 0 got))
                end))
    end
    else if close then
      (* realLength < 0 and closing (HTTP/1.0 close-delimited): read until EOF. *)
      Body.Stream
        (fun () ->
          let want = copy_buf_size in
          let b = Bytes.create want in
          Lwt.bind
            (Lwt.catch
               (fun () -> Lwt_io.read_into ic b 0 want)
               (function End_of_file -> Lwt.return 0 | e -> Lwt.fail e))
            (fun got -> if got = 0 then Lwt.return None else Lwt.return (Some (Bytes.sub_string b 0 got))))
    else
      (* Persistent connection, no length -> no body. *)
      Body.Empty
  in

  Lwt_result.return { body; content_length; is_chunked; result_close = close; trailer }

(* ------------------------------------------------------------------ *)
(* write_body: the transferWriter body-writing logic.                  *)
(* ------------------------------------------------------------------ *)

(* The sanitized writer triple, mirroring transferWriter (the fields needed to
   write a body). Construct with [make_transfer_writer]. *)
type transfer_writer = {
  tw_method : string;
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

(* newTransferWriter's Body/ContentLength/TransferEncoding sanitization, the
   pure part (no probeRequestBody async sniffing). *)
let make_transfer_writer ?(is_response = false) ?(method_ = "GET") ?(response_to_head = false)
    ?(trailer = None) ?(at_least_http11 = true) ?(close = false) ?header ~(body : Body.t)
    ~(content_length : int64) ~(transfer_encoding : string list) () : transfer_writer =
  let header = match header with Some h -> h | None -> Header.create () in
  let body_is_nil = body = Body.Empty in
  let te = ref transfer_encoding in
  let cl = ref content_length in
  let body = ref body in
  if response_to_head then begin
    body := Body.Empty;
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
  else if t.tw_method = "POST" || t.tw_method = "PUT" || t.tw_method = "PATCH" then true
  else if Int64.compare t.tw_content_length 0L = 0 && is_identity t.tw_transfer_encoding then
    if t.tw_method = "GET" || t.tw_method = "HEAD" then false else true
  else false

(* transferWriter.writeHeader: write Connection/Content-Length/Transfer-Encoding/
   Trailer header lines derived from the sanitized triple. Raises Bad_string_error
   on an invalid Trailer key. *)
let write_transfer_header (oc : Lwt_io.output_channel) (t : transfer_writer) : unit Lwt.t =
  let open Lwt.Infix in
  (if t.tw_close && not (has_token (Header.get t.tw_header "Connection") "close") then
     Lwt_io.write oc "Connection: close\r\n"
   else Lwt.return_unit)
  >>= fun () ->
  (if should_send_content_length t then
     Lwt_io.write oc (Printf.sprintf "Content-Length: %Ld\r\n" t.tw_content_length)
   else if chunked t.tw_transfer_encoding then Lwt_io.write oc "Transfer-Encoding: chunked\r\n"
   else Lwt.return_unit)
  >>= fun () ->
  match t.tw_trailer with
  | None -> Lwt.return_unit
  | Some tr ->
    let keys =
      Hashtbl.fold
        (fun k _ acc ->
          let k = Header.canonical_header_key k in
          (match k with
          | "Transfer-Encoding" | "Trailer" | "Content-Length" ->
            raise (bad_string_error "invalid Trailer key" k)
          | _ -> ());
          k :: acc)
        tr []
    in
    if keys = [] then Lwt.return_unit
    else
      let keys = List.sort String.compare keys in
      Lwt_io.write oc ("Trailer: " ^ String.concat "," keys ^ "\r\n")

(* writeBody: write the body (and trailers) to [oc] in wire format. Raises
   Chunk_error on a ContentLength/body-length mismatch. *)
let write_body (oc : Lwt_io.output_channel) (t : transfer_writer) : unit Lwt.t =
  let body_present = (not t.tw_response_to_head) && t.tw_body <> Body.Empty in
  let after_body () : unit Lwt.t =
    if (not t.tw_response_to_head) && chunked t.tw_transfer_encoding then begin
      (* Trailer header then the terminating CRLF. *)
      Lwt.bind
        (match t.tw_trailer with
        | Some tr ->
          let buf = Buffer.create 64 in
          Header.write tr buf;
          Lwt_io.write oc (Buffer.contents buf)
        | None -> Lwt.return_unit)
        (fun () -> Lwt_io.write oc "\r\n")
    end
    else Lwt.return_unit
  in
  if not body_present then after_body ()
  else if chunked t.tw_transfer_encoding then
    (* Chunked: stream each source chunk through the chunked writer (Go's
       [io.Copy] into the chunkedWriter), then the terminating 0-chunk. *)
    Lwt.bind
      (Body.iter (fun chunk -> chunked_writer_write oc chunk) t.tw_body)
      (fun () -> Lwt.bind (chunked_writer_close oc) (fun () -> after_body ()))
  else if Int64.compare t.tw_content_length (-1L) = 0 then
    (* Unknown length: copy entire body. *)
    Lwt.bind (Body.write oc t.tw_body) (fun () -> after_body ())
  else
    (* Fixed length: stream the body (Go's [io.CopyN]), counting bytes, then
       verify the byte count matches ContentLength. *)
    let n = ref 0L in
    Lwt.bind
      (Body.iter
         (fun chunk ->
           n := Int64.add !n (Int64.of_int (String.length chunk));
           Lwt_io.write oc chunk)
         t.tw_body)
      (fun () ->
        if Int64.compare t.tw_content_length !n <> 0 then
          raise
            (Chunk_error
               (Printf.sprintf "http: ContentLength=%Ld with Body length %Ld" t.tw_content_length
                  !n));
        after_body ())
