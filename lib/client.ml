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

let default_check_redirect : check_redirect =
 fun via ->
  if List.length via >= 10 then Error "stopped after 10 redirects" else Ok ()

type t = {
  transport : Transport.t;
  check_redirect : check_redirect;
  timeout : float option;  (** Go's [Client.Timeout]; [None] = no timeout. *)
}

let create ?(transport = Transport.default_transport)
    ?(check_redirect = default_check_redirect) ?timeout () =
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
          (* Drain/close the previous response body so the connection can be
             reused (Go reads up to maxBodySlurpSize then closes). The body is
             already materialized; nothing to drain. *)
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
            }
          in
          (match c.check_redirect via with
          | Ok () -> loop new_req via include_body
          | Error msg -> Lwt.fail (Failure ("http: " ^ msg)))
  in
  loop req [] true

let do_ c (req : Body.t Request.t) : Body.t Response.t Lwt.t =
  match c.timeout with
  | None -> do_one c req
  | Some secs -> Net.with_timeout secs (do_one c req)

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

let get c url = do_ c (make_request Method.get url)

let head c url = do_ c (make_request Method.head url)

let post c url ~content_type body =
  let len =
    match body with
    | Body.String s -> Int64.of_int (String.length s)
    | Body.Empty -> 0L
    | Body.Stream _ -> -1L
  in
  let req = make_request ~body ~content_length:len Method.post url in
  Header.set req.Request.header "Content-Type" content_type;
  do_ c req
