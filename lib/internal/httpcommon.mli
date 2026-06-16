(* Port of go/src/net/http/internal/httpcommon/httpcommon.go.

   Request/header machinery that Go shares between net/http and internal/http2.
   Like Go's package, it is deliberately decoupled from the public request/url
   types: it works on primitive values (and the structural Hashtbl behind
   [Httpg.Header.t]) so the bundled H2_* modules can reuse it without creating
   a dependency cycle (httpg_internal must not depend on httpg). Where Go's
   package reuses textproto canonicalization, callers inject
   [Httpg.Header.canonical_header_key] via [~canonical]. *)

(* Handleable request-validation failures from [encode_headers], mirroring Go's
   error returns from EncodeHeaders:
   - [Invalid_request msg]: Go's errors.New / fmt.Errorf returns (the [msg]
     carries Go's message text verbatim);
   - [Header_list_size]: Go's ErrRequestHeaderListSize (the encoded header list
     exceeds the peer's advertised limit). *)
type error = Invalid_request of string | Header_list_size

val error_to_string : error -> string

(* Go's [Request]: a subset of http.Request built from primitive types.
   [header]/[trailer] use the same structural type as [Httpg.Header.t]. *)
type request = {
  url_scheme : string;
  url_host : string;
  request_uri : string; (* URL.RequestURI(): path?query, precomputed *)
  url_opaque : string; (* URL.Opaque (only used in a :path error message) *)
  meth : Httpg_base.Method.t;
  host : string;
  header : (string, string list) Hashtbl.t;
  trailer : (string, string list) Hashtbl.t;
  actual_content_length : int64; (* 0 means 0, -1 means unknown *)
}

type encode_headers_param = {
  request : request;
  add_gzip_header : bool;
  peer_max_header_list_size : int64; (* 0 = unset *)
  default_user_agent : string;
}

type encode_headers_result = { has_body : bool; has_trailers : bool }

type server_request_param = {
  sp_method : Httpg_base.Method.t;
  sp_scheme : string;
  sp_authority : string;
  sp_path : string;
  sp_protocol : string;
  sp_header : (string, string list) Hashtbl.t;
}

type server_request_result = {
  sr_request_uri : string;
  sr_trailer : (string, string list) Hashtbl.t option;
  sr_needs_continue : bool; (* client sent "Expect: 100-continue" *)
  sr_invalid_reason : string; (* "" when valid (Go's CountError reason) *)
}

(* Go LowerHeader: lower-case a header name, reporting whether it was ASCII.
   (Go's asciiToLower: ok is false iff some byte is >= 0x80.) *)
val lower_header : string -> string * bool

(* httpguts.IsTokenRune restricted to ASCII bytes. *)
val is_token_byte : char -> bool

(* httpguts.ValidHeaderFieldName: non-empty, all token bytes (uppercase ok). *)
val valid_header_field_name : string -> bool

(* http2.validWireHeaderFieldName: valid field name with NO uppercase. *)
val valid_wire_header_field_name : string -> bool

(* httpguts.ValidHeaderFieldValue: reject CTL bytes that are not LWS. *)
val valid_header_field_value : string -> bool

(* Go validPseudoPath. *)
val valid_pseudo_path : string -> bool

(* Go shouldSendReqContentLength (contentLength: 0 = 0, -1 = unknown). *)
val should_send_req_content_length : Httpg_base.Method.t -> int64 -> bool

(* Go IsRequestGzip. *)
val is_request_gzip :
  Httpg_base.Method.t -> (string, string list) Hashtbl.t -> bool -> bool

(* Go EncodeHeaders: validates the request and calls [headerf name value] for
   each (lower-cased, validated) pseudo-header and header. All validation runs
   up-front (as in Go), so on [Error] no [headerf] call has happened and the
   caller's hpack state is untouched. *)
val encode_headers :
  canonical:(string -> string) ->
  encode_headers_param ->
  (string -> string -> unit) ->
  (encode_headers_result, error) result

(* Go NewServerRequest. Mutates [param.sp_header] in place (strips Expect,
   merges Cookie, strips Trailer) as Go mutates rp.Header. *)
val new_server_request :
  canonical:(string -> string) -> server_request_param -> server_request_result
