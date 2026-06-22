(* Port of the read/write halves of request.go and response.go over
   [Eio.Buf_read.t] / [Eio.Buf_write.t]: readRequest / Request.Write /
   ReadResponse / Response.Write. Multipart, trace and proxy modes are out of
   scope. *)

let bad_string_error_string what value = Printf.sprintf "%s %S" what value

(* Handleable boundary error (see io.mli). *)
type error =
  | Protocol of string
  | Missing_host
  | Transfer of Transfer.error
  | Unexpected_eof
  | Request_too_large
  | Trailer_too_large
  | Malformed_host
  | Response_header_too_large

let error_to_string = function
  | Protocol s -> s
  | Missing_host -> "http: Request.Write on Request with no Host or URL set"
  | Transfer e -> Transfer.error_to_string e
  | Unexpected_eof -> "unexpected EOF"
  | Request_too_large -> "http: request too large"
  | Trailer_too_large -> "http: suspiciously long trailer after chunked body"
  | Malformed_host -> "malformed Host header"
  | Response_header_too_large ->
      "net/http: server response headers exceeded MaxResponseHeaderBytes; \
       aborted"

let ( let* ) = Result.bind

(* ------------------------------------------------------------------ *)
(* textproto-style line + MIME header reading.                         *)
(* ------------------------------------------------------------------ *)

(* Read one CRLF/LF-terminated line, eliding the terminator (textproto.ReadLine).
   Returns [Ok None] at a clean EOF before any bytes (Go's [io.EOF] from
   [ReadLine]); [Ok (Some line)] otherwise; [Error Request_too_large] when the
   budget is exhausted.

   [limit] is a shared mutable byte budget (Go's connReader.setReadLimit,
   server.go:803-818,:1024): each byte pulled — including the terminator —
   decrements it, failing with {!constructor-Request_too_large} before buffering
   an unbounded line. Passing the same ref to the request line and every header
   line bounds the whole head against one cumulative limit. *)
let read_line ?(limit : int ref option) (r : Eio.Buf_read.t) :
    (string option, error) result =
  let buf = Buffer.create 128 in
  let consume () =
    match limit with
    | None -> true
    | Some budget ->
        if !budget <= 0 then false
        else begin
          decr budget;
          true
        end
  in
  let rec loop got_any =
    if not (consume ()) then Error Request_too_large
    else
      match Eio.Buf_read.any_char r with
      | exception End_of_file ->
          if got_any then Ok (Some (Buffer.contents buf)) else Ok None
      | '\n' ->
          let s = Buffer.contents buf in
          let n = String.length s in
          Ok
            (Some
               (if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s))
      | c ->
          Buffer.add_char buf c;
          loop true
  in
  loop false

(* trim: leading/trailing spaces and tabs (textproto.trim). *)
let trim_ws = Httpg_base.Textproto.trim_string

(* validHeaderValueByte (textproto): \t and any byte >= 0x20 except DEL. *)
let valid_header_value_byte c =
  let b = Char.code c in
  b = 0x09 || (b >= 0x20 && b <> 0x7f)

(* httpguts.validHostByte (httplex.go:209-263): the lenient host byte set. *)
let valid_host_byte c =
  match c with
  | '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z' -> true
  | '!' | '$' | '%' | '&' | '(' | ')' | '*' | '+' | ',' | '-' | '.' | ':' | ';'
  | '=' | '[' | '\'' | ']' | '_' | '~' ->
      true
  | _ -> false

let valid_host_header h = String.for_all valid_host_byte h

(* ReadMIMEHeader: read a header block until the blank line, honoring obs-fold
   continuation lines. A malformed line short-circuits as [Error (Protocol _)];
   a clean EOF before the terminating blank line is [Error Unexpected_eof]. *)
