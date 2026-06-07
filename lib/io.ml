(* Port of the read/write halves of request.go and response.go over
   [Eio.Buf_read.t] / [Eio.Buf_write.t]: readRequest / Request.Write /
   ReadResponse / Response.Write. Multipart, trace and proxy modes are out of
   scope. *)

(* Internal raise mechanism for the parse helpers (caught at the boundary and
   mapped to {!error}) and for the mid-stream body thunk. Transport also raises
   it to thread a round-trip failure message. *)
exception Protocol_error of string

(* write_request "no Host" (Go's errMissingHost). Declared before [type error]
   so its constructor is the exception; aliased for raising after [error]'s
   [Missing_host] arm shadows the name. *)
exception Missing_host

let missing_host_sentinel = Missing_host

let bad_string_error what value =
  Protocol_error (Printf.sprintf "%s %S" what value)

(* errTooLarge (server.go:998): request head exceeded the bounded read budget.
   Aliased so the deep parser can raise it; mapped to {!error} at the boundary.
   The same sentinel backs every bounded read. *)
exception Request_too_large

let request_too_large_sentinel = Request_too_large

(* "suspiciously long trailer after chunked body" (transfer.go:934). Read
   mid-stream inside the body [Stream] thunk, so per the mid-stream policy it
   keeps raising rather than surfacing as a boundary [Error]. *)
exception Trailer_too_large

let trailer_too_large_sentinel = Trailer_too_large

(* badRequestError("malformed Host header") (server.go:1051). *)
exception Malformed_host

let malformed_host_sentinel = Malformed_host

(* Client-side analogue of [Request_too_large]: response head exceeded the
   bounded budget (Transport.MaxResponseHeaderBytes). *)
exception Response_header_too_large

let response_header_too_large_sentinel = Response_header_too_large

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

(* Internal sentinels carrying a typed boundary error through the raising parse
   path; caught at the boundary and mapped to {!error}. *)
exception Transfer_error_sentinel of Transfer.error
exception Unexpected_eof_sentinel

let read_transfer_or_raise msg r : Transfer.result =
  match Transfer.read_transfer msg r with
  | Ok res -> res
  | Error e -> raise (Transfer_error_sentinel e)

let error_of_exception = function
  | Protocol_error s -> Protocol s
  | Transfer_error_sentinel e -> Transfer e
  | Unexpected_eof_sentinel -> Unexpected_eof
  | End_of_file -> Unexpected_eof
  | e when e == missing_host_sentinel -> Missing_host
  | e when e == request_too_large_sentinel -> Request_too_large
  | e when e == trailer_too_large_sentinel -> Trailer_too_large
  | e when e == malformed_host_sentinel -> Malformed_host
  | e when e == response_header_too_large_sentinel -> Response_header_too_large
  | e -> raise e

(* ------------------------------------------------------------------ *)
(* textproto-style line + MIME header reading.                         *)
(* ------------------------------------------------------------------ *)

(* Read one CRLF/LF-terminated line, eliding the terminator. Raises
   [End_of_file] at a clean EOF before any bytes (textproto.ReadLine).

   [limit] is a shared mutable byte budget (Go's connReader.setReadLimit,
   server.go:803-818,:1024): each byte pulled — including the terminator —
   decrements it, raising {!Request_too_large} before buffering an unbounded
   line. Passing the same ref to the request line and every header line bounds
   the whole head against one cumulative limit. *)
let read_line ?(limit : int ref option) (r : Eio.Buf_read.t) : string =
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
    if not (consume ()) then raise request_too_large_sentinel
    else
      match Eio.Buf_read.any_char r with
      | exception End_of_file ->
          if got_any then Buffer.contents buf else raise End_of_file
      | '\n' ->
          let s = Buffer.contents buf in
          let n = String.length s in
          if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s
      | c ->
          Buffer.add_char buf c;
          loop true
  in
  loop false

(* trim: leading/trailing spaces and tabs (textproto.trim). *)
let trim_ws s =
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
   continuation lines. Raises Protocol_error on a malformed line. *)
