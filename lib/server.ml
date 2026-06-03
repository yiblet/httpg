(* Port of the HTTP/1.x subset of go/src/net/http/server.go:
   Handler / HandlerFunc, ResponseWriter, the per-connection serve loop,
   Server / listen_and_serve, ServeMux dispatch, NotFound / Error /
   Redirect / RedirectHandler. HTTP/2, hijacking, TLS-NPN and graceful
   shutdown niceties are out of scope (Server.close is minimal). *)

open Lwt.Infix

(* ---- Date header (Go's TimeFormat: "Mon, 02 Jan 2006 15:04:05 GMT") ---- *)

let weekday_names = [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |]

let month_names =
  [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"; "Oct";
     "Nov"; "Dec" |]

let utc_of_unix t =
  let secs = int_of_float (Float.floor t) in
  let days = if secs >= 0 then secs / 86400 else (secs - 86399) / 86400 in
  let rem = secs - (days * 86400) in
  let h = rem / 3600 in
  let mi = rem mod 3600 / 60 in
  let s = rem mod 60 in
  let weekday = (((days mod 7) + 4) mod 7 + 7) mod 7 in
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
    month_names.(mo - 1) y h mi s

(* ---- ResponseWriter / Handler ---- *)

(* Go's ResponseWriter interface. [header] returns the mutable header map the
   handler writes to before the headers are flushed; [write_header] sets the
   status (Go's WriteHeader); [write] writes body bytes (implicitly calling
   write_header 200 on first use). *)
type response_writer = {
  header : unit -> Header.t;
  write_header : int -> unit;
  write : string -> unit Lwt.t;
}

(* Go's Handler interface: ServeHTTP(ResponseWriter, *Request). *)
type handler = { serve_http : response_writer -> Body.t Request.t -> unit Lwt.t }

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
        if trailing && not (String.length cleaned > 0
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
let redirect_handler url code =
  handler_func (fun w r -> redirect w r url code)

(* ---- ServeMux ---- *)

(* Go's cleanPath: canonical path, eliminating . and .. and preserving a
   trailing slash. Reuses Pattern.path_clean (path.Clean). *)
let clean_path p =
  if p = "" then "/"
  else begin
    let p = if p.[0] <> '/' then "/" ^ p else p in
    let np = Pattern.path_clean p in
    if p.[String.length p - 1] = '/' && np <> "/" then begin
      if String.length p = String.length np + 1
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
        if String.length host >= 2 && host.[0] = '['
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

exception Register_error of string

(* Go's registerErr: parse, conflict-check, add to the tree. *)
let register mux patstr handler =
  if patstr = "" then raise (Register_error "http: invalid pattern");
  match Pattern.parse patstr with
  | Error msg ->
      raise (Register_error (Printf.sprintf "parsing %S: %s" patstr msg))
  | Ok pat ->
      List.iter
        (fun pat2 ->
          if Pattern.conflicts_with pat pat2 then
            raise
              (Register_error
                 (Printf.sprintf
                    "pattern %S conflicts with pattern %S:\n%s"
                    (Pattern.to_string pat) (Pattern.to_string pat2)
                    (Pattern.describe_conflict pat pat2))))
        mux.patterns;
      Routing_tree.add_pattern mux.tree pat handler;
      mux.patterns <- pat :: mux.patterns

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
  if (not is_exact) && try_redirect
     && not (String.length path > 0 && path.[String.length path - 1] = '/')
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
          let u =
            if raw_query <> "" then path ^ "?" ^ raw_query else path
          in
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

(* Run [serve] for one request on [oc], returning whether the connection
   should be kept alive afterward. Implements implicit WriteHeader(200),
   content-type sniffing, Date, Content-Length (buffered body) and the
   version-sensitive Connection handling. Bodies are buffered then flushed so
   we can always emit an exact Content-Length, matching Go's common case. *)
let serve_one oc (r : Body.t Request.t) (h : handler) : bool Lwt.t =
  let header = Header.create () in
  let status = ref Status.status_ok in
  let wrote_header = ref false in
  let body_buf = Buffer.create 256 in
  (* Whether the client/handler requested the connection be closed. *)
  let req_should_close = r.close in
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
          if not !wrote_header then begin
            wrote_header := true;
            status := Status.status_ok
          end;
          if body_allowed_for_status !status then Buffer.add_string body_buf data;
          Lwt.return_unit);
    }
  in
  h.serve_http rw r >>= fun () ->
  (* finishRequest: ensure header was written. *)
  if not !wrote_header then begin
    wrote_header := true;
    status := Status.status_ok
  end;
  let is_head = r.meth = "HEAD" in
  let body = Buffer.contents body_buf in
  let body_allowed = body_allowed_for_status !status in
  (* Content-Type sniffing when not set and a body is allowed. *)
  if body_allowed && not (Header.has header "Content-Type") then begin
    (* Only sniff if X-Content-Type-Options nosniff is not set. *)
    if not (Gohttp_internal.Ascii.equal_fold (Header.get header "X-Content-Type-Options") "nosniff")
    then
      if String.length body > 0 then
        Header.set header "Content-Type" (Sniff.detect_content_type body)
  end;
  (* Date header (Go always sets it if absent). *)
  if not (Header.has header "Date") then
    Header.set header "Date" (http_time_now ());
  (* Determine close: HTTP/1.0 closes by default unless keep-alive; HTTP/1.1
     keeps alive unless close. Honor an explicit handler "Connection: close". *)
  let handler_conn_close =
    Transfer.has_token (String.lowercase_ascii (Header.get header "Connection")) "close"
  in
  let keep_alive = (not req_should_close) && not handler_conn_close in
  (* Build the status line with the request's protocol. *)
  let proto =
    if Request.proto_at_least r 1 1 then "HTTP/1.1" else "HTTP/1.0"
  in
  let status_text = Status.status_text !status in
  let status_line =
    if status_text = "" then Printf.sprintf "%s %03d status code %d\r\n" proto !status !status
    else Printf.sprintf "%s %03d %s\r\n" proto !status status_text
  in
  let out = Buffer.create (256 + String.length body) in
  Buffer.add_string out status_line;
  (* Framing headers (managed; not part of the handler header subset). *)
  let content_length = String.length body in
  if body_allowed then
    Buffer.add_string out (Printf.sprintf "Content-Length: %d\r\n" content_length)
  else if (not is_head) && String.length body = 0 then
    (* For 204/304/1xx we omit Content-Length entirely (Go does too). *)
    ();
  (* Connection header per version rules. *)
  if not keep_alive then Buffer.add_string out "Connection: close\r\n"
  else if not (Request.proto_at_least r 1 1) then
    (* HTTP/1.0 keep-alive must be explicit on the wire. *)
    Buffer.add_string out "Connection: keep-alive\r\n";
  (* Remaining handler headers (sorted), excluding the managed ones. *)
  Header.write_subset header out ~exclude:excluded_headers;
  Buffer.add_string out "\r\n";
  Lwt_io.write oc (Buffer.contents out) >>= fun () ->
  (if is_head then Lwt.return_unit else Lwt_io.write oc body) >>= fun () ->
  Lwt_io.flush oc >>= fun () ->
  Lwt.return keep_alive

(* Note: Io.read_request returns a streaming request body; the serve loop runs
   Body.drain on it before reusing a kept-alive connection (Go's finishRequest
   drain) so the connection is positioned at the next message boundary. *)

(* ---- Server ---- *)

type t = {
  mutable addr : string;
  mutable port : int;
  handler : handler;
  (* a promise that, when resolved, makes the accept loop stop. *)
  stop : unit Lwt.t;
  wake_stop : unit Lwt.u;
  mutable listen_fd : Lwt_unix.file_descr option;
}

let create ?(addr = "") ?(port = 0) handler =
  let stop, wake_stop = Lwt.wait () in
  { addr; port; handler; stop; wake_stop; listen_fd = None }

(* Minimal Server.Close: resolve the stop promise and close the listener. *)
let close srv =
  (if Lwt.is_sleeping srv.stop then Lwt.wakeup_later srv.wake_stop ());
  match srv.listen_fd with
  | Some fd ->
      srv.listen_fd <- None;
      Lwt.catch (fun () -> Lwt_unix.close fd) (fun _ -> Lwt.return_unit)
  | None -> Lwt.return_unit

(* The per-connection serve loop: read a request, dispatch, write the response,
   loop while keep-alive holds. *)
let serve_conn (handler : handler) (cfd, peer) =
  let ic, oc = Net.channels_of_fd cfd in
  let remote = Net.sockaddr_to_string peer in
  (* Go's Server: a base context cancelled when the connection is closed
     (connContext / cancelCtx in conn.serve), off which each request derives
     its own per-request context. Cancelled in the finalizer below so a handler
     observing Context.done_ sees the connection close (Go's conn.serve). *)
  let conn_ctx, cancel_conn = Context.with_cancel Context.background in
  let rec loop () =
    Lwt.catch
      (fun () -> Io.read_request ic >>= fun r -> Lwt.return (Some r))
      (fun _ -> Lwt.return None)
    >>= function
    | None -> Lwt.return_unit (* EOF or parse error: close. *)
    | Some r ->
        r.Request.remote_addr <- remote;
        (* Per-request context cancelled when the handler returns (Go cancels
           the request context as ServeHTTP unwinds) and, via its parent
           [conn_ctx], when the connection closes. *)
        let req_ctx, cancel_req = Context.with_cancel conn_ctx in
        r.Request.ctx <- req_ctx;
        Lwt.catch
          (fun () -> serve_one oc r handler)
          (fun _ -> Lwt.return false)
        >>= fun keep_alive ->
        cancel_req Context.Canceled;
        (* Go's finishRequest: consume/close the request body before reusing the
           connection, so a kept-alive connection is positioned at the next
           message boundary (and any chunked trailer is read). *)
        if keep_alive then
          Lwt.catch (fun () -> Body.drain r.Request.body) (fun _ -> Lwt.return_unit)
          >>= loop
        else Lwt.return_unit
  in
  Lwt.finalize loop (fun () ->
      cancel_conn Context.Canceled;
      Lwt.catch (fun () -> Lwt_io.close oc) (fun _ -> Lwt.return_unit)
      >>= fun () ->
      Lwt.catch (fun () -> Lwt_io.close ic) (fun _ -> Lwt.return_unit))

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
        Lwt.async (fun () ->
            Lwt.catch
              (fun () -> serve_conn srv.handler conn)
              (fun _ -> Lwt.return_unit));
        accept_loop ()
  in
  Lwt.catch accept_loop (fun _ -> Lwt.return_unit)

(* Go's Server.ListenAndServe / ListenAndServe: bind addr:port and serve. *)
let listen_and_serve ~addr ~port handler =
  let srv = create ~addr ~port handler in
  Net.listen (if addr = "" then "0.0.0.0" else addr) port
  >>= fun listen_fd -> serve srv listen_fd

(* ---- HTTP/2 over TLS (ALPN dispatch) ---- *)

(* The default ALPN protocols advertised by the TLS server, in descending order
   of preference (Go's [http2.NextProtoTLS] + ["http/1.1"]). *)
let default_alpn_protocols = [ "h2"; "http/1.1" ]

(* Adapt an HTTP/1.x [Server.handler] into an [H2_server.handler]: build the
   H2 response_writer, expose it to the user handler as a {!response_writer}
   (the H2 writer minus [flush]), run the handler, then flush the buffered
   headers/body onto the wire. The two writer types are structurally identical
   apart from H2's extra [flush] (which the serve loop drives), so the bridge is
   a straight field projection. *)
let h2_handler_of_handler (handler : handler) : H2_server.handler =
 fun (h2w : H2_server.response_writer) (r : Body.t Request.t) ->
  let w =
    {
      header = h2w.H2_server.header;
      write_header = h2w.H2_server.write_header;
      write = h2w.H2_server.write;
    }
  in
  handler.serve_http w r >>= fun () -> h2w.H2_server.flush ()

(* Serve one accepted TLS connection, branching on the ALPN-negotiated protocol:
   "h2" runs the HTTP/2 server connection; anything else (incl. no ALPN) runs the
   existing HTTP/1.x serve loop over the TLS channels. *)
let serve_tls_conn (handler : handler) (ic, oc, alpn, peer) =
  match alpn with
  | Some "h2" ->
      Lwt.finalize
        (fun () -> H2_server.serve ic oc ~handler:(h2_handler_of_handler handler))
        (fun () ->
          Lwt.catch (fun () -> Lwt_io.close oc) (fun _ -> Lwt.return_unit)
          >>= fun () ->
          Lwt.catch (fun () -> Lwt_io.close ic) (fun _ -> Lwt.return_unit))
  | _ ->
      (* HTTP/1.x over TLS: reuse the plaintext serve loop. It already wraps the
         channels in a keep-alive loop with per-conn/per-request contexts and
         closes the channels in its finalizer. *)
      let remote = Net.sockaddr_to_string peer in
      let conn_ctx, cancel_conn = Context.with_cancel Context.background in
      let rec loop () =
        Lwt.catch
          (fun () -> Io.read_request ic >>= fun r -> Lwt.return (Some r))
          (fun _ -> Lwt.return None)
        >>= function
        | None -> Lwt.return_unit
        | Some r ->
            r.Request.remote_addr <- remote;
            let req_ctx, cancel_req = Context.with_cancel conn_ctx in
            r.Request.ctx <- req_ctx;
            Lwt.catch
              (fun () -> serve_one oc r handler)
              (fun _ -> Lwt.return false)
            >>= fun keep_alive ->
            cancel_req Context.Canceled;
            if keep_alive then
              Lwt.catch (fun () -> Body.drain r.Request.body) (fun _ -> Lwt.return_unit)
              >>= loop
            else Lwt.return_unit
      in
      Lwt.finalize loop (fun () ->
          cancel_conn Context.Canceled;
          Lwt.catch (fun () -> Lwt_io.close oc) (fun _ -> Lwt.return_unit)
          >>= fun () ->
          Lwt.catch (fun () -> Lwt_io.close ic) (fun _ -> Lwt.return_unit))

(* Go's Server.ServeTLS over a [Net.tls_server]: accept + handshake each
   connection, dispatch by ALPN, until [srv.stop] resolves. *)
let serve_tls srv (tls_srv : Net.tls_server) =
  srv.listen_fd <- Some (Net.tls_listen_fd tls_srv);
  let rec accept_loop () =
    let accept_p =
      Lwt.map (fun c -> `Conn c) (Net.accept_tls tls_srv)
    in
    let stop_p = Lwt.map (fun () -> `Stop) srv.stop in
    Lwt.choose [ accept_p; stop_p ] >>= function
    | `Stop -> Lwt.return_unit
    | `Conn conn ->
        Lwt.async (fun () ->
            Lwt.catch
              (fun () -> serve_tls_conn srv.handler conn)
              (fun _ -> Lwt.return_unit));
        accept_loop ()
  in
  Lwt.catch accept_loop (fun _ -> Lwt.return_unit)

(* Go's Server.ListenAndServeTLS: bind addr:port with TLS + ALPN and serve,
   dispatching h2/http1 by the negotiated protocol. *)
let listen_and_serve_tls ~certificates ?(alpn = default_alpn_protocols) ~addr
    ~port handler =
  let srv = create ~addr ~port handler in
  Net.listen_tls ~certificates ~alpn (if addr = "" then "0.0.0.0" else addr)
    port
  >>= fun tls_srv -> serve_tls srv tls_srv

(* Like {!listen_and_serve_tls} but binds first and returns the running server,
   the bound port and the serve loop promise, so tests can connect over an
   ephemeral TLS port and {!close}. *)
let listen_and_serve_tls_started ~certificates ?(alpn = default_alpn_protocols)
    ~addr ~port handler =
  let srv = create ~addr ~port handler in
  Net.listen_tls ~certificates ~alpn (if addr = "" then "0.0.0.0" else addr)
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
let listen_and_serve_started ~addr ~port handler =
  let srv = create ~addr ~port handler in
  Net.listen (if addr = "" then "0.0.0.0" else addr) port
  >>= fun listen_fd ->
  srv.listen_fd <- Some listen_fd;
  let bound = Net.bound_port listen_fd in
  let serve_t = serve srv listen_fd in
  Lwt.return (srv, bound, serve_t)