let read_mime_header_threaded ?(limit : int ref option) (r : Eio.Buf_read.t) :
    (Header.t, error) result =
  let rec gather acc =
    let* line = read_line ?limit r in
    match line with
    | None -> Error Unexpected_eof
    | Some "" -> Ok (List.rev acc)
    | Some line ->
        if line.[0] = ' ' || line.[0] = '\t' then
          match acc with
          | prev :: rest -> gather ((prev ^ " " ^ trim_ws line) :: rest)
          | [] ->
              Error
                (Protocol
                   (Printf.sprintf "malformed MIME header initial line: %S" line))
        else gather (line :: acc)
  in
  let* lines = gather [] in
  List.fold_left
    (fun h kv ->
      let* h = h in
      match String.index_opt kv ':' with
      | None ->
          Error (Protocol (Printf.sprintf "malformed MIME header line: %S" kv))
      | Some i ->
          let k = String.sub kv 0 i in
          let v = String.sub kv (i + 1) (String.length kv - i - 1) in
          let key = Header.canonical_header_key k in
          if key = "" then
            Error
              (Protocol (Printf.sprintf "malformed MIME header line: %S" kv))
          else if not (String.for_all valid_header_value_byte v) then
            Error
              (Protocol (Printf.sprintf "malformed MIME header line: %S" kv))
          else
            let value =
              let n = String.length v in
              let j = ref 0 in
              while !j < n && (v.[!j] = ' ' || v.[!j] = '\t') do
                incr j
              done;
              String.sub v !j (n - !j)
            in
            Ok (Header.add h key value))
    (Ok (Header.create ()))
    lines

(* fixPragmaCacheControl (response.go). Returns the (possibly updated) header. *)
let fix_pragma_cache_control (h : Header.t) : Header.t =
  match Header.values h "Pragma" with
  | hp :: _ when hp = "no-cache" ->
      if not (Header.has h "Cache-Control") then
        Header.set h "Cache-Control" "no-cache"
      else h
  | _ -> h

(* ------------------------------------------------------------------ *)
(* Body / trailer materialization helpers.                             *)
(* ------------------------------------------------------------------ *)

(* mergeSetHeader (transfer.go): the declared trailer (keys with empty values)
   is the starting point; actual values read after the body overwrite it. *)
let merge_trailer (declared : Header.t option) (hdr : Header.t) :
    Header.t option =
  match declared with
  | None -> if Header.is_empty hdr then None else Some hdr
  | Some t -> Some (Header.fold (fun k v t -> Header.set_values t k v) hdr t)

(* Go bounds the chunked trailer to its bufio buffer size (~4kB,
   transfer.go:932) via a peek-for-double-CRLF hack. We reproduce the effect:
   cap the trailer read to the same byte budget. *)
let trailer_buffer_size = 4096

(* readTrailer (transfer.go:911-951): read the trailer block after a chunked
   body, bounded so a malicious peer cannot OOM us. Read {b mid-stream} when the
   body reaches EOF; a parse failure is typed data ([Error (Body.error)]): a
   budget exhaustion as {!Body.Trailer_too_large}, any other framing error as
   {!Body.Protocol} carrying its message text. *)
let read_trailer (r : Eio.Buf_read.t) : (Header.t, Body.error) result =
  let limit = Some (ref trailer_buffer_size) in
  match read_mime_header_threaded ?limit r with
  | Ok h -> Ok h
  | Error Request_too_large -> Error Body.Trailer_too_large
  | Error e -> Error (Body.Protocol (error_to_string e))

(* Wrap [read_transfer]'s body as the public read-path body: it pulls the
   underlying body chunks; on the first clean EOF, for a chunked body, it reads
   the trailing trailer block and merges it into the trailer cell ([set_trailer]
   mutates the message's [trailer], Go's mergeSetHeader). The underlying body
   already produces its mid-stream framing failures as terminal [Error] elements
   (ticket 006: the chunked / fixed-length readers are result-yielding), so this
   only forwards them; the trailer read likewise returns its own [Error]. No
   try/with converting a raise to an [Error] remains. *)
let stream_body ~(is_chunked : bool) ~(declared_trailer : Header.t option)
    ~(set_trailer : Header.t option -> unit) (r : Eio.Buf_read.t)
    (inner : Body.t) : Body.t =
  let pull = Body.to_stream inner in
  let eof = ref false in
  let next () : (string, Body.error) result option =
    if !eof then None
    else
      match pull () with
      | Some (Ok _) as chunk -> chunk
      | Some (Error _) as e ->
          eof := true;
          e
      | None ->
          eof := true;
          if is_chunked then
            match read_trailer r with
            | Ok tr ->
                set_trailer (merge_trailer declared_trailer tr);
                None
            | Error e -> Some (Error e)
          else begin
            set_trailer declared_trailer;
            None
          end
  in
  Body.of_stream_result next