let read_mime_header_raising ?(limit : int ref option) (r : Eio.Buf_read.t) :
    Header.t =
  let h = Header.create () in
  let rec gather acc =
    let line = read_line ?limit r in
    if line = "" then List.rev acc
    else if line.[0] = ' ' || line.[0] = '\t' then
      match acc with
      | prev :: rest -> gather ((prev ^ " " ^ trim_ws line) :: rest)
      | [] ->
          raise
            (Protocol_error
               (Printf.sprintf "malformed MIME header initial line: %S" line))
    else gather (line :: acc)
  in
  List.iter
    (fun kv ->
      match String.index_opt kv ':' with
      | None ->
          raise
            (Protocol_error (Printf.sprintf "malformed MIME header line: %S" kv))
      | Some i ->
          let k = String.sub kv 0 i in
          let v = String.sub kv (i + 1) (String.length kv - i - 1) in
          let key = Header.canonical_header_key k in
          if key = "" then
            raise
              (Protocol_error
                 (Printf.sprintf "malformed MIME header line: %S" kv));
          String.iter
            (fun c ->
              if not (valid_header_value_byte c) then
                raise
                  (Protocol_error
                     (Printf.sprintf "malformed MIME header line: %S" kv)))
            v;
          let value =
            let n = String.length v in
            let j = ref 0 in
            while !j < n && (v.[!j] = ' ' || v.[!j] = '\t') do
              incr j
            done;
            String.sub v !j (n - !j)
          in
          Header.add h key value)
    (gather []);
  h

(* fixPragmaCacheControl (response.go). *)
let fix_pragma_cache_control (h : Header.t) =
  match Header.values h "Pragma" with
  | hp :: _ when hp = "no-cache" ->
      if not (Header.has h "Cache-Control") then
        Header.set h "Cache-Control" "no-cache"
  | _ -> ()

(* ------------------------------------------------------------------ *)
(* Body / trailer materialization helpers.                             *)
(* ------------------------------------------------------------------ *)

(* mergeSetHeader (transfer.go): the declared trailer (keys with empty values)
   is the starting point; actual values read after the body overwrite it. *)
let merge_trailer (declared : Header.t option) (hdr : Header.t) :
    Header.t option =
  match declared with
  | None -> if Hashtbl.length hdr = 0 then None else Some hdr
  | Some t ->
      Hashtbl.iter (fun k v -> Hashtbl.replace t k v) hdr;
      Some t

(* Go bounds the chunked trailer to its bufio buffer size (~4kB,
   transfer.go:932) via a peek-for-double-CRLF hack. We reproduce the effect:
   cap the trailer read to the same byte budget. *)
let trailer_buffer_size = 4096

(* readTrailer (transfer.go:911-951): read the trailer block after a chunked
   body, bounded so a malicious peer cannot OOM us. Budget exhaustion raises the
   shared {!Request_too_large} sentinel; remap to {!Trailer_too_large}. *)
let read_trailer (r : Eio.Buf_read.t) : Header.t =
  let limit = Some (ref trailer_buffer_size) in
  try read_mime_header_raising ?limit r
  with e when e == request_too_large_sentinel ->
    raise trailer_too_large_sentinel

(* Wrap [read_transfer]'s incremental reader as a [Body.Stream]. On the first
   EOF, for a chunked body, read the trailing trailer block and merge it into
   the trailer cell ([set_trailer] mutates the message's [trailer], Go's
   mergeSetHeader). A second call after EOF keeps returning [None] (gating
   keep-alive reuse). *)
let stream_body ~(is_chunked : bool) ~(declared_trailer : Header.t option)
    ~(set_trailer : Header.t option -> unit) (r : Eio.Buf_read.t)
    (reader : unit -> string option) : Body.t =
  let eof = ref false in
  let next () : string option =
    if !eof then None
    else
      match reader () with
      | Some _ as chunk -> chunk
      | None ->
          eof := true;
          if is_chunked then begin
            set_trailer (merge_trailer declared_trailer (read_trailer r));
            None
          end
          else begin
            set_trailer declared_trailer;
            None
          end
  in
  Body.Stream next

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

