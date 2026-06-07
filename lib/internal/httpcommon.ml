(* Port of go/src/net/http/internal/httpcommon/httpcommon.go. See httpcommon.mli
   for why this lives in the internal library and uses primitive types.

   Deviations from Go, all pre-existing in the inline code this replaces:
   - host is not run through httpguts.PunycodeHostPort / ValidHostHeader;
   - the :path / NewServerRequest path is validated by the cheap
     [valid_pseudo_path] / leading-char check rather than url.ParseRequestURI. *)

exception Request_header_list_size
exception Error of string

type request = {
  url_scheme : string;
  url_host : string;
  request_uri : string;
  url_opaque : string;
  meth : Httpg_base.Method.t;
  host : string;
  header : (string, string list) Hashtbl.t;
  trailer : (string, string list) Hashtbl.t;
  actual_content_length : int64;
}

type encode_headers_param = {
  request : request;
  add_gzip_header : bool;
  peer_max_header_list_size : int64;
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
  sr_needs_continue : bool;
  sr_invalid_reason : string;
}

let hget h k = match Hashtbl.find_opt h k with Some v -> v | None -> []

(* Go LowerHeader / asciiToLower. *)
let lower_header v =
  let ascii = ref true in
  let b = Bytes.of_string v in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    if Char.code c >= 128 then ascii := false
    else if c >= 'A' && c <= 'Z' then
      Bytes.set b i (Char.chr (Char.code c + 32))
  done;
  (Bytes.to_string b, !ascii)

let is_token_byte b =
  let c = Char.code b in
  if c >= 128 then false
  else
    match b with
    | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_'
    | '`' | '|' | '~' ->
        true
    | '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z' -> true
    | _ -> false

let valid_header_field_name v =
  String.length v > 0 && String.for_all is_token_byte v

let valid_wire_header_field_name v =
  if String.length v = 0 then false
  else begin
    let ok = ref true in
    String.iter
      (fun c ->
        if not (is_token_byte c) then ok := false
        else if c >= 'A' && c <= 'Z' then ok := false)
      v;
    !ok
  end

let valid_header_field_value v =
  let ok = ref true in
  String.iter
    (fun c ->
      let b = Char.code c in
      let is_ctl = b < 0x20 || b = 0x7f in
      let is_lws = c = ' ' || c = '\t' in
      if is_ctl && not is_lws then ok := false)
    v;
  !ok

let valid_pseudo_path v = (String.length v > 0 && v.[0] = '/') || v = "*"

let should_send_req_content_length meth content_length =
  if content_length > 0L then true
  else if content_length < 0L then false
  else
    match meth with Httpg_base.Method.Post | Put | Patch -> true | _ -> false

let is_request_gzip meth header disable_compression =
  (not disable_compression)
  && hget header "Accept-Encoding" = []
  && hget header "Range" = []
  && meth <> Httpg_base.Method.Head

(* Go checkConnHeaders: raise on invalid connection-level headers. *)
let check_conn_headers h =
  let bad_upgrade =
    match hget h "Upgrade" with
    | v0 :: _ when v0 <> "" && v0 <> "chunked" -> true
    | _ -> false
  in
  let bad_te =
    match hget h "Transfer-Encoding" with
    | [] -> false
    | [ v0 ] -> v0 <> "" && v0 <> "chunked"
    | _ -> true
  in
  let bad_conn =
    match hget h "Connection" with
    | [] -> false
    | [ v0 ] ->
        v0 <> ""
        && (not (Ascii.equal_fold v0 "close"))
        && not (Ascii.equal_fold v0 "keep-alive")
    | _ -> true
  in
  if bad_upgrade then raise (Error "invalid Upgrade request header");
  if bad_te then raise (Error "invalid Transfer-Encoding request header");
  if bad_conn then raise (Error "invalid Connection request header")

(* Go validateHeaders: returns "" when ok, else a short description. *)
let validate_headers hdrs =
  Hashtbl.fold
    (fun k vv acc ->
      if acc <> "" then acc
      else if (not (valid_header_field_name k)) && k <> ":protocol" then
        Printf.sprintf "name %S" k
      else if List.exists (fun v -> not (valid_header_field_value v)) vv then
        Printf.sprintf "value for header %S" k
      else "")
    hdrs ""

let comma_separated_trailers ~canonical trailer =
  let keys = Hashtbl.fold (fun k _ acc -> canonical k :: acc) trailer [] in
  List.iter
    (function
      | ("Transfer-Encoding" | "Trailer" | "Content-Length") as k ->
          raise (Error (Printf.sprintf "invalid Trailer key %S" k))
      | _ -> ())
    keys;
  match keys with
  | [] -> ""
  | _ -> String.concat "," (List.sort String.compare keys)

