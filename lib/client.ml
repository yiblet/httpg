(* Port of the HTTP/1.x subset of go/src/net/http/client.go: the Client (Do,
   Get, Post, Head) and redirect following (CheckRedirect, default cap of 10).

   Cookie jars, timeouts-as-deadlines, the makeHeadersCopier sensitive-header
   stripping across cross-origin redirects, GetBody re-sending and the
   url.Error wrapping are reduced to the HTTP/1.x essentials: redirect method
   rewriting per redirectBehavior, the default 10-redirect cap, and a single
   composed Transport.round_trip per hop. *)

open Lwt.Infix

(* Go's defaultCheckRedirect: error out after 10 redirects. Modeled as a policy
   function [via -> unit result] so callers can override the cap. *)
type check_redirect = Body.t Request.t list -> (unit, string) result

(* Handleable client error: the redirect policy aborted the request (Go's Do
   returning the CheckRedirect error wrapped in a *url.Error). [do_] surfaces it
   by raising [Aborted] (it keeps Go's [(resp, err)] split as an exception at the
   [Body.t Response.t Lwt.t] boundary, since the convenience verbs and the test
   suite consume that shape). *)
type error = Redirect of string

let error_to_string = function Redirect s -> "http: " ^ s

exception Aborted of error

let default_check_redirect : check_redirect =
 fun via ->
  if List.length via >= 10 then Error "stopped after 10 redirects" else Ok ()

