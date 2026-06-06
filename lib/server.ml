(* Port of the HTTP/1.x subset of go/src/net/http/server.go:
   Handler / HandlerFunc, ResponseWriter, the per-connection serve loop,
   Server / listen_and_serve, ServeMux dispatch, NotFound / Error /
   Redirect / RedirectHandler. HTTP/2, hijacking, TLS-NPN and graceful
   shutdown niceties are out of scope (Server.close is minimal). *)

open Lwt.Infix

(* ---- Date header (Go's TimeFormat: "Mon, 02 Jan 2006 15:04:05 GMT") ---- *)

let weekday_names = [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |]

let month_names =
  [|
    "Jan";
    "Feb";
    "Mar";
    "Apr";
    "May";
    "Jun";
    "Jul";
    "Aug";
    "Sep";
    "Oct";
    "Nov";
    "Dec";
  |]

let utc_of_unix t =
  let secs = int_of_float (Float.floor t) in
  let days = if secs >= 0 then secs / 86400 else (secs - 86399) / 86400 in
  let rem = secs - (days * 86400) in
  let h = rem / 3600 in
  let mi = rem mod 3600 / 60 in
  let s = rem mod 60 in
  let weekday = ((((days mod 7) + 4) mod 7) + 7) mod 7 in
  let z = days + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = if m <= 2 then y + 1 else y in
  (y, m, d, h, mi, s, weekday)

(* Go's http.TimeFormat applied to the current time. *)
let http_time_now () =
  let y, mo, d, h, mi, s, wd = utc_of_unix (Unix.gettimeofday ()) in
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT" weekday_names.(wd) d
    month_names.(mo - 1)
    y h mi s

(* ---- ResponseWriter / Handler ---- *)

(* Go's ResponseWriter interface. [header] returns the mutable header map the
   handler writes to before the headers are flushed; [write_header] sets the
   status (Go's WriteHeader); [write] writes body bytes (implicitly calling
   write_header 200 on first use). *)
type response_writer = {
  header : unit -> Header.t;
  write_header : int -> unit;
  write : string -> unit Lwt.t;
  flush : unit -> unit Lwt.t;
}

(* Go's Handler interface: ServeHTTP(ResponseWriter, *Request). *)
type handler = {
  serve_http : response_writer -> Body.t Request.t -> unit Lwt.t;
}

(* Go's HandlerFunc adapter. *)
let handler_func f = { serve_http = f }

(* ---- helpers: Error / NotFound / Redirect (Go server.go) ---- *)

(* fmt.Fprintln writes the string followed by a newline. *)
let fprintln w s = w.write (s ^ "\n")

(* Go's Error: reset Content-Type to text/plain, drop Content-Length, set the
   nosniff option, write the status code, then the message + newline. *)
let error w msg code =
  let h = w.header () in
  Header.del h "Content-Length";
  Header.set h "Content-Type" "text/plain; charset=utf-8";
  Header.set h "X-Content-Type-Options" "nosniff";
  w.write_header code;
  fprintln w msg

(* Go's NotFound. *)
let not_found w _r = error w "404 page not found" Status.status_not_found

(* Go's NotFoundHandler. *)
let not_found_handler () = handler_func not_found

(* Go's htmlEscape (htmlReplacer). *)
let html_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | '"' -> Buffer.add_string buf "&#34;"
      | '\'' -> Buffer.add_string buf "&#39;"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(* Go's Redirect (HTTP/1.x subset; non-ASCII hex-escaping of the URL is
   narrowed: we pass the URL through unchanged, which is faithful for ASCII
   targets — the only ones the ported tests use). Relative-target resolution
   against the request path is performed as in Go. *)
let redirect w (r : Body.t Request.t) url code =
  (* Resolve a relative path target against the request path. *)
  let url =
    let u = Uri.of_string url in
    if Uri.scheme u = None && Uri.host u = None then begin
      let oldpath =
        let p = Uri.path r.url in
        if p = "" then "/" else p
      in
      let url =
        if String.length url = 0 || url.[0] <> '/' then begin
          (* make relative path absolute: path.Split on oldpath. *)
          let olddir =
            match String.rindex_opt oldpath '/' with
            | Some i -> String.sub oldpath 0 (i + 1)
            | None -> ""
          in
          olddir ^ url
        end
        else url
      in
      (* split off query *)
      let url, query =
        match String.index_opt url '?' with
        | Some i ->
            (String.sub url 0 i, String.sub url i (String.length url - i))
        | None -> (url, "")
      in
      let trailing =
        String.length url > 0 && url.[String.length url - 1] = '/'
      in
      let cleaned = Pattern.path_clean url in
      let cleaned =
        if
          trailing
          && not
               (String.length cleaned > 0
               && cleaned.[String.length cleaned - 1] = '/')
        then cleaned ^ "/"
        else cleaned
      in
      cleaned ^ query
    end
    else url
  in
  let h = w.header () in
  let had_ct = Header.has h "Content-Type" in
  Header.set h "Location" url;
  if (not had_ct) && (r.meth = "GET" || r.meth = "HEAD") then
    Header.set h "Content-Type" "text/html; charset=utf-8";
  w.write_header code;
  if (not had_ct) && r.meth = "GET" then
    let body =
      "<a href=\"" ^ html_escape url ^ "\">" ^ Status.status_text code
      ^ "</a>.\n"
    in
    fprintln w body
  else Lwt.return_unit

(* Go's RedirectHandler. *)
let redirect_handler url code = handler_func (fun w r -> redirect w r url code)

(* ---- ServeMux ---- *)

(* Go's cleanPath: canonical path, eliminating . and .. and preserving a
   trailing slash. Reuses Pattern.path_clean (path.Clean). *)
let clean_path p =
  if p = "" then "/"
  else begin
    let p = if p.[0] <> '/' then "/" ^ p else p in
    let np = Pattern.path_clean p in
    if p.[String.length p - 1] = '/' && np <> "/" then
      begin if
        String.length p = String.length np + 1
        && String.length np <= String.length p
        && String.sub p 0 (String.length np) = np
      then p
      else np ^ "/"
      end
    else np
  end

(* Go's stripHostPort: drop a trailing ":<port>". *)
let strip_host_port h =
  if not (String.contains h ':') then h
  else
    (* net.SplitHostPort: the host is everything before the last ':' for a
       simple host:port, with []-bracketed IPv6 handled. *)
    match String.rindex_opt h ':' with
    | None -> h
    | Some i ->
        let host = String.sub h 0 i in
        (* strip [] brackets for IPv6 literals *)
        if
          String.length host >= 2
          && host.[0] = '['
          && host.[String.length host - 1] = ']'
        then String.sub host 1 (String.length host - 2)
        else host

type serve_mux = {
  mutable tree : handler Routing_tree.t;
  (* registered patterns, for conflict detection (Go's index, simplified to a
     linear scan over the registered set). *)
  mutable patterns : Pattern.t list;
}

(* Go's NewServeMux. *)
let new_serve_mux () = { tree = Routing_tree.create (); patterns = [] }

type error = Register of string

let error_to_string = function Register s -> s

(* Go's registerErr: parse, conflict-check, add to the tree. Returns
   [Error (Register _)] on an invalid or conflicting pattern. *)
let register mux patstr handler : (unit, error) result =
  if patstr = "" then Error (Register "http: invalid pattern")
  else
    match Pattern.parse patstr with
    | Error e ->
        Error
          (Register
             (Printf.sprintf "parsing %S: %s" patstr
                (Pattern.error_to_string e)))
    | Ok pat -> (
        let conflict =
          List.find_opt
            (fun pat2 -> Pattern.conflicts_with pat pat2)
            mux.patterns
        in
        match conflict with
        | Some pat2 ->
            Error
              (Register
                 (Printf.sprintf "pattern %S conflicts with pattern %S:\n%s"
                    (Pattern.to_string pat) (Pattern.to_string pat2)
                    (Pattern.describe_conflict pat pat2)))
        | None ->
            Routing_tree.add_pattern mux.tree pat handler;
            mux.patterns <- pat :: mux.patterns;
            Ok ())

(* Go's ServeMux.Handle. *)
let handle mux pattern handler = register mux pattern handler

(* Go's ServeMux.HandleFunc. *)
let handle_func mux pattern f = register mux pattern (handler_func f)

(* Go's exactMatch. *)
let exact_match (pat : Pattern.t) path =
  let last = Pattern.last_segment pat in
  if not last.multi then true
  else if String.length path > 0 && path.[String.length path - 1] <> '/' then
    false
  else begin
    (* count slashes in path *)
    let count = ref 0 in
    String.iter (fun c -> if c = '/' then incr count) path;
    List.length pat.segments = !count
  end

(* Go's matchingMethods: sorted list of methods matching host/path (also tries
   the trailing-slash variant). *)
let matching_methods mux host path =
  let ms = Hashtbl.create 8 in
  Routing_tree.matching_methods mux.tree ~host ~path ms;
  if not (String.length path > 0 && path.[String.length path - 1] = '/') then
    Routing_tree.matching_methods mux.tree ~host ~path:(path ^ "/") ms;
  let keys = Hashtbl.fold (fun k _ acc -> k :: acc) ms [] in
  List.sort String.compare keys

(* Go's matchOrRedirect: match in the tree, with trailing-slash redirection
   when [try_redirect] and there's no exact match. Returns the matched
   (pattern, handler, captures) and an optional redirect path. *)
let match_or_redirect mux ~host ~method_ ~path ~try_redirect ~raw_query =
  let m = Routing_tree.match_ mux.tree ~host ~method_ ~path in
  let is_exact =
    match m with Some ((pat, _), _) -> exact_match pat path | None -> false
  in
  if
    (not is_exact) && try_redirect
    && (not (String.length path > 0 && path.[String.length path - 1] = '/'))
    && path <> ""
  then begin
    let path2 = path ^ "/" in
    let m2 = Routing_tree.match_ mux.tree ~host ~method_ ~path:path2 in
    match m2 with
    | Some ((pat2, _), _) when exact_match pat2 path2 ->
        let target = clean_path path ^ "/" in
        let target =
          if raw_query <> "" then target ^ "?" ^ raw_query else target
        in
        (m2, Some target)
    | _ -> (m, None)
  end
  else (m, None)

let find_handler_finish mux ~host ~path m =
  match m with
  | Some ((_pat, h), _captures) -> h
  | None ->
      let allowed = matching_methods mux host path in
      if List.length allowed > 0 then
        handler_func (fun w _r ->
            let hd = w.header () in
            Header.set hd "Allow" (String.concat ", " allowed);
            error w
              (Status.status_text Status.status_method_not_allowed)
              Status.status_method_not_allowed)
      else not_found_handler ()

(* The result of dispatch: a handler to run plus the captured wildcard values
   (unused at present, but mirrors Go's findHandler return). *)
let find_handler mux (r : Body.t Request.t) =
  let escaped_path = Uri.path r.url in
  let raw_query =
    match Uri.verbatim_query r.url with Some q -> q | None -> ""
  in
  if r.meth = "CONNECT" then begin
    let host = match Uri.host r.url with Some h -> h | None -> "" in
    let _, redir =
      match_or_redirect mux ~host ~method_:r.meth ~path:escaped_path
        ~try_redirect:true ~raw_query
    in
    match redir with
    | Some u -> redirect_handler u Status.status_temporary_redirect
    | None ->
        let m, _ =
          match_or_redirect mux ~host:r.host ~method_:r.meth ~path:escaped_path
            ~try_redirect:false ~raw_query
        in
        find_handler_finish mux ~host:r.host ~path:escaped_path m
  end
  else begin
    let host = strip_host_port r.host in
    let path = clean_path escaped_path in
    let m, redir =
      match_or_redirect mux ~host ~method_:r.meth ~path ~try_redirect:true
        ~raw_query
    in
    match redir with
    | Some u -> redirect_handler u Status.status_temporary_redirect
    | None ->
        if path <> escaped_path then begin
          (* Redirect to cleaned path. *)
          let u = if raw_query <> "" then path ^ "?" ^ raw_query else path in
          redirect_handler u Status.status_temporary_redirect
        end
        else find_handler_finish mux ~host ~path m
  end

(* Go's ServeMux.ServeHTTP. *)
let serve_mux_serve_http mux w (r : Body.t Request.t) =
  if r.request_uri = "*" then begin
    if Request.proto_at_least r 1 1 then
      Header.set (w.header ()) "Connection" "close";
    w.write_header Status.status_bad_request;
    Lwt.return_unit
  end
  else
    let h = find_handler mux r in
    h.serve_http w r

(* A ServeMux as a Handler. *)
let serve_mux_handler mux = handler_func (serve_mux_serve_http mux)

(* ---- ResponseWriter implementation over an Lwt_io output channel ---- *)

(* The set of headers managed by the writer; excluded from the handler header
   block when written (Go's excludedHeaders concept). *)
let excluded_headers = [ "Content-Length"; "Transfer-Encoding"; "Connection" ]

(* bodyAllowedForStatus mirrors Go: 1xx, 204, 304 carry no body. *)
let body_allowed_for_status status =
  if status >= 100 && status <= 199 then false
  else if status = Status.status_no_content then false
  else if status = Status.status_not_modified then false
  else true

(* Go's bufferBeforeChunkingSize (server.go:342): the response is buffered into
   a bufio.Writer of this size before the framing decision (Content-Length vs
   chunked) is forced. *)
let buffer_before_chunking_size = 2048

(* Run [serve] for one request on [oc], returning whether the connection should
   be kept alive afterward. Faithfully mirrors Go's [response]/[chunkWriter]
   buffer-then-chunk model (server.go:1096,1284,1353):

   - Handler [write]s accumulate in a [buffer_before_chunking_size]-byte buffer.
   - The framing decision (Go's chunkWriter.writeHeader) fires at first flush:
     the buffer overflows 2048 bytes, the handler returns, or [flush] is called.
   - If the handler finished ([handler_done]) with <=2048 buffered, set no
     explicit Content-Length, the status allows a body, and it is not a
     zero-byte HEAD -> emit an exact Content-Length and the buffered bytes, NO
     chunking (Go's common case, server.go:1353).
   - Otherwise (overflow / Flush / still running) -> HTTP/1.1: emit
     Transfer-Encoding: chunked and stream subsequent writes chunk-encoded;
     HTTP/1.0 unknown length: Connection: close, raw bytes, close at EOF.
   - Content-Type is sniffed from the first <=512 buffered bytes when unset and
     a body is allowed. Implicit WriteHeader(200). HEAD writes no body. *)
let serve_one oc (r : Body.t Request.t) (h : handler) : bool Lwt.t =
  let header = Header.create () in
  let status = ref Status.status_ok in
  let wrote_header = ref false in
  (* Whether the response framing headers have been emitted on the wire. *)
  let headers_emitted = ref false in
  (* Whether we committed to chunked transfer encoding. *)
  let chunking = ref false in
  (* Whether the handler has returned (forces the Content-Length common case). *)
  let handler_done = ref false in
  (* Pending body bytes not yet committed to a framing decision. *)
  let body_buf = Buffer.create 256 in
  let is_head = r.meth = "HEAD" in
  let req_should_close = r.close in
  (* mutable "close after reply" flag (Go's w.closeAfterReply). *)
  let close_after_reply = ref req_should_close in
  let proto = if Request.proto_at_least r 1 1 then "HTTP/1.1" else "HTTP/1.0" in
  (* Emit the status line + headers, deciding the framing. [final_cl] is
     [Some n] when we know the exact Content-Length (handler done, fits, no
     explicit CL); otherwise framing is chunked (HTTP/1.1) or close (HTTP/1.0).
     Returns once the header block is written to [oc]. *)
  let emit_headers () =
    headers_emitted := true;
    let code = !status in
    let body_allowed = body_allowed_for_status code in
    let buffered = Buffer.contents body_buf in
    (* Content-Type sniff from the first <=512 buffered bytes (Go uses
       bufferBeforeChunkingSize's head; sniff itself caps at 512). *)
    (if body_allowed && not (Header.has header "Content-Type") then
       if
         not
           (Gohttp_internal.Ascii.equal_fold
              (Header.get header "X-Content-Type-Options")
              "nosniff")
       then
         if String.length buffered > 0 then
           let sniff_src =
             if String.length buffered > 512 then String.sub buffered 0 512
             else buffered
           in
           Header.set header "Content-Type"
             (Sniff.detect_content_type sniff_src));
    (* Date header (Go always sets it if absent). *)
    if not (Header.has header "Date") then
      Header.set header "Date" (http_time_now ());
    let handler_conn_close =
      Transfer.has_token
        (String.lowercase_ascii (Header.get header "Connection"))
        "close"
    in
    if handler_conn_close then close_after_reply := true;
    let has_explicit_cl = Header.has header "Content-Length" in
    let has_te = Header.has header "Transfer-Encoding" in
    (* Decide the exact-Content-Length common case: handler is done, everything
       fit in <=2048 (i.e. we have not started chunking), no explicit CL, body
       allowed, not a zero-byte HEAD, no explicit TE (server.go:1353). *)
    let auto_cl =
      !handler_done && (not has_te) && body_allowed && (not has_explicit_cl)
      && ((not is_head) || String.length buffered > 0)
    in
    let content_length =
      if auto_cl then Some (String.length buffered)
      else if has_explicit_cl then
        int_of_string_opt (String.trim (Header.get header "Content-Length"))
      else None
    in
    (* Framing: HEAD / no-body status -> no body framing. Else CL present ->
       Content-Length, no chunking. Else HTTP/1.1 -> chunked; HTTP/1.0 unknown
       length -> close-delimited (server.go:1503). *)
    if (not body_allowed) || (is_head && (not auto_cl) && not has_explicit_cl)
    then chunking := false
    else if content_length <> None then chunking := false
    else if Request.proto_at_least r 1 1 then chunking := true
    else begin
      (* HTTP/1.0 unknown length: signal EOF by closing the connection. *)
      chunking := false;
      close_after_reply := true
    end;
    (* HTTP/1.0 keep-alive (Go's wants10KeepAlive, server.go:1369): an HTTP/1.0
       request asking for keep-alive that we answer with a known length (a
       Content-Length, a HEAD, or a no-body status) may keep the connection
       alive and must advertise it explicitly. Otherwise HTTP/1.0 closes. *)
    let wants10_keep_alive =
      (not (Request.proto_at_least r 1 1))
      && Request.proto_at_least r 1 0
      && Transfer.has_token
           (String.lowercase_ascii (Header.get r.Request.header "Connection"))
           "keep-alive"
    in
    let sent_known_length =
      is_head || content_length <> None || not body_allowed
    in
    let advertise10_keep_alive = ref false in
    if not (Request.proto_at_least r 1 1) then
      begin if wants10_keep_alive && sent_known_length && not req_should_close
      then advertise10_keep_alive := true
      else close_after_reply := true
      end;
    let keep_alive = not !close_after_reply in
    let status_text = Status.status_text code in
    let status_line =
      if status_text = "" then
        Printf.sprintf "%s %03d status code %d\r\n" proto code code
      else Printf.sprintf "%s %03d %s\r\n" proto code status_text
    in
    let out = Buffer.create 256 in
    Buffer.add_string out status_line;
    (match content_length with
    | Some n ->
        Buffer.add_string out (Printf.sprintf "Content-Length: %d\r\n" n)
    | None ->
        if !chunking then Buffer.add_string out "Transfer-Encoding: chunked\r\n");
    if not keep_alive then Buffer.add_string out "Connection: close\r\n"
    else if !advertise10_keep_alive then
      Buffer.add_string out "Connection: keep-alive\r\n";
    Header.write_subset header out ~exclude:excluded_headers;
    Buffer.add_string out "\r\n";
    Lwt_io.write oc (Buffer.contents out) >>= fun () -> Lwt.return keep_alive
  in
  (* Push the currently-buffered bytes to the wire under the decided framing.
     Only called after [emit_headers]; clears the buffer. *)
  let flush_buffered () =
    let data = Buffer.contents body_buf in
    Buffer.clear body_buf;
    if is_head || String.length data = 0 then Lwt.return_unit
    else if !chunking then Transfer.chunked_writer_write oc data
    else Lwt_io.write oc data
  in
  (* The implicit-WriteHeader-200 helper for the first write. *)
  let ensure_status () =
    if not !wrote_header then begin
      wrote_header := true;
      status := Status.status_ok
    end
  in
  let rw =
    {
      header = (fun () -> header);
      write_header =
        (fun code ->
          if not !wrote_header then begin
            wrote_header := true;
            status := code
          end);
      write =
        (fun data ->
          ensure_status ();
          if not (body_allowed_for_status !status) then Lwt.return_unit
          else begin
            Buffer.add_string body_buf data;
            (* Overflow past 2048 with headers not yet emitted: force the
               framing decision now (handler is NOT done -> chunked/close, not
               Content-Length), emit headers, stream the buffer. *)
            if
              (not !headers_emitted)
              && Buffer.length body_buf > buffer_before_chunking_size
            then emit_headers () >>= fun _ -> flush_buffered ()
            else if !headers_emitted then flush_buffered ()
            else Lwt.return_unit
          end);
      flush =
        (fun () ->
          ensure_status ();
          (* Force the framing decision now; handler not necessarily done, so
             length is unknown -> chunked (HTTP/1.1) / close (HTTP/1.0). *)
          (if not !headers_emitted then
             emit_headers () >>= fun _ -> Lwt.return_unit
           else Lwt.return_unit)
          >>= fun () ->
          flush_buffered () >>= fun () -> Lwt_io.flush oc);
    }
  in
  h.serve_http rw r >>= fun () ->
  handler_done := true;
  (* finishRequest: ensure the status is set. *)
  ensure_status ();
  (* If headers were never emitted (everything fit in <=2048 and no flush),
     emit them now: this is the exact-Content-Length common case. Then write
     the buffered body. If chunking already started, finish the chunk stream. *)
  if not !headers_emitted then
    emit_headers () >>= fun keep_alive ->
    flush_buffered () >>= fun () ->
    Lwt_io.flush oc >>= fun () -> Lwt.return keep_alive
  else begin
    (* Streaming already started. Flush any residual buffered bytes, then
        terminate the framing: close the chunk stream when chunking. *)
    flush_buffered () >>= fun () ->
    (* Terminate the chunk stream: the 0-chunk size line ([chunked_writer_close]
        writes ["0\r\n"]) followed by the trailing CRLF that ends the (empty)
        trailer block — mirroring Go's [chunkWriter.close] and {!Transfer}'s
        [write_body]/[after_body]. Without the final CRLF a kept-alive peer that
        reads the chunked trailer (e.g. {!Io.stream_body}) blocks waiting for
        the blank line. *)
    (if !chunking then
       Transfer.chunked_writer_close oc >>= fun () -> Lwt_io.write oc "\r\n"
     else Lwt.return_unit)
    >>= fun () ->
    Lwt_io.flush oc >>= fun () -> Lwt.return (not !close_after_reply)
  end

(* Note: Io.read_request returns a streaming request body; the serve loop runs
   a bounded Body.drain on it before reusing a kept-alive connection (Go's
   finishRequest drain) so the connection is positioned at the next message
   boundary. *)

(* maxPostHandlerReadBytes (Go's server.go): the max number of unread
   Request.Body bytes the server will discard in order to keep a connection
   alive. Past this, to be paranoid, the server closes the connection instead of
   reading an unbounded amount. *)
let max_post_handler_read_bytes = 256 * 1024

(* Go's finishRequest: consume the unread request body before reusing a
   kept-alive connection, but only up to [max_post_handler_read_bytes]. If more
   than that remains, drop keep-alive and close so a client cannot make the
   server read an unbounded amount. Returns whether the connection may still be
   reused. *)
let drain_request_body (r : Body.t Request.t) : bool Lwt.t =
  Lwt.catch
    (fun () ->
      Body.drain ~limit:max_post_handler_read_bytes r.Request.body >>= function
      | `Drained -> Lwt.return true
      | `Too_big -> Lwt.return false)
    (fun _ -> Lwt.return false)

(* ---- Server ---- *)

type t = {
  mutable addr : string;
  mutable port : int;
  handler : handler;
  (* Go's Server duration knobs (server.go:3717-3724); seconds, 0. = no timeout
     (Go's zero-value = off). [read_header_timeout]/[idle_timeout] fall back to
     [read_timeout] when zero, mirroring Server.readHeaderTimeout()/idleTimeout()
     (server.go:3717-3729). *)
  read_timeout : float;
  read_header_timeout : float;
  write_timeout : float;
  idle_timeout : float;
  (* Go's Server.MaxHeaderBytes (server.go:920-929); the request line + header
     block is bounded against [max_header_bytes + 4096] ("bufio slop"). Default
     [DefaultMaxHeaderBytes = 1 lsl 20] (1 MB). *)
  max_header_bytes : int;
  (* a promise that, when resolved, makes the accept loop stop. *)
  stop : unit Lwt.t;
  wake_stop : unit Lwt.u;
  mutable listen_fd : Lwt_unix.file_descr option;
}

(* Go's DefaultMaxHeaderBytes (server.go:922). *)
let default_max_header_bytes = 1 lsl 20

let create ?(addr = "") ?(port = 0) ?(read_timeout = 0.)
    ?(read_header_timeout = 0.) ?(write_timeout = 0.) ?(idle_timeout = 0.)
    ?(max_header_bytes = default_max_header_bytes) handler =
  let stop, wake_stop = Lwt.wait () in
  {
    addr;
    port;
    handler;
    read_timeout;
    read_header_timeout;
    write_timeout;
    idle_timeout;
    max_header_bytes;
    stop;
    wake_stop;
    listen_fd = None;
  }

(* Minimal Server.Close: resolve the stop promise and close the listener. *)
let close srv =
  if Lwt.is_sleeping srv.stop then Lwt.wakeup_later srv.wake_stop ();
  match srv.listen_fd with
  | Some fd ->
      srv.listen_fd <- None;
      Lwt.catch (fun () -> Lwt_unix.close fd) (fun _ -> Lwt.return_unit)
  | None -> Lwt.return_unit

(* Go's conn.serve error branch (server.go): map a request-read error to a
   minimal HTTP response written directly onto the wire (no handler), then close.
   - An unsupported transfer-encoding -> 501 (RFC 7230 3.3.1).
   - A clean / unexpected EOF before a full message is a common net read error
     -> no reply, just close.
   - Any other malformed request (protocol error, missing Host) -> 400 Bad
     Request. *)
let error_headers =
  "\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n"

let write_read_error_response oc (e : Io.error) : unit Lwt.t =
  let write s =
    Lwt.catch
      (fun () -> Lwt_io.write oc s >>= fun () -> Lwt_io.flush oc)
      (fun _ -> Lwt.return_unit)
  in
  match e with
  | Io.Transfer (Transfer.Unsupported_transfer_encoding _) ->
      let code = Status.status_not_implemented in
      write
        (Printf.sprintf "HTTP/1.1 %d %s%sUnsupported transfer encoding" code
           (Status.status_text code) error_headers)
  | Io.Unexpected_eof ->
      (* Common net read error: don't reply. *)
      Lwt.return_unit
  | Io.Request_too_large ->
      (* errTooLarge -> 431 Request Header Fields Too Large + close
         (server.go:2053-2062, errTooLarge at :998). The client may or may not
         read this if it is still writing its request — undefined, as in Go. *)
      let public_err = "431 Request Header Fields Too Large" in
      write
        (Printf.sprintf "HTTP/1.1 %s%s%s" public_err error_headers public_err)
  | Io.Protocol _ | Io.Missing_host | Io.Transfer _ | Io.Trailer_too_large
  | Io.Malformed_host ->
      (* Invalid header name/value, missing required Host, and a malformed Host
         value (server.go:1045-1062) all map to 400 Bad Request, as Go does via
         [badRequestError]. *)
      (* [Trailer_too_large] is normally a mid-stream raise (read inside the body
         [Stream] thunk after the header boundary returned [Ok]), so it rarely
         reaches here; if it does, treat it as a bad request like Go does for a
         malformed trailer (transfer.go:934, returned as a plain Read error). *)
      let public_err = "400 Bad Request" in
      write
        (Printf.sprintf "HTTP/1.1 %s%s%s" public_err error_headers public_err)

(* Go's response.sendExpectationFailed (server.go:2236-2252): a request carrying
   an "Expect" header with any value other than [100-continue] gets 417
   Expectation Failed with [Connection: close], and the handler is NOT run
   (server.go:2097-2100). Written directly onto the wire, then the connection is
   closed (RFC 7231 5.1.1). *)
let write_expectation_failed oc : unit Lwt.t =
  let code = Status.status_expectation_failed in
  let body = Printf.sprintf "%d %s" code (Status.status_text code) in
  Lwt.catch
    (fun () ->
      Lwt_io.write oc
        (Printf.sprintf "HTTP/1.1 %d %s%s%s" code (Status.status_text code)
           error_headers body)
      >>= fun () -> Lwt_io.flush oc)
    (fun _ -> Lwt.return_unit)

(* The four server duration knobs, resolved for one connection (Go's
   readHeaderTimeout()/idleTimeout() fallback to ReadTimeout already applied).
   Seconds; 0. means "no timeout" (Go's zero-value semantics). *)
type timeouts = {
  to_read : float;
  to_read_header : float;
  to_write : float;
  to_idle : float;
}

let timeouts_of_server (srv : t) : timeouts =
  let fallback x = if x <> 0. then x else srv.read_timeout in
  {
    to_read = srv.read_timeout;
    to_read_header = fallback srv.read_header_timeout;
    to_write = srv.write_timeout;
    to_idle = fallback srv.idle_timeout;
  }

(* Go implements these timeouts with socket SetReadDeadline/SetWriteDeadline
   (server.go:1007-1022, :2145-2149), separate from the request context. Lwt_io
   channels expose no settable socket deadline, so we use a child Context as the
   timeout vehicle — the same adaptation the client made (client.ml:203-209).
   The deadline child is derived off [conn_ctx] and is NOT made the parent of
   [req_ctx] (Go's request context is not cancelled by ReadTimeout).

   [race_deadline conn_ctx ~secs op]: when [secs] <= 0. run [op] unbounded; else
   derive [Context.with_timeout conn_ctx secs] and race the operation against
   the deadline, calling [cancel] on the happy path to disarm the timer (as
   client.ml:209 does). Returns [`Done v] when [op] finished first, [`Timeout]
   when the deadline fired (server hangs up — no reply, as Go does). *)
let race_deadline conn_ctx ~secs (op : unit -> 'a Lwt.t) :
    [ `Done of 'a | `Timeout ] Lwt.t =
  if secs <= 0. then op () >>= fun v -> Lwt.return (`Done v)
  else begin
    let ctx, cancel = Context.with_timeout conn_ctx secs in
    Lwt.try_bind
      (fun () ->
        Lwt.pick
          [
            (op () >>= fun v -> Lwt.return (`Done v));
            (Context.done_ ctx >>= fun () -> Lwt.return `Timeout);
          ])
      (fun outcome ->
        cancel Context.Canceled;
        Lwt.return outcome)
      (fun exn ->
        cancel Context.Canceled;
        Lwt.fail exn)
  end

(* Wrap the request body so each stream pull is bounded by the whole-request
   read deadline (Go's ReadTimeout / wholeReqDeadline, server.go:1015,:1074-1076),
   a child Context derived off [conn_ctx]. On EOF (or read failure) the timer is
   disarmed via [cancel] (idempotent), mirroring [Client.wrap_timer_body]
   (client.ml:164-180). A zero [secs] leaves the body untouched. *)
let wrap_read_timeout_body conn_ctx ~secs (r : Body.t Request.t) : unit =
  if secs > 0. then
    match r.Request.body with
    | Body.Empty | Body.String _ -> ()
    | Body.Stream inner ->
        let ctx, cancel = Context.with_timeout conn_ctx secs in
        let next () =
          Lwt.try_bind
            (fun () ->
              Lwt.pick
                [
                  (inner () >>= fun chunk -> Lwt.return (`Chunk chunk));
                  (Context.done_ ctx >>= fun () -> Lwt.return `Timeout);
                ])
            (function
              | `Chunk (Some _ as chunk) -> Lwt.return chunk
              | `Chunk None ->
                  cancel Context.Canceled;
                  Lwt.return_none
              | `Timeout ->
                  (* Whole-request deadline exceeded mid-body: surface as EOF so
                     the read terminates (Go's read past the deadline errors). *)
                  Lwt.return_none)
            (fun exn ->
              cancel Context.Canceled;
              Lwt.fail exn)
        in
        r.Request.body <- Body.Stream next

(* Go's expectContinueReader (server.go:964-983): wrap the request body so the
   FIRST read replies "HTTP/1.1 100 Continue\r\n\r\n" on the connection (once),
   then proceeds to read the body. This makes the interim 100 lazy — it is sent
   only when the handler actually reads the body, not before dispatch — so a
   spec-compliant client that withholds the body until it sees 100 unblocks.
   Same one-shot-side-effect-on-pull shape as [Client.wrap_timer_body]
   (client.ml:164-180) / [wrap_read_timeout_body] above. Only [Body.Stream]
   bodies are wrapped (Empty/String have no upcoming read to gate on; Go only
   wraps when ContentLength<>0, which never yields those here). *)
let wrap_expect_continue_body oc (r : Body.t Request.t) : unit =
  match r.Request.body with
  | Body.Empty | Body.String _ -> ()
  | Body.Stream inner ->
      let wrote = ref false in
      let next () =
        (if !wrote then Lwt.return_unit
         else begin
           wrote := true;
           Lwt.catch
             (fun () ->
               Lwt_io.write oc "HTTP/1.1 100 Continue\r\n\r\n" >>= fun () ->
               Lwt_io.flush oc)
             (fun _ -> Lwt.return_unit)
         end)
        >>= fun () -> inner ()
      in
      r.Request.body <- Body.Stream next

let no_timeouts =
  { to_read = 0.; to_read_header = 0.; to_write = 0.; to_idle = 0. }

(* The per-connection keep-alive serve loop over already-wrapped channels (used
   by both the plaintext and the HTTP/1.x-over-TLS paths). Reads a request,
   dispatches, writes the response, loops while keep-alive holds. The four Go
   duration knobs (server.go:1007-1022, :2145-2149) are applied as Context
   deadlines derived off [conn_ctx]:
   - [to_read_header] around the header read (Io.read_request);
   - [to_idle] around the between-requests wait for the next request's first
     bytes (Go's Peek(4), server.go:2145-2152);
   - [to_read] (whole-request) around the request body stream pulls
     (server.go:1015,:1074-1076), via [wrap_read_timeout_body];
   - [to_write] around the response write (serve_one).
   On a header or idle timeout the connection is closed with no reply (Go's
   read past the deadline errors out and conn.serve returns). *)
let serve_loop ~timeouts ~max_header_bytes ~ic ~oc ~remote (handler : handler) :
    unit Lwt.t =
  (* Go's Server: a base context cancelled when the connection is closed
     (connContext / cancelCtx in conn.serve), off which each request derives
     its own per-request context. Cancelled in the finalizer below so a handler
     observing Context.done_ sees the connection close (Go's conn.serve). *)
  let conn_ctx, cancel_conn = Context.with_cancel Context.background in
  (* [first] distinguishes the very first request (header timeout only) from a
     kept-alive next request (idle timeout until the first bytes arrive, then
     the header timeout takes over). *)
  let rec loop ~first () =
    (* Idle deadline: wait for the next request's first byte before arming the
       header deadline (Go peeks 4 bytes under the idle deadline, server.go:
       2145-2156). We approximate the peek by racing the whole read against the
       idle deadline; once it returns we are already past the header read too,
       which is acceptable since both deadlines are read-side. On the first
       request there is no idle wait — Go arms the header deadline directly. *)
    let read_secs =
      if first then timeouts.to_read_header
      else if timeouts.to_idle > 0. then timeouts.to_idle
      else timeouts.to_read_header
    in
    race_deadline conn_ctx ~secs:read_secs (fun () ->
        Lwt.catch
          (fun () ->
            Io.read_request ~max_header_bytes ic >>= fun r ->
            Lwt.return (`Read r))
          (fun _ -> Lwt.return (`Read (Error Io.Unexpected_eof))))
    >>= function
    | `Timeout ->
        (* Header / idle deadline exceeded: hang up, no reply (Go's behavior). *)
        Lwt.return_unit
    | `Done (`Read (Error e)) ->
        (* Malformed request: reply (400 / 501) per Go's conn.serve, then close. *)
        write_read_error_response oc e
    | `Done (`Read (Ok r)) ->
        r.Request.remote_addr <- remote;
        (* Per-request context cancelled when the handler returns (Go cancels
           the request context as ServeHTTP unwinds) and, via its parent
           [conn_ctx], when the connection closes. *)
        let req_ctx, cancel_req = Context.with_cancel conn_ctx in
        r.Request.ctx <- req_ctx;
        (* Expect: 100-continue support (server.go:2089-2101). If the client
           expects a 100, lazily reply on the first body read (wrap the body
           BEFORE the read-timeout wrapper so the 100 is written on the first
           real pull); else if it sent some other Expect value, reply 417 and
           close without running the handler. *)
        let unknown_expect =
          if Request.expects_continue r then begin
            if Request.proto_at_least r 1 1 && r.Request.content_length <> 0L
            then wrap_expect_continue_body oc r;
            false
          end
          else Header.get r.Request.header "Expect" <> ""
        in
        if unknown_expect then begin
          cancel_req Context.Canceled;
          write_expectation_failed oc
        end
        else begin
          (* Whole-request read deadline around the streaming body pulls. *)
          wrap_read_timeout_body conn_ctx ~secs:timeouts.to_read r;
          (* Write deadline around the response write (Go's deferred
             SetWriteDeadline, server.go:1017-1021). *)
          race_deadline conn_ctx ~secs:timeouts.to_write (fun () ->
              Lwt.catch
                (fun () -> serve_one oc r handler)
                (fun _ -> Lwt.return false))
          >>= fun write_outcome ->
          cancel_req Context.Canceled;
          let keep_alive =
            match write_outcome with `Done k -> k | `Timeout -> false
          in
          (* Go's finishRequest: consume/close the request body before reusing
             the connection, so a kept-alive connection is positioned at the
             next message boundary (and any chunked trailer is read). The drain
             is bounded; if too much remained unread, close instead of reusing. *)
          if keep_alive then
            drain_request_body r >>= fun reusable ->
            if reusable then loop ~first:false () else Lwt.return_unit
          else Lwt.return_unit
        end
  in
  Lwt.finalize
    (fun () -> loop ~first:true ())
    (fun () ->
      cancel_conn Context.Canceled;
      Lwt.catch (fun () -> Lwt_io.close oc) (fun _ -> Lwt.return_unit)
      >>= fun () ->
      Lwt.catch (fun () -> Lwt_io.close ic) (fun _ -> Lwt.return_unit))

let serve_conn ?(timeouts = no_timeouts)
    ?(max_header_bytes = default_max_header_bytes) (handler : handler)
    (cfd, peer) =
  let ic, oc = Net.channels_of_fd cfd in
  let remote = Net.sockaddr_to_string peer in
  serve_loop ~timeouts ~max_header_bytes ~ic ~oc ~remote handler

(* Go's Server.Serve over a listening fd: accept connections, handle each in
   its own fiber, until [stop] resolves. *)
let serve srv listen_fd =
  srv.listen_fd <- Some listen_fd;
  let rec accept_loop () =
    let accept_p = Lwt.map (fun c -> `Conn c) (Net.accept listen_fd) in
    let stop_p = Lwt.map (fun () -> `Stop) srv.stop in
    Lwt.choose [ accept_p; stop_p ] >>= function
    | `Stop -> Lwt.return_unit
    | `Conn conn ->
        let timeouts = timeouts_of_server srv in
        Lwt.async (fun () ->
            Lwt.catch
              (fun () ->
                serve_conn ~timeouts ~max_header_bytes:srv.max_header_bytes
                  srv.handler conn)
              (fun _ -> Lwt.return_unit));
        accept_loop ()
  in
  Lwt.catch accept_loop (fun _ -> Lwt.return_unit)

(* Go's Server.ListenAndServe / ListenAndServe: bind addr:port and serve. *)
let listen_and_serve ~addr ~port handler =
  let srv = create ~addr ~port handler in
  Net.listen (if addr = "" then "0.0.0.0" else addr) port >>= fun listen_fd ->
  serve srv listen_fd

(* ---- HTTP/2 over TLS (ALPN dispatch) ---- *)

(* The default ALPN protocols advertised by the TLS server, in descending order
   of preference (Go's [http2.NextProtoTLS] + ["http/1.1"]). *)
let default_alpn_protocols = [ "h2"; "http/1.1" ]

(* net/http <-> http2 translation shim (Go's http2.go: http2Handler.ServeHTTP).
   The HTTP/2 server hands the handler a decoupled {!Gohttp_http2.Api} request +
   response_writer; we expand them to a [Request.t] and a {!response_writer}. *)

let body_of_api_body (b : Gohttp_http2.Api.Body.t) : Body.t =
  match b with
  | Gohttp_http2.Api.Body.Empty -> Body.Empty
  | Gohttp_http2.Api.Body.String s -> Body.String s
  | Gohttp_http2.Api.Body.Stream f -> Body.Stream f

let request_of_server_request (r : Gohttp_http2.Api.server_request) :
    Body.t Request.t =
  {
    meth = r.sreq_meth;
    url = r.sreq_url;
    proto = r.sreq_proto;
    proto_major = r.sreq_proto_major;
    proto_minor = r.sreq_proto_minor;
    header = r.sreq_header;
    body = body_of_api_body r.sreq_body;
    content_length = r.sreq_content_length;
    transfer_encoding = [];
    close = false;
    host = r.sreq_host;
    trailer =
      (if Hashtbl.length r.sreq_trailer = 0 then None else Some r.sreq_trailer);
    request_uri = r.sreq_request_uri;
    remote_addr = r.sreq_remote_addr;
    form = None;
    post_form = None;
    multipart_form = None;
    ctx = r.sreq_ctx;
  }

(* Adapt a [Server.handler] into a {!Gohttp_http2.Api.handler}: expose the H2
   response_writer to the user handler as a {!response_writer} (the H2 writer
   minus [flush]), run the handler, then flush the buffered headers/body. *)
let h2_handler_of_handler (handler : handler) : Gohttp_http2.H2_server.handler =
 fun (h2w : Gohttp_http2.Api.response_writer)
     (r : Gohttp_http2.Api.server_request) ->
  let w =
    {
      header = h2w.Gohttp_http2.Api.rw_header;
      write_header = h2w.rw_write_header;
      write = h2w.rw_write;
      flush = h2w.rw_flush;
    }
  in
  handler.serve_http w (request_of_server_request r) >>= fun () ->
  h2w.rw_flush ()

(* Serve one accepted TLS connection, branching on the ALPN-negotiated protocol:
   "h2" runs the HTTP/2 server connection; anything else (incl. no ALPN) runs the
   existing HTTP/1.x serve loop over the TLS channels. *)
let serve_tls_conn ?(timeouts = no_timeouts)
    ?(max_header_bytes = default_max_header_bytes) (handler : handler)
    (ic, oc, alpn, peer) =
  match alpn with
  | Some "h2" ->
      Lwt.finalize
        (fun () ->
          Gohttp_http2.H2_server.serve ic oc
            ~handler:(h2_handler_of_handler handler))
        (fun () ->
          Lwt.catch (fun () -> Lwt_io.close oc) (fun _ -> Lwt.return_unit)
          >>= fun () ->
          Lwt.catch (fun () -> Lwt_io.close ic) (fun _ -> Lwt.return_unit))
  | _ ->
      (* HTTP/1.x over TLS: reuse the shared keep-alive serve loop. It wraps the
         channels with per-conn/per-request contexts, applies the timeout
         deadlines, and closes the channels in its finalizer. *)
      let remote = Net.sockaddr_to_string peer in
      serve_loop ~timeouts ~max_header_bytes ~ic ~oc ~remote handler

(* Go's Server.ServeTLS over a [Net.tls_server]: accept + handshake each
   connection, dispatch by ALPN, until [srv.stop] resolves. *)
let serve_tls srv (tls_srv : Net.tls_server) =
  srv.listen_fd <- Some (Net.tls_listen_fd tls_srv);
  let rec accept_loop () =
    let accept_p = Lwt.map (fun c -> `Conn c) (Net.accept_tls tls_srv) in
    let stop_p = Lwt.map (fun () -> `Stop) srv.stop in
    Lwt.choose [ accept_p; stop_p ] >>= function
    | `Stop -> Lwt.return_unit
    | `Conn conn ->
        let timeouts = timeouts_of_server srv in
        Lwt.async (fun () ->
            Lwt.catch
              (fun () ->
                serve_tls_conn ~timeouts ~max_header_bytes:srv.max_header_bytes
                  srv.handler conn)
              (fun _ -> Lwt.return_unit));
        accept_loop ()
  in
  Lwt.catch accept_loop (fun _ -> Lwt.return_unit)

(* Go's Server.ListenAndServeTLS: bind addr:port with TLS + ALPN and serve,
   dispatching h2/http1 by the negotiated protocol. *)
let listen_and_serve_tls ~certificates ?(alpn = default_alpn_protocols) ~addr
    ~port handler =
  let srv = create ~addr ~port handler in
  Net.listen_tls ~certificates ~alpn
    (if addr = "" then "0.0.0.0" else addr)
    port
  >>= fun tls_srv -> serve_tls srv tls_srv

(* Like {!listen_and_serve_tls} but binds first and returns the running server,
   the bound port and the serve loop promise, so tests can connect over an
   ephemeral TLS port and {!close}. *)
let listen_and_serve_tls_started ~certificates ?(alpn = default_alpn_protocols)
    ~addr ~port handler =
  let srv = create ~addr ~port handler in
  Net.listen_tls ~certificates ~alpn
    (if addr = "" then "0.0.0.0" else addr)
    port
  >>= fun tls_srv ->
  let lfd = Net.tls_listen_fd tls_srv in
  srv.listen_fd <- Some lfd;
  let bound = Net.bound_port lfd in
  let serve_t = serve_tls srv tls_srv in
  Lwt.return (srv, bound, serve_t)

(* Like listen_and_serve but returns the [Server.t] and the bound port via a
   callback once the listener is up, so tests can connect to an ephemeral
   port and stop the server. *)
let listen_and_serve_started ?read_timeout ?read_header_timeout ?write_timeout
    ?idle_timeout ?max_header_bytes ~addr ~port handler =
  let srv =
    create ?read_timeout ?read_header_timeout ?write_timeout ?idle_timeout
      ?max_header_bytes ~addr ~port handler
  in
  Net.listen (if addr = "" then "0.0.0.0" else addr) port >>= fun listen_fd ->
  srv.listen_fd <- Some listen_fd;
  let bound = Net.bound_port listen_fd in
  let serve_t = serve srv listen_fd in
  Lwt.return (srv, bound, serve_t)
