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
   [type error] so its constructor name is the exception; [missing_host_exn]
   aliases it for raising after the [error] variant (which also has a
   [Missing_host] arm) shadows the name. *)
exception Missing_host

let missing_host_exn = Missing_host

let bad_string_error what value = Protocol_error (Printf.sprintf "%s %S" what value)

(* Handleable boundary error (see io.mli). *)
type error =
  | Protocol of string
  | Missing_host
  | Transfer of Transfer.error
  | Unexpected_eof

let error_to_string = function
  | Protocol s -> s
  | Missing_host -> "http: Request.Write on Request with no Host or URL set"
  | Transfer e -> Transfer.error_to_string e
  | Unexpected_eof -> "unexpected EOF"

(* Internal sentinels carrying a typed boundary error through the raising parse
   path. Caught at the read/write boundary and mapped to {!error}; never escape
   the module. *)
exception Transfer_error_exn of Transfer.error
exception Unexpected_eof_exn

(* Run [Transfer.read_transfer], raising the internal sentinel on a boundary
   framing error so the surrounding raising parse code stays linear. *)
let read_transfer_or_raise msg ic : Transfer.result Lwt.t =
  Transfer.read_transfer msg ic >>= function
  | Ok res -> Lwt.return res
  | Error e -> Lwt.fail (Transfer_error_exn e)

(* Map an exception raised by the raising parse path to a boundary {!error}. *)
let error_of_exn = function
  | Protocol_error s -> Protocol s
  | Transfer_error_exn e -> Transfer e
  | Unexpected_eof_exn -> Unexpected_eof
  | End_of_file -> Unexpected_eof
  | e when e == missing_host_exn -> Missing_host
  | e -> raise e

(* ------------------------------------------------------------------ *)
(* textproto-style line + MIME header reading.                         *)
(* ------------------------------------------------------------------ *)

(* Read one CRLF- (or bare-LF-) terminated line, eliding the trailing
   \r\n / \n. Raises End_of_file at a clean EOF before any bytes. Mirrors
   bufio.ReadLine as consumed by textproto.ReadLine. *)
let read_line (ic : Lwt_io.input_channel) : string Lwt.t =
  let buf = Buffer.create 128 in
  let rec loop got_any =
    Lwt.catch
      (fun () -> Lwt_io.read_char ic >|= fun c -> Some c)
      (function End_of_file -> Lwt.return None | e -> Lwt.fail e)
    >>= function
    | None -> if got_any then Lwt.return (Buffer.contents buf) else Lwt.fail End_of_file
    | Some '\n' ->
      let s = Buffer.contents buf in
      (* Strip a single trailing CR. *)
      let n = String.length s in
      if n > 0 && s.[n - 1] = '\r' then Lwt.return (String.sub s 0 (n - 1)) else Lwt.return s
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

(* ReadMIMEHeader: read a CRLF-terminated header block (until the blank line),
   honoring obs-fold continuation lines (lines starting with space/tab). Returns
   the populated Header. Raises Protocol_error on a malformed line. *)
let read_mime_header_raising (ic : Lwt_io.input_channel) : Header.t Lwt.t =
  let h = Header.create () in
  (* Read all raw lines of the header block, folding continuations. *)
  let rec gather acc =
    read_line ic >>= fun line ->
    if line = "" then Lwt.return (List.rev acc)
    else if (String.length line > 0) && (line.[0] = ' ' || line.[0] = '\t') then
      (* Continuation of the previous logical line. *)
      match acc with
      | prev :: rest -> gather ((prev ^ " " ^ trim_ws line) :: rest)
      | [] -> Lwt.fail (Protocol_error (Printf.sprintf "malformed MIME header initial line: %S" line))
    else gather (line :: acc)
  in
  gather [] >>= fun lines ->
  List.iter
    (fun kv ->
      match String.index_opt kv ':' with
      | None -> raise (Protocol_error (Printf.sprintf "malformed MIME header line: %S" kv))
      | Some i ->
        let k = String.sub kv 0 i in
        let v = String.sub kv (i + 1) (String.length kv - i - 1) in
        let key = Header.canonical_header_key k in
        (* canonical_header_key returns the input unchanged on an invalid key. *)
        if key = "" then raise (Protocol_error (Printf.sprintf "malformed MIME header line: %S" kv));
        String.iter
          (fun c ->
            if not (valid_header_value_byte c) then
              raise (Protocol_error (Printf.sprintf "malformed MIME header line: %S" kv)))
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
  | hp :: _ when hp = "no-cache" -> if not (Header.has h "Cache-Control") then Header.set h "Cache-Control" "no-cache"
  | _ -> ()

(* ------------------------------------------------------------------ *)
(* Body / trailer materialization helpers.                             *)
(* ------------------------------------------------------------------ *)

(* mergeSetHeader (transfer.go): merge [hdr] into the trailer cell. The
   declared trailer (parsed from the Trailer header, keys with empty values) is
   the starting point; the actual trailer values read after the chunked body
   overwrite it. *)
let merge_trailer (declared : Header.t option) (hdr : Header.t) : Header.t option =
  match declared with
  | None -> if Hashtbl.length hdr = 0 then None else Some hdr
  | Some t ->
    Hashtbl.iter (fun k v -> Hashtbl.replace t k v) hdr;
    Some t

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
        if is_chunked then
          read_mime_header_raising ic >|= fun hdr ->
          set_trailer (merge_trailer declared_trailer hdr);
          None
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
         | '(' | ')' | '<' | '>' | '@' | ',' | ';' | ':' | '\\' | '"' | '/' | '[' | ']' | '?' | '='
         | '{' | '}' ->
           false
         | _ -> true)
       s

