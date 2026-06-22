(* Port of go/src/net/http/request.go: the Request type and its pure helpers.

   Form/multipart parsing is NOT cached on the Request (a deliberate deviation
   from Go's in-place mutation): it is done by the composable body parsers
   {!Form.of_body} and {!Multipart.of_body}, which take a [Body.t] and return a
   parsed value. *)

type t = {
  mutable meth : Httpg_base.Method.t;
  mutable url : Uri.t;
  mutable proto : Httpg_base.Protocol.t;
  mutable header : Header.t;
  mutable body : Body.t;
  mutable content_length : int64 option; (* None = unknown (Go's -1) *)
  mutable transfer_encoding : string list;
  mutable close : bool;
  mutable host : string option; (* None = derive from URL *)
  mutable trailer : Header.t option;
  mutable request_uri : string option;
  mutable remote_addr : string option;
}

(* defaultUserAgent (request.go). *)
let default_user_agent = "Go-http-client/1.1"

(* Smart constructor (Go's NewRequest): [url] is required; everything else is an
   optional field. [host] defaults to the URL's host (Go sets [req.Host] from the
   parsed URL); pass [~host] to override. No zero-value record to start from. *)
let make ?(meth = Httpg_base.Method.Get) ?(proto = Httpg_base.Protocol.Http11)
    ?(header = Header.empty) ?(body = Body.empty) ?content_length
    ?(transfer_encoding = []) ?(close = false) ?host ?(trailer = None)
    ?request_uri ?remote_addr url =
  {
    meth;
    url;
    proto;
    (* Like Go's [NewRequest]: an explicit [content_length] wins (negative means
       unknown, Go's -1); otherwise inherit the body's known length when it has
       one (a string/in-memory body), else leave it unknown. *)
    content_length =
      (match content_length with
      | Some n -> if Int64.compare n 0L < 0 then None else Some n
      | None -> Body.content_length body);
    header;
    body;
    transfer_encoding;
    close;
    host = (match host with Some _ as h -> h | None -> Uri.host url);
    trailer;
    request_uri;
    remote_addr;
  }

(* ParseHTTPVersion(vers): kept as Go's package-level helper; the parsing logic
   now lives in {!Httpg_base.Protocol.of_string}. *)
let parse_http_version (vers : string) : (int * int) option =
  match Httpg_base.Protocol.of_string vers with
  | Some p -> Some (Httpg_base.Protocol.major p, Httpg_base.Protocol.minor p)
  | None -> None

(* Request.ProtoAtLeast. *)
let proto_at_least (r : t) major minor =
  Httpg_base.Protocol.at_least r.proto major minor

(* Request.expectsContinue (request.go:1518): true when the "Expect" header
   carries the [100-continue] token (case-insensitive, token-boundary aware).
   Reuses [Transfer.has_token], the faithful port of header.go's [hasToken]. *)
let expects_continue (r : t) =
  match Header.get r.header "Expect" with
  | None -> false
  | Some s -> Transfer.has_token s "100-continue"

(* Request.UserAgent. *)
let user_agent (r : t) = Header.get r.header "User-Agent"

(* Request.Referer. *)
let referer (r : t) = Header.get r.header "Referer"

(* Request.Cookies. *)
let cookies (r : t) = Cookie.read_cookies r.header ~filter:None

(* Request.Cookie(name): the named cookie, or None (ErrNoCookie). *)
let cookie (r : t) name =
  if name = "" then None
  else
    match Cookie.read_cookies r.header ~filter:(Some name) with
    | c :: _ -> Some c
    | [] -> None

(* Request.AddCookie. *)
let add_cookie (r : t) (c : Cookie.t) =
  let s =
    Printf.sprintf "%s=%s"
      (Cookie.sanitize_cookie_name c.Cookie.name)
      (Cookie.sanitize_cookie_value c.Cookie.value ~quoted:c.Cookie.quoted)
  in
  match Header.get r.header "Cookie" with
  | None -> r.header <- Header.set "Cookie" s r.header
  | Some existing ->
      r.header <- Header.set "Cookie" (existing ^ "; " ^ s) r.header

(* The parsed Authorization header, or None if absent or malformed (subsumes
   Go's BasicAuth/SetBasicAuth, generalised over the scheme via {!Authorization}). *)
let auth (r : t) : Authorization.t option =
  match Header.get r.header "Authorization" with
  | None -> None
  | Some v -> Authorization.of_string v |> Result.to_option

(* Set the Authorization header from a typed {!Authorization.t}. *)
let set_auth (r : t) (a : Authorization.t) =
  r.header <- Header.set "Authorization" (Authorization.to_string a) r.header