(* ------------------------------------------------------------------ *)
(* read_request (readRequest / ReadRequest).                           *)
(* ------------------------------------------------------------------ *)

(* parseRequestLine "GET /foo HTTP/1.1". *)
let parse_request_line (line : string) : (string * string * string) option =
  match String.index_opt line ' ' with
  | None -> None
  | Some i1 -> (
      let meth = String.sub line 0 i1 in
      let rest = String.sub line (i1 + 1) (String.length line - i1 - 1) in
      match String.index_opt rest ' ' with
      | None -> None
      | Some i2 ->
          let request_uri = String.sub rest 0 i2 in
          let proto = String.sub rest (i2 + 1) (String.length rest - i2 - 1) in
          Some (meth, request_uri, proto))

(* validMethod: a non-empty token (no CTLs/separators). *)
let is_token (s : string) : bool =
  s <> ""
  && String.for_all
       (fun c ->
         let b = Char.code c in
         b > 0x20 && b < 0x7f
         &&
         match c with
         | '(' | ')' | '<' | '>' | '@' | ',' | ';' | ':' | '\\' | '"' | '/'
         | '[' | ']' | '?' | '=' | '{' | '}' ->
             false
         | _ -> true)
       s

let read_request_threaded ?(max_header_bytes : int option) (r : Eio.Buf_read.t)
    : (Request.t, error) result =
  (* Bound the head against one cumulative budget (initialReadLimitSize =
     maxHeaderBytes + 4096, server.go:929,:1024). *)
  let limit =
    match max_header_bytes with Some n -> Some (ref (n + 4096)) | None -> None
  in
  let bad what value = Error (Protocol (bad_string_error_string what value)) in
  let* s = read_line ?limit r in
  (* A clean EOF before the request line is a truncated head. *)
  let* s = match s with None -> Error Unexpected_eof | Some s -> Ok s in
  let* meth, request_uri, proto =
    match parse_request_line s with
    | None -> bad "malformed HTTP request" s
    | Some t -> Ok t
  in
  let* () = if is_token meth then Ok () else bad "invalid method" meth in
  match Httpg_base.Protocol.of_string proto with
  | None -> bad "malformed HTTP version" proto
  | Some proto_t ->
      let proto_major = Httpg_base.Protocol.major proto_t in
      let proto_minor = Httpg_base.Protocol.minor proto_t in
      let just_authority =
        meth = "CONNECT"
        && not (String.length request_uri > 0 && request_uri.[0] = '/')
      in
      let rawurl =
        if just_authority then "http://" ^ request_uri else request_uri
      in
      let url = Uri.of_string rawurl in
      let url = if just_authority then Uri.with_scheme url None else url in
      let* header = read_mime_header_threaded ?limit r in
      let* () =
        if List.length (Header.values header "Host") > 1 then
          Error (Protocol "too many Host headers")
        else Ok ()
      in
      (* Post-parse validation sweep (server.go:1045-1062). isH2Upgrade:
         method "PRI", no headers, path "*", proto "HTTP/2.0". *)
      let proto_at_least_11 =
        proto_major > 1 || (proto_major = 1 && proto_minor >= 1)
      in
      let host_values = Header.values header "Host" in
      let is_h2_upgrade =
        meth = "PRI" && Header.is_empty header
        && Uri.path url = "*"
        && proto = "HTTP/2.0"
      in
      let* () =
        if
          proto_at_least_11 && host_values = [] && (not is_h2_upgrade)
          && meth <> "CONNECT"
        then Error (Protocol "missing required Host header")
        else Ok ()
      in
      let* () =
        match host_values with
        | [ h ] when not (valid_host_header h) -> Error Malformed_host
        | _ -> Ok ()
      in
      let* () =
        Header.fold
          (fun k vs acc ->
            let* () = acc in
            if not (Header.valid_header_field_name k) then
              Error (Protocol "invalid header name")
            else if
              not
                (List.for_all
                   (fun v -> String.for_all valid_header_value_byte v)
                   vs)
            then Error (Protocol "invalid header value")
            else Ok ())
          header (Ok ())
      in
      let host =
        match Uri.host url with
        | Some h when h <> "" -> h
        | _ -> Header.get header "Host" |> Option.value ~default:""
      in
      let header = fix_pragma_cache_control header in
      let close, _ =
        Transfer.should_close ~major:proto_major ~minor:proto_minor ~header
          ~remove_close_header:false
      in
      (* The wire method token is validated above; carry it typed from here. *)
      let meth = Httpg_base.Method.of_string meth in
      let msg =
        {
          Transfer.is_response = false;
          header;
          status_code = Httpg_base.Status.Custom 0;
          request_method = meth;
          proto = proto_t;
          close;
        }
      in
      let* res =
        Transfer.read_transfer msg r |> Result.map_error (fun e -> Transfer e)
      in
      (* ReadRequest deletes Host from the post-framing header. *)
      let header = Header.del res.Transfer.header "Host" in
      let req =
        {
          Request.meth;
          url;
          proto = proto_t;
          header;
          body = Body.empty;
          content_length =
            (let n = res.Transfer.content_length in
             if Int64.compare n 0L < 0 then None else Some n);
          transfer_encoding =
            (if res.Transfer.is_chunked then [ "chunked" ] else []);
          close = res.Transfer.result_close;
          host = (if host = "" then None else Some host);
          trailer = res.Transfer.trailer;
          request_uri = Some request_uri;
          remote_addr = None;
        }
      in
      req.Request.body <-
        (if res.Transfer.streaming then
           stream_body ~is_chunked:res.Transfer.is_chunked
             ~declared_trailer:res.Transfer.trailer
             ~set_trailer:(fun t -> req.Request.trailer <- t)
             r res.Transfer.body
         else res.Transfer.body);
      Ok req