let read_request_raising ?(max_header_bytes : int option) (r : Eio.Buf_read.t) :
    Body.t Request.t =
  (* Bound the head against one cumulative budget (initialReadLimitSize =
     maxHeaderBytes + 4096, server.go:929,:1024). *)
  let limit =
    match max_header_bytes with Some n -> Some (ref (n + 4096)) | None -> None
  in
  try
    let s = read_line ?limit r in
    let meth, request_uri, proto =
      match parse_request_line s with
      | None -> raise (bad_string_error "malformed HTTP request" s)
      | Some t -> t
    in
    if not (is_token meth) then raise (bad_string_error "invalid method" meth);
    match Request.parse_http_version proto with
    | None -> raise (bad_string_error "malformed HTTP version" proto)
    | Some (proto_major, proto_minor) ->
        let just_authority =
          meth = "CONNECT"
          && not (String.length request_uri > 0 && request_uri.[0] = '/')
        in
        let rawurl =
          if just_authority then "http://" ^ request_uri else request_uri
        in
        let url = Uri.of_string rawurl in
        let url = if just_authority then Uri.with_scheme url None else url in
        let header = read_mime_header_raising ?limit r in
        if List.length (Header.values header "Host") > 1 then
          raise (Protocol_error "too many Host headers");
        (* Post-parse validation sweep (server.go:1045-1062). isH2Upgrade:
           method "PRI", no headers, path "*", proto "HTTP/2.0". *)
        let proto_at_least_11 =
          proto_major > 1 || (proto_major = 1 && proto_minor >= 1)
        in
        let host_values = Header.values header "Host" in
        let is_h2_upgrade =
          meth = "PRI"
          && Hashtbl.length header = 0
          && Uri.path url = "*"
          && proto = "HTTP/2.0"
        in
        if
          proto_at_least_11 && host_values = [] && (not is_h2_upgrade)
          && meth <> "CONNECT"
        then raise (Protocol_error "missing required Host header");
        (match host_values with
        | [ h ] when not (valid_host_header h) -> raise malformed_host_sentinel
        | _ -> ());
        Hashtbl.iter
          (fun k vs ->
            if not (Header.valid_header_field_name k) then
              raise (Protocol_error "invalid header name");
            List.iter
              (fun v ->
                if not (String.for_all valid_header_value_byte v) then
                  raise (Protocol_error "invalid header value"))
              vs)
          header;
        let host =
          match Uri.host url with
          | Some h when h <> "" -> h
          | _ -> Header.get header "Host"
        in
        fix_pragma_cache_control header;
        let close =
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
            proto_major;
            proto_minor;
            close;
          }
        in
        let res = read_transfer_or_raise msg r in
        Header.del header "Host";
        (* ReadRequest deletes Host *)
        let req =
          {
            Request.meth;
            url;
            proto;
            proto_major;
            proto_minor;
            header;
            body = Body.Empty;
            content_length = res.Transfer.content_length;
            transfer_encoding =
              (if res.Transfer.is_chunked then [ "chunked" ] else []);
            close = res.Transfer.result_close;
            host;
            trailer = res.Transfer.trailer;
            request_uri;
            remote_addr = "";
            form = None;
            post_form = None;
            multipart_form = None;
          }
        in
        req.Request.body <-
          (match res.Transfer.body with
          | Body.Stream reader ->
              stream_body ~is_chunked:res.Transfer.is_chunked
                ~declared_trailer:res.Transfer.trailer
                ~set_trailer:(fun t -> req.Request.trailer <- t)
                r reader
          | (Body.Empty | Body.String _) as b -> b);
        req
  with End_of_file -> raise Unexpected_eof_sentinel

(* ------------------------------------------------------------------ *)
(* read_response (ReadResponse).                                       *)
(* ------------------------------------------------------------------ *)

(* strings.TrimLeft(s, " "). *)
let trim_left_spaces s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && s.[!i] = ' ' do
    incr i
  done;
  String.sub s !i (n - !i)

