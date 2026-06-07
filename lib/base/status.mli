(* Port of go/src/net/http/status.go *)

(* HTTP status codes as registered with IANA.
   See: https://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml *)

type error = InvalidStatus

type t =
  | Continue  (** RFC 9110, 15.2.1 *)
  | SwitchingProtocols  (** RFC 9110, 15.2.2 *)
  | Processing  (** RFC 2518, 10.1 *)
  | EarlyHints  (** RFC 8297 *)
  | Ok  (** RFC 9110, 15.3.1 *)
  | Created  (** RFC 9110, 15.3.2 *)
  | Accepted  (** RFC 9110, 15.3.3 *)
  | NonAuthoritativeInfo  (** RFC 9110, 15.3.4 *)
  | NoContent  (** RFC 9110, 15.3.5 *)
  | ResetContent  (** RFC 9110, 15.3.6 *)
  | PartialContent  (** RFC 9110, 15.3.7 *)
  | MultiStatus  (** RFC 4918, 11.1 *)
  | AlreadyReported  (** RFC 5842, 7.1 *)
  | ImUsed  (** RFC 3229, 10.4.1 *)
  | MultipleChoices  (** RFC 9110, 15.4.1 *)
  | MovedPermanently  (** RFC 9110, 15.4.2 *)
  | Found  (** RFC 9110, 15.4.3 *)
  | SeeOther  (** RFC 9110, 15.4.4 *)
  | NotModified  (** RFC 9110, 15.4.5 *)
  | UseProxy  (** RFC 9110, 15.4.6 *)
  | TemporaryRedirect  (** RFC 9110, 15.4.8 *)
  | PermanentRedirect  (** RFC 9110, 15.4.9 *)
  | BadRequest  (** RFC 9110, 15.5.1 *)
  | Unauthorized  (** RFC 9110, 15.5.2 *)
  | PaymentRequired  (** RFC 9110, 15.5.3 *)
  | Forbidden  (** RFC 9110, 15.5.4 *)
  | NotFound  (** RFC 9110, 15.5.5 *)
  | MethodNotAllowed  (** RFC 9110, 15.5.6 *)
  | NotAcceptable  (** RFC 9110, 15.5.7 *)
  | ProxyAuthRequired  (** RFC 9110, 15.5.8 *)
  | RequestTimeout  (** RFC 9110, 15.5.9 *)
  | Conflict  (** RFC 9110, 15.5.10 *)
  | Gone  (** RFC 9110, 15.5.11 *)
  | LengthRequired  (** RFC 9110, 15.5.12 *)
  | PreconditionFailed  (** RFC 9110, 15.5.13 *)
  | RequestEntityTooLarge  (** RFC 9110, 15.5.14 *)
  | RequestUriTooLong  (** RFC 9110, 15.5.15 *)
  | UnsupportedMediaType  (** RFC 9110, 15.5.16 *)
  | RequestedRangeNotSatisfiable  (** RFC 9110, 15.5.17 *)
  | ExpectationFailed  (** RFC 9110, 15.5.18 *)
  | Teapot  (** RFC 9110, 15.5.19 (Unused) *)
  | MisdirectedRequest  (** RFC 9110, 15.5.20 *)
  | UnprocessableEntity  (** RFC 9110, 15.5.21 *)
  | Locked  (** RFC 4918, 11.3 *)
  | FailedDependency  (** RFC 4918, 11.4 *)
  | TooEarly  (** RFC 8470, 5.2. *)
  | UpgradeRequired  (** RFC 9110, 15.5.22 *)
  | PreconditionRequired  (** RFC 6585, 3 *)
  | TooManyRequests  (** RFC 6585, 4 *)
  | RequestHeaderFieldsTooLarge  (** RFC 6585, 5 *)
  | UnavailableForLegalReasons  (** RFC 7725, 3 *)
  | InternalServerError  (** RFC 9110, 15.6.1 *)
  | NotImplemented  (** RFC 9110, 15.6.2 *)
  | BadGateway  (** RFC 9110, 15.6.3 *)
  | ServiceUnavailable  (** RFC 9110, 15.6.4 *)
  | GatewayTimeout  (** RFC 9110, 15.6.5 *)
  | HttpVersionNotSupported  (** RFC 9110, 15.6.6 *)
  | VariantAlsoNegotiates  (** RFC 2295, 8.1 *)
  | InsufficientStorage  (** RFC 4918, 11.5 *)
  | LoopDetected  (** RFC 5842, 7.2 *)
  | NotExtended  (** RFC 2774, 7 *)
  | NetworkAuthenticationRequired  (** RFC 6585, 6 *)
  | Custom of int  (** Any other code in [0, 999]. *)

val to_int : t -> int
(** The numeric HTTP status code. *)

val of_int_result : int -> (t, error) result
(** Map a numeric code to its variant. Codes in [0, 999] with no dedicated
    variant map to {!Custom}; anything outside that range is
    [Error InvalidStatus]. *)

val of_string_result : string -> (t, error) result
(** Parse a status reason phrase (case/whitespace-insensitive), e.g.
    ["Not Found"] -> [Ok NotFound]. *)

val to_string : t -> string
(** [to_string code] returns the reason phrase for the HTTP status code (Go's
    [StatusText]). A {!Custom} code (no dedicated variant) yields ["Custom"]. *)
