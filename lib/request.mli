(* Port of go/src/net/http/request.go: the Request type and pure helpers.
   The IO halves (readRequest / Request.Write) live in {!Io}. GetBody, Cancel,
   TLS and context fields are intentionally omitted (deferred). Form/multipart
   parsing is NOT cached on the Request (a deliberate deviation from Go's in-place
   mutation): use the composable body parsers {!Form.of_body} / {!Multipart.of_body},
   which take the [body] and return a parsed value. *)

type t = {
  mutable meth : Httpg_base.Method.t;
      (** Go [Method]; [Custom ""] means GET for client requests *)
  mutable url : Uri.t;  (** Go [URL] (a [*url.URL] modeled as [Uri.t]) *)
  mutable proto : Httpg_base.Protocol.t;
      (** Go [Proto]/[ProtoMajor]/[ProtoMinor], collapsed *)
  mutable header : Header.t;
  mutable body : Body.t;
  mutable content_length : int64 option;
      (** [None] = unknown (Go's [-1]); [Some n] = known length ([Some 0L] =
          genuinely empty body) *)
  mutable transfer_encoding : string list;
  mutable close : bool;
  mutable host : string option;  (** Go [Host]; [None] = derive from URL *)
  mutable trailer : Header.t option;
  mutable request_uri : string;
  mutable remote_addr : string;
}
(** A request mirroring Go's [Request] struct. *)

val default_user_agent : string
(** [defaultUserAgent]. *)

val make :
  ?meth:Httpg_base.Method.t ->
  ?proto:Httpg_base.Protocol.t ->
  ?header:Header.t ->
  ?body:Body.t ->
  ?content_length:int64 ->
  ?transfer_encoding:string list ->
  ?close:bool ->
  ?host:string ->
  ?trailer:Header.t option ->
  ?request_uri:string ->
  ?remote_addr:string ->
  Uri.t ->
  t
(** [make url] builds a request for [url] (Go's [NewRequest]). [meth] defaults
    to [GET]; [host] defaults to the URL's host (pass [~host] to override).
    Replaces starting from a zero-value record. *)

val parse_http_version : string -> (int * int) option
(** [ParseHTTPVersion vers]: [Some (major, minor)] on success, [None] on a
    malformed version. *)

val proto_at_least : t -> int -> int -> bool
(** [Request.ProtoAtLeast]. *)

val expects_continue : t -> bool
(** [Request.expectsContinue] (request.go:1518): true when the "Expect" header
    contains the [100-continue] token (case-insensitive). *)

val user_agent : t -> string option
(** [Request.UserAgent]: the "User-Agent" header value, or [None] when absent
    (where Go's [Request.UserAgent] returns ""). *)

val referer : t -> string option
(** [Request.Referer]: the "Referer" header value, or [None] when absent (where
    Go's [Request.Referer] returns ""). *)

val cookies : t -> Cookie.t list
(** [Request.Cookies]: all cookies in the "Cookie" header. *)

val cookie : t -> string -> Cookie.t option
(** [Request.Cookie name]: the named cookie, or [None] (Go's [ErrNoCookie]). *)

val add_cookie : t -> Cookie.t -> unit
(** [Request.AddCookie]: append a single cookie to the "Cookie" header (RFC 6265
    5.4: one Cookie header field, semicolon-separated). *)

val auth : t -> Authorization.t option
(** The parsed "Authorization" header, or [None] if it is absent or malformed
    (generalises Go's [Request.BasicAuth] over the scheme — see
    {!Authorization}). *)

val set_auth : t -> Authorization.t -> unit
(** Set the "Authorization" header from a typed {!Authorization.t} (generalises
    Go's [Request.SetBasicAuth]). *)
