(* The value of an HTTP [Authorization] (or [Proxy-Authorization]) header: a
   scheme plus its credentials (RFC 7235). [Basic] (RFC 7617) and [Bearer]
   (RFC 6750) are first-class; any other scheme (Digest, Negotiate, NTLM, …) is
   kept verbatim as {!Other} so the value round-trips losslessly without this
   module having to understand it. Go's net/http only models Basic
   ([Request.BasicAuth]/[SetBasicAuth]); Bearer/[Other] are a deliberate
   extension. *)

type t =
  | Basic of { username : string; password : string }
      (** RFC 7617: [Basic base64(username ":" password)]. *)
  | Bearer of string  (** RFC 6750: [Bearer <token>]. *)
  | Other of { scheme : string; params : string }
      (** any other scheme, credentials left unparsed (Digest, Negotiate, …). *)

type error =
  | Malformed of string
      (** not a [scheme SP credentials] header value (carries the input). *)
  | Invalid_basic
      (** the [Basic] credentials are not valid base64 of ["user:pass"]. *)

val error_to_string : error -> string
(** Render an {!error} as a message. *)

val to_string : t -> string
(** The header value: ["Basic …"], ["Bearer …"], or [scheme ^ " " ^ params]. *)

val of_string : string -> (t, error) result
(** Parse an [Authorization] header value. The scheme match is case-insensitive
    (Go's [EqualFold]). [Error (Malformed _)] if there is no scheme/credentials
    split; [Error Invalid_basic] if a [Basic] payload is not base64 of
    ["user:pass"]. An unrecognised scheme parses to {!Other}, not an error. *)
