(* Port of the HTTP/1.x subset of go/src/net/http/client.go: the Client (Do,
   Get, Post, Head) and redirect following (CheckRedirect, default cap of 10).

   Cookie jars, GetBody re-sending and the url.Error wrapping are reduced to the
   HTTP/1.x essentials: redirect method rewriting per redirectBehavior, the
   default 10-redirect cap, sensitive-header stripping across cross-origin
   redirects, and a single Transport.round_trip per hop. *)

(* Go's defaultCheckRedirect: error out after 10 redirects. *)
type check_redirect = Body.t Request.t list -> (unit, string) result

(* Handleable client error: the redirect policy aborted the request (Go's Do
   returning the CheckRedirect error). Surfaced by raising [Aborted], keeping
   Go's [(resp, err)] split as an exception at the [Body.t Response.t] boundary
   (the convenience verbs and the test suite consume that shape). *)
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

let create ~net ?clock ?transport ?(check_redirect = default_check_redirect)
    ?timeout ?insecure ?authenticator () =
  (* An explicit [?transport] is used as-is (it carries its own net/TLS policy).
     Otherwise build a fresh transport capturing the client's net/clock. *)
  let transport =
    match transport with
    | Some t -> t
    | None -> Transport.create ~net ?clock ?insecure ?authenticator ()
  in
  { transport; check_redirect; timeout }

(* Go's redirectBehavior: (redirect_method, should_redirect, include_body). *)
let redirect_behavior ~req_method (resp : Body.t Response.t) =
  match resp.Response.status_code |> Httpg_base.Status.to_int with
  | 301 | 302 | 303 ->
      let redirect_method =
        if
          req_method <> Httpg_base.Method.Get
          && req_method <> Httpg_base.Method.Head
        then Httpg_base.Method.Get
        else req_method
      in
      (redirect_method, true, false)
  | 307 | 308 -> (req_method, true, true)
  | _ -> (req_method, false, false)

(* Sensitive / body headers, for the cross-host redirect strip (Go's
   makeHeadersCopier). *)
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

(* Go's isDomainOrSubdomain (client.go:1026-1048). *)
let is_domain_or_subdomain ~sub ~parent =
  if String.equal sub parent then true
  else if String.exists (function ':' | '%' -> true | _ -> false) sub then false
  else
    let ls = String.length sub and lp = String.length parent in
    ls > lp
    && String.equal (String.sub sub (ls - lp) lp) parent
    && Char.equal sub.[ls - lp - 1] '.'

(* Go's shouldCopyHeaderOnRedirect (client.go:1008-1024). *)
let should_copy_header_on_redirect ~initial ~dest =
  is_domain_or_subdomain ~sub:(url_host dest) ~parent:(url_host initial)

(* Go's refererForURL (client.go:147-170). *)
let referer_for_url ~last ~next ~explicit =
  let scheme u = match Uri.scheme u with Some s -> s | None -> "" in
  if String.equal (scheme last) "https" && String.equal (scheme next) "http"
  then None
  else if explicit <> "" then Some explicit
  else Some (Uri.to_string (Uri.with_userinfo last None))

(* Go's Client.do: the redirect-following loop composing Transport.round_trip.
   [round_trip] is the per-hop round-tripper (defaults to the client's transport);
   it is a parameter so tests can drive the loop against a stub. *)
let do_one ?round_trip c (req : Body.t Request.t) : Body.t Response.t =
  let round_trip =
    match round_trip with
    | Some f -> f
    | None -> fun r -> Transport.round_trip c.transport r
  in
  let initial_header = Header.clone req.Request.header in
  let explicit_referer = Header.get req.Request.header "Referer" in
  (* Sticky strip latch (client.go:691-694): once stripped on a cross-host hop
     it never resets. *)
  let strip_sensitive = ref false in
  let rec loop req via include_body =
    let via = via @ [ req ] in
    let resp = round_trip req in
    let redirect_method, should_redirect, include_body_on_hop =
      redirect_behavior ~req_method:req.Request.meth resp
    in
    if not should_redirect then resp
    else
      match Response.location resp with
      | None -> resp (* 3xx without Location: hand the response back. *)
      | Some loc_url -> (
          (* Drain the previous response body so its connection returns to the
             pool before the next hop (Go reads up to maxBodySlurpSize then
             closes). *)
          ignore (Body.drain resp.Response.body);
          let include_body = include_body && include_body_on_hop in
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
            }
          in
          match c.check_redirect via with
          | Ok () -> loop new_req via include_body
          | Error msg -> raise (Aborted (Redirect msg)))
  in
  loop req [] true

let do_ ~sw c (req : Body.t Request.t) : Body.t Response.t =
  (* The client's [sw] (the session lifetime) owns the transport's pool, so
     pooled conns outlive each round trip but are reclaimed when the client
     session ends. *)
  Transport.run c.transport ~sw @@ fun () ->
  match (c.timeout, Transport.clock c.transport) with
  | Some secs, Some clock ->
      (* Go's Client.Timeout bounds the whole exchange via Eio.Time. *)
      Net.with_timeout clock secs (fun () -> do_one c req)
  | _ -> do_one c req

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
  }

let get ~sw c url = do_ ~sw c (make_request Httpg_base.Method.get url)
let head ~sw c url = do_ ~sw c (make_request Httpg_base.Method.head url)

let post ~sw c url ~content_type body =
  let len =
    match body with
    | Body.String s -> Int64.of_int (String.length s)
    | Body.Empty -> 0L
    | Body.Stream _ -> -1L
  in
  let req = make_request ~body ~content_length:len Httpg_base.Method.post url in
  Header.set req.Request.header "Content-Type" content_type;
  do_ ~sw c req
