(* Port of the read/write halves of request.go and response.go:
   readRequest / Request.Write and ReadResponse / Response.Write, over Lwt_io
   channels (the analogue of Go's bufio.Reader/Writer wrapping a *textproto.Reader).
   Multipart, trace and proxy modes are out of scope. *)

open Lwt.Infix

(* A protocol/parse error, carrying Go's message text. Retained as the internal
   raise mechanism for the parse helpers (caught at the read/write boundary and
   mapped to {!error}) and for the mid-stream body thunk. Transport also raises
   it to thread a round-trip failure message through its exception-based flow. *)
exception Protocol_error of string

(* The write_request "no Host" case (Go's errMissingHost). Declared before
   [type error] so its constructor name is the exception; [missing_host_sentinel]
   aliases it for raising after the [error] variant (which also has a
   [Missing_host] arm) shadows the name. *)
exception Missing_host

let missing_host_sentinel = Missing_host

let bad_string_error what value =
  Protocol_error (Printf.sprintf "%s %S" what value)

(* errTooLarge (server.go:998): the request status line + header block exceeded
   the bounded read budget. Declared before [type error] (whose [Request_too_large]
   arm shadows the name) and aliased so the deep parser can raise it; caught at the
   boundary and mapped to the {!error} arm. The same sentinel backs every bounded
   read (request, response, chunked trailer). *)
exception Request_too_large

let request_too_large_sentinel = Request_too_large

(* "http: suspiciously long trailer after chunked body" (transfer.go:934): the
   trailer block read after a chunked body exceeded the bounded peek budget. Go
   bounds the trailer to its bufio buffer size (~4kB) via [seeUpcomingDoubleCRLF]
   peeking for an upcoming double-CRLF (transfer.go:894-951); since Lwt_io has no
   non-consuming Peek, we reproduce the {b effect} — cap the trailer block to the
   same buffer-size budget using the T2 [read_line ?limit] primitive — and raise
   this distinct sentinel (not [Request_too_large], which would mis-map to 431).
   Read mid-stream inside the body [Stream] thunk, so per the mid-stream policy
   (see io.mli) it keeps raising rather than surfacing as a boundary [Error]. *)
exception Trailer_too_large

let trailer_too_large_sentinel = Trailer_too_large

(* badRequestError("malformed Host header") (server.go:1051): the single inbound
   Host value contained a byte outside [httpguts.ValidHostHeader]'s lenient host
   byte set (httplex.go:209-263). Declared before [type error] (whose
   [Malformed_host] arm shadows the name) and aliased so the deep parser can raise
   it; caught at the boundary and mapped to the {!error} arm -> 400. *)
exception Malformed_host

let malformed_host_sentinel = Malformed_host

(* Client-side analogue of [Request_too_large]: the response status line + header
   block exceeded the bounded read budget (Go's [Transport.MaxResponseHeaderBytes],
   default 10<<20, transport.go:275-280,:337-340,:364). Declared before
   [type error] (whose [Response_header_too_large] arm shadows the name) and
   aliased so the deep parser can raise it; caught at the boundary and mapped to
   the {!error} arm. Reuses the same T2 [read_line ?limit] budget mechanism as the
   request side, but raises a distinct sentinel so the client maps it to its own
   typed error rather than the server-side 431 path. *)
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
   path. Caught at the read/write boundary and mapped to {!error}; never escape
   the module. *)
exception Transfer_error_sentinel of Transfer.error
exception Unexpected_eof_sentinel

(* Run [Transfer.read_transfer], raising the internal sentinel on a boundary
   framing error so the surrounding raising parse code stays linear. *)
let read_transfer_or_raise msg ic : Transfer.result Lwt.t =
  Transfer.read_transfer msg ic >>= function
  | Ok res -> Lwt.return res
  | Error e -> Lwt.fail (Transfer_error_sentinel e)

(* Map an exception raised by the raising parse path to a boundary {!error}. *)
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

(* Read one CRLF- (or bare-LF-) terminated line, eliding the trailing
   \r\n / \n. Raises End_of_file at a clean EOF before any bytes. Mirrors
   bufio.ReadLine as consumed by textproto.ReadLine.

   The optional [limit] is a {b shared mutable byte budget} (Go's
   [connReader.setReadLimit] / [hitReadLimit], server.go:803-818,:1024): each byte
   pulled off [ic] — including the terminating CRLF — decrements it, and the read
   raises the {!Request_too_large} sentinel as soon as the budget would go
   negative, before buffering an unbounded line. Passing the same [int ref] to
   the request-line read and every subsequent header-line read bounds the whole
   request head against one cumulative limit (server.go:929,:1024). Omitting
   [limit] (or any non-bounded caller) leaves the read unbounded, as before. *)
let read_line ?(limit : int ref option) (ic : Lwt_io.input_channel) :
    string Lwt.t =
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
    if not (consume ()) then Lwt.fail request_too_large_sentinel
    else
      Lwt.catch
        (fun () -> Lwt_io.read_char ic >|= fun c -> Some c)
        (function End_of_file -> Lwt.return None | e -> Lwt.fail e)
      >>= function
      | None ->
          if got_any then Lwt.return (Buffer.contents buf)
          else Lwt.fail End_of_file
      | Some '\n' ->
          let s = Buffer.contents buf in
          (* Strip a single trailing CR. *)
          let n = String.length s in
          if n > 0 && s.[n - 1] = '\r' then Lwt.return (String.sub s 0 (n - 1))
          else Lwt.return s
      | Some c ->
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

(* validHeaderValueByte (textproto): allow all bytes except certain controls. *)
let valid_header_value_byte c =
  let b = Char.code c in
  (* From Go: \t (0x09) and any byte >= 0x20 except DEL (0x7f). *)
  b = 0x09 || (b >= 0x20 && b <> 0x7f)

(* httpguts.ValidHostHeader / validHostByte (httplex.go:209-263): a lenient host
   byte set — uri-host plus the optional ":port" — searching for any byte that is
   not valid in those grammars rather than fully parsing. Faithful port of the
   [validHostByte] table. *)
let valid_host_byte c =
  match c with
  | '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z' -> true
  (* sub-delims, unreserved, pct-encoded, IPv6 brackets/zone, port colon. *)
  | '!' | '$' | '%' | '&' | '(' | ')' | '*' | '+' | ',' | '-' | '.' | ':' | ';'
  | '=' | '[' | '\'' | ']' | '_' | '~' ->
      true
  | _ -> false

let valid_host_header h = String.for_all valid_host_byte h

(* ReadMIMEHeader: read a CRLF-terminated header block (until the blank line),
   honoring obs-fold continuation lines (lines starting with space/tab). Returns
   the populated Header. Raises Protocol_error on a malformed line. *)
let read_mime_header_raising ?(limit : int ref option)
    (ic : Lwt_io.input_channel) : Header.t Lwt.t =
  let h = Header.create () in
  (* Read all raw lines of the header block, folding continuations. The shared
     [limit] budget (when present) is decremented across every line, continuing
     from wherever the request/status line left it. *)
  let rec gather acc =
    read_line ?limit ic >>= fun line ->
    if line = "" then Lwt.return (List.rev acc)
    else if String.length line > 0 && (line.[0] = ' ' || line.[0] = '\t') then
      (* Continuation of the previous logical line. *)
      match acc with
      | prev :: rest -> gather ((prev ^ " " ^ trim_ws line) :: rest)
      | [] ->
          Lwt.fail
            (Protocol_error
               (Printf.sprintf "malformed MIME header initial line: %S" line))
    else gather (line :: acc)
  in
  gather [] >>= fun lines ->
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
          (* canonical_header_key returns the input unchanged on an invalid key. *)
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
          (* Skip initial spaces/tabs in the value. *)
          let value =
            let n = String.length v in
            let j = ref 0 in
            while !j < n && (v.[!j] = ' ' || v.[!j] = '\t') do
              incr j
            done;
            String.sub v !j (n - !j)
          in
          Header.add h key value)
    lines;
  Lwt.return h

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