let read_response_raising ?(request : Body.t Request.t option)
    ?(max_header_bytes : int option) (r : Eio.Buf_read.t) : Body.t Response.t =
  (* Client-side mirror of read_request's head budget
     (Transport.MaxResponseHeaderBytes). The shared sentinel remaps to the
     distinct {!Response_header_too_large}. *)
  let limit =
    match max_header_bytes with Some n -> Some (ref (n + 4096)) | None -> None
  in
  let read_head () =
    try read_line ?limit r with
    | End_of_file -> raise Unexpected_eof_sentinel
    | e when e == request_too_large_sentinel ->
        raise response_header_too_large_sentinel
  in
  let line = read_head () in
  let proto, status =
    match String.index_opt line ' ' with
    | None -> raise (bad_string_error "malformed HTTP response" line)
    | Some i ->
        ( String.sub line 0 i,
          trim_left_spaces
            (String.sub line (i + 1) (String.length line - i - 1)) )
  in
  let status_code_str =
    match String.index_opt status ' ' with
    | None -> status
    | Some j -> String.sub status 0 j
  in
  let bad_status () =
    raise (bad_string_error "malformed HTTP status code" status_code_str)
  in
  if String.length status_code_str <> 3 then bad_status ();
  match int_of_string_opt status_code_str with
  | None -> bad_status ()
  | Some sc when sc < 0 -> bad_status ()
  | Some status_code -> (
      match Request.parse_http_version proto with
      | None -> raise (bad_string_error "malformed HTTP version" proto)
      | Some (proto_major, proto_minor) ->
          let status_code =
            match Httpg_base.Status.of_int_result status_code with
            | Ok s -> s
            | Error _ -> bad_status ()
          in
          let header =
            try read_mime_header_raising ?limit r
            with e when e == request_too_large_sentinel ->
              raise response_header_too_large_sentinel
          in
          fix_pragma_cache_control header;
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
              proto_major;
              proto_minor;
              close = false;
            }
          in
          let res = read_transfer_or_raise msg r in
          let resp =
            {
              Response.status;
              status_code;
              proto;
              proto_major;
              proto_minor;
              header;
              body = Body.Empty;
              content_length = res.Transfer.content_length;
              transfer_encoding =
                (if res.Transfer.is_chunked then [ "chunked" ] else []);
              close = res.Transfer.result_close;
              uncompressed = false;
              trailer = res.Transfer.trailer;
              request;
            }
          in
          resp.Response.body <-
            (match res.Transfer.body with
            | Body.Stream reader ->
                stream_body ~is_chunked:res.Transfer.is_chunked
                  ~declared_trailer:res.Transfer.trailer
                  ~set_trailer:(fun t -> resp.Response.trailer <- t)
                  r reader
            | (Body.Empty | Body.String _) as b -> b);
          resp)

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

let write_request_raising (w : Eio.Buf_write.t) (r : Body.t Request.t) : unit =
  let out = Eio.Buf_write.string w in
  let host =
    if r.Request.host <> "" then r.Request.host
    else match Uri.host r.Request.url with Some h -> h | None -> ""
  in
  if
    host = ""
    && (match Uri.host r.Request.url with Some _ -> false | None -> true)
    && r.Request.host = ""
  then raise missing_host_sentinel;
  let ruri =
    if r.Request.meth = Httpg_base.Method.Connect && Uri.path r.Request.url = ""
    then host
    else request_uri_of r.Request.url
  in
  if string_contains_ctl_byte ruri then
    raise
      (Protocol_error "net/http: can't write control character in Request.URL");
  let meth =
    match r.Request.meth with
    | Httpg_base.Method.Custom "" -> Httpg_base.Method.Get
    | m -> m
  in
  out
    (Printf.sprintf "%s %s HTTP/1.1\r\n" (Httpg_base.Method.to_string meth) ruri);
  out (Printf.sprintf "Host: %s\r\n" host);
  (* User-Agent: default unless present (a present blank value suppresses it). *)
  let user_agent =
    if Header.has r.Request.header "User-Agent" then
      Header.get r.Request.header "User-Agent"
    else Request.default_user_agent
  in
  if user_agent <> "" then begin
    let ua =
      String.map (fun c -> if c = '\n' || c = '\r' then ' ' else c) user_agent
    in
    out (Printf.sprintf "User-Agent: %s\r\n" (trim_ws ua))
  end;
  let tw =
    Transfer.make_transfer_writer ~is_response:false ~method_:meth
      ~at_least_http11:true ~close:r.Request.close ~header:r.Request.header
      ~trailer:r.Request.trailer ~body:r.Request.body
      ~content_length:r.Request.content_length
      ~transfer_encoding:r.Request.transfer_encoding ()
  in
  Transfer.write_transfer_header w tw;
  let buf = Buffer.create 256 in
  Header.write_subset r.Request.header buf
    ~exclude:
      [ "Host"; "User-Agent"; "Content-Length"; "Transfer-Encoding"; "Trailer" ];
  out (Buffer.contents buf);
  out "\r\n";
  Transfer.write_body w tw

