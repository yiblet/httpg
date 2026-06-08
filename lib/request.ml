(* Port of go/src/net/http/request.go: the Request type and its pure helpers.
   The body field is parametric so the type stays IO-agnostic; io.ml
   instantiates ['body] to {!Body.t}. *)

(* A multipart file part, the analogue of Go's multipart.FileHeader. A part up
   to the [max_memory] budget is held in [content]; an oversized part is spilled
   to [tmpfile] (formdata.go:174) and [content] is "". *)
type file_header = {
  filename : string;
  fh_header : (string * string) list;  (** the part's MIME header fields *)
  content : string;
  tmpfile : string option;  (** Go FileHeader.tmpfile: spilled-part path. *)
}

(* The analogue of Go's *multipart.Form: named text values plus file parts. *)
type multipart_form = {
  value : Values.t;
  file : (string, file_header list) Hashtbl.t;
}

(* Form.RemoveAll (formdata.go:240): unlink any spilled temp files; idempotent
   (clears [tmpfile]). Bug-only failures (missing file is fine) are swallowed. *)
let remove_multipart_files (file : (string, file_header list) Hashtbl.t) : unit
    =
  Hashtbl.iter
    (fun k fhs ->
      let cleaned =
        List.map
          (fun fh ->
            (match fh.tmpfile with
            | Some path -> ( try Sys.remove path with Sys_error _ -> ())
            | None -> ());
            { fh with tmpfile = None })
          fhs
      in
      Hashtbl.replace file k cleaned)
    file

type 'body t = {
  mutable meth : Httpg_base.Method.t;
  mutable url : Uri.t;
  mutable proto : Httpg_base.Protocol.t;
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

(* Remove any temp files spilled by multipart parsing on [r]; idempotent. Wired
   to a per-request switch by the serve loop and exposed publicly (Go's
   Request.MultipartForm.RemoveAll). Safe to call when nothing spilled. *)
let remove_multipart_temp_files (r : 'a t) : unit =
  match r.multipart_form with
  | Some mf -> remove_multipart_files mf.file
  | None -> ()

(* defaultUserAgent (request.go). *)
let default_user_agent = "Go-http-client/1.1"

(* ParseHTTPVersion(vers): kept as Go's package-level helper; the parsing logic
   now lives in {!Httpg_base.Protocol.of_string}. *)
let parse_http_version (vers : string) : (int * int) option =
  match Httpg_base.Protocol.of_string vers with
  | Some p -> Some (Httpg_base.Protocol.major p, Httpg_base.Protocol.minor p)
  | None -> None

(* Request.ProtoAtLeast. *)
let proto_at_least (r : 'a t) major minor =
  Httpg_base.Protocol.at_least r.proto major minor

(* Request.expectsContinue (request.go:1518): true when the "Expect" header
   carries the [100-continue] token (case-insensitive, token-boundary aware).
   Reuses [Transfer.has_token], the faithful port of header.go's [hasToken]. *)
let expects_continue (r : 'a t) =
  Transfer.has_token (Header.get r.header "Expect") "100-continue"

(* Request.UserAgent. *)
let user_agent (r : 'a t) = Header.get r.header "User-Agent"

(* Request.Referer. *)
let referer (r : 'a t) = Header.get r.header "Referer"

(* Request.Cookies. *)
let cookies (r : 'a t) = Cookie.read_cookies r.header ~filter:""

(* Request.Cookie(name): the named cookie, or None (ErrNoCookie). *)
let cookie (r : 'a t) name =
  if name = "" then None
  else
    match Cookie.read_cookies r.header ~filter:name with
    | c :: _ -> Some c
    | [] -> None

(* Request.AddCookie. *)
let add_cookie (r : 'a t) (c : Cookie.t) =
  let s =
    Printf.sprintf "%s=%s"
      (Cookie.sanitize_cookie_name c.Cookie.name)
      (Cookie.sanitize_cookie_value c.Cookie.value ~quoted:c.Cookie.quoted)
  in
  match Header.get r.header "Cookie" with
  | "" -> r.header <- Header.set r.header "Cookie" s
  | existing -> r.header <- Header.set r.header "Cookie" (existing ^ "; " ^ s)

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
let basic_auth (r : 'a t) : (string * string) option =
  match Header.get r.header "Authorization" with
  | "" -> None
  | auth -> parse_basic_auth auth

(* basicAuth(username, password) (client.go). *)
let basic_auth_encode username password =
  Base64.encode_string (username ^ ":" ^ password)

(* Request.SetBasicAuth. *)
let set_basic_auth (r : 'a t) username password =
  r.header <-
    Header.set r.header "Authorization"
      ("Basic " ^ basic_auth_encode username password)