(* mergeSetHeader (transfer.go): merge [hdr] into the trailer cell. The
   declared trailer (parsed from the Trailer header, keys with empty values) is
   the starting point; the actual trailer values read after the chunked body
   overwrite it. *)
let merge_trailer (declared : Header.t option) (hdr : Header.t) :
    Header.t option =
  match declared with
  | None -> if Hashtbl.length hdr = 0 then None else Some hdr
  | Some t ->
      Hashtbl.iter (fun k v -> Hashtbl.replace t k v) hdr;
      Some t

(* Go bounds the chunked trailer to its [bufio.Reader]'s buffer size — "typically
   4kB" (transfer.go:932) — by iteratively peeking for an upcoming double-CRLF
   (seeUpcomingDoubleCRLF, transfer.go:894-907) before handing the bytes to
   textproto. We use the same buffer size as the trailer byte budget. *)
let trailer_buffer_size = 4096

(* readTrailer (transfer.go:911-951): read the trailer block following a chunked
   body and merge it into the trailer cell. Bounded to {!trailer_buffer_size}
   bytes so a malicious peer cannot OOM us with an endless/gigantic trailer.

   Go's defense (transfer.go:925-935) is a peek hack: it cannot slip a
   LimitReader in front of textproto, so it iteratively [Peek]s up to the
   bufio.Reader's buffer size looking for a double-CRLF and rejects the trailer
   ("suspiciously long trailer after chunked body") if none appears within that
   window. [Lwt_io] exposes no non-consuming Peek, so instead of replicating the
   peek-then-parse we reproduce its {b effect} directly: bound the trailer's
   [read_mime_header_raising] with a {!trailer_buffer_size}-byte T2 budget. This
   is equivalent — both cap the trailer to the buffer size — and avoids a parallel
   bounding mechanism. The empty-trailer common case (a bare CRLF, transfer.go:
   913-917) is the [read_line]-returns-"" fast path inside [read_mime_header_raising].

   The budget exhaustion raises [Request_too_large] (the shared [read_line]
   sentinel); we translate it to the distinct {!Trailer_too_large} so it maps to
   the right boundary error rather than 431. *)