(* ------------------------------------------------------------------ *)
(* Result boundary wrappers.                                           *)
(* ------------------------------------------------------------------ *)

(* Catch the internal raising sentinels and map them to a boundary [error];
   non-boundary exceptions (IO errors, programmer bugs) escape. *)
let to_result (f : unit -> 'a) : ('a, error) result =
  try Ok (f ()) with e -> Error (error_of_exception e)

let read_mime_header r : (Header.t, error) result =
  to_result (fun () -> read_mime_header_raising r)

let read_request ?max_header_bytes r : (Body.t Request.t, error) result =
  to_result (fun () -> read_request_raising ?max_header_bytes r)

let read_response ?request ?max_header_bytes r :
    (Body.t Response.t, error) result =
  to_result (fun () -> read_response_raising ?request ?max_header_bytes r)

let write_request w r : (unit, error) result =
  to_result (fun () -> write_request_raising w r)

(* ------------------------------------------------------------------ *)
(* write_response (Response.Write).                                    *)
(* ------------------------------------------------------------------ *)

let write_response (w : Eio.Buf_write.t) (r : Body.t Response.t) : unit =
  let out = Eio.Buf_write.string w in
  let itoa = string_of_int (Httpg_base.Status.to_int r.Response.status_code) in
  let text =
    if r.Response.status <> "" then begin
      (* Strip a leading "<code> " prefix to reduce stutter. *)
      let prefix = itoa ^ " " in
      if
        String.length r.Response.status >= String.length prefix
        && String.sub r.Response.status 0 (String.length prefix) = prefix
      then
        String.sub r.Response.status (String.length prefix)
          (String.length r.Response.status - String.length prefix)
      else r.Response.status
    end
    else
      let st = Httpg_base.Status.to_string r.Response.status_code in
      if st <> "" then st else "status code " ^ itoa
  in
  out
    (Printf.sprintf "HTTP/%d.%d %03d %s\r\n" r.Response.proto_major
       r.Response.proto_minor
       (Httpg_base.Status.to_int r.Response.status_code)
       text);
  (* Clone fields we may modify (r1). *)
  let content_length = ref r.Response.content_length in
  let body = ref r.Response.body in
  let close = ref r.Response.close in
  (* If ContentLength==0 and body non-nil, probe whether it is actually empty. *)
  if Int64.compare !content_length 0L = 0 && !body <> Body.Empty then begin
    let data = Body.read_all !body in
    if data = "" then body := Body.Empty
    else begin
      content_length := -1L;
      body := Body.String data
    end
  end;
  (* HTTP/1.1 non-chunked unknown length must signal EOF via Connection: close. *)
  if
    Int64.compare !content_length (-1L) = 0
    && (not !close)
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
      ~body:!body ~content_length:!content_length
      ~transfer_encoding:r.Response.transfer_encoding ()
  in
  Transfer.write_transfer_header w tw;
  let buf = Buffer.create 256 in
  Header.write_subset r.Response.header buf
    ~exclude:[ "Content-Length"; "Transfer-Encoding"; "Trailer" ];
  out (Buffer.contents buf);
  let content_length_already_sent = Transfer.should_send_content_length tw in
  if
    Int64.compare !content_length 0L = 0
    && (not (Transfer.chunked r.Response.transfer_encoding))
    && (not content_length_already_sent)
    && Transfer.body_allowed_for_status
         (Httpg_base.Status.to_int r.Response.status_code)
  then out "Content-Length: 0\r\n";
  out "\r\n";
  Transfer.write_body w tw
