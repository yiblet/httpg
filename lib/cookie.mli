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

(** A [t] represents an HTTP cookie as sent in the Set-Cookie header of a
    response or the Cookie header of a request (Go's [Cookie] struct). [expires]
    is a Unix-epoch time in seconds; [0.] means unset (mirroring Go's zero
    [time.Time], detected via [IsZero]). *)
type t = {
  name : string;
  value : string;
  quoted : bool;  (** whether [value] was originally quoted *)
  path : string;
  domain : string;
  expires : float;  (** Unix seconds; 0. = unset *)
  raw_expires : string;  (** for reading cookies only *)
  max_age : int;
      (** 0 = no Max-Age; <0 = delete now (Max-Age:0); >0 = seconds *)
  secure : bool;
  http_only : bool;
  same_site : same_site;
  partitioned : bool;
  raw : string;
  unparsed : string list;  (** raw text of unparsed attribute-value pairs *)
}

(** An empty cookie (all fields zero/empty), used as a base for record updates. *)
val default : t

(** [read_set_cookies h] parses all "Set-Cookie" values from header [h] and
    returns the successfully parsed cookies (Go's [readSetCookies]). *)
val read_set_cookies : Header.t -> t list

(** [read_cookies h ~filter] parses all "Cookie" values from header [h]. If
    [filter] isn't empty, only cookies of that name are returned (Go's
    [readCookies]). *)
val read_cookies : Header.t -> filter:string -> t list

(** [set_cookie c] returns the serialization of the cookie for use in a Cookie
    header (if only name/value are set) or a Set-Cookie response header (Go's
    [Cookie.String]). Returns "" if the name is invalid. *)
val set_cookie : t -> string

(** [valid c] reports [Ok ()] if the cookie is valid, else [Error msg]
    (Go's [Cookie.Valid]). *)
val valid : t -> (unit, string) result

(** [sanitize_cookie_value v ~quoted] produces a suitable cookie-value from [v]
    (Go's [sanitizeCookieValue]). *)
val sanitize_cookie_value : string -> quoted:bool -> string

(** [sanitize_cookie_path v] (Go's [sanitizeCookiePath]). *)
val sanitize_cookie_path : string -> string

(** [sanitize_cookie_name n] replaces CR/LF with '-' (Go's
    [sanitizeCookieName]). *)
val sanitize_cookie_name : string -> string

(** [valid_cookie_domain v] (Go's [validCookieDomain]). *)
val valid_cookie_domain : string -> bool

(** [is_cookie_name_valid n] (Go's [isToken] applied to a cookie name). *)
val is_cookie_name_valid : string -> bool

(** [parse_cookie_value raw ~allow_double_quote] returns [Some (value, quoted)]
    on success, [None] on an invalid value (Go's [parseCookieValue]). *)
val parse_cookie_value : string -> allow_double_quote:bool -> (string * bool) option
