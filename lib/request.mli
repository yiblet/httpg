(* Port of go/src/net/http/request.go: the Request type and pure helpers.
   The IO halves (readRequest / Request.Write) live in {!Io}. Multipart/form
   parsing, GetBody, Cancel, TLS and context fields are intentionally omitted
   (deferred). *)

(** A multipart file part, the analogue of Go's [multipart.FileHeader]. The
    contents are held in memory (the multipart_form-lwt stand-in materializes
    parts as strings). *)
type file_header = {
  filename : string;
  fh_header : (string * string) list;
  content : string;
}

(** The analogue of Go's [*multipart.Form]: named text values and file parts. *)
type multipart_form = {
  value : Values.t;
  file : (string, file_header list) Hashtbl.t;
}

(** A request mirroring Go's [Request] struct. The body field is parametric so
    the type carries no IO dependency; {!Io} instantiates ['body] to
    {!Body.t}. *)
type 'body t = {
  mutable meth : string;  (** Go [Method]; "" means GET for client requests *)
  mutable url : Uri.t;  (** Go [URL] (a [*url.URL] modeled as [Uri.t]) *)
  mutable proto : string;  (** e.g. "HTTP/1.0" *)
  mutable proto_major : int;
  mutable proto_minor : int;
  mutable header : Header.t;
  mutable body : 'body;
  mutable content_length : int64;  (** -1 means unknown *)
  mutable transfer_encoding : string list;
  mutable close : bool;
  mutable host : string;
  mutable trailer : Header.t option;
  mutable request_uri : string;
  mutable remote_addr : string;
  mutable form : Values.t option;
      (** Go [Form]: query + urlencoded body params; [None] until parsed. *)
  mutable post_form : Values.t option;  (** Go [PostForm]: body params only. *)
  mutable multipart_form : multipart_form option;  (** Go [MultipartForm]. *)
}

(** [defaultUserAgent]. *)
val default_user_agent : string

(** [ParseHTTPVersion vers]: [Some (major, minor)] on success, [None] on a
    malformed version. *)
val parse_http_version : string -> (int * int) option

(** [Request.ProtoAtLeast]. *)
val proto_at_least : 'a t -> int -> int -> bool

(** [Request.UserAgent]: the "User-Agent" header value, or "". *)
val user_agent : 'a t -> string

(** [Request.Referer]: the "Referer" header value, or "". *)
val referer : 'a t -> string

(** [Request.Cookies]: all cookies in the "Cookie" header. *)
val cookies : 'a t -> Cookie.t list

(** [Request.Cookie name]: the named cookie, or [None] (Go's [ErrNoCookie]). *)
val cookie : 'a t -> string -> Cookie.t option

(** [Request.AddCookie]: append a single cookie to the "Cookie" header
    (RFC 6265 5.4: one Cookie header field, semicolon-separated). *)
val add_cookie : 'a t -> Cookie.t -> unit

(** [parseBasicAuth auth]: [Some (username, password)] or [None]. *)
val parse_basic_auth : string -> (string * string) option

(** [Request.BasicAuth]: parse the "Authorization" header. *)
val basic_auth : 'a t -> (string * string) option

(** [basicAuth username password] (client.go): the base64 credential. *)
val basic_auth_encode : string -> string -> string

(** [Request.SetBasicAuth]: set the "Authorization" header. *)
val set_basic_auth : 'a t -> string -> string -> unit
