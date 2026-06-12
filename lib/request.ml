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
  mutable content_length : int64;
  mutable transfer_encoding : string list;
  mutable close : bool;
  mutable host : string option;
  mutable trailer : Header.t option;
  mutable request_uri : string option;
  mutable remote_addr : string option;
}

(* defaultUserAgent (request.go). *)
let default_user_agent = "Go-http-client/1.1"

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
let cookies (r : t) = Cookie.read_cookies r.header ~filter:""

(* Request.Cookie(name): the named cookie, or None (ErrNoCookie). *)
let cookie (r : t) name =
  if name = "" then None
  else
    match Cookie.read_cookies r.header ~filter:name with
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
  | None -> r.header <- Header.set r.header "Cookie" s
  | Some existing ->
      r.header <- Header.set r.header "Cookie" (existing ^ "; " ^ s)

(* parseBasicAuth(auth). *)
let parse_basic_auth (auth : string) : (string * string) option =
  let prefix = "Basic " in
  let lp = String.length prefix in
  let eq_fold_prefix s =
    String.length s >= lp
    && Httpg_internal.Ascii.equal_fold (String.sub s 0 lp) prefix
  in
  if String.length auth < lp || not (eq_fold_prefix auth) then None
  else
    match
      match Base64.decode (String.sub auth lp (String.length auth - lp)) with
      | Ok s -> Some s
      | Error _ -> None
      | exception _ -> None
    with
    | None -> None
    | Some cs -> (
        match String.index_opt cs ':' with
        | None -> None
        | Some i ->
            Some
              ( String.sub cs 0 i,
                String.sub cs (i + 1) (String.length cs - i - 1) ))

(* Request.BasicAuth. *)
let basic_auth (r : t) : (string * string) option =
  match Header.get r.header "Authorization" with
  | None -> None
  | Some auth -> parse_basic_auth auth

(* basicAuth(username, password) (client.go). *)
let basic_auth_encode username password =
  Base64.encode_string (username ^ ":" ^ password)

(* Request.SetBasicAuth. *)
let set_basic_auth (r : t) username password =
  r.header <-
    Header.set r.header "Authorization"
      ("Basic " ^ basic_auth_encode username password)