(* ------------------------------------------------------------------ *)
(* read_response (ReadResponse).                                       *)
(* ------------------------------------------------------------------ *)

(* strings.TrimLeft(s, " "). *)
let trim_left_spaces s = Httpg_base.Textproto.trim_left ~chars:" " s

let read_response_threaded ?(request : Request.t option)
    ?(max_header_bytes : int option) (r : Eio.Buf_read.t) :
    (Response.t, error) result =
  (* Client-side mirror of read_request's head budget
     (Transport.MaxResponseHeaderBytes). The shared budget error remaps to the
     distinct {!Response_header_too_large}. *)
  let limit =
    match max_header_bytes with Some n -> Some (ref (n + 4096)) | None -> None
  in
  (* The status line + header block both use the same budget; a budget
     exhaustion surfaces as the client-side {!Response_header_too_large}. *)
  let head_too_large = function
    | Request_too_large -> Response_header_too_large
    | e -> e
  in
  let bad what value = Error (Protocol (bad_string_error_string what value)) in
  let* line = read_line ?limit r |> Result.map_error head_too_large in
  let* line = match line with None -> Error Unexpected_eof | Some l -> Ok l in
  let proto, status =
    match String.index_opt line ' ' with
    | None -> ("", line)
    | Some i ->
        ( String.sub line 0 i,
          trim_left_spaces
            (String.sub line (i + 1) (String.length line - i - 1)) )
  in
  let* () =
    match String.index_opt line ' ' with
    | None -> bad "malformed HTTP response" line
    | Some _ -> Ok ()
  in
  let status_code_str =
    match String.index_opt status ' ' with
    | None -> status
    | Some j -> String.sub status 0 j
  in
  let bad_status () = bad "malformed HTTP status code" status_code_str in
  if String.length status_code_str <> 3 then bad_status ()
  else
    match int_of_string_opt status_code_str with
    | None -> bad_status ()
    | Some sc when sc < 0 -> bad_status ()
    | Some status_code -> (
        match Httpg_base.Protocol.of_string proto with
        | None -> bad "malformed HTTP version" proto
        | Some proto_t -> (
            match Httpg_base.Status.of_int_result status_code with
            | Error _ -> bad_status ()
            | Ok status_code ->
                let* header =
                  read_mime_header_threaded ?limit r
                  |> Result.map_error head_too_large
                in
                let header = fix_pragma_cache_control header in
                let request_method =
                  match request with
                  | Some req -> req.Request.meth
                  | None -> Httpg_base.Method.Get
                in
                let msg =
                  {
                    Transfer.is_response = true;
                    header;
                    status_code;
                    request_method;
                    proto = proto_t;
                    close = false;
                  }
                in
                let* res =
                  Transfer.read_transfer msg r
                  |> Result.map_error (fun e -> Transfer e)
                in
                let resp =
                  {
                    Response.status = status_code;
                    proto = proto_t;
                    header = res.Transfer.header;
                    body = Body.empty;
                    content_length =
                      (let n = res.Transfer.content_length in
                       if Int64.compare n 0L < 0 then None else Some n);
                    transfer_encoding =
                      (if res.Transfer.is_chunked then [ "chunked" ] else []);
                    close = res.Transfer.result_close;
                    uncompressed = false;
                    trailer = res.Transfer.trailer;
                    request;
                  }
                in
                resp.Response.body <-
                  (if res.Transfer.streaming then
                     stream_body ~is_chunked:res.Transfer.is_chunked
                       ~declared_trailer:res.Transfer.trailer
                       ~set_trailer:(fun t -> resp.Response.trailer <- t)
                       r res.Transfer.body
                   else res.Transfer.body);
                Ok resp))

