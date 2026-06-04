(* Port of go/src/net/http/status.go *)

(* HTTP status codes as registered with IANA.
   See: https://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml *)

let status_continue = 100 (* RFC 9110, 15.2.1 *)
let status_switching_protocols = 101 (* RFC 9110, 15.2.2 *)
let status_processing = 102 (* RFC 2518, 10.1 *)
let status_early_hints = 103 (* RFC 8297 *)
let status_ok = 200 (* RFC 9110, 15.3.1 *)
let status_created = 201 (* RFC 9110, 15.3.2 *)
let status_accepted = 202 (* RFC 9110, 15.3.3 *)
let status_non_authoritative_info = 203 (* RFC 9110, 15.3.4 *)
let status_no_content = 204 (* RFC 9110, 15.3.5 *)
let status_reset_content = 205 (* RFC 9110, 15.3.6 *)
let status_partial_content = 206 (* RFC 9110, 15.3.7 *)
let status_multi_status = 207 (* RFC 4918, 11.1 *)
let status_already_reported = 208 (* RFC 5842, 7.1 *)
let status_im_used = 226 (* RFC 3229, 10.4.1 *)
let status_multiple_choices = 300 (* RFC 9110, 15.4.1 *)
let status_moved_permanently = 301 (* RFC 9110, 15.4.2 *)
let status_found = 302 (* RFC 9110, 15.4.3 *)
let status_see_other = 303 (* RFC 9110, 15.4.4 *)
let status_not_modified = 304 (* RFC 9110, 15.4.5 *)
let status_use_proxy = 305 (* RFC 9110, 15.4.6 *)

(* 306 (* RFC 9110, 15.4.7 *) is unused *)
let status_temporary_redirect = 307 (* RFC 9110, 15.4.8 *)
let status_permanent_redirect = 308 (* RFC 9110, 15.4.9 *)
let status_bad_request = 400 (* RFC 9110, 15.5.1 *)
let status_unauthorized = 401 (* RFC 9110, 15.5.2 *)
let status_payment_required = 402 (* RFC 9110, 15.5.3 *)
let status_forbidden = 403 (* RFC 9110, 15.5.4 *)
let status_not_found = 404 (* RFC 9110, 15.5.5 *)
let status_method_not_allowed = 405 (* RFC 9110, 15.5.6 *)
let status_not_acceptable = 406 (* RFC 9110, 15.5.7 *)
let status_proxy_auth_required = 407 (* RFC 9110, 15.5.8 *)
let status_request_timeout = 408 (* RFC 9110, 15.5.9 *)
let status_conflict = 409 (* RFC 9110, 15.5.10 *)
let status_gone = 410 (* RFC 9110, 15.5.11 *)
let status_length_required = 411 (* RFC 9110, 15.5.12 *)
let status_precondition_failed = 412 (* RFC 9110, 15.5.13 *)
let status_request_entity_too_large = 413 (* RFC 9110, 15.5.14 *)
let status_request_uri_too_long = 414 (* RFC 9110, 15.5.15 *)
let status_unsupported_media_type = 415 (* RFC 9110, 15.5.16 *)
let status_requested_range_not_satisfiable = 416 (* RFC 9110, 15.5.17 *)
let status_expectation_failed = 417 (* RFC 9110, 15.5.18 *)
let status_teapot = 418 (* RFC 9110, 15.5.19 (Unused) *)
let status_misdirected_request = 421 (* RFC 9110, 15.5.20 *)
let status_unprocessable_entity = 422 (* RFC 9110, 15.5.21 *)
let status_locked = 423 (* RFC 4918, 11.3 *)
let status_failed_dependency = 424 (* RFC 4918, 11.4 *)
let status_too_early = 425 (* RFC 8470, 5.2. *)
let status_upgrade_required = 426 (* RFC 9110, 15.5.22 *)
let status_precondition_required = 428 (* RFC 6585, 3 *)
let status_too_many_requests = 429 (* RFC 6585, 4 *)
let status_request_header_fields_too_large = 431 (* RFC 6585, 5 *)
let status_unavailable_for_legal_reasons = 451 (* RFC 7725, 3 *)
let status_internal_server_error = 500 (* RFC 9110, 15.6.1 *)
let status_not_implemented = 501 (* RFC 9110, 15.6.2 *)
let status_bad_gateway = 502 (* RFC 9110, 15.6.3 *)
let status_service_unavailable = 503 (* RFC 9110, 15.6.4 *)
let status_gateway_timeout = 504 (* RFC 9110, 15.6.5 *)
let status_http_version_not_supported = 505 (* RFC 9110, 15.6.6 *)
let status_variant_also_negotiates = 506 (* RFC 2295, 8.1 *)
let status_insufficient_storage = 507 (* RFC 4918, 11.5 *)
let status_loop_detected = 508 (* RFC 5842, 7.2 *)
let status_not_extended = 510 (* RFC 2774, 7 *)
let status_network_authentication_required = 511 (* RFC 6585, 6 *)

(* status_text returns a text for the HTTP status code. It returns the empty
   string if the code is unknown. *)
let status_text (code : int) : string =
  if code = status_continue then "Continue"
  else if code = status_switching_protocols then "Switching Protocols"
  else if code = status_processing then "Processing"
  else if code = status_early_hints then "Early Hints"
  else if code = status_ok then "OK"
  else if code = status_created then "Created"
  else if code = status_accepted then "Accepted"
  else if code = status_non_authoritative_info then
    "Non-Authoritative Information"
  else if code = status_no_content then "No Content"
  else if code = status_reset_content then "Reset Content"
  else if code = status_partial_content then "Partial Content"
  else if code = status_multi_status then "Multi-Status"
  else if code = status_already_reported then "Already Reported"
  else if code = status_im_used then "IM Used"
  else if code = status_multiple_choices then "Multiple Choices"
  else if code = status_moved_permanently then "Moved Permanently"
  else if code = status_found then "Found"
  else if code = status_see_other then "See Other"
  else if code = status_not_modified then "Not Modified"
  else if code = status_use_proxy then "Use Proxy"
  else if code = status_temporary_redirect then "Temporary Redirect"
  else if code = status_permanent_redirect then "Permanent Redirect"
  else if code = status_bad_request then "Bad Request"
  else if code = status_unauthorized then "Unauthorized"
  else if code = status_payment_required then "Payment Required"
  else if code = status_forbidden then "Forbidden"
  else if code = status_not_found then "Not Found"
  else if code = status_method_not_allowed then "Method Not Allowed"
  else if code = status_not_acceptable then "Not Acceptable"
  else if code = status_proxy_auth_required then "Proxy Authentication Required"
  else if code = status_request_timeout then "Request Timeout"
  else if code = status_conflict then "Conflict"
  else if code = status_gone then "Gone"
  else if code = status_length_required then "Length Required"
  else if code = status_precondition_failed then "Precondition Failed"
  else if code = status_request_entity_too_large then "Request Entity Too Large"
  else if code = status_request_uri_too_long then "Request URI Too Long"
  else if code = status_unsupported_media_type then "Unsupported Media Type"
  else if code = status_requested_range_not_satisfiable then
    "Requested Range Not Satisfiable"
  else if code = status_expectation_failed then "Expectation Failed"
  else if code = status_teapot then "I'm a teapot"
  else if code = status_misdirected_request then "Misdirected Request"
  else if code = status_unprocessable_entity then "Unprocessable Entity"
  else if code = status_locked then "Locked"
  else if code = status_failed_dependency then "Failed Dependency"
  else if code = status_too_early then "Too Early"
  else if code = status_upgrade_required then "Upgrade Required"
  else if code = status_precondition_required then "Precondition Required"
  else if code = status_too_many_requests then "Too Many Requests"
  else if code = status_request_header_fields_too_large then
    "Request Header Fields Too Large"
  else if code = status_unavailable_for_legal_reasons then
    "Unavailable For Legal Reasons"
  else if code = status_internal_server_error then "Internal Server Error"
  else if code = status_not_implemented then "Not Implemented"
  else if code = status_bad_gateway then "Bad Gateway"
  else if code = status_service_unavailable then "Service Unavailable"
  else if code = status_gateway_timeout then "Gateway Timeout"
  else if code = status_http_version_not_supported then
    "HTTP Version Not Supported"
  else if code = status_variant_also_negotiates then "Variant Also Negotiates"
  else if code = status_insufficient_storage then "Insufficient Storage"
  else if code = status_loop_detected then "Loop Detected"
  else if code = status_not_extended then "Not Extended"
  else if code = status_network_authentication_required then
    "Network Authentication Required"
  else ""
