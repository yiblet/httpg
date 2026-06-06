(* Port of go/src/net/http/request.go: the Request type and pure helpers.
   The IO halves (readRequest / Request.Write) live in {!Io}. Multipart/form
   parsing, GetBody, Cancel, TLS and context fields are intentionally omitted
   (deferred). *)

type file_header = {
  filename : string;
  fh_header : (string * string) list;
  content : string;
}
(** A multipart file part, the analogue of Go's [multipart.FileHeader]. The
    contents are held in memory (the multipart_form-lwt stand-in materializes
    parts as strings). *)

type multipart_form = {
  value : Values.t;
  file : (string, file_header list) Hashtbl.t;
}
(** The analogue of Go's [*multipart.Form]: named text values and file parts. *)

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
  mutable ctx : Context.t;
      (** Go [Request.ctx]: the request context (deadline/cancellation),
          defaulting to {!Context.background}. *)
}
(** A request mirroring Go's [Request] struct. The body field is parametric so
    the type carries no IO dependency; {!Io} instantiates ['body] to {!Body.t}.
*)

val default_user_agent : string
(** [defaultUserAgent]. *)

val parse_http_version : string -> (int * int) option
(** [ParseHTTPVersion vers]: [Some (major, minor)] on success, [None] on a
    malformed version. *)

val proto_at_least : 'a t -> int -> int -> bool
(** [Request.ProtoAtLeast]. *)

val expects_continue : 'a t -> bool
(** [Request.expectsContinue] (request.go:1518): true when the "Expect" header
    contains the [100-continue] token (case-insensitive). *)

val user_agent : 'a t -> string
(** [Request.UserAgent]: the "User-Agent" header value, or "". *)

val referer : 'a t -> string
(** [Request.Referer]: the "Referer" header value, or "". *)

val cookies : 'a t -> Cookie.t list
(** [Request.Cookies]: all cookies in the "Cookie" header. *)

val cookie : 'a t -> string -> Cookie.t option
(** [Request.Cookie name]: the named cookie, or [None] (Go's [ErrNoCookie]). *)

val add_cookie : 'a t -> Cookie.t -> unit
(** [Request.AddCookie]: append a single cookie to the "Cookie" header (RFC 6265
    5.4: one Cookie header field, semicolon-separated). *)

val parse_basic_auth : string -> (string * string) option
(** [parseBasicAuth auth]: [Some (username, password)] or [None]. *)

val basic_auth : 'a t -> (string * string) option
(** [Request.BasicAuth]: parse the "Authorization" header. *)

val basic_auth_encode : string -> string -> string
(** [basicAuth username password] (client.go): the base64 credential. *)

val set_basic_auth : 'a t -> string -> string -> unit
(** [Request.SetBasicAuth]: set the "Authorization" header. *)

val context : 'a t -> Context.t
(** [Request.Context]: the request's context (never nil; defaults to
    {!Context.background}). *)

val with_context : 'a t -> Context.t -> 'a t
(** [Request.WithContext]: a shallow copy of the request carrying [ctx]. *)
