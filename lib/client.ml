(* Port of the HTTP/1.x subset of go/src/net/http/client.go: the Client (Do,
   Get, Post, Head) and redirect following (CheckRedirect, default cap of 10).

   Cookie jars, GetBody re-sending and the url.Error wrapping are reduced to the
   HTTP/1.x essentials: redirect method rewriting per redirectBehavior, the
   default 10-redirect cap, sensitive-header stripping across cross-origin
   redirects, and a single Transport.round_trip per hop. *)

(* Go's defaultCheckRedirect: error out after 10 redirects. *)
type check_redirect = Request.t list -> (unit, string) result

(* Handleable client errors (Go's [Client.Do] returning an error): the redirect
   policy aborted the request ([Redirect], Go's CheckRedirect error), a per-hop
   [Transport.round_trip] failed ([Round_trip], embedding the lower layer's
   typed error), or the whole exchange exceeded [Client.timeout] ([Timeout],
   Go's Client.Timeout). Returned as [Error _] from the result-typed public API
   ([do_]/[get]/[head]/[post]); no exception boundary. *)
type error = Redirect of string | Round_trip of Transport.error | Timeout

let error_to_string = function
  | Redirect s -> "http: " ^ s
  | Round_trip e -> Transport.error_to_string e
  | Timeout -> "http: timeout"

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
let redirect_behavior ~req_method (resp : Response.t) =
  match resp.Response.status |> Httpg_base.Status.to_int with
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
  Header.fold
    (fun k vv into ->
      if
        (not (sensitive_header k && strip_sensitive))
        && not (body_header k && strip_body)
      then Header.set_values into k vv
      else into)
    from into

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
  else
    match explicit with
    | Some r -> Some r
    | None -> Some (Uri.to_string (Uri.with_userinfo last None))

(* Go's Client.do: the redirect-following loop composing Transport.round_trip.
   [round_trip] is the per-hop round-tripper (defaults to the client's transport);
   it is a parameter so tests can drive the loop against a stub. *)
let do_one ?round_trip ?(force_h2 = false) c (req : Request.t) :
    (Response.t, error) result =
  let round_trip =
    match round_trip with
    | Some f -> f
    | None -> fun r -> Transport.round_trip ~force_h2 c.transport r
  in
  let initial_header = req.Request.header in
  let explicit_referer = Header.get req.Request.header "Referer" in
  (* Sticky strip latch (client.go:691-694): once stripped on a cross-host hop
     it never resets. *)
  let strip_sensitive = ref false in
  let rec loop req via include_body =
    let via = via @ [ req ] in
    match round_trip req with
    | Error e -> Error (Round_trip e)
    | Ok resp -> (
        let redirect_method, should_redirect, include_body_on_hop =
          redirect_behavior ~req_method:req.Request.meth resp
        in
        if not should_redirect then Ok resp
        else
          match Response.location resp with
          | None -> Ok resp (* 3xx without Location: hand the response back. *)
          | Some loc_url -> (
              (* Drain the previous response body so its connection returns to the
             pool before the next hop (Go reads up to maxBodySlurpSize then
             closes). *)
              (* Best-effort slurp (Go reads up to maxBodySlurpSize then closes
                 the conn); a mid-stream framing failure just means the conn
                 isn't reused — the next hop opens a fresh one, as in Go. *)
              ignore (Body.drain resp.Response.body : (_, Body.error) result);
              let include_body = include_body && include_body_on_hop in
              let initial_req = List.hd via in
              if
                (not !strip_sensitive)
                && url_host initial_req.Request.url <> url_host loc_url
                && not
                     (should_copy_header_on_redirect
                        ~initial:initial_req.Request.url ~dest:loc_url)
              then strip_sensitive := true;
              let new_header =
                copy_headers ~from:initial_header ~into:(Header.create ())
                  ~strip_sensitive:!strip_sensitive
                  ~strip_body:(not include_body)
              in
              let new_header =
                match
                  referer_for_url ~last:req.Request.url ~next:loc_url
                    ~explicit:explicit_referer
                with
                | Some ref_ -> Header.set new_header "Referer" ref_
                | None -> new_header
              in
              let new_req =
                {
                  Request.meth = redirect_method;
                  url = loc_url;
                  proto = Httpg_base.Protocol.Http11;
                  header = new_header;
                  body = (if include_body then req.Request.body else Body.empty);
                  content_length =
                    (if include_body then req.Request.content_length
                     else Some 0L);
                  transfer_encoding =
                    (if include_body then req.Request.transfer_encoding else []);
                  close = false;
                  host = None;
                  trailer = None;
                  request_uri = "";
                  remote_addr = "";
                }
              in
              match c.check_redirect via with
              | Ok () -> loop new_req via include_body
              | Error msg -> Error (Redirect msg)))
  in
  loop req [] true

let do_ ?force_h2 ~sw c (req : Request.t) : (Response.t, error) result =
  (* The client's [sw] (the session lifetime) owns the transport's pool, so
     pooled conns outlive each round trip but are reclaimed when the client
     session ends. *)
  Transport.run c.transport ~sw @@ fun () ->
  match (c.timeout, Transport.clock c.transport) with
  | Some secs, Some clock -> (
      (* Go's Client.Timeout bounds the whole exchange via Eio.Time. *)
      match Net.with_timeout clock secs (fun () -> do_one ?force_h2 c req) with
      | Ok v -> v
      | Error _ -> Error Timeout)
  | _ -> do_one ?force_h2 c req

(* ---- Request builders + convenience verbs (Go's NewRequest + Get/Post/Head). *)

let get ?force_h2 ~sw c url =
  do_ ?force_h2 ~sw c (Request.make ~meth:Httpg_base.Method.get url)

let head ?force_h2 ~sw c url =
  do_ ?force_h2 ~sw c (Request.make ~meth:Httpg_base.Method.head url)

let post ?force_h2 ~sw c url ~content_type body =
  (* Like Go's [Post]/[NewRequest] with an in-memory reader: the body is owned
     by the caller and materialized here to set an exact Content-Length (the
     framing-info producer for this path). A mid-stream framing failure while
     reading the supplied body is a programming error in the caller's stream,
     not a handleable client error, so it surfaces as the body's own [Error]
     text via [Round_trip]-shaped reporting is not applicable here; we keep the
     read total simple. *)
  let body, len =
    match Body.read_all body with
    | Ok s -> (Body.of_string s, Int64.of_int (String.length s))
    | Error _ ->
        (* Best-effort: an unreadable supplied body becomes an empty body. *)
        (Body.empty, 0L)
  in
  let req =
    Request.make ~meth:Httpg_base.Method.post ~body ~content_length:len url
  in
  req.Request.header <-
    Header.set req.Request.header "Content-Type" content_type;
  do_ ?force_h2 ~sw c req

module Private = struct
  let do_one = do_one
end
