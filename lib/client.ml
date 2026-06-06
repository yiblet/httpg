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

(* Go's isDomainOrSubdomain (client.go:1026-1048): whether [sub] is a subdomain
   of (or an exact match for) [parent]. Both are expected in canonical (host,
   no-port) form. An exact match keeps the headers; a [:] or [%] in [sub] marks
   it as an IPv6 literal/zone, which never matches a hostname suffix; otherwise
   [sub] must end in ["." ^ parent]. *)
let is_domain_or_subdomain ~sub ~parent =
  if String.equal sub parent then true
  else if String.exists (function ':' | '%' -> true | _ -> false) sub then false
  else
    let ls = String.length sub and lp = String.length parent in
    (* strings.HasSuffix(sub, parent) && sub[len(sub)-len(parent)-1] == '.' *)
    ls > lp
    && String.equal (String.sub sub (ls - lp) lp) parent
    && Char.equal sub.[ls - lp - 1] '.'

(* Go's shouldCopyHeaderOnRedirect (client.go:1008-1024): permit sending
   auth/cookie headers from "foo.com" to "foo.com" or "sub.foo.com". Go runs
   both hosts through idnaASCIIFromURL first; this port has no IDNA helper, so
   it uses the raw (already-ASCII) hostnames, which is exactly Go's fallback
   when idnaASCII reports no error (request.go:786-800). The suffix/"."/IPv6
   logic matches isDomainOrSubdomain exactly. *)
let should_copy_header_on_redirect ~initial ~dest =
  is_domain_or_subdomain ~sub:(url_host dest) ~parent:(url_host initial)

(* Go's refererForURL (client.go:147-170): the Referer to set on the next hop,
   computed from the previous hop's URL. Returns [None] (omit Referer) when the
   previous request used https and the next uses http; otherwise the previous
   URL with any userinfo stripped. [explicit] is a Referer the user set on the
   original request, which is preserved. *)
let referer_for_url ~last ~next ~explicit =
  let scheme u = match Uri.scheme u with Some s -> s | None -> "" in
  if String.equal (scheme last) "https" && String.equal (scheme next) "http"
  then None
  else if explicit <> "" then Some explicit
  else
    (* lastReq.String() with the userinfo ("user:pass@") removed. *)
    Some (Uri.to_string (Uri.with_userinfo last None))

(* Go's Client.do: the redirect-following loop composing Transport.round_trip.
   [round_trip] is the per-hop round-tripper (defaults to the client's
   transport); it is a parameter so tests can drive the redirect loop against a
   stub that captures the headers seen on each hop and returns canned
   redirects. *)
let do_one ?round_trip c (req : Body.t Request.t) : Body.t Response.t Lwt.t =
  let round_trip =
    match round_trip with
    | Some f -> f
    | None -> fun r -> Transport.round_trip c.transport r
  in
  let initial_header = Header.clone req.Request.header in
  (* The user's explicit Referer on the original request, preserved by
     refererForURL across hops (client.go:147,:155-157). *)
  let explicit_referer = Header.get req.Request.header "Referer" in
  (* sticky strip latch: once stripped on a cross-host hop it never resets, even
     when the chain bounces back to the initial host (client.go:691-694). *)
  let strip_sensitive = ref false in
  let rec loop req via include_body =
    let via = via @ [ req ] in
    round_trip req >>= fun resp ->
    let redirect_method, should_redirect, include_body_on_hop =
      redirect_behavior ~req_method:req.Request.meth resp
    in
    if not should_redirect then Lwt.return resp
    else
      match Response.location resp with
      | None ->
          (* 3xx without Location: hand the response back, as Go does. *)
          Lwt.return resp
      | Some loc_url -> (
          (* Drain the previous response body so its connection returns to the
             idle pool before the next hop (Go reads up to [maxBodySlurpSize]
             then closes — closing releases the connection). The body now
             streams, so this drain is what actually advances the connection to
             EOF and fires its pool-return action; without it the next hop would
             dial a fresh connection. *)
          Body.drain resp.Response.body
          >>= fun _ ->
          let include_body = include_body && include_body_on_hop in
          (* Sticky, subdomain-aware strip vs the INITIAL request (client.go:
             691-694): the initial host is [List.hd via] (the first request
             made), [loc_url] is the destination. Once latched, stays latched. *)
          let initial_req = List.hd via in
          if
            (not !strip_sensitive)
            && url_host initial_req.Request.url <> url_host loc_url
            && not
                 (should_copy_header_on_redirect
                    ~initial:initial_req.Request.url ~dest:loc_url)
          then strip_sensitive := true;
          let new_header = Header.create () in
          copy_headers ~from:initial_header ~into:new_header
            ~strip_sensitive:!strip_sensitive ~strip_body:(not include_body);
          (* Referer from the PREVIOUS hop's URL (client.go:698), omitted on
             https->http. [req] is the request we just made (the last hop). *)
          (match
             referer_for_url ~last:req.Request.url ~next:loc_url
               ~explicit:explicit_referer
           with
          | Some ref_ -> Header.set new_header "Referer" ref_
          | None -> ());
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
          match c.check_redirect via with
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
            | None ->
                cancel Context.Canceled;
                Lwt.return_none)
          (fun exn ->
            cancel Context.Canceled;
            Lwt.fail exn)
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
        (fun resp -> Lwt.return (wrap_timer_body ~cancel resp))
        (fun exn ->
          cancel Context.Canceled;
          Lwt.fail exn)

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