(* ------------------------------------------------------------------ *)
(* write_request (Request.Write / write).                              *)
(* ------------------------------------------------------------------ *)

(* RequestURI of a URL: path?query (or "/" if empty). *)
let request_uri_of (u : Uri.t) : string =
  let path = Uri.path u in
  let path = if path = "" then "/" else path in
  match Uri.verbatim_query u with Some q -> path ^ "?" ^ q | None -> path

let string_contains_ctl_byte s =
  String.exists
    (fun c ->
      let b = Char.code c in
      b < 0x20 || b = 0x7f)
    s

(* The read path threads [result] directly; the write path threads it too:
   "no Host", a control byte in the request URI, and an invalid Trailer key
   (from {!Transfer.write_transfer_header}) all surface as [Error] returns.
   A ContentLength/body-length mismatch or a broken write-side body in
   {!Transfer.write_body} is a caller contract violation and raises
   [Invalid_argument] (an unhandleable bug, not a modeled [Error]). *)
let write_request (w : Eio.Buf_write.t) (r : Request.t) : (unit, error) result =
  let out = Eio.Buf_write.string w in
  let host =
    match r.Request.host with
    | Some h -> h
    | None -> ( match Uri.host r.Request.url with Some h -> h | None -> "")
  in
  if
    host = ""
    && (match Uri.host r.Request.url with Some _ -> false | None -> true)
    && r.Request.host = None
  then Error Missing_host
  else
    let ruri =
      if
        r.Request.meth = Httpg_base.Method.Connect
        && Uri.path r.Request.url = ""
      then host
      else request_uri_of r.Request.url
    in
    if string_contains_ctl_byte ruri then
      Error (Protocol "net/http: can't write control character in Request.URL")
    else begin
      let meth =
        match r.Request.meth with
        | Httpg_base.Method.Custom "" -> Httpg_base.Method.Get
        | m -> m
      in
      out
        (Printf.sprintf "%s %s HTTP/1.1\r\n"
           (Httpg_base.Method.to_string meth)
           ruri);
      out (Printf.sprintf "Host: %s\r\n" host);
      (* User-Agent: default unless present (a present key with no value — i.e.
         [set_values h "User-Agent" []] — suppresses it). *)
      let user_agent =
        if Header.has r.Request.header "User-Agent" then
          Header.get r.Request.header "User-Agent"
        else Some Request.default_user_agent
      in
      Option.iter
        (fun ua ->
          let ua =
            String.map (fun c -> if c = '\n' || c = '\r' then ' ' else c) ua
          in
          out (Printf.sprintf "User-Agent: %s\r\n" (trim_ws ua)))
        user_agent;
      let tw =
        Transfer.make_transfer_writer ~is_response:false ~method_:meth
          ~at_least_http11:true ~close:r.Request.close ~header:r.Request.header
          ~trailer:r.Request.trailer ~body:r.Request.body
          ~content_length:(Option.value ~default:(-1L) r.Request.content_length)
          ~transfer_encoding:r.Request.transfer_encoding ()
      in
      let* () =
        Transfer.write_transfer_header w tw
        |> Result.map_error (fun e -> Transfer e)
      in
      let buf = Buffer.create 256 in
      Header.write_subset r.Request.header buf
        ~exclude:
          [
            "Host";
            "User-Agent";
            "Content-Length";
            "Transfer-Encoding";
            "Trailer";
          ];
      out (Buffer.contents buf);
      out "\r\n";
      Transfer.write_body w tw;
      Ok ()
    end

