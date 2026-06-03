(* Port of go/src/net/http/request.go: the Request type and its pure helpers.
   The body field is parametric so the type stays IO-agnostic; io.ml
   instantiates ['body] to {!Body.t}. *)

(* A multipart file part, the analogue of Go's multipart.FileHeader. Contents
   are held in memory (the multipart_form-lwt stand-in materializes parts as
   strings; Go spills large parts to temp files). *)
type file_header = {
  filename : string;
  fh_header : (string * string) list;  (** the part's MIME header fields *)
  content : string;
}

(* The analogue of Go's *multipart.Form: named text values plus file parts. *)
type multipart_form = {
  value : Values.t;
  file : (string, file_header list) Hashtbl.t;
}

type 'body t = {
  mutable meth : string;
  mutable url : Uri.t;
  mutable proto : string;
  mutable proto_major : int;
  mutable proto_minor : int;
  mutable header : Header.t;
  mutable body : 'body;
  mutable content_length : int64;
  mutable transfer_encoding : string list;
  mutable close : bool;
  mutable host : string;
  mutable trailer : Header.t option;
  mutable request_uri : string;
  mutable remote_addr : string;
  (* Form parsing state (Ticket 11), populated lazily by {!Form}. Optionals
     default to [None] so existing constructors are unaffected. Go mutates the
     Request in place; these mutable fields mirror that. *)
  mutable form : Values.t option;
  mutable post_form : Values.t option;
  mutable multipart_form : multipart_form option;
}

(* defaultUserAgent (request.go). *)
let default_user_agent = "Go-http-client/1.1"

(* ParseHTTPVersion(vers). *)
let parse_http_version (vers : string) : (int * int) option =
  match vers with
  | "HTTP/1.1" -> Some (1, 1)
  | "HTTP/1.0" -> Some (1, 0)
  | _ ->
    let prefix = "HTTP/" in
    let n = String.length vers in
    if n <> String.length "HTTP/X.Y" then None
    else if not (String.length vers >= 5 && String.sub vers 0 5 = prefix) then None
    else if vers.[6] <> '.' then None
    else begin
      (* strconv.ParseUint on a single digit: reject non-digit, '+', leading
         signs. Single char so leading zeros are not an issue here. *)
      let parse_digit c = if c >= '0' && c <= '9' then Some (Char.code c - Char.code '0') else None in
      match (parse_digit vers.[5], parse_digit vers.[7]) with
      | Some maj, Some min -> Some (maj, min)
      | _ -> None
    end

(* Request.ProtoAtLeast. *)
let proto_at_least (r : 'a t) major minor =
  r.proto_major > major || (r.proto_major = major && r.proto_minor >= minor)

(* Request.UserAgent. *)
let user_agent (r : 'a t) = Header.get r.header "User-Agent"

(* Request.Referer. *)
let referer (r : 'a t) = Header.get r.header "Referer"

(* Request.Cookies. *)
let cookies (r : 'a t) = Cookie.read_cookies r.header ~filter:""

(* Request.Cookie(name): the named cookie, or None (ErrNoCookie). *)
let cookie (r : 'a t) name =
  if name = "" then None
  else match Cookie.read_cookies r.header ~filter:name with c :: _ -> Some c | [] -> None

(* Request.AddCookie. *)
let add_cookie (r : 'a t) (c : Cookie.t) =
  let s =
    Printf.sprintf "%s=%s"
      (Cookie.sanitize_cookie_name c.Cookie.name)
      (Cookie.sanitize_cookie_value c.Cookie.value ~quoted:c.Cookie.quoted)
  in
  match Header.get r.header "Cookie" with
  | "" -> Header.set r.header "Cookie" s
  | existing -> Header.set r.header "Cookie" (existing ^ "; " ^ s)

(* parseBasicAuth(auth). *)
let parse_basic_auth (auth : string) : (string * string) option =
  let prefix = "Basic " in
  let lp = String.length prefix in
  let eq_fold_prefix s =
    String.length s >= lp
    && Gohttp_internal.Ascii.equal_fold (String.sub s 0 lp) prefix
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
      | Some i -> Some (String.sub cs 0 i, String.sub cs (i + 1) (String.length cs - i - 1)))

(* Request.BasicAuth. *)
let basic_auth (r : 'a t) : (string * string) option =
  match Header.get r.header "Authorization" with
  | "" -> None
  | auth -> parse_basic_auth auth

(* basicAuth(username, password) (client.go). *)
let basic_auth_encode username password = Base64.encode_string (username ^ ":" ^ password)

(* Request.SetBasicAuth. *)
let set_basic_auth (r : 'a t) username password =
  Header.set r.header "Authorization" ("Basic " ^ basic_auth_encode username password)