(* Go's per-Cookie-header splitting on ';' (8.1.2.5). *)
let emit_cookie f v =
  let rec go v =
    match String.index_opt v ';' with
    | None -> if String.length v > 0 then f "cookie" v
    | Some p ->
        f "cookie" (String.sub v 0 p);
        let n = String.length v in
        let i = ref (p + 1) in
        while !i < n && v.[!i] = ' ' do
          incr i
        done;
        go (String.sub v !i (n - !i))
  in
  go v

let encode_headers ~canonical param headerf =
  let req = param.request in
  check_conn_headers req.header;
  let host = if req.host <> "" then req.host else req.url_host in
  let protocol =
    match hget req.header ":protocol" with v :: _ -> v | [] -> ""
  in
  let is_normal_connect =
    if req.meth = Httpg_base.Method.Connect && protocol = "" then true
    else if protocol <> "" && req.meth <> Httpg_base.Method.Connect then
      raise (Error "invalid :protocol header in non-CONNECT request")
    else false
  in
  let path =
    if is_normal_connect then ""
    else begin
      let p = req.request_uri in
      if valid_pseudo_path p then p
      else begin
        let prefix = req.url_scheme ^ "://" ^ host in
        let plen = String.length prefix in
        let p2 =
          if String.length p >= plen && String.sub p 0 plen = prefix then
            String.sub p plen (String.length p - plen)
          else p
        in
        if valid_pseudo_path p2 then p2
        else if req.url_opaque <> "" then
          raise
            (Error
               (Printf.sprintf "invalid request :path %S from URL.Opaque = %S" p
                  req.url_opaque))
        else raise (Error (Printf.sprintf "invalid request :path %S" p))
      end
    end
  in
  (let e = validate_headers req.header in
   if e <> "" then raise (Error (Printf.sprintf "invalid HTTP header %s" e)));
  (let e = validate_headers req.trailer in
   if e <> "" then raise (Error (Printf.sprintf "invalid HTTP trailer %s" e)));
  let trailers = comma_separated_trailers ~canonical req.trailer in
  let enumerate f =
    f ":authority" host;
    let m =
      match req.meth with
      | Httpg_base.Method.Custom "" -> "GET"
      | m -> Httpg_base.Method.to_string m
    in
    f ":method" m;
    if not is_normal_connect then begin
      f ":path" path;
      f ":scheme" req.url_scheme
    end;
    if protocol <> "" then f ":protocol" protocol;
    if trailers <> "" then f "trailer" trailers;
    let did_ua = ref false in
    Hashtbl.iter
      (fun k vv ->
        if Ascii.equal_fold k "host" || Ascii.equal_fold k "content-length" then
          ()
        else if
          Ascii.equal_fold k "connection"
          || Ascii.equal_fold k "proxy-connection"
          || Ascii.equal_fold k "transfer-encoding"
          || Ascii.equal_fold k "upgrade"
          || Ascii.equal_fold k "keep-alive"
        then ()
        else if Ascii.equal_fold k "user-agent" then begin
          did_ua := true;
          match vv with [] -> () | v :: _ -> if v <> "" then f k v
        end
        else if Ascii.equal_fold k "cookie" then
          List.iter (fun v -> emit_cookie f v) vv
        else if k = ":protocol" then ()
        else List.iter (fun v -> f k v) vv)
      req.header;
    if should_send_req_content_length req.meth req.actual_content_length then
      f "content-length" (Int64.to_string req.actual_content_length);
    if param.add_gzip_header then f "accept-encoding" "gzip";
    if not !did_ua then f "user-agent" param.default_user_agent
  in
  if param.peer_max_header_list_size > 0L then begin
    let hl_size = ref 0L in
    enumerate (fun name value ->
        hl_size :=
          Int64.add !hl_size
            (Int64.of_int (String.length name + String.length value + 32)));
    if !hl_size > param.peer_max_header_list_size then
      raise Request_header_list_size
  end;
  enumerate (fun name value ->
      let name, ascii = lower_header name in
      if ascii then headerf name value);
  { has_body = req.actual_content_length <> 0L; has_trailers = trailers <> "" }

let header_values_contains_token vv token =
  List.exists
    (fun v ->
      List.exists
        (fun part -> Ascii.equal_fold (String.trim part) token)
        (String.split_on_char ',' v))
    vv

let new_server_request ~canonical param =
  let h = param.sp_header in
  let needs_continue =
    header_values_contains_token (hget h "Expect") "100-continue"
  in
  if needs_continue then Hashtbl.remove h "Expect";
  (match hget h "Cookie" with
  | _ :: _ :: _ as cookies ->
      Hashtbl.replace h "Cookie" [ String.concat "; " cookies ]
  | _ -> ());
  let trailer = ref None in
  List.iter
    (fun v ->
      List.iter
        (fun key ->
          match canonical (String.trim key) with
          | "Transfer-Encoding" | "Trailer" | "Content-Length" -> ()
          | key ->
              let t =
                match !trailer with
                | Some t -> t
                | None ->
                    let t = Hashtbl.create 4 in
                    trailer := Some t;
                    t
              in
              Hashtbl.replace t key [])
        (String.split_on_char ',' v))
    (hget h "Trailer");
  Hashtbl.remove h "Trailer";
  if
    String.contains param.sp_authority '@'
    && (param.sp_scheme = "http" || param.sp_scheme = "https")
  then
    {
      sr_request_uri = "";
      sr_trailer = None;
      sr_needs_continue = false;
      sr_invalid_reason = "userinfo_in_authority";
    }
  else if param.sp_method = Httpg_base.Method.Connect && param.sp_protocol = ""
  then
    {
      sr_request_uri = param.sp_authority;
      sr_trailer = !trailer;
      sr_needs_continue = needs_continue;
      sr_invalid_reason = "";
    }
  else
    let p = param.sp_path in
    if p = "" || (p.[0] <> '/' && p <> "*") then
      {
        sr_request_uri = "";
        sr_trailer = None;
        sr_needs_continue = false;
        sr_invalid_reason = "bad_path";
      }
    else
      {
        sr_request_uri = p;
        sr_trailer = !trailer;
        sr_needs_continue = needs_continue;
        sr_invalid_reason = "";
      }