let read_mime_header r : (Header.t, error) result = read_mime_header_threaded r

let read_request ?max_header_bytes r : (Request.t, error) result =
  read_request_threaded ?max_header_bytes r

let read_response ?request ?max_header_bytes r : (Response.t, error) result =
  read_response_threaded ?request ?max_header_bytes r

(* ------------------------------------------------------------------ *)
(* write_response (Response.Write).                                    *)
(* ------------------------------------------------------------------ *)

let write_response (w : Eio.Buf_write.t) (r : Response.t) : unit =
  let out = Eio.Buf_write.string w in
  let itoa = string_of_int (Httpg_base.Status.to_int r.Response.status) in
  (* Canonical reason phrase (Go preserves the raw wire text; this port uses the
     canonical text — see Response.status). *)
  let text =
    let st = Httpg_base.Status.to_string r.Response.status in
    if st <> "" then st else "status code " ^ itoa
  in
  out
    (Printf.sprintf "HTTP/%d.%d %03d %s\r\n"
       (Httpg_base.Protocol.major r.Response.proto)
       (Httpg_base.Protocol.minor r.Response.proto)
       (Httpg_base.Status.to_int r.Response.status)
       text);
  (* Clone fields we may modify (r1). *)
  let content_length = ref r.Response.content_length in
  let body = ref r.Response.body in
  let close = ref r.Response.close in
  (* If ContentLength==0 and body non-nil, probe whether it is actually empty.
     This path already buffers the whole body (Go's resp.Write reads it to learn
     the real length), so [read_all] here is not a new whole-body buffering. A
     mid-stream framing [Error] is unexpected on a write-side body (a broken
     caller-supplied body is a contract violation), so it raises [Invalid_argument]
     (an unhandleable bug; this helper is unit-returning / test-facing). *)
  let body_is_nil, peeked = Body.is_empty !body in
  body := peeked;
  if !content_length = Some 0L && not body_is_nil then begin
    let data =
      match Body.read_all !body with
      | Ok d -> d
      | Error e -> invalid_arg ("http: write body: " ^ Body.error_to_string e)
    in
    if data = "" then body := Body.empty
    else begin
      content_length := None;
      body := Body.of_string data
    end
  end;
  (* HTTP/1.1 non-chunked unknown length must signal EOF via Connection: close. *)
  if
    !content_length = None && (not !close)
    && Response.proto_at_least r 1 1
    && (not (Transfer.chunked r.Response.transfer_encoding))
    && not r.Response.uncompressed
  then close := true;
  let method_ =
    match r.Response.request with
    | Some req -> req.Request.meth
    | None -> Httpg_base.Method.Custom ""
  in
  let response_to_head = Transfer.no_response_body_expected method_ in
  let tw =
    Transfer.make_transfer_writer ~is_response:true ~method_ ~response_to_head
      ~at_least_http11:(Response.proto_at_least r 1 1)
      ~close:!close ~header:r.Response.header ~trailer:r.Response.trailer
      ~body:!body
      ~content_length:(Option.value ~default:(-1L) !content_length)
      ~transfer_encoding:r.Response.transfer_encoding ()
  in
  (* White-box test-only: a forbidden Trailer key is a caller contract
     violation, raised as [Invalid_argument] (no result thread out of this test
     helper). *)
  (match Transfer.write_transfer_header w tw with
  | Ok () -> ()
  | Error e -> invalid_arg (error_to_string (Transfer e)));
  let buf = Buffer.create 256 in
  Header.write_subset r.Response.header buf
    ~exclude:[ "Content-Length"; "Transfer-Encoding"; "Trailer" ];
  out (Buffer.contents buf);
  let content_length_already_sent = Transfer.should_send_content_length tw in
  if
    !content_length = Some 0L
    && (not (Transfer.chunked r.Response.transfer_encoding))
    && (not content_length_already_sent)
    && Transfer.body_allowed_for_status
         (Httpg_base.Status.to_int r.Response.status)
  then out "Content-Length: 0\r\n";
  out "\r\n";
  Transfer.write_body w tw

module Private = struct
  let write_response = write_response
end
