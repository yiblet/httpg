(* Port of the HTTP/1.x subset of go/src/net/http/server.go:
   Handler / HandlerFunc, ResponseWriter, the per-connection serve loop,
   Server / listen_and_serve, ServeMux dispatch, NotFound / Error /
   Redirect / RedirectHandler. HTTP/2-over-TLS is dispatched by ALPN (the h2
   branch hands off to {!Httpg_http2.H2_server} via the translation shim below,
   Go's http2.go); hijacking and graceful shutdown niceties are out of scope. *)

(* Routing internals live in the private httpg_internal library (Go keeps
   pattern.go / routingNode / mapping.go unexported in net/http). [Pattern] is
   used by {!redirect}'s path cleaning; the ServeMux dispatch that uses the
   routing tree lives in {!Mux}. *)
module Pattern = Httpg_base.Pattern

(* Go's http.TimeFormat applied to the current time. Go's server.go reads the
   clock with [time.Now()] in [response.WriteHeader] / [extraHeaders] to set
   the Date header; here "now" comes from the Eio clock the server captured (so
   tests can drive a mock clock). With no clock captured there is no wall-clock
   source, so we return [None] and the Date header is simply omitted — matching
   the codebase's other clock-optional paths, which skip clock-dependent
   behaviour when no clock is present. *)
let http_time_now clock =
  match clock with
  | None -> None
  | Some clock -> Some (Http_time.format_gmt (Eio.Time.now clock))

(* ---- Handler ---- *)

(* An axum-style handler: a request maps to a fully-built response. (Departs from
   Go's [ServeHTTP(ResponseWriter, *Request)]: instead of mutating a writer, the
   handler returns an immutable {!Response.t} that the serve loop flushes.
   Streaming is expressed by a {!Body.Stream} body the runtime drives.)

   [~sw] is the request's switch: it scopes resources whose lifetime must outlive
   the handler return — a {!Body.Stream} body is pulled by the serve loop *after*
   the handler returns, so a handler that streams from an opened resource (the
   file server's file handle) must open it under [~sw], which is released once
   the response has been sent. Most handlers ignore [~sw]. *)
type handler = sw:Eio.Switch.t -> Request.t -> Response.t

(* ---- helpers: Error / NotFound / Redirect (Go server.go) ---- *)

(* Go's Error: a text/plain, nosniff response carrying the message + newline.
   (Content-Length is derived from the body by the builder.) *)
let error msg code =
  Response.create () |> Response.with_status code
  |> Response.with_set_header "Content-Type" "text/plain; charset=utf-8"
  |> Response.with_set_header "X-Content-Type-Options" "nosniff"
  |> Response.with_body_string (msg ^ "\n")

let not_found _r = error "404 page not found" Httpg_base.Status.NotFound
let not_found_handler () ~sw:_ r = not_found r

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

(* Go's Redirect (HTTP/1.x subset): relative-target resolution against the
   request path is performed as in Go; non-ASCII hex-escaping is narrowed
   (ASCII targets pass through unchanged). *)
let redirect (r : Request.t) url code : Response.t =
  let url =
    let u = Uri.of_string url in
    if Uri.scheme u = None && Uri.host u = None then begin
      let oldpath =
        let p = Uri.path r.url in
        if p = "" then "/" else p
      in
      let url =
        if String.length url = 0 || url.[0] <> '/' then begin
          let olddir =
            match String.rindex_opt oldpath '/' with
            | Some i -> String.sub oldpath 0 (i + 1)
            | None -> ""
          in
          olddir ^ url
        end
        else url
      in
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
  let base =
    Response.create () |> Response.with_status code
    |> Response.with_set_header "Location" url
  in
  (* Set Content-Type for GET/HEAD; write the HTML body only for GET (Go's
     Redirect). A fresh response never has a pre-set Content-Type. *)
  match r.meth with
  | Httpg_base.Method.Get ->
      base
      |> Response.with_set_header "Content-Type" "text/html; charset=utf-8"
      |> Response.with_body_string
           ("<a href=\"" ^ html_escape url ^ "\">"
           ^ Httpg_base.Status.to_string code
           ^ "</a>.\n")
  | Httpg_base.Method.Head ->
      base |> Response.with_set_header "Content-Type" "text/html; charset=utf-8"
  | _ -> base

let redirect_handler url code ~sw:_ r = redirect r url code

(* The ServeMux request multiplexer (Go keeps it in this same server.go) lives
   in {!Mux}; it builds on {!handler} and the {!error} / {!not_found_handler} /
   {!redirect_handler} helpers above. *)

(* ---- Writing the handler's Response to the wire ---- *)

(* Headers the serve loop frames itself; excluded from the response header block
   (Go's excludedHeaders). *)
let excluded_headers = [ "Content-Length"; "Transfer-Encoding"; "Connection" ]

(* bodyAllowedForStatus: 1xx, 204, 304 carry no body. *)
let body_allowed_for_status status =
  let code = Httpg_base.Status.to_int status in
  if code >= 100 && code <= 199 then false
  else if code = 204 then false
  else if code = 304 then false
  else true

(* Run the handler for one request on [w], returning whether the connection
   should be kept alive afterward. Mirrors Go's [response]/[chunkWriter]
   buffer-then-chunk model (server.go:1096,1284,1353):

   - Handler [write]s accumulate in a 2048-byte buffer.
   - The framing decision (chunkWriter.writeHeader) fires at first flush: buffer
     overflow, the handler returns, or [flush] is called.
   - Handler done with <=2048 buffered, no explicit Content-Length, body allowed,
     not a zero-byte HEAD -> exact Content-Length, NO chunking (the common case).
   - Otherwise HTTP/1.1 -> Transfer-Encoding: chunked; HTTP/1.0 unknown length ->
     Connection: close, raw bytes, close at EOF. *)
(* Run the handler and flush its returned response to the wire, deciding the
   framing from the response body's shape: a [String]/[Empty] body has an exact
   Content-Length; a [Stream] body is unknown-length and sent chunked (HTTP/1.1)
   or close-delimited (HTTP/1.0), one DATA flush per pulled chunk so the client
   observes incremental delivery. Returns the keep-alive verdict. *)
let serve_one ~sw ~clock w (r : Request.t) (h : handler) : bool =
  let resp = h ~sw r in
  let is_head = r.meth = Httpg_base.Method.Head in
  let req_should_close = r.close in
  let close_after_reply = ref req_should_close in
  let proto = if Request.proto_at_least r 1 1 then "HTTP/1.1" else "HTTP/1.0" in
  let header = resp.Response.header in
  let code = resp.Response.status in
  let body_allowed = body_allowed_for_status code in
  (* Resolve the body into a leading chunk (for sniffing + exact length) and an
     optional continuation. A String/Empty body is fully known; a Stream body is
     unknown-length and streamed (we probe one chunk up front for sniffing). *)
  (* Resolve the body into a leading chunk (for sniffing) and a continuation
     stream for the rest. The "known length vs streaming" framing decision is
     [content_length] ([Some _] = exact Content-Length, raw bytes; [None] =
     chunked/close-delimited), independent of how many chunks the body yields.
     The serve loop must sniff the leading bytes, so we force the first element
     (matching the old code, which forced the first [Stream] chunk for
     sniffing); the rest stays lazy via the continuation. *)
  let pull = Body.to_stream resp.Response.body in
  let leading_error = ref false in
  let leading, body_present =
    match pull () with
    | Some (Ok c) -> (c, true)
    | Some (Error _) ->
        leading_error := true;
        ("", true)
    | None -> ("", false)
  in
  (* [streaming] = the response is delivered chunk-by-chunk through the loop
     (true whenever a body was present); an empty body short-circuits. *)
  let streaming = body_present in
  let tail_stream = if streaming then Some pull else None in
  (* Content-Type sniff from the first <=512 bytes when unset. *)
  let header =
    if
      body_allowed
      && (not (Header.has header "Content-Type"))
      && (not
            (match Header.get header "X-Content-Type-Options" with
            | Some v -> Httpg_internal.Ascii.equal_fold v "nosniff"
            | None -> false))
      && String.length leading > 0
    then
      let src =
        if String.length leading > 512 then String.sub leading 0 512
        else leading
      in
      Header.set "Content-Type" (Sniff.detect_content_type src) header
    else header
  in
  let header =
    if not (Header.has header "Date") then
      match http_time_now clock with
      | Some date -> Header.set "Date" date header
      | None -> header
    else header
  in
  (match Header.get header "Connection" with
  | Some conn when Transfer.has_token (String.lowercase_ascii conn) "close" ->
      close_after_reply := true
  | _ -> ());
  (* Framing. A response with a declared [content_length] (>= 0) — including a
     known-length [Stream] body, as the file server uses for byte ranges — is
     sent with an exact Content-Length and raw (unchunked) bytes; an
     unknown-length [Stream] is chunked (HTTP/1.1) or close-delimited (1.0). *)
  let content_length =
    if not body_allowed then None
    else Option.map Int64.to_int resp.Response.content_length
  in
  let chunking =
    body_allowed && streaming && content_length = None && (not is_head)
    && Request.proto_at_least r 1 1
  in
  if
    body_allowed && streaming && content_length = None
    && not (Request.proto_at_least r 1 1)
  then close_after_reply := true;
  (* HTTP/1.0 keep-alive (wants10KeepAlive, server.go:1369). *)
  let wants10_keep_alive =
    (not (Request.proto_at_least r 1 1))
    && Request.proto_at_least r 1 0
    &&
    match Header.get r.Request.header "Connection" with
    | Some conn -> Transfer.has_token (String.lowercase_ascii conn) "keep-alive"
    | None -> false
  in
  let sent_known_length =
    is_head || content_length <> None || not body_allowed
  in
  let advertise10_keep_alive = ref false in
  if not (Request.proto_at_least r 1 1) then
    if wants10_keep_alive && sent_known_length && not req_should_close then
      advertise10_keep_alive := true
    else close_after_reply := true;
  let keep_alive = not !close_after_reply in
  (* Status line + headers. *)
  let code_int = Httpg_base.Status.to_int code in
  let status_text = Httpg_base.Status.to_string code in
  let status_line =
    if status_text = "" then
      Printf.sprintf "%s %03d status code %d\r\n" proto code_int code_int
    else Printf.sprintf "%s %03d %s\r\n" proto code_int status_text
  in
  let out = Buffer.create 256 in
  Buffer.add_string out status_line;
  (match content_length with
  | Some n -> Buffer.add_string out (Printf.sprintf "Content-Length: %d\r\n" n)
  | None ->
      if chunking then Buffer.add_string out "Transfer-Encoding: chunked\r\n");
  if not keep_alive then Buffer.add_string out "Connection: close\r\n"
  else if !advertise10_keep_alive then
    Buffer.add_string out "Connection: keep-alive\r\n";
  Header.write_subset header out ~exclude:excluded_headers;
  Buffer.add_string out "\r\n";
  Eio.Buf_write.string w (Buffer.contents out);
  (* Body. A mid-stream [Error] element (a body whose source failed while being
     produced, e.g. a file read error) aborts the response: we stop writing and
     force the connection closed, the faithful analogue of the old code's raise
     propagating out of the write loop. *)
  let aborted = ref !leading_error in
  if is_head then ()
  else if not streaming then begin
    if String.length leading > 0 then Eio.Buf_write.string w leading
  end
  else begin
    let write_chunk data =
      if String.length data > 0 then begin
        if chunking then Transfer.chunked_writer_write w data
        else Eio.Buf_write.string w data;
        Eio.Buf_write.flush w
      end
    in
    write_chunk leading;
    (match tail_stream with
    | Some next ->
        let rec loop () =
          match next () with
          | Some (Ok c) ->
              write_chunk c;
              loop ()
          | Some (Error _) -> aborted := true
          | None -> ()
        in
        loop ()
    | None -> ());
    if (not !aborted) && chunking then begin
      Transfer.chunked_writer_close w;
      Eio.Buf_write.string w "\r\n"
    end
  end;
  Eio.Buf_write.flush w;
  keep_alive && not !aborted

(* maxPostHandlerReadBytes (server.go): the max number of unread Request.Body
   bytes the server discards to keep a connection alive; past this it closes. *)
let max_post_handler_read_bytes = 256 * 1024

(* Go's finishRequest: consume the unread request body before reusing a
   kept-alive connection, bounded by [max_post_handler_read_bytes]. Returns
   whether the connection may still be reused. *)
let drain_request_body (r : Request.t) : bool =
  try
    match Body.drain ~limit:max_post_handler_read_bytes r.Request.body with
    | Ok `Drained -> true
    | Ok `Too_big -> false
    | Error _ -> false
  with _ -> false

(* ---- Server ---- *)

type t = {
  (* Eio capabilities captured at construction (cohttp_eio style); per-op
     surfaces don't re-thread them. The accept [Switch]es are NOT captured. *)
  net : [ `Generic ] Eio.Net.ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
  (* Optional domain manager (Eio.Stdenv.domain_mgr) for the multicore accept
     pool; [None] forces single-domain serving regardless of [?domains]. *)
  domain_mgr : Eio.Domain_manager.ty Eio.Resource.t option;
  mutable addr : string option;
  mutable port : int;
  handler : handler;
  (* Go's Server duration knobs (server.go:3717-3724); seconds, 0. = off.
     read_header_timeout/idle_timeout fall back to read_timeout when zero. *)
  read_timeout : float;
  read_header_timeout : float;
  write_timeout : float;
  idle_timeout : float;
  (* Go's Server.MaxHeaderBytes; default DefaultMaxHeaderBytes (1 MB). *)
  max_header_bytes : int;
  (* h2c (HTTP/2 cleartext, prior-knowledge per RFC 9113 §3.3): when set, the
     plaintext serve loop runs the HTTP/2 server directly on the cleartext
     channels instead of HTTP/1.x. No Go-stdlib analogue (h2c lives in
     golang.org/x/net/http2/h2c, outside the vendored spec). *)
  force_h2 : bool;
  (* Cross-domain shutdown trigger (Go's Server.Close). [serve] forks a watcher
     that awaits [stop] then fails the pool switch *on the serve domain*; that
     cancellation propagates into each spawned domain (Domain_manager.run docs),
     tearing down all K accept loops + their in-flight connection fibers. The
     resolver is one-shot, so [close] resolving it from ANY domain is safe
     (Promise is cross-domain). *)
  mutable stop : unit Eio.Promise.t;
  mutable stop_u : unit Eio.Promise.u;
  (* Graceful-shutdown trigger (Go's Server.Shutdown). Distinct from [stop]:
     resolving it does NOT cancel in-flight connections; instead live h2 conns
     observe it and start a graceful GOAWAY drain, and the listener is closed so
     no new connections are accepted. Resolved once, cross-domain. *)
  mutable graceful : unit Eio.Promise.t;
  mutable graceful_u : unit Eio.Promise.u;
  (* Closes the listening socket (Go's Server.Close closing the net.Listener);
     set by [serve]/[serve_tls] once the listener is known. *)
  mutable close_listener : unit -> unit;
}

let default_max_header_bytes = 1 lsl 20

let create ~net ?clock ?domain_mgr ?addr ?(port = 0) ?(read_timeout = 0.)
    ?(read_header_timeout = 0.) ?(write_timeout = 0.) ?(idle_timeout = 0.)
    ?(max_header_bytes = default_max_header_bytes) ?(force_h2 = false) handler =
  {
    net :> [ `Generic ] Eio.Net.ty Eio.Resource.t;
    clock =
      Option.map (fun c -> (c :> float Eio.Time.clock_ty Eio.Resource.t)) clock;
    domain_mgr =
      Option.map
        (fun d -> (d :> Eio.Domain_manager.ty Eio.Resource.t))
        domain_mgr;
    addr;
    port;
    handler;
    read_timeout;
    read_header_timeout;
    write_timeout;
    idle_timeout;
    max_header_bytes;
    force_h2;
    (* placeholder pair; [serve]/[serve_tls] install a fresh one before use. *)
    stop = fst (Eio.Promise.create ());
    stop_u = snd (Eio.Promise.create ());
    graceful = fst (Eio.Promise.create ());
    graceful_u = snd (Eio.Promise.create ());
    close_listener = (fun () -> ());
  }

(* Fiber-control cancellation signal (a sibling to [Eio.Cancel]), NOT a modeled
   error: {!close} threads it through [Eio.Switch.fail] to cancel the accept
   switches, and {!serve}/{!serve_tls} swallow it so a clean shutdown returns
   normally. It rides [Eio.Switch.fail], which requires an [exn], so it stays an
   [exception] under the philosophy's fiber-control exemption. *)
exception Shutdown

(* Minimal Server.Close: close the listener (free the port, refuse new
   connects), then resolve the cross-domain [stop] trigger, which the serve
   watcher turns into a pool-switch cancellation tearing down all K accept loops
   + in-flight connection fibers. Safe from any domain (Promise is one-shot and
   cross-domain). *)
let close srv =
  (try srv.close_listener () with _ -> ());
  srv.close_listener <- (fun () -> ());
  ignore (Eio.Promise.try_resolve srv.stop_u ())

(* Go's Server.Shutdown: close the listener (refuse new connects), then signal a
   graceful shutdown to live connections. h1 conns finish their current request
   on the next read (close on idle, bounded by the read/idle deadlines); h2
   conns observe [graceful] and start a GOAWAY drain (see H2_server.serve's
   [?graceful]). Does NOT force-cancel in-flight work; use {!close} for that. *)
let shutdown srv =
  (try srv.close_listener () with _ -> ());
  srv.close_listener <- (fun () -> ());
  ignore (Eio.Promise.try_resolve srv.graceful_u ())

(* Go's conn.serve error branch: map a request-read error to a minimal HTTP
   response written directly onto the wire (no handler), then close. *)
let error_headers =
  "\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n"

let write_read_error_response w (e : Io.error) : unit =
  let write s =
    try
      Eio.Buf_write.string w s;
      Eio.Buf_write.flush w
    with _ -> ()
  in
  match e with
  | Io.Transfer (Transfer.Unsupported_transfer_encoding _) ->
      let code = Httpg_base.Status.NotImplemented in
      write
        (Printf.sprintf "HTTP/1.1 %d %s%sUnsupported transfer encoding"
           (Httpg_base.Status.to_int code)
           (Httpg_base.Status.to_string code)
           error_headers)
  | Io.Unexpected_eof -> () (* Common net read error: don't reply. *)
  | Io.Request_too_large ->
      (* errTooLarge -> 431 + close (server.go:2053-2062). *)
      let public_err = "431 Request Header Fields Too Large" in
      write
        (Printf.sprintf "HTTP/1.1 %s%s%s" public_err error_headers public_err)
  | Io.Protocol _ | Io.Missing_host | Io.Transfer _ | Io.Trailer_too_large
  | Io.Malformed_host | Io.Response_header_too_large ->
      (* Invalid header, missing/malformed Host -> 400 Bad Request
         (server.go:1045-1062). Trailer_too_large normally surfaces as a
         mid-stream Body.error, not a boundary error; Response_header_too_large
         is client-side and never reaches here. *)
      let public_err = "400 Bad Request" in
      write
        (Printf.sprintf "HTTP/1.1 %s%s%s" public_err error_headers public_err)

(* Go's response.sendExpectationFailed (server.go:2236-2252): a non-100-continue
   Expect gets 417 + Connection: close, handler NOT run. *)
let write_expectation_failed w : unit =
  let code = Httpg_base.Status.ExpectationFailed in
  let code_int = Httpg_base.Status.to_int code in
  let body =
    Printf.sprintf "%d %s" code_int (Httpg_base.Status.to_string code)
  in
  try
    Eio.Buf_write.string w
      (Printf.sprintf "HTTP/1.1 %d %s%s%s" code_int
         (Httpg_base.Status.to_string code)
         error_headers body);
    Eio.Buf_write.flush w
  with _ -> ()

(* The four server duration knobs, resolved for one connection (Go's
   readHeaderTimeout()/idleTimeout() fallback to ReadTimeout). Seconds; 0. = off. *)
type timeouts = {
  to_read : float;
  to_read_header : float;
  to_write : float;
  to_idle : float;
}

let no_timeouts =
  { to_read = 0.; to_read_header = 0.; to_write = 0.; to_idle = 0. }

let timeouts_of_server (srv : t) : timeouts =
  let fallback x = if x <> 0. then x else srv.read_timeout in
  {
    to_read = srv.read_timeout;
    to_read_header = fallback srv.read_header_timeout;
    to_write = srv.write_timeout;
    to_idle = fallback srv.idle_timeout;
  }

(* Run [op] bounded by [secs] using [clock]; [`Timeout] when it fires, else
   [`Done v]. With no clock or secs<=0 the op runs unbounded. Go uses socket
   SetReadDeadline/SetWriteDeadline; Eio uses a clock-driven cancellation. *)
let with_deadline clock ~secs op =
  match clock with
  | Some clock when secs > 0. -> (
      match Net.with_timeout clock secs op with
      | Ok v -> `Done v
      | Error _ -> `Timeout)
  | _ -> `Done (op ())

(* Wrap the request body so its pulls share a whole-request read deadline (Go's
   ReadTimeout / wholeReqDeadline). On the deadline the pull yields EOF so the
   read terminates. A zero [secs] / no clock leaves the body untouched. *)
let wrap_read_timeout_body clock ~secs (r : Request.t) : unit =
  match clock with
  | Some clock when secs > 0. ->
      let deadline = Eio.Time.now clock +. secs in
      let inner = Body.to_stream r.Request.body in
      let next () =
        Eio.Fiber.first
          (fun () ->
            Eio.Time.sleep_until clock deadline;
            None)
          inner
      in
      r.Request.body <- Body.of_stream_result next
  | _ -> ()

(* Go's expectContinueReader (server.go:964-983): the FIRST body read replies
   "HTTP/1.1 100 Continue\r\n\r\n" once, then proceeds. Lazy so a client that
   withholds the body until it sees 100 unblocks. *)
let wrap_expect_continue_body w (r : Request.t) : unit =
  (* Wrap unconditionally: the 100 is sent only on the first actual pull, so a
     body that is never read (or is empty and pulls straight to EOF only when
     read) sends nothing until the handler asks for bytes — matching Go, which
     wraps the (present) request body and emits 100 on first Read. *)
  let inner = Body.to_stream r.Request.body in
  let wrote = ref false in
  let next () =
    if not !wrote then begin
      wrote := true;
      try
        Eio.Buf_write.string w "HTTP/1.1 100 Continue\r\n\r\n";
        Eio.Buf_write.flush w
      with _ -> ()
    end;
    inner ()
  in
  r.Request.body <- Body.of_stream_result next

(* The per-connection keep-alive serve loop over buffered channels (used by the
   plaintext and HTTP/1.x-over-TLS paths). Reads a request, dispatches, writes
   the response, loops while keep-alive holds. The duration knobs are applied as
   clock deadlines: read_header around the header read; idle between requests;
   read (whole-request) around body pulls; write around the response write. On a
   header/idle timeout the connection is closed with no reply (Go's behavior). *)
let serve_loop ~clock ~timeouts ~max_header_bytes ~r ~w ~remote
    (handler : handler) : unit =
  let rec loop ~first () =
    let read_secs =
      if first then timeouts.to_read_header
      else if timeouts.to_idle > 0. then timeouts.to_idle
      else timeouts.to_read_header
    in
    let read () =
      try Io.read_request ~max_header_bytes r
      with _ -> Error Io.Unexpected_eof
    in
    match with_deadline clock ~secs:read_secs read with
    | `Timeout -> () (* header/idle deadline exceeded: hang up, no reply. *)
    | `Done (Error e) -> write_read_error_response w e
    | `Done (Ok req) ->
        req.Request.remote_addr <- Some remote;
        (* Expect: 100-continue (server.go:2089-2101). *)
        let unknown_expect =
          if Request.expects_continue req then begin
            if
              Request.proto_at_least req 1 1
              && req.Request.content_length <> Some 0L
            then wrap_expect_continue_body w req;
            false
          end
          else Option.is_some (Header.get req.Request.header "Expect")
        in
        if unknown_expect then write_expectation_failed w
        else begin
          wrap_read_timeout_body clock ~secs:timeouts.to_read req;
          let keep_alive =
            (* Per-request switch handed to the handler as [~sw]: resources the
               handler opens under it (a file server's fd, multipart tempfiles
               from {!Multipart.of_body}) are released on its teardown, so they
               never outlive the request nor leak across keep-alive. NOT the
               connection switch, which would accumulate them per request. *)
            Eio.Switch.run @@ fun req_sw ->
            match
              with_deadline clock ~secs:timeouts.to_write (fun () ->
                  try serve_one ~sw:req_sw ~clock w req handler
                  with _ -> false)
            with
            | `Done k -> k
            | `Timeout -> false
          in
          (* finishRequest: drain the request body (bounded) before reusing the
             connection so it sits at the next message boundary. *)
          if keep_alive && drain_request_body req then loop ~first:false ()
        end
  in
  loop ~first:true ()

(* ---- net/http <-> http2 translation shim (shared by h2c + h2-over-TLS) ----

   The HTTP/2 server (Go's http2.go: http2Handler.ServeHTTP) hands the handler a
   decoupled {!Httpg_http2.Api} request + response_writer; we expand them to a
   [Request.t] and drive the writer from the returned [Response.t]. The http2
   library never names the public types — translation lives here. Defined above
   the serve loops so both the plaintext (h2c) and TLS (ALPN) dispatchers can
   reach it. *)

let body_of_api_body (b : Httpg_http2.Api.Body.t) : Body.t =
  match b with
  | Httpg_http2.Api.Body.Empty -> Body.empty
  | Httpg_http2.Api.Body.String s -> Body.of_string s
  | Httpg_http2.Api.Body.Stream f -> Body.of_stream f

(* The decoupled Api.header (mutable Hashtbl) -> the public Header (Map). *)
let header_of_api_header (t : Httpg_http2.Api.header) : Header.t =
  List.fold_left
    (fun acc (k, vs) -> Header.set_values k vs acc)
    Header.empty
    (Httpg_http2.Api.Header.to_list t)

let request_of_server_request (r : Httpg_http2.Api.server_request) : Request.t =
  {
    meth = r.sreq_meth;
    url = r.sreq_url;
    proto = r.sreq_proto;
    header = header_of_api_header r.sreq_header;
    body = body_of_api_body r.sreq_body;
    content_length =
      (let n = r.sreq_content_length in
       if Int64.compare n 0L < 0 then None else Some n);
    transfer_encoding = [];
    close = false;
    host = (if r.sreq_host = "" then None else Some r.sreq_host);
    trailer =
      (if Hashtbl.length r.sreq_trailer = 0 then None
       else Some (header_of_api_header r.sreq_trailer));
    request_uri =
      (if r.sreq_request_uri = "" then None else Some r.sreq_request_uri);
    remote_addr =
      (if r.sreq_remote_addr = "" then None else Some r.sreq_remote_addr);
  }

(* Adapt a [Server.handler] into a {!Httpg_http2.Api.handler}: run the handler,
   then drive the H2 response_writer from the returned response — seed headers,
   set the status, then write the body (streaming a [Body.Stream] chunk-by-chunk
   with a flush per chunk). Go's http2Handler.ServeHTTP. *)
let h2_handler_of_handler (handler : handler) : Httpg_http2.H2_server.handler =
 fun (h2w : Httpg_http2.Api.response_writer)
     (r : Httpg_http2.Api.server_request) ->
  let req = request_of_server_request r in
  (* Per-request switch (mirrors the h1 serve loop). The whole response — headers
     AND body — is driven inside the switch, because a [Body.Stream] may read
     from a resource the handler opened under [~sw] (e.g. the file server's fd, or
     multipart tempfiles from {!Multipart.of_body}); the switch must stay open
     until the body is fully written, and releasing it cleans those up so they
     never outlive the h2 stream. *)
  Eio.Switch.run (fun req_sw ->
      let resp = handler ~sw:req_sw req in
      let h2h = h2w.Httpg_http2.Api.rw_header () in
      List.iter
        (fun (k, vs) ->
          List.iter (fun v -> Httpg_http2.Api.Header.add h2h k v) vs)
        (Header.to_list resp.Response.header);
      h2w.rw_write_header (Httpg_base.Status.to_int resp.Response.status);
      (let next = Body.to_stream resp.Response.body in
       let rec loop () =
         match next () with
         | Some (Ok c) ->
             h2w.rw_write c;
             h2w.rw_flush ();
             loop ()
         | Some (Error _) -> () (* mid-stream framing error: stop the body *)
         | None -> ()
       in
       loop ());
      h2w.rw_flush ())

(* Serve one accepted plaintext connection. With [~force_h2] the connection is
   served as h2c (HTTP/2 cleartext, prior-knowledge): {!Httpg_http2.H2_server.serve}
   reads and validates the client preface itself, then runs the HTTP/2 loop over
   the cleartext channels — no ALPN, no Upgrade. Otherwise the HTTP/1.x serve loop
   runs. [?graceful] is threaded into the h2 loop so an h2c connection observes a
   graceful GOAWAY drain (Go's Server.Shutdown), mirroring {!serve_tls_conn}. *)
let serve_conn ~clock ?graceful ?(timeouts = no_timeouts)
    ?(max_header_bytes = default_max_header_bytes) ?(force_h2 = false)
    (handler : handler) flow peer =
  let remote = Net.sockaddr_to_string peer in
  Net.with_connection flow (fun r w ->
      if force_h2 then
        Httpg_http2.H2_server.serve ~max_header_bytes ?clock
          ~idle_timeout:timeouts.to_idle ~read_timeout:timeouts.to_read
          ?graceful r w
          ~handler:(h2_handler_of_handler handler)
      else serve_loop ~clock ~timeouts ~max_header_bytes ~r ~w ~remote handler)

(* Resolve the domain count: [?domains] clamped to >=1, falling back to all
   cores; capped to 1 when no domain_mgr was captured (single-domain). *)
let resolve_domains srv domains =
  let n =
    match domains with
    | Some d -> max 1 d
    | None -> max 1 (Domain.recommended_domain_count ())
  in
  match srv.domain_mgr with Some _ -> n | None -> 1

(* One accept loop over [listen_sock]: fork [conn] per accepted connection (Go's
   [for { c := l.Accept(); go c.serve(c) }]), under [sw]. [on_error] keeps one
   bad conn from killing the loop. [Net.ensure_rng] seeds this domain's RNG (the
   stateless getrandom generator, safe to draw from concurrently across domains;
   see Net.ensure_rng) before any TLS handshake runs on it. *)
let accept_loop ~sw listen_sock conn =
  Net.ensure_rng ();
  let rec loop () =
    Net.accept_fork ~sw ~on_error:(fun _ -> ()) listen_sock conn;
    loop ()
  in
  loop ()

(* Pre-spawn a pool of K accept loops, one per domain, all accepting the SAME
   listening socket (F022 Prototype B: a single Eio listening_socket is safe to
   accept from concurrently across domains). Loop 0 runs on the calling domain;
   loops 1..K-1 each run on their own domain via [Domain_manager.run]. K=1 (or
   no domain_mgr) collapses to today's single-domain accept loop.

   All loops attach to [pool_sw]. A watcher fiber awaits [srv.stop] and, on the
   serve domain, fails [pool_sw] with {!Shutdown}: that cancels loop 0 and the
   forked [Domain_manager.run] fibers, propagating cancellation into each
   spawned domain (its accept loop + in-flight connection fibers). [Shutdown] is
   swallowed so a clean shutdown returns normally. *)
let run_accept_pool srv ~domains listen_sock conn =
  let k = resolve_domains srv domains in
  let stop, stop_u = Eio.Promise.create () in
  srv.stop <- stop;
  srv.stop_u <- stop_u;
  let graceful, graceful_u = Eio.Promise.create () in
  srv.graceful <- graceful;
  srv.graceful_u <- graceful_u;
  try
    Eio.Switch.run @@ fun pool_sw ->
    Eio.Fiber.fork ~sw:pool_sw (fun () ->
        Eio.Promise.await srv.stop;
        Eio.Switch.fail pool_sw Shutdown);
    if k > 1 then begin
      let dmgr = Option.get srv.domain_mgr in
      for _ = 2 to k do
        Eio.Fiber.fork ~sw:pool_sw (fun () ->
            Eio.Domain_manager.run dmgr (fun () ->
                Eio.Switch.run @@ fun dsw ->
                accept_loop ~sw:dsw listen_sock conn))
      done
    end;
    accept_loop ~sw:pool_sw listen_sock conn
  with Shutdown -> ()

(* Go's Server.Serve: accept connections, handle each in its own fiber, until
   the accept switches are cancelled. With [?domains > 1] (default all cores) a
   per-domain pool of accept loops delivers genuine multicore parallelism. *)
let serve ?domains srv listen_sock =
  let clock = srv.clock in
  let timeouts = timeouts_of_server srv in
  let max_header_bytes = srv.max_header_bytes in
  srv.close_listener <- (fun () -> Eio.Resource.close listen_sock);
  run_accept_pool srv ~domains listen_sock (fun flow peer ->
      (* [srv.graceful] is the fresh promise installed by run_accept_pool; an h2c
         connection observes it for a graceful GOAWAY drain. *)
      serve_conn ~clock ~graceful:srv.graceful ~timeouts ~max_header_bytes
        ~force_h2:srv.force_h2 srv.handler flow peer)

let ( let* ) = Result.bind

(* Go's ListenAndServe: bind addr:port and serve until the listener is torn
   down. With [?domain_mgr] + [?domains] (default all cores) the accept pool
   runs across domains; without [?domain_mgr] it stays single-domain. *)
let listen_and_serve ?read_timeout ?read_header_timeout ?write_timeout
    ?idle_timeout ?max_header_bytes ?force_h2 ~net ?clock ?domain_mgr ?domains
    ~addr ~port handler =
  let srv =
    create ~net ?clock ?domain_mgr ?read_timeout ?read_header_timeout
      ?write_timeout ?idle_timeout ?max_header_bytes ?force_h2 ~addr ~port
      handler
  in
  Eio.Switch.run @@ fun sw ->
  let* listen_sock =
    Net.listen ~sw net (if addr = "" then "0.0.0.0" else addr) port
  in
  serve ?domains srv listen_sock;
  Ok ()

(* Like listen_and_serve but binds first and hands the running server, the bound
   port and a thunk that runs the accept pool to [fn] — so tests can connect to
   an ephemeral port and {!close}. The listener lives under [sw]. *)
let listen_and_serve_started ?read_timeout ?read_header_timeout ?write_timeout
    ?idle_timeout ?max_header_bytes ?force_h2 ~net ?clock ?domain_mgr ?domains
    ~sw ~addr ~port handler =
  let srv =
    create ~net ?clock ?domain_mgr ?read_timeout ?read_header_timeout
      ?write_timeout ?idle_timeout ?max_header_bytes ?force_h2 ~addr ~port
      handler
  in
  let* listen_sock =
    Net.listen ~sw net (if addr = "" then "0.0.0.0" else addr) port
  in
  let bound =
    match Net.bound_port listen_sock with
    | Some p -> p
    | None -> assert false (* Net.listen always binds TCP *)
  in
  Ok (srv, bound, fun () -> serve ?domains srv listen_sock)

(* ---- HTTP/2 over TLS (ALPN dispatch) ---- *)

(* The default ALPN protocols advertised by the TLS server (Go's
   http2.NextProtoTLS + "http/1.1"). *)
let default_alpn_protocols = [ "h2"; "http/1.1" ]

(* Serve one accepted TLS connection, branching on the ALPN-negotiated protocol:
   "h2" runs the HTTP/2 server connection; anything else (incl. no ALPN) runs the
   HTTP/1.x serve loop over the TLS channels. *)
let serve_tls_conn ~clock ?graceful ?(timeouts = no_timeouts)
    ?(max_header_bytes = default_max_header_bytes) (handler : handler) tls_srv
    flow peer =
  let remote = Net.sockaddr_to_string peer in
  Net.accept_tls tls_srv flow (fun ~proto r w ->
      match proto with
      | Some "h2" ->
          (* Thread the server's clock + idle/read knobs + graceful trigger into
             the h2 serve loop (Go's serverConn timers + Server.Shutdown). *)
          Httpg_http2.H2_server.serve ~max_header_bytes ?clock
            ~idle_timeout:timeouts.to_idle ~read_timeout:timeouts.to_read
            ?graceful r w
            ~handler:(h2_handler_of_handler handler)
      | _ -> serve_loop ~clock ~timeouts ~max_header_bytes ~r ~w ~remote handler)

(* Go's Server.ServeTLS: accept + handshake each connection in its own fiber,
   dispatch by ALPN, until the accept switches are cancelled. The multicore
   accept pool (per-domain accept loops on the shared listener) carries TLS too;
   the per-connection TLS engine is built inside the handling fiber, so it is
   domain-local, and the RNG it draws from is the stateless getrandom generator
   seeded per domain by [accept_loop_on] (Net.ensure_rng). *)
let serve_tls ?domains srv tls_srv =
  let clock = srv.clock in
  let listen_sock = Net.tls_listen_sock tls_srv in
  let timeouts = timeouts_of_server srv in
  let max_header_bytes = srv.max_header_bytes in
  srv.close_listener <- (fun () -> Eio.Resource.close listen_sock);
  run_accept_pool srv ~domains listen_sock (fun flow peer ->
      (* [srv.graceful] is the fresh promise installed by run_accept_pool. *)
      serve_tls_conn ~clock ~graceful:srv.graceful ~timeouts ~max_header_bytes
        srv.handler tls_srv flow peer)

(* Go's ListenAndServeTLS: bind addr:port with TLS + ALPN and serve. *)
let listen_and_serve_tls ?read_timeout ?read_header_timeout ?write_timeout
    ?idle_timeout ?max_header_bytes ~net ?clock ?domain_mgr ?domains
    ~certificates ?(alpn = default_alpn_protocols) ~addr ~port handler =
  let srv =
    create ~net ?clock ?domain_mgr ?read_timeout ?read_header_timeout
      ?write_timeout ?idle_timeout ?max_header_bytes ~addr ~port handler
  in
  Eio.Switch.run @@ fun sw ->
  let* tls_srv =
    Net.listen_tls ~sw ~certificates ~alpn net
      (if addr = "" then "0.0.0.0" else addr)
      port
  in
  serve_tls ?domains srv tls_srv;
  Ok ()

(* Like listen_and_serve_tls but binds first and returns the running server, the
   bound port and the accept-pool thunk, so tests can connect over an ephemeral
   TLS port and {!close}. The listener lives under [sw]. *)
let listen_and_serve_tls_started ?read_timeout ?read_header_timeout
    ?write_timeout ?idle_timeout ?max_header_bytes ~net ?clock ?domain_mgr
    ?domains ~certificates ?(alpn = default_alpn_protocols) ~sw ~addr ~port
    handler =
  let srv =
    create ~net ?clock ?domain_mgr ?read_timeout ?read_header_timeout
      ?write_timeout ?idle_timeout ?max_header_bytes ~addr ~port handler
  in
  let* tls_srv =
    Net.listen_tls ~sw ~certificates ~alpn net
      (if addr = "" then "0.0.0.0" else addr)
      port
  in
  let bound =
    match Net.bound_port (Net.tls_listen_sock tls_srv) with
    | Some p -> p
    | None -> assert false (* Net.listen_tls always binds TCP *)
  in
  Ok (srv, bound, fun () -> serve_tls ?domains srv tls_srv)