type t = {
  transport : Transport.t;
  check_redirect : check_redirect;
  timeout : float option;  (** Go's [Client.Timeout]; [None] = no timeout. *)
}

let create ?transport ?(check_redirect = default_check_redirect) ?timeout
    ?insecure ?authenticator () =
  (* Resolve the transport. An explicit [?transport] is used as-is (it already
     carries its own TLS policy). Otherwise, if a TLS verification override is
     requested, build a fresh transport carrying it; with no override at all we
     reuse the shared [default_transport] (secure by default). *)
  let transport =
    match transport with
    | Some t -> t
    | None -> (
        match (insecure, authenticator) with
        | None, None -> Transport.default_transport
        | _ -> Transport.create ?insecure ?authenticator ())
  in
  { transport; check_redirect; timeout }

let default_client = create ()

(* Go's redirectBehavior: given the request method and the response, return
   (redirect_method, should_redirect, include_body). *)
let redirect_behavior ~req_method (resp : Body.t Response.t) =
  match resp.Response.status_code with
  | 301 | 302 | 303 ->
      let redirect_method =
        if req_method <> "GET" && req_method <> "HEAD" then "GET"
        else req_method
      in
      (redirect_method, true, false)
  | 307 | 308 -> (req_method, true, true)
  | _ -> (req_method, false, false)

(* The headers copied from the initial request onto each redirect hop, minus
   sensitive ones on a cross-host redirect and body-related ones when the body
   is dropped (Go's makeHeadersCopier). *)
let sensitive_header k =
  match Header.canonical_header_key k with
  | "Authorization" | "Www-Authenticate" | "Cookie" | "Cookie2"
  | "Proxy-Authorization" | "Proxy-Authenticate" ->
      true
  | _ -> false

let body_header k =
  match Header.canonical_header_key k with
  | "Content-Encoding" | "Content-Language" | "Content-Location"
  | "Content-Type" ->
      true
  | _ -> false

let copy_headers ~from ~into ~strip_sensitive ~strip_body =
  Hashtbl.iter
    (fun k vv ->
      if
        (not (sensitive_header k && strip_sensitive))
        && not (body_header k && strip_body)
      then Hashtbl.replace into k vv)
    from

let url_host (u : Uri.t) = match Uri.host u with Some h -> h | None -> ""

(* Go's Client.do: the redirect-following loop composing Transport.round_trip. *)
let do_one c (req : Body.t Request.t) : Body.t Response.t Lwt.t =
  let initial_header = Header.clone req.Request.header in
  let initial_host = url_host req.Request.url in
  let rec loop req via include_body =
    let via = via @ [ req ] in
    Transport.round_trip c.transport req >>= fun resp ->
    let redirect_method, should_redirect, include_body_on_hop =
      redirect_behavior ~req_method:req.Request.meth resp
    in
    if not should_redirect then Lwt.return resp
    else
      match Response.location resp with
      | None ->
          (* 3xx without Location: hand the response back, as Go does. *)
          Lwt.return resp
      | Some loc_url ->
          (* Drain the previous response body so its connection returns to the
             idle pool before the next hop (Go reads up to [maxBodySlurpSize]
             then closes — closing releases the connection). The body now
             streams, so this drain is what actually advances the connection to
             EOF and fires its pool-return action; without it the next hop would
             dial a fresh connection. *)
          Body.drain resp.Response.body >>= fun () ->
          let include_body = include_body && include_body_on_hop in
          let strip_sensitive = url_host loc_url <> initial_host in
          let new_header = Header.create () in
          copy_headers ~from:initial_header ~into:new_header
            ~strip_sensitive ~strip_body:(not include_body);
          let new_req =
            {
              Request.meth = redirect_method;
              url = loc_url;
              proto = "HTTP/1.1";
              proto_major = 1;
              proto_minor = 1;
              header = new_header;
              body = (if include_body then req.Request.body else Body.Empty);
              content_length =
                (if include_body then req.Request.content_length else 0L);
              transfer_encoding =
                (if include_body then req.Request.transfer_encoding else []);
              close = false;
              host = "";
              trailer = None;
              request_uri = "";
              remote_addr = "";
              form = None;
              post_form = None;
              multipart_form = None;
              (* Go's redirect path clones the original request, preserving its
                 context so the overall deadline still bounds later hops. *)
              ctx = req.Request.ctx;
            }
          in
          (match c.check_redirect via with
          | Ok () -> loop new_req via include_body
          | Error msg -> Lwt.fail (Aborted (Redirect msg)))
  in
  loop req [] true

(* Wrap [resp]'s body so that reaching EOF (or a read failure) disarms the
   deadline timer via [cancel] (Go's [cancelTimerBody.Read]/[Close] stopping the
   timer once the body is fully consumed). [cancel] is idempotent on the context
   (a second call after [done_] is a no-op), so this is safe even if the body is
   never read (the timer then fires and disarms itself). Empty/String bodies are
   already complete: disarm immediately. *)
let wrap_timer_body ~cancel (resp : Body.t Response.t) : Body.t Response.t =
  (match resp.Response.body with
  | Body.Empty | Body.String _ -> cancel Context.Canceled
  | Body.Stream inner ->
    let next () =
      Lwt.try_bind
        (fun () -> inner ())
        (function
          | Some _ as chunk -> Lwt.return chunk
          | None -> cancel Context.Canceled; Lwt.return_none)
        (fun exn -> cancel Context.Canceled; Lwt.fail exn)
    in
    resp.Response.body <- Body.Stream next);
  resp

let do_ ?context c (req : Body.t Request.t) : Body.t Response.t Lwt.t =
  (* Apply the caller-supplied per-request context (Go's req.Context()) before
     the exchange; when omitted the request keeps its existing [ctx]. *)
  (match context with Some ctx -> req.Request.ctx <- ctx | None -> ());
  match c.timeout with
  | None -> do_one c req
  | Some secs ->
      (* Go's Client.Timeout = context.WithDeadline over the request context,
         covering the whole exchange {b including the streaming body read} (Go's
         [cancelTimerBody] wraps [resp.Body] so the deadline keeps running until
         the body is consumed). Our response body now streams, and
         {!Transport.round_trip} races each body read against the same request
         context — so the deadline applies until the caller drains/reads the
         body. We therefore must NOT cancel the timer when [do_one] returns the
         response (the headers arrived but the body is still in flight); doing so
         would let an unbounded body read run past the deadline. Instead, on
         success we leave the deadline armed and {b wrap the response body} so
         that draining it to EOF (or a context cancellation) disarms the timer
         — mirroring [cancelTimerBody.Close]/EOF stopping the timer. On failure
         (the deadline fired, or any other error) we cancel and re-raise. *)
      let ctx, cancel = Context.with_timeout req.Request.ctx secs in
      let req = Request.with_context req ctx in
      Lwt.try_bind
        (fun () -> do_one c req)
        (fun resp ->
          Lwt.return (wrap_timer_body ~cancel resp))
        (fun exn -> cancel Context.Canceled; Lwt.fail exn)

(* ---- Request builders + convenience verbs (Go's NewRequest + Get/Post/Head). *)

let make_request ?(body = Body.Empty) ?(content_length = 0L) meth url_str =
  let url = Uri.of_string url_str in
  let header = Header.create () in
  let host = match Uri.host url with Some h -> h | None -> "" in
  {
    Request.meth;
    url;
    proto = "HTTP/1.1";
    proto_major = 1;
    proto_minor = 1;
    header;
    body;
    content_length;
    transfer_encoding = [];
    close = false;
    host;
    trailer = None;
    request_uri = "";
    remote_addr = "";
    form = None;
    post_form = None;
    multipart_form = None;
    ctx = Context.background;
  }

let get ?context c url = do_ ?context c (make_request Method.get url)

let head ?context c url = do_ ?context c (make_request Method.head url)

let post ?context c url ~content_type body =
  let len =
    match body with
    | Body.String s -> Int64.of_int (String.length s)
    | Body.Empty -> 0L
    | Body.Stream _ -> -1L
  in
  let req = make_request ~body ~content_length:len Method.post url in
  Header.set req.Request.header "Content-Type" content_type;
  do_ ?context c req
