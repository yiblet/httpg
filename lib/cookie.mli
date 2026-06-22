(* Port of go/src/net/http/cookie.go. *)

(** Go's [SameSite] enum (cookie.go). The four modes mirror Go's
    [SameSiteDefaultMode .. SameSiteNoneMode] constants (iota+1). The extra
    [Same_site_unset] models Go's zero value (a [SameSite] field that was never
    assigned), which prints/serializes like the default mode but is the initial
    state of a freshly-built cookie. *)
type same_site =
  | Same_site_unset
  | Same_site_default_mode
  | Same_site_lax_mode
  | Same_site_strict_mode
  | Same_site_none_mode

(** The present cases of a cookie's Max-Age attribute. [None] of
    [max_age option] means no Max-Age attribute. *)
type max_age =
  | DeleteNow  (** emits "Max-Age=0" (delete immediately) *)
  | Seconds of int  (** positive seconds *)

val max_age_seconds : int -> max_age option
(** Smart constructor folding Go's int overload: [n = 0 -> None] (unset);
    [n < 0 -> Some DeleteNow]; [n > 0 -> Some (Seconds n)]. Keeps [Seconds]
    always positive. NB: this differs from wire parsing, where Go's
    [readSetCookies] maps a literal [Max-Age=0] to delete-now, not unset. *)

type t = {
  name : string;
  value : string;
  quoted : bool;  (** whether [value] was originally quoted *)
  path : string option;  (** [None] = no Path attribute *)
  domain : string option;  (** [None] = no Domain attribute *)
  expires : float;  (** Unix seconds; 0. = unset *)
  raw_expires : string option;  (** for reading cookies only *)
  max_age : max_age option;
      (** [None] = no Max-Age attribute; [Some DeleteNow] = Max-Age:0
          (delete now); [Some (Seconds n)] = Max-Age:n seconds *)
  secure : bool;
  http_only : bool;
  same_site : same_site;
  partitioned : bool;
  raw : string option;
  unparsed : string list;  (** raw text of unparsed attribute-value pairs *)
}
(** A [t] represents an HTTP cookie as sent in the Set-Cookie header of a
    response or the Cookie header of a request (Go's [Cookie] struct). [expires]
    is a Unix-epoch time in seconds; [0.] means unset (mirroring Go's zero
    [time.Time], detected via [IsZero]). *)

val make :
  name:string ->
  value:string ->
  ?quoted:bool ->
  ?path:string ->
  ?domain:string ->
  ?expires:float ->
  ?raw_expires:string ->
  ?max_age:max_age ->
  ?secure:bool ->
  ?http_only:bool ->
  ?same_site:same_site ->
  ?partitioned:bool ->
  ?raw:string ->
  ?unparsed:string list ->
  unit ->
  t
(** Build a cookie. [name]/[value] are required; other fields are optional
    attributes defaulting to their zero. Replaces a bare [default] record. *)

val read_set_cookies : Header.t -> t list
(** [read_set_cookies h] parses all "Set-Cookie" values from header [h] and
    returns the successfully parsed cookies (Go's [readSetCookies]). *)

val read_cookies : Header.t -> filter:string option -> t list
(** [read_cookies h ~filter] parses all "Cookie" values from header [h]. If
    [filter] is [Some name], only cookies of that name are returned; [None]
    returns all (Go's [readCookies]). *)

val set_cookie : t -> string
(** [set_cookie c] returns the serialization of the cookie for use in a Cookie
    header (if only name/value are set) or a Set-Cookie response header (Go's
    [Cookie.String]). Returns "" if the name is invalid. *)

(** A cookie-validation failure (Go's [Cookie.Valid] error cases). The [char]
    arms carry the first offending byte. *)
type error =
  | Invalid_name  (** [name] is not a valid token *)
  | Invalid_expires  (** [expires] is out of range *)
  | Invalid_value of char  (** byte not allowed in a cookie value *)
  | Invalid_path of char  (** byte not allowed in a cookie path *)
  | Invalid_domain  (** [domain] is not a valid cookie domain *)
  | Partitioned_without_secure
      (** partitioned cookie set without the Secure attribute *)

val error_to_string : error -> string
(** Render [error] as Go's faithful "http: ..." message. *)

val valid : t -> (unit, error) result
(** [valid c] reports [Ok ()] if the cookie is valid, else [Error e] (Go's
    [Cookie.Valid]). *)

val sanitize_cookie_value : string -> quoted:bool -> string
(** [sanitize_cookie_value v ~quoted] produces a suitable cookie-value from [v]
    (Go's [sanitizeCookieValue]). *)

val sanitize_cookie_name : string -> string
(** [sanitize_cookie_name n] replaces CR/LF with '-' (Go's
    [sanitizeCookieName]). *)

val valid_cookie_domain : string -> bool
(** [valid_cookie_domain v] (Go's [validCookieDomain]). *)

val is_cookie_name_valid : string -> bool
(** [is_cookie_name_valid n] (Go's [isToken] applied to a cookie name). *)

val parse_cookie_value :
  string -> allow_double_quote:bool -> (string * bool) option
(** [parse_cookie_value raw ~allow_double_quote] returns [Some (value, quoted)]
    on success, [None] on an invalid value (Go's [parseCookieValue]). *)

module Private : sig
  (** Helpers exposed only for the ported white-box tests; not part of the
      public API. *)

  val sanitize_cookie_path : string -> string
  (** [sanitize_cookie_path v] (Go's [sanitizeCookiePath]). *)
end