let read_trailer (ic : Lwt_io.input_channel) : Header.t Lwt.t =
  let limit = Some (ref trailer_buffer_size) in
  Lwt.catch
    (fun () -> read_mime_header_raising ?limit ic)
    (function
      | e when e == request_too_large_sentinel ->
          Lwt.fail trailer_too_large_sentinel
      | e -> Lwt.fail e)

(* The non-buffering replacement for materialize_body: wrap [read_transfer]'s
   incremental reader as a [Body.Stream] without collapsing it to a String.

   Faithful to Go's [body.Read]/[body.readTrailer]/[body.Close] lifecycle: the
   underlying reader yields chunks until it returns [None] (io.EOF). On that
   first EOF, for a chunked body, we read the trailing trailer block (the bare
   CRLF or a MIME header) and merge it into the trailer cell ([set_trailer],
   which mutates the message's [trailer] field — Go's [mergeSetHeader] onto
   rr.Trailer). The [eof] flag is then set so the connection is positioned at
   the next message boundary; a second call after EOF keeps returning [None]
   (gating keep-alive reuse — the caller, e.g. the server serve loop, runs
   {!Body.drain} to reach this point before reading the next message). *)
let stream_body ~(is_chunked : bool) ~(declared_trailer : Header.t option)
    ~(set_trailer : Header.t option -> unit) (ic : Lwt_io.input_channel)
    (reader : unit -> string option Lwt.t) : Body.t =
  let eof = ref false in
  let next () : string option Lwt.t =
    if !eof then Lwt.return_none
    else
      reader () >>= function
      | Some _ as chunk -> Lwt.return chunk
      | None ->
          eof := true;
          (* On EOF, read & merge the chunked trailer (Go's body.readTrailer).
           Our chunked reader stops at the 0-chunk without consuming the
           trailing CRLF, so the trailer block (possibly a bare CRLF) is read
           here. *)
          if is_chunked then (
            read_trailer ic >|= fun hdr ->
            set_trailer (merge_trailer declared_trailer hdr);
            None)
          else (
            set_trailer declared_trailer;
            Lwt.return_none)
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

(* validMethod: isToken. We accept a non-empty token (no CTLs/separators).
   Reuse Header.canonical_header_key's notion of a valid field name via a simple
   token check. *)
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

let read_request_raising ?(max_header_bytes : int option)
    (ic : Lwt_io.input_channel) : Body.t Request.t Lwt.t =
  (* Bound the request line + header block against one cumulative budget (Go's
     initialReadLimitSize = maxHeaderBytes + 4096 bufio slop, server.go:929,:1024).
     [None] leaves the read unbounded. *)
  let limit =
    match max_header_bytes with Some n -> Some (ref (n + 4096)) | None -> None
  in
  Lwt.catch
    (fun () ->
      read_line ?limit ic >>= fun s ->
      (match parse_request_line s with
        | None -> Lwt.fail (bad_string_error "malformed HTTP request" s)
        | Some (meth, request_uri, proto) ->
            Lwt.return (meth, request_uri, proto))
      >>= fun (meth, request_uri, proto) ->
      if not (is_token meth) then
        Lwt.fail (bad_string_error "invalid method" meth)
      else
        begin match Request.parse_http_version proto with
        | None -> Lwt.fail (bad_string_error "malformed HTTP version" proto)
        | Some (proto_major, proto_minor) ->
            let rawurl = request_uri in
            let just_authority =
              meth = "CONNECT"
              && not (String.length rawurl > 0 && rawurl.[0] = '/')
            in
            let rawurl =
              if just_authority then "http://" ^ rawurl else rawurl
            in
            let url = Uri.of_string rawurl in
            let url =
              if just_authority then Uri.with_scheme url None else url
            in
            read_mime_header_raising ?limit ic >>= fun header ->
            if List.length (Header.values header "Host") > 1 then
              Lwt.fail (Protocol_error "too many Host headers")
            else begin
              (* Post-parse validation sweep (server.go:1045-1062). Go's
                 [isH2Upgrade]: method "PRI", no headers, path "*", proto
                 "HTTP/2.0" (request.go:529). *)
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
              (* Missing required Host on HTTP/1.1+ (server.go:1045-1048). *)
              if
                proto_at_least_11 && host_values = [] && (not is_h2_upgrade)
                && meth <> "CONNECT"
              then Lwt.fail (Protocol_error "missing required Host header")
              else
                (* Malformed single Host value (server.go:1050-1051). *)
                begin match host_values with
                | [ h ] when not (valid_host_header h) ->
                    Lwt.fail malformed_host_sentinel
                | _ -> Lwt.return_unit
                end
                >>= fun () ->
                (* Invalid header name / value sweep (server.go:1053-1062), using
                 the write-side [Header.valid_header_field_name] and the read-side
                 [valid_header_value_byte]. *)
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
                  Transfer.should_close ~major:proto_major ~minor:proto_minor
                    ~header ~remove_close_header:false
                in
                let msg =
                  {
                    Transfer.is_response = false;
                    header;
                    status_code = 0;
                    request_method = meth;
                    proto_major;
                    proto_minor;
                    close;
                  }
                in
                read_transfer_or_raise msg ic >>= fun res ->
                (* ReadRequest deletes the Host header. *)
                Header.del header "Host";
                (* Build the record first with the declared trailer; the streaming
               body's EOF action mutates [r.trailer] (Go's mergeSetHeader onto
               rr.Trailer) on the chunked trailer read. *)
                let r =
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
                    ctx = Context.background;
                  }
                in
                r.Request.body <-
                  (match res.Transfer.body with
                  | Body.Stream reader ->
                      stream_body ~is_chunked:res.Transfer.is_chunked
                        ~declared_trailer:res.Transfer.trailer
                        ~set_trailer:(fun t -> r.Request.trailer <- t)
                        ic reader
                  | (Body.Empty | Body.String _) as b -> b);
                Lwt.return r
            end
        end)
    (function
      | End_of_file -> Lwt.fail Unexpected_eof_sentinel | e -> Lwt.fail e)

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
    ?(max_header_bytes : int option) (ic : Lwt_io.input_channel) :
    Body.t Response.t Lwt.t =
  (* Bound the status line + header block against one cumulative budget, the
     client-side mirror of [read_request_raising] (Go's
     [Transport.MaxResponseHeaderBytes] / [pc.readLimit], transport.go:275-280,
     :337-340,:364). [None] leaves the read unbounded. The shared T2 [read_line]
     budget raises [Request_too_large] on exhaustion; remap it to the distinct
     [Response_header_too_large] sentinel so the client surfaces its own typed
     error rather than the server-side 431 path. *)
  let limit =
    match max_header_bytes with Some n -> Some (ref (n + 4096)) | None -> None
  in
  Lwt.catch
    (fun () -> read_line ?limit ic >|= fun l -> l)
    (function
      | End_of_file -> Lwt.fail Unexpected_eof_sentinel
      | e when e == request_too_large_sentinel ->
          Lwt.fail response_header_too_large_sentinel
      | e -> Lwt.fail e)
  >>= fun line ->
  (match String.index_opt line ' ' with
    | None -> Lwt.fail (bad_string_error "malformed HTTP response" line)
    | Some i ->
        let proto = String.sub line 0 i in
        let status =
          trim_left_spaces
            (String.sub line (i + 1) (String.length line - i - 1))
        in
        Lwt.return (proto, status))
  >>= fun (proto, status) ->
  let status_code_str =
    match String.index_opt status ' ' with
    | None -> status
    | Some j -> String.sub status 0 j
  in
  if String.length status_code_str <> 3 then
    Lwt.fail (bad_string_error "malformed HTTP status code" status_code_str)
  else
    match int_of_string_opt status_code_str with
    | None ->
        Lwt.fail (bad_string_error "malformed HTTP status code" status_code_str)
    | Some sc when sc < 0 ->
        Lwt.fail (bad_string_error "malformed HTTP status code" status_code_str)
    | Some status_code -> (
        match Request.parse_http_version proto with
        | None -> Lwt.fail (bad_string_error "malformed HTTP version" proto)
        | Some (proto_major, proto_minor) ->
            Lwt.catch
              (fun () -> read_mime_header_raising ?limit ic)
              (function
                | e when e == request_too_large_sentinel ->
                    Lwt.fail response_header_too_large_sentinel
                | e -> Lwt.fail e)
            >>= fun header ->
            fix_pragma_cache_control header;
            let request_method =
              match request with Some r -> r.Request.meth | None -> "GET"
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
            read_transfer_or_raise msg ic >>= fun res ->
            (* Build the record first with the declared trailer; the streaming
           body's EOF action mutates [resp.trailer] on the chunked trailer read
           (Go's mergeSetHeader onto rr.Trailer). *)
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
                    ic reader
              | (Body.Empty | Body.String _) as b -> b);
            Lwt.return resp)

(* ------------------------------------------------------------------ *)
(* write_request (Request.Write / write).                              *)
(* ------------------------------------------------------------------ *)

(* RequestURI of a URL: path?query (or "/" if empty). Mirrors url.URL.RequestURI
   for the common (non-opaque, non-proxy) case. *)
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

let write_request_raising (oc : Lwt_io.output_channel) (r : Body.t Request.t) :
    unit Lwt.t =
  let host =
    if r.Request.host <> "" then r.Request.host
    else match Uri.host r.Request.url with Some h -> h | None -> ""
  in
  (if
     host = ""
     &&
     match Uri.host r.Request.url with
     | Some _ -> false
     | None -> r.Request.host = ""
   then Lwt.fail missing_host_sentinel
   else Lwt.return_unit)
  >>= fun () ->
  let ruri =
    if r.Request.meth = "CONNECT" && Uri.path r.Request.url = "" then host
    else request_uri_of r.Request.url
  in
  if string_contains_ctl_byte ruri then
    Lwt.fail
      (Protocol_error "net/http: can't write control character in Request.URL")
  else begin
    let meth = if r.Request.meth = "" then "GET" else r.Request.meth in
    Lwt_io.write oc (Printf.sprintf "%s %s HTTP/1.1\r\n" meth ruri)
    >>= fun () ->
    Lwt_io.write oc (Printf.sprintf "Host: %s\r\n" host) >>= fun () ->
    (* User-Agent: default unless present (a present blank value suppresses it). *)
    let user_agent =
      if Header.has r.Request.header "User-Agent" then
        Header.get r.Request.header "User-Agent"
      else Request.default_user_agent
    in
    (if user_agent <> "" then
       (* headerNewlineToSpace + TrimString. *)
       let ua =
         String.map
           (fun c -> if c = '\n' || c = '\r' then ' ' else c)
           user_agent
       in
       let ua = trim_ws ua in
       Lwt_io.write oc (Printf.sprintf "User-Agent: %s\r\n" ua)
     else Lwt.return_unit)
    >>= fun () ->
    let tw =
      Transfer.make_transfer_writer ~is_response:false ~method_:meth
        ~at_least_http11:true ~close:r.Request.close ~header:r.Request.header
        ~trailer:r.Request.trailer ~body:r.Request.body
        ~content_length:r.Request.content_length
        ~transfer_encoding:r.Request.transfer_encoding ()
    in
    Transfer.write_transfer_header oc tw >>= fun () ->
    let buf = Buffer.create 256 in
    Header.write_subset r.Request.header buf
      ~exclude:
        [
          "Host"; "User-Agent"; "Content-Length"; "Transfer-Encoding"; "Trailer";
        ];
    Lwt_io.write oc (Buffer.contents buf) >>= fun () ->
    Lwt_io.write oc "\r\n" >>= fun () -> Transfer.write_body oc tw
  end

(* ------------------------------------------------------------------ *)
(* Result boundary wrappers.                                           *)
(* ------------------------------------------------------------------ *)

(* Catch the internal raising sentinels and map them to a boundary [error];
   non-boundary exceptions (IO errors other than EOF, programmer bugs) escape. *)
let to_result (f : unit -> 'a Lwt.t) : ('a, error) result Lwt.t =
  Lwt.catch
    (fun () -> f () >|= fun v -> Ok v)
    (fun e -> Lwt.return (Error (error_of_exception e)))

let read_mime_header ic : (Header.t, error) result Lwt.t =
  to_result (fun () -> read_mime_header_raising ic)

let read_request ?max_header_bytes ic : (Body.t Request.t, error) result Lwt.t =
  to_result (fun () -> read_request_raising ?max_header_bytes ic)

let read_response ?request ?max_header_bytes ic :
    (Body.t Response.t, error) result Lwt.t =
  to_result (fun () -> read_response_raising ?request ?max_header_bytes ic)

let write_request oc r : (unit, error) result Lwt.t =
  to_result (fun () -> write_request_raising oc r)

(* ------------------------------------------------------------------ *)
(* write_response (Response.Write).                                    *)
(* ------------------------------------------------------------------ *)

let write_response (oc : Lwt_io.output_channel) (r : Body.t Response.t) :
    unit Lwt.t =
  (* Status line text. *)
  let itoa = string_of_int r.Response.status_code in
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
      let st = Status.status_text r.Response.status_code in
      if st <> "" then st else "status code " ^ itoa
  in
  Lwt_io.write oc
    (Printf.sprintf "HTTP/%d.%d %03d %s\r\n" r.Response.proto_major
       r.Response.proto_minor r.Response.status_code text)
  >>= fun () ->
  (* Clone fields we may modify (r1). *)
  let content_length = ref r.Response.content_length in
  let body = ref r.Response.body in
  let close = ref r.Response.close in
  (* If ContentLength==0 and body non-nil, probe whether it is actually empty. *)
  (if Int64.compare !content_length 0L = 0 && !body <> Body.Empty then
     Body.read_all !body >|= fun data ->
     if data = "" then body := Body.Empty
     else begin
       content_length := -1L;
       body := Body.String data
     end
   else Lwt.return_unit)
  >>= fun () ->
  (* HTTP/1.1 non-chunked unknown length must signal EOF via Connection: close. *)
  if
    Int64.compare !content_length (-1L) = 0
    && (not !close)
    && Response.proto_at_least r 1 1
    && (not (Transfer.chunked r.Response.transfer_encoding))
    && not r.Response.uncompressed
  then close := true;
  let method_ =
    match r.Response.request with Some req -> req.Request.meth | None -> ""
  in
  let response_to_head = Transfer.no_response_body_expected method_ in
  let tw =
    Transfer.make_transfer_writer ~is_response:true ~method_ ~response_to_head
      ~at_least_http11:(Response.proto_at_least r 1 1)
      ~close:!close ~header:r.Response.header ~trailer:r.Response.trailer
      ~body:!body ~content_length:!content_length
      ~transfer_encoding:r.Response.transfer_encoding ()
  in
  Transfer.write_transfer_header oc tw >>= fun () ->
  let buf = Buffer.create 256 in
  Header.write_subset r.Response.header buf
    ~exclude:[ "Content-Length"; "Transfer-Encoding"; "Trailer" ];
  Lwt_io.write oc (Buffer.contents buf) >>= fun () ->
  let content_length_already_sent = Transfer.should_send_content_length tw in
  (if
     Int64.compare !content_length 0L = 0
     && (not (Transfer.chunked r.Response.transfer_encoding))
     && (not content_length_already_sent)
     && Transfer.body_allowed_for_status r.Response.status_code
   then Lwt_io.write oc "Content-Length: 0\r\n"
   else Lwt.return_unit)
  >>= fun () ->
  Lwt_io.write oc "\r\n" >>= fun () -> Transfer.write_body oc tw