let read_request_raising (ic : Lwt_io.input_channel) : Body.t Request.t Lwt.t =
  Lwt.catch
    (fun () ->
      read_line ic >>= fun s ->
      (match parse_request_line s with
      | None -> Lwt.fail (bad_string_error "malformed HTTP request" s)
      | Some (meth, request_uri, proto) -> Lwt.return (meth, request_uri, proto))
      >>= fun (meth, request_uri, proto) ->
      if not (is_token meth) then Lwt.fail (bad_string_error "invalid method" meth)
      else begin
        match Request.parse_http_version proto with
        | None -> Lwt.fail (bad_string_error "malformed HTTP version" proto)
        | Some (proto_major, proto_minor) ->
          let rawurl = request_uri in
          let just_authority = meth = "CONNECT" && not (String.length rawurl > 0 && rawurl.[0] = '/') in
          let rawurl = if just_authority then "http://" ^ rawurl else rawurl in
          let url = Uri.of_string rawurl in
          let url = if just_authority then Uri.with_scheme url None else url in
          read_mime_header_raising ic >>= fun header ->
          if List.length (Header.values header "Host") > 1 then Lwt.fail (Protocol_error "too many Host headers")
          else begin
            let host =
              match Uri.host url with Some h when h <> "" -> h | _ -> Header.get header "Host"
            in
            fix_pragma_cache_control header;
            let close = Transfer.should_close ~major:proto_major ~minor:proto_minor ~header ~remove_close_header:false in
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
                transfer_encoding = (if res.Transfer.is_chunked then [ "chunked" ] else []);
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
    (function End_of_file -> Lwt.fail Unexpected_eof_exn | e -> Lwt.fail e)

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

let read_response_raising ?(request : Body.t Request.t option) (ic : Lwt_io.input_channel) :
    Body.t Response.t Lwt.t =
  Lwt.catch
    (fun () -> read_line ic >|= fun l -> l)
    (function End_of_file -> Lwt.fail Unexpected_eof_exn | e -> Lwt.fail e)
  >>= fun line ->
  (match String.index_opt line ' ' with
  | None -> Lwt.fail (bad_string_error "malformed HTTP response" line)
  | Some i ->
    let proto = String.sub line 0 i in
    let status = trim_left_spaces (String.sub line (i + 1) (String.length line - i - 1)) in
    Lwt.return (proto, status))
  >>= fun (proto, status) ->
  let status_code_str =
    match String.index_opt status ' ' with None -> status | Some j -> String.sub status 0 j
  in
  if String.length status_code_str <> 3 then Lwt.fail (bad_string_error "malformed HTTP status code" status_code_str)
  else
    match int_of_string_opt status_code_str with
    | None -> Lwt.fail (bad_string_error "malformed HTTP status code" status_code_str)
    | Some sc when sc < 0 -> Lwt.fail (bad_string_error "malformed HTTP status code" status_code_str)
    | Some status_code -> (
      match Request.parse_http_version proto with
      | None -> Lwt.fail (bad_string_error "malformed HTTP version" proto)
      | Some (proto_major, proto_minor) ->
        read_mime_header_raising ic >>= fun header ->
        fix_pragma_cache_control header;
        let request_method = match request with Some r -> r.Request.meth | None -> "GET" in
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
            transfer_encoding = (if res.Transfer.is_chunked then [ "chunked" ] else []);
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
  String.exists (fun c -> let b = Char.code c in b < 0x20 || b = 0x7f) s

let write_request_raising (oc : Lwt_io.output_channel) (r : Body.t Request.t) : unit Lwt.t =
  let host =
    if r.Request.host <> "" then r.Request.host
    else match Uri.host r.Request.url with Some h -> h | None -> ""
  in
  (if host = "" && (match Uri.host r.Request.url with Some _ -> false | None -> r.Request.host = "") then
     Lwt.fail missing_host_exn
   else Lwt.return_unit)
  >>= fun () ->
  let ruri =
    if r.Request.meth = "CONNECT" && Uri.path r.Request.url = "" then host else request_uri_of r.Request.url
  in
  if string_contains_ctl_byte ruri then
    Lwt.fail (Protocol_error "net/http: can't write control character in Request.URL")
  else begin
    let meth = if r.Request.meth = "" then "GET" else r.Request.meth in
    Lwt_io.write oc (Printf.sprintf "%s %s HTTP/1.1\r\n" meth ruri) >>= fun () ->
    Lwt_io.write oc (Printf.sprintf "Host: %s\r\n" host) >>= fun () ->
    (* User-Agent: default unless present (a present blank value suppresses it). *)
    let user_agent = if Header.has r.Request.header "User-Agent" then Header.get r.Request.header "User-Agent" else Request.default_user_agent in
    (if user_agent <> "" then
       (* headerNewlineToSpace + TrimString. *)
       let ua = String.map (fun c -> if c = '\n' || c = '\r' then ' ' else c) user_agent in
       let ua = trim_ws ua in
       Lwt_io.write oc (Printf.sprintf "User-Agent: %s\r\n" ua)
     else Lwt.return_unit)
    >>= fun () ->
    let tw =
      Transfer.make_transfer_writer ~is_response:false ~method_:meth ~at_least_http11:true
        ~close:r.Request.close ~header:r.Request.header ~trailer:r.Request.trailer ~body:r.Request.body
        ~content_length:r.Request.content_length ~transfer_encoding:r.Request.transfer_encoding ()
    in
    Transfer.write_transfer_header oc tw >>= fun () ->
    let buf = Buffer.create 256 in
    Header.write_subset r.Request.header buf
      ~exclude:[ "Host"; "User-Agent"; "Content-Length"; "Transfer-Encoding"; "Trailer" ];
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
    (fun e -> Lwt.return (Error (error_of_exn e)))

let read_mime_header ic : (Header.t, error) result Lwt.t =
  to_result (fun () -> read_mime_header_raising ic)

let read_request ic : (Body.t Request.t, error) result Lwt.t =
  to_result (fun () -> read_request_raising ic)

let read_response ?request ic : (Body.t Response.t, error) result Lwt.t =
  to_result (fun () -> read_response_raising ?request ic)

let write_request oc r : (unit, error) result Lwt.t =
  to_result (fun () -> write_request_raising oc r)

(* ------------------------------------------------------------------ *)
(* write_response (Response.Write).                                    *)
(* ------------------------------------------------------------------ *)

let write_response (oc : Lwt_io.output_channel) (r : Body.t Response.t) : unit Lwt.t =
  (* Status line text. *)
  let itoa = string_of_int r.Response.status_code in
  let text =
    if r.Response.status <> "" then begin
      (* Strip a leading "<code> " prefix to reduce stutter. *)
      let prefix = itoa ^ " " in
      if String.length r.Response.status >= String.length prefix && String.sub r.Response.status 0 (String.length prefix) = prefix
      then String.sub r.Response.status (String.length prefix) (String.length r.Response.status - String.length prefix)
      else r.Response.status
    end
    else
      let st = Status.status_text r.Response.status_code in
      if st <> "" then st else "status code " ^ itoa
  in
  Lwt_io.write oc (Printf.sprintf "HTTP/%d.%d %03d %s\r\n" r.Response.proto_major r.Response.proto_minor r.Response.status_code text)
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
    Int64.compare !content_length (-1L) = 0 && not !close
    && Response.proto_at_least r 1 1
    && not (Transfer.chunked r.Response.transfer_encoding)
    && not r.Response.uncompressed
  then close := true;
  let method_ = match r.Response.request with Some req -> req.Request.meth | None -> "" in
  let response_to_head = Transfer.no_response_body_expected method_ in
  let tw =
    Transfer.make_transfer_writer ~is_response:true ~method_ ~response_to_head
      ~at_least_http11:(Response.proto_at_least r 1 1) ~close:!close ~header:r.Response.header
      ~trailer:r.Response.trailer ~body:!body ~content_length:!content_length
      ~transfer_encoding:r.Response.transfer_encoding ()
  in
  Transfer.write_transfer_header oc tw >>= fun () ->
  let buf = Buffer.create 256 in
  Header.write_subset r.Response.header buf ~exclude:[ "Content-Length"; "Transfer-Encoding"; "Trailer" ];
  Lwt_io.write oc (Buffer.contents buf) >>= fun () ->
  let content_length_already_sent = Transfer.should_send_content_length tw in
  (if
     Int64.compare !content_length 0L = 0
     && not (Transfer.chunked r.Response.transfer_encoding)
     && not content_length_already_sent
     && Transfer.body_allowed_for_status r.Response.status_code
   then Lwt_io.write oc "Content-Length: 0\r\n"
   else Lwt.return_unit)
  >>= fun () ->
  Lwt_io.write oc "\r\n" >>= fun () -> Transfer.write_body oc tw
