(* Port of go/src/net/http/status.go *)

(* HTTP status codes as registered with IANA.
   See: https://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml *)

type error = InvalidStatus

type t =
  | Continue (* RFC 9110, 15.2.1 *)
  | SwitchingProtocols (* RFC 9110, 15.2.2 *)
  | Processing (* RFC 2518, 10.1 *)
  | EarlyHints (* RFC 8297 *)
  | Ok (* RFC 9110, 15.3.1 *)
  | Created (* RFC 9110, 15.3.2 *)
  | Accepted (* RFC 9110, 15.3.3 *)
  | NonAuthoritativeInfo (* RFC 9110, 15.3.4 *)
  | NoContent (* RFC 9110, 15.3.5 *)
  | ResetContent (* RFC 9110, 15.3.6 *)
  | PartialContent (* RFC 9110, 15.3.7 *)
  | MultiStatus (* RFC 4918, 11.1 *)
  | AlreadyReported (* RFC 5842, 7.1 *)
  | ImUsed (* RFC 3229, 10.4.1 *)
  | MultipleChoices (* RFC 9110, 15.4.1 *)
  | MovedPermanently (* RFC 9110, 15.4.2 *)
  | Found (* RFC 9110, 15.4.3 *)
  | SeeOther (* RFC 9110, 15.4.4 *)
  | NotModified (* RFC 9110, 15.4.5 *)
  | UseProxy (* RFC 9110, 15.4.6 *)
  (* 306 (* RFC 9110, 15.4.7 *) is unused *)
  | TemporaryRedirect (* RFC 9110, 15.4.8 *)
  | PermanentRedirect (* RFC 9110, 15.4.9 *)
  | BadRequest (* RFC 9110, 15.5.1 *)
  | Unauthorized (* RFC 9110, 15.5.2 *)
  | PaymentRequired (* RFC 9110, 15.5.3 *)
  | Forbidden (* RFC 9110, 15.5.4 *)
  | NotFound (* RFC 9110, 15.5.5 *)
  | MethodNotAllowed (* RFC 9110, 15.5.6 *)
  | NotAcceptable (* RFC 9110, 15.5.7 *)
  | ProxyAuthRequired (* RFC 9110, 15.5.8 *)
  | RequestTimeout (* RFC 9110, 15.5.9 *)
  | Conflict (* RFC 9110, 15.5.10 *)
  | Gone (* RFC 9110, 15.5.11 *)
  | LengthRequired (* RFC 9110, 15.5.12 *)
  | PreconditionFailed (* RFC 9110, 15.5.13 *)
  | RequestEntityTooLarge (* RFC 9110, 15.5.14 *)
  | RequestUriTooLong (* RFC 9110, 15.5.15 *)
  | UnsupportedMediaType (* RFC 9110, 15.5.16 *)
  | RequestedRangeNotSatisfiable (* RFC 9110, 15.5.17 *)
  | ExpectationFailed (* RFC 9110, 15.5.18 *)
  | Teapot (* RFC 9110, 15.5.19 (Unused) *)
  | MisdirectedRequest (* RFC 9110, 15.5.20 *)
  | UnprocessableEntity (* RFC 9110, 15.5.21 *)
  | Locked (* RFC 4918, 11.3 *)
  | FailedDependency (* RFC 4918, 11.4 *)
  | TooEarly (* RFC 8470, 5.2. *)
  | UpgradeRequired (* RFC 9110, 15.5.22 *)
  | PreconditionRequired (* RFC 6585, 3 *)
  | TooManyRequests (* RFC 6585, 4 *)
  | RequestHeaderFieldsTooLarge (* RFC 6585, 5 *)
  | UnavailableForLegalReasons (* RFC 7725, 3 *)
  | InternalServerError (* RFC 9110, 15.6.1 *)
  | NotImplemented (* RFC 9110, 15.6.2 *)
  | BadGateway (* RFC 9110, 15.6.3 *)
  | ServiceUnavailable (* RFC 9110, 15.6.4 *)
  | GatewayTimeout (* RFC 9110, 15.6.5 *)
  | HttpVersionNotSupported (* RFC 9110, 15.6.6 *)
  | VariantAlsoNegotiates (* RFC 2295, 8.1 *)
  | InsufficientStorage (* RFC 4918, 11.5 *)
  | LoopDetected (* RFC 5842, 7.2 *)
  | NotExtended (* RFC 2774, 7 *)
  | NetworkAuthenticationRequired (* RFC 6585, 6 *)
  | Custom of int

let to_int status =
  match status with
  | Continue -> 100
  | SwitchingProtocols -> 101
  | Processing -> 102
  | EarlyHints -> 103
  | Ok -> 200
  | Created -> 201
  | Accepted -> 202
  | NonAuthoritativeInfo -> 203
  | NoContent -> 204
  | ResetContent -> 205
  | PartialContent -> 206
  | MultiStatus -> 207
  | AlreadyReported -> 208
  | ImUsed -> 226
  | MultipleChoices -> 300
  | MovedPermanently -> 301
  | Found -> 302
  | SeeOther -> 303
  | NotModified -> 304
  | UseProxy -> 305
  | TemporaryRedirect -> 307
  | PermanentRedirect -> 308
  | BadRequest -> 400
  | Unauthorized -> 401
  | PaymentRequired -> 402
  | Forbidden -> 403
  | NotFound -> 404
  | MethodNotAllowed -> 405
  | NotAcceptable -> 406
  | ProxyAuthRequired -> 407
  | RequestTimeout -> 408
  | Conflict -> 409
  | Gone -> 410
  | LengthRequired -> 411
  | PreconditionFailed -> 412
  | RequestEntityTooLarge -> 413
  | RequestUriTooLong -> 414
  | UnsupportedMediaType -> 415
  | RequestedRangeNotSatisfiable -> 416
  | ExpectationFailed -> 417
  | Teapot -> 418
  | MisdirectedRequest -> 421
  | UnprocessableEntity -> 422
  | Locked -> 423
  | FailedDependency -> 424
  | TooEarly -> 425
  | UpgradeRequired -> 426
  | PreconditionRequired -> 428
  | TooManyRequests -> 429
  | RequestHeaderFieldsTooLarge -> 431
  | UnavailableForLegalReasons -> 451
  | InternalServerError -> 500
  | NotImplemented -> 501
  | BadGateway -> 502
  | ServiceUnavailable -> 503
  | GatewayTimeout -> 504
  | HttpVersionNotSupported -> 505
  | VariantAlsoNegotiates -> 506
  | InsufficientStorage -> 507
  | LoopDetected -> 508
  | NotExtended -> 510
  | NetworkAuthenticationRequired -> 511
  | Custom v -> v

let of_int_result status =
  match status with
  | 100 -> Result.Ok Continue
  | 101 -> Result.Ok SwitchingProtocols
  | 102 -> Result.Ok Processing
  | 103 -> Result.Ok EarlyHints
  | 200 -> Result.Ok Ok
  | 201 -> Result.Ok Created
  | 202 -> Result.Ok Accepted
  | 203 -> Result.Ok NonAuthoritativeInfo
  | 204 -> Result.Ok NoContent
  | 205 -> Result.Ok ResetContent
  | 206 -> Result.Ok PartialContent
  | 207 -> Result.Ok MultiStatus
  | 208 -> Result.Ok AlreadyReported
  | 226 -> Result.Ok ImUsed
  | 300 -> Result.Ok MultipleChoices
  | 301 -> Result.Ok MovedPermanently
  | 302 -> Result.Ok Found
  | 303 -> Result.Ok SeeOther
  | 304 -> Result.Ok NotModified
  | 305 -> Result.Ok UseProxy
  | 307 -> Result.Ok TemporaryRedirect
  | 308 -> Result.Ok PermanentRedirect
  | 400 -> Result.Ok BadRequest
  | 401 -> Result.Ok Unauthorized
  | 402 -> Result.Ok PaymentRequired
  | 403 -> Result.Ok Forbidden
  | 404 -> Result.Ok NotFound
  | 405 -> Result.Ok MethodNotAllowed
  | 406 -> Result.Ok NotAcceptable
  | 407 -> Result.Ok ProxyAuthRequired
  | 408 -> Result.Ok RequestTimeout
  | 409 -> Result.Ok Conflict
  | 410 -> Result.Ok Gone
  | 411 -> Result.Ok LengthRequired
  | 412 -> Result.Ok PreconditionFailed
  | 413 -> Result.Ok RequestEntityTooLarge
  | 414 -> Result.Ok RequestUriTooLong
  | 415 -> Result.Ok UnsupportedMediaType
  | 416 -> Result.Ok RequestedRangeNotSatisfiable
  | 417 -> Result.Ok ExpectationFailed
  | 418 -> Result.Ok Teapot
  | 421 -> Result.Ok MisdirectedRequest
  | 422 -> Result.Ok UnprocessableEntity
  | 423 -> Result.Ok Locked
  | 424 -> Result.Ok FailedDependency
  | 425 -> Result.Ok TooEarly
  | 426 -> Result.Ok UpgradeRequired
  | 428 -> Result.Ok PreconditionRequired
  | 429 -> Result.Ok TooManyRequests
  | 431 -> Result.Ok RequestHeaderFieldsTooLarge
  | 451 -> Result.Ok UnavailableForLegalReasons
  | 500 -> Result.Ok InternalServerError
  | 501 -> Result.Ok NotImplemented
  | 502 -> Result.Ok BadGateway
  | 503 -> Result.Ok ServiceUnavailable
  | 504 -> Result.Ok GatewayTimeout
  | 505 -> Result.Ok HttpVersionNotSupported
  | 506 -> Result.Ok VariantAlsoNegotiates
  | 507 -> Result.Ok InsufficientStorage
  | 508 -> Result.Ok LoopDetected
  | 510 -> Result.Ok NotExtended
  | 511 -> Result.Ok NetworkAuthenticationRequired
  | v ->
      if v >= 0 && v <= 999 then Result.Ok (Custom v)
      else Result.Error InvalidStatus

(* status_text returns a text for the HTTP status code. It returns the empty
   string if the code is unknown. *)
let of_string_result (code : string) =
  let code = String.lowercase_ascii code |> String.trim in
  match code with
  | "continue" -> Result.Ok Continue
  | "switching protocols" -> Result.Ok SwitchingProtocols
  | "processing" -> Result.Ok Processing
  | "early hints" -> Result.Ok EarlyHints
  | "ok" -> Result.Ok Ok
  | "created" -> Result.Ok Created
  | "accepted" -> Result.Ok Accepted
  | "non-authoritative information" -> Result.Ok NonAuthoritativeInfo
  | "no content" -> Result.Ok NoContent
  | "reset content" -> Result.Ok ResetContent
  | "partial content" -> Result.Ok PartialContent
  | "multi-status" -> Result.Ok MultiStatus
  | "already reported" -> Result.Ok AlreadyReported
  | "im used" -> Result.Ok ImUsed
  | "multiple choices" -> Result.Ok MultipleChoices
  | "moved permanently" -> Result.Ok MovedPermanently
  | "found" -> Result.Ok Found
  | "see other" -> Result.Ok SeeOther
  | "not modified" -> Result.Ok NotModified
  | "use proxy" -> Result.Ok UseProxy
  | "temporary redirect" -> Result.Ok TemporaryRedirect
  | "permanent redirect" -> Result.Ok PermanentRedirect
  | "bad request" -> Result.Ok BadRequest
  | "unauthorized" -> Result.Ok Unauthorized
  | "payment required" -> Result.Ok PaymentRequired
  | "forbidden" -> Result.Ok Forbidden
  | "not found" -> Result.Ok NotFound
  | "method not allowed" -> Result.Ok MethodNotAllowed
  | "not acceptable" -> Result.Ok NotAcceptable
  | "proxy authentication required" -> Result.Ok ProxyAuthRequired
  | "request timeout" -> Result.Ok RequestTimeout
  | "conflict" -> Result.Ok Conflict
  | "gone" -> Result.Ok Gone
  | "length required" -> Result.Ok LengthRequired
  | "precondition failed" -> Result.Ok PreconditionFailed
  | "request entity too large" -> Result.Ok RequestEntityTooLarge
  | "request uri too long" -> Result.Ok RequestUriTooLong
  | "unsupported media type" -> Result.Ok UnsupportedMediaType
  | "requested range not satisfiable" -> Result.Ok RequestedRangeNotSatisfiable
  | "expectation failed" -> Result.Ok ExpectationFailed
  | "i'm a teapot" -> Result.Ok Teapot
  | "misdirected request" -> Result.Ok MisdirectedRequest
  | "unprocessable entity" -> Result.Ok UnprocessableEntity
  | "locked" -> Result.Ok Locked
  | "failed dependency" -> Result.Ok FailedDependency
  | "too early" -> Result.Ok TooEarly
  | "upgrade required" -> Result.Ok UpgradeRequired
  | "precondition required" -> Result.Ok PreconditionRequired
  | "too many requests" -> Result.Ok TooManyRequests
  | "request header fields too large" -> Result.Ok RequestHeaderFieldsTooLarge
  | "unavailable for legal reasons" -> Result.Ok UnavailableForLegalReasons
  | "internal server error" -> Result.Ok InternalServerError
  | "not implemented" -> Result.Ok NotImplemented
  | "bad gateway" -> Result.Ok BadGateway
  | "service unavailable" -> Result.Ok ServiceUnavailable
  | "gateway timeout" -> Result.Ok GatewayTimeout
  | "http version not supported" -> Result.Ok HttpVersionNotSupported
  | "variant also negotiates" -> Result.Ok VariantAlsoNegotiates
  | "insufficient storage" -> Result.Ok InsufficientStorage
  | "loop detected" -> Result.Ok LoopDetected
  | "not extended" -> Result.Ok NotExtended
  | "network authentication required" -> Result.Ok NetworkAuthenticationRequired
  | _ -> Result.Error InvalidStatus

(* status_text returns a text for the HTTP status code. It returns the empty
   string if the code is unknown. *)
let to_string (code : t) : string =
  match code with
  | Continue -> "Continue"
  | SwitchingProtocols -> "Switching Protocols"
  | Processing -> "Processing"
  | EarlyHints -> "Early Hints"
  | Ok -> "OK"
  | Created -> "Created"
  | Accepted -> "Accepted"
  | NonAuthoritativeInfo -> "Non-Authoritative Information"
  | NoContent -> "No Content"
  | ResetContent -> "Reset Content"
  | PartialContent -> "Partial Content"
  | MultiStatus -> "Multi-Status"
  | AlreadyReported -> "Already Reported"
  | ImUsed -> "IM Used"
  | MultipleChoices -> "Multiple Choices"
  | MovedPermanently -> "Moved Permanently"
  | Found -> "Found"
  | SeeOther -> "See Other"
  | NotModified -> "Not Modified"
  | UseProxy -> "Use Proxy"
  | TemporaryRedirect -> "Temporary Redirect"
  | PermanentRedirect -> "Permanent Redirect"
  | BadRequest -> "Bad Request"
  | Unauthorized -> "Unauthorized"
  | PaymentRequired -> "Payment Required"
  | Forbidden -> "Forbidden"
  | NotFound -> "Not Found"
  | MethodNotAllowed -> "Method Not Allowed"
  | NotAcceptable -> "Not Acceptable"
  | ProxyAuthRequired -> "Proxy Authentication Required"
  | RequestTimeout -> "Request Timeout"
  | Conflict -> "Conflict"
  | Gone -> "Gone"
  | LengthRequired -> "Length Required"
  | PreconditionFailed -> "Precondition Failed"
  | RequestEntityTooLarge -> "Request Entity Too Large"
  | RequestUriTooLong -> "Request URI Too Long"
  | UnsupportedMediaType -> "Unsupported Media Type"
  | RequestedRangeNotSatisfiable -> "Requested Range Not Satisfiable"
  | ExpectationFailed -> "Expectation Failed"
  | Teapot -> "I'm a teapot"
  | MisdirectedRequest -> "Misdirected Request"
  | UnprocessableEntity -> "Unprocessable Entity"
  | Locked -> "Locked"
  | FailedDependency -> "Failed Dependency"
  | TooEarly -> "Too Early"
  | UpgradeRequired -> "Upgrade Required"
  | PreconditionRequired -> "Precondition Required"
  | TooManyRequests -> "Too Many Requests"
  | RequestHeaderFieldsTooLarge -> "Request Header Fields Too Large"
  | UnavailableForLegalReasons -> "Unavailable For Legal Reasons"
  | InternalServerError -> "Internal Server Error"
  | NotImplemented -> "Not Implemented"
  | BadGateway -> "Bad Gateway"
  | ServiceUnavailable -> "Service Unavailable"
  | GatewayTimeout -> "Gateway Timeout"
  | HttpVersionNotSupported -> "HTTP Version Not Supported"
  | VariantAlsoNegotiates -> "Variant Also Negotiates"
  | InsufficientStorage -> "Insufficient Storage"
  | LoopDetected -> "Loop Detected"
  | NotExtended -> "Not Extended"
  | NetworkAuthenticationRequired -> "Network Authentication Required"
  | Custom _ -> "Custom"
