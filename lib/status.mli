(* Port of go/src/net/http/status.go *)

(* HTTP status codes as registered with IANA.
   See: https://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml *)

val status_continue : int
val status_switching_protocols : int
val status_processing : int
val status_early_hints : int
val status_ok : int
val status_created : int
val status_accepted : int
val status_non_authoritative_info : int
val status_no_content : int
val status_reset_content : int
val status_partial_content : int
val status_multi_status : int
val status_already_reported : int
val status_im_used : int
val status_multiple_choices : int
val status_moved_permanently : int
val status_found : int
val status_see_other : int
val status_not_modified : int
val status_use_proxy : int
val status_temporary_redirect : int
val status_permanent_redirect : int
val status_bad_request : int
val status_unauthorized : int
val status_payment_required : int
val status_forbidden : int
val status_not_found : int
val status_method_not_allowed : int
val status_not_acceptable : int
val status_proxy_auth_required : int
val status_request_timeout : int
val status_conflict : int
val status_gone : int
val status_length_required : int
val status_precondition_failed : int
val status_request_entity_too_large : int
val status_request_uri_too_long : int
val status_unsupported_media_type : int
val status_requested_range_not_satisfiable : int
val status_expectation_failed : int
val status_teapot : int
val status_misdirected_request : int
val status_unprocessable_entity : int
val status_locked : int
val status_failed_dependency : int
val status_too_early : int
val status_upgrade_required : int
val status_precondition_required : int
val status_too_many_requests : int
val status_request_header_fields_too_large : int
val status_unavailable_for_legal_reasons : int
val status_internal_server_error : int
val status_not_implemented : int
val status_bad_gateway : int
val status_service_unavailable : int
val status_gateway_timeout : int
val status_http_version_not_supported : int
val status_variant_also_negotiates : int
val status_insufficient_storage : int
val status_loop_detected : int
val status_not_extended : int
val status_network_authentication_required : int

(** [status_text code] returns a text for the HTTP status code. It returns the
    empty string if the code is unknown. *)
val status_text : int -> string
