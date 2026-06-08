(* Port of go/src/net/http/cookie.go.

   Faithful 1:1 port of the cookie parsing/formatting/sanitization logic.
   Time handling: Go uses time.Time for Expires and formats with the fixed
   layout "Mon, 02 Jan 2006 15:04:05 GMT" (http.TimeFormat). OCaml has no
   stdlib formatter for that, so we model Expires as a Unix-epoch float
   (0. = unset, mirroring Go's zero time IsZero check) and implement a small
   faithful GMT formatter and the two parsers Go uses (RFC1123 and
   "Mon, 02-Jan-2006 15:04:05 MST"). *)

type same_site =
  | Same_site_unset
  | Same_site_default_mode
  | Same_site_lax_mode
  | Same_site_strict_mode
  | Same_site_none_mode

type t = {
  name : string;
  value : string;
  quoted : bool;
  path : string;
  domain : string;
  expires : float;
  raw_expires : string;
  max_age : int;
  secure : bool;
  http_only : bool;
  same_site : same_site;
  partitioned : bool;
  raw : string;
  unparsed : string list;
}

let default =
  {
    name = "";
    value = "";
    quoted = false;
    path = "";
    domain = "";
    expires = 0.;
    raw_expires = "";
    max_age = 0;
    secure = false;
    http_only = false;
    same_site = Same_site_unset;
    partitioned = false;
    raw = "";
    unparsed = [];
  }

(* ---- defaultCookieMaxNum ---- *)
(* Go's defaultCookieMaxNum = 3000. The GODEBUG override (httpcookiemaxnum) is
   not modeled; we always use the default limit. *)
let default_cookie_max_num = 3000
let cookie_num_within_max n = n <= default_cookie_max_num

(* ---- isToken / cookie name validity ---- *)
(* Port of httpguts.isTokenTable / ValidHeaderFieldName (== isToken). The token
   (tchar) byte set is identical to Go's table, so it shares the single byte
   predicate in httpg_base ([Textproto.valid_header_field_byte]). *)
let is_token_byte = Httpg_base.Textproto.valid_header_field_byte

let is_token v =
  if String.length v = 0 then false
  else
    let ok = ref true in
    String.iter (fun c -> if not (is_token_byte c) then ok := false) v;
    !ok

let is_cookie_name_valid = is_token

(* ---- string helpers mirroring textproto / strings ---- *)

(* textproto.TrimString: trim leading/trailing ' ' and '\t'. *)
let trim_string = Httpg_base.Textproto.trim_string

(* strings.Cut(s, sep): returns (before, after, found). *)
let cut = Httpg_base.Textproto.cut

(* ascii.ToLower: returns (lowered, ok) where ok=false if s is not ASCII
   printable. *)
let ascii_to_lower = Httpg_internal.Ascii.to_lower

(* ---- cookie value bytes / sanitization ---- *)

let valid_cookie_value_byte b =
  let c = Char.code b in
  c >= 0x20 && c < 0x7f && b <> '"' && b <> ';' && b <> '\\'

let valid_cookie_path_byte b =
  let c = Char.code b in
  c >= 0x20 && c < 0x7f && b <> ';'

(* sanitizeOrWarn: drops invalid bytes. (Logging is omitted; OCaml has no
   log.Printf analog here. The "dropping invalid bytes" log substring asserted
   by the Go tests is therefore a Go-specific artifact, omitted.) *)
let sanitize_or_warn valid v =
  let ok = ref true in
  (try
     String.iter
       (fun c ->
         if not (valid c) then (
           ok := false;
           raise Exit))
       v
   with Exit -> ());
  if !ok then v
  else
    let buf = Buffer.create (String.length v) in
    String.iter (fun c -> if valid c then Buffer.add_char buf c) v;
    Buffer.contents buf

let sanitize_cookie_value v ~quoted =
  let v = sanitize_or_warn valid_cookie_value_byte v in
  (* strings.ContainsAny(v, " ,"). *)
  if String.exists (fun c -> String.contains " ," c) v || quoted then
    "\"" ^ v ^ "\""
  else v

let sanitize_cookie_path v = sanitize_or_warn valid_cookie_path_byte v

let cookie_name_sanitizer s =
  String.map (fun c -> match c with '\n' | '\r' -> '-' | _ -> c) s

let sanitize_cookie_name = cookie_name_sanitizer

(* parseCookieValue: returns Some (value, quoted) or None. *)
let parse_cookie_value raw ~allow_double_quote =
  let raw, quoted =
    if
      allow_double_quote
      && String.length raw > 1
      && raw.[0] = '"'
      && raw.[String.length raw - 1] = '"'
    then (String.sub raw 1 (String.length raw - 2), true)
    else (raw, false)
  in
  let ok = ref true in
  (try
     String.iter
       (fun c ->
         if not (valid_cookie_value_byte c) then (
           ok := false;
           raise Exit))
       raw
   with Exit -> ());
  if !ok then Some (raw, quoted) else None

(* ---- domain validity ---- *)

(* isCookieDomainName: almost a direct copy of net's isDomainName. *)
let is_cookie_domain_name s =
  let len = String.length s in
  if len = 0 || len > 255 then false
  else begin
    let s = if s.[0] = '.' then String.sub s 1 (len - 1) else s in
    let n = String.length s in
    let last = ref '.' in
    let ok = ref false in
    let partlen = ref 0 in
    let valid = ref true in
    (try
       for i = 0 to n - 1 do
         let c = s.[i] in
         (match c with
         | 'a' .. 'z' | 'A' .. 'Z' ->
             ok := true;
             incr partlen
         | '0' .. '9' -> incr partlen
         | '-' ->
             if !last = '.' then (
               valid := false;
               raise Exit);
             incr partlen
         | '.' ->
             if !last = '.' || !last = '-' then (
               valid := false;
               raise Exit);
             if !partlen > 63 || !partlen = 0 then (
               valid := false;
               raise Exit);
             partlen := 0
         | _ ->
             valid := false;
             raise Exit);
         last := c
       done
     with Exit -> ());
    if not !valid then false
    else if !last = '-' || !partlen > 63 then false
    else !ok
  end

(* net.ParseIP for the cookie domain case: Go accepts an IPv4 or IPv6 address,
   but validCookieDomain additionally requires no ':' (so IPv6 is rejected).
   We therefore only need IPv4 detection here. *)
let is_ipv4 v =
  let parts = String.split_on_char '.' v in
  match parts with
  | [ _; _; _; _ ] ->
      List.for_all
        (fun p ->
          let l = String.length p in
          l >= 1 && l <= 3
          && String.for_all (fun c -> c >= '0' && c <= '9') p
          && (l = 1 || p.[0] <> '0' || false)
          && int_of_string_opt p
             |> Option.fold ~none:false ~some:(fun n -> n <= 255))
        parts
  | _ -> false

let valid_cookie_domain v =
  if is_cookie_domain_name v then true
  else if is_ipv4 v && not (String.contains v ':') then true
  else false

(* ---- time formatting/parsing ----
   The civil-date math (days_from_civil / utc_of_unix / month tables) and the
   RFC1123 GMT formatter now live in the shared {!Http_time} module (Go's
   http.TimeFormat); cookie.ml delegates to it. The cookie-specific expires
   parser (which accepts "DD-Mon-YYYY HH:MM:SS MST" with a 4-digit year and an
   arbitrary zone token, unlike Go's http.ParseTime) stays here. *)

let month_of_name = Http_time.month_of_name
let make_time = Http_time.make_time

(* http.TimeFormat: "Mon, 02 Jan 2006 15:04:05 GMT". *)
let format_time = Http_time.format_gmt

(* The year of an expires value, for validCookieExpires. *)
let year_of t =
  let y, _, _, _, _, _, _ = Http_time.utc_of_unix t in
  y

(* validCookieExpires: year must be >= 1601 (RFC 6265 5.1.1.5). *)
let valid_cookie_expires t = year_of t >= 1601

(* Parse "Wdy, DD Mon YYYY HH:MM:SS GMT" (RFC1123) and
   "Wdy, DD-Mon-YYYY HH:MM:SS MST". Returns Some unix_seconds (UTC) or None. *)
let parse_expires raw =
  (* Find the comma + space, then parse the remainder. *)
  match String.index_opt raw ',' with
  | None -> None
  | Some ci -> (
      let rest = String.sub raw (ci + 1) (String.length raw - ci - 1) in
      let rest = trim_string rest in
      (* rest is like "23-Nov-2011 01:05:03 GMT" or "10 Nov 2009 23:00:00 GMT".
         Normalize '-' between date components to spaces for the date part. *)
      (* Split on spaces first. *)
      let try_parse rest =
        (* Replace '-' with ' ' only in the leading date token group.
           Simpler: split into space-separated tokens; the date may itself be
           "DD-Mon-YYYY". *)
        let toks =
          String.split_on_char ' ' rest |> List.filter (fun s -> s <> "")
        in
        match toks with
        | [ date; time; _tz ] when String.contains date '-' -> (
            (* DD-Mon-YYYY HH:MM:SS TZ *)
            match String.split_on_char '-' date with
            | [ dd; mon; yyyy ] -> Some (dd, mon, yyyy, time)
            | _ -> None)
        | [ dd; mon; yyyy; time; _tz ] -> Some (dd, mon, yyyy, time)
        | _ -> None
      in
      match try_parse rest with
      | None -> None
      | Some (dd, mon, yyyy, time) -> (
          match
            ( int_of_string_opt dd,
              month_of_name mon,
              int_of_string_opt yyyy,
              String.split_on_char ':' time )
          with
          | Some d, Some m, Some y, [ hh; mi; ss ] -> (
              match
                ( int_of_string_opt hh,
                  int_of_string_opt mi,
                  int_of_string_opt ss )
              with
              | Some h, Some min_, Some s ->
                  (* [make_time] (via Ptime) validates the date/time, subsuming
                     the old hand-rolled leap-year / days-in-month / range
                     checks. *)
                  make_time y m d h min_ s
              | _ -> None)
          | _ -> None))

(* ---- ParseSetCookie ---- *)

let parse_set_cookie line =
  (* strings.Split(line, ";"). *)
  let parts = String.split_on_char ';' (trim_string line) in
  match parts with
  | [ "" ] -> Error `Blank
  | [] -> Error `Blank
  | first :: rest_parts -> (
      let first = trim_string first in
      let name, value, ok = cut first '=' in
      if not ok then Error `EqualNotFound
      else
        let name = trim_string name in
        if not (is_token name) then Error `InvalidName
        else
          match parse_cookie_value value ~allow_double_quote:true with
          | None -> Error `InvalidValue
          | Some (value, quoted) ->
              let c = ref { default with name; value; quoted; raw = line } in
              let unparsed_rev = ref [] in
              List.iter
                (fun part ->
                  let part = trim_string part in
                  if String.length part = 0 then ()
                  else begin
                    let attr, v, _ = cut part '=' in
                    let lower_attr, is_ascii = ascii_to_lower attr in
                    if not is_ascii then ()
                    else
                      match parse_cookie_value v ~allow_double_quote:false with
                      | None -> unparsed_rev := part :: !unparsed_rev
                      | Some (v, _) -> (
                          match lower_attr with
                          | "samesite" ->
                              let lower_val, ascii = ascii_to_lower v in
                              if not ascii then
                                c :=
                                  { !c with same_site = Same_site_default_mode }
                              else
                                c :=
                                  {
                                    !c with
                                    same_site =
                                      (match lower_val with
                                      | "lax" -> Same_site_lax_mode
                                      | "strict" -> Same_site_strict_mode
                                      | "none" -> Same_site_none_mode
                                      | _ -> Same_site_default_mode);
                                  }
                          | "secure" -> c := { !c with secure = true }
                          | "httponly" -> c := { !c with http_only = true }
                          | "domain" -> c := { !c with domain = v }
                          | "max-age" -> (
                              (* Go: secs, err := strconv.Atoi(val);
                                 if err != nil || secs != 0 && val[0]=='0' { break } *)
                              match int_of_string_opt v with
                              | None -> ()
                              | Some secs ->
                                  if secs <> 0 && v <> "" && v.[0] = '0' then ()
                                  else
                                    let secs = if secs <= 0 then -1 else secs in
                                    c := { !c with max_age = secs })
                          | "expires" ->
                              let exp =
                                match parse_expires v with
                                | Some t -> t
                                | None -> 0.
                              in
                              c := { !c with raw_expires = v; expires = exp }
                          | "path" -> c := { !c with path = v }
                          | "partitioned" -> c := { !c with partitioned = true }
                          | _ -> unparsed_rev := part :: !unparsed_rev)
                  end)
                rest_parts;
              c := { !c with unparsed = List.rev !unparsed_rev };
              Ok !c)

(* ---- readSetCookies ---- *)

let read_set_cookies (h : Header.t) =
  let lines = Header.values h "Set-Cookie" in
  let cookie_count = List.length lines in
  if cookie_count = 0 then []
  else if not (cookie_num_within_max cookie_count) then []
  else
    List.filter_map
      (fun line ->
        match parse_set_cookie line with Ok c -> Some c | Error _ -> None)
      lines

(* ---- readCookies ---- *)

let read_cookies (h : Header.t) ~filter =
  let lines = Header.values h "Cookie" in
  if lines = [] then []
  else
    let cookie_count =
      (* strings.Count(line, ";") + 1 per line. *)
      List.fold_left
        (fun acc line ->
          acc
          + String.fold_left (fun n c -> if c = ';' then n + 1 else n) 0 line
          + 1)
        0 lines
    in
    if not (cookie_num_within_max cookie_count) then []
    else
      let cookies = ref [] in
      List.iter
        (fun line ->
          let line = ref (trim_string line) in
          while String.length !line > 0 do
            let part, rest, _ = cut !line ';' in
            line := rest;
            let part = trim_string part in
            if part = "" then ()
            else
              let name, v, _ = cut part '=' in
              let name = trim_string name in
              if not (is_token name) then ()
              else if filter <> "" && filter <> name then ()
              else
                match parse_cookie_value v ~allow_double_quote:true with
                | None -> ()
                | Some (v, quoted) ->
                    cookies :=
                      { default with name; value = v; quoted } :: !cookies
          done)
        lines;
      List.rev !cookies

(* ---- Cookie.String (set_cookie) ---- *)

let set_cookie c =
  if not (is_token c.name) then ""
  else begin
    let b = Buffer.create 64 in
    Buffer.add_string b c.name;
    Buffer.add_char b '=';
    Buffer.add_string b (sanitize_cookie_value c.value ~quoted:c.quoted);
    if String.length c.path > 0 then begin
      Buffer.add_string b "; Path=";
      Buffer.add_string b (sanitize_cookie_path c.path)
    end;
    if String.length c.domain > 0 then
      begin if valid_cookie_domain c.domain then begin
        let d =
          if c.domain.[0] = '.' then
            String.sub c.domain 1 (String.length c.domain - 1)
          else c.domain
        in
        Buffer.add_string b "; Domain=";
        Buffer.add_string b d
      end (* else: invalid domain dropped (Go logs a warning; omitted). *)
      end;
    if c.expires <> 0. && valid_cookie_expires c.expires then begin
      Buffer.add_string b "; Expires=";
      Buffer.add_string b (format_time c.expires)
    end;
    if c.max_age > 0 then begin
      Buffer.add_string b "; Max-Age=";
      Buffer.add_string b (string_of_int c.max_age)
    end
    else if c.max_age < 0 then Buffer.add_string b "; Max-Age=0";
    if c.http_only then Buffer.add_string b "; HttpOnly";
    if c.secure then Buffer.add_string b "; Secure";
    (match c.same_site with
    | Same_site_unset | Same_site_default_mode -> ()
    | Same_site_none_mode -> Buffer.add_string b "; SameSite=None"
    | Same_site_lax_mode -> Buffer.add_string b "; SameSite=Lax"
    | Same_site_strict_mode -> Buffer.add_string b "; SameSite=Strict");
    if c.partitioned then Buffer.add_string b "; Partitioned";
    Buffer.contents b
  end

(* ---- Cookie.Valid ---- *)

type error =
  | Invalid_name
  | Invalid_expires
  | Invalid_value of char
  | Invalid_path of char
  | Invalid_domain
  | Partitioned_without_secure

let error_to_string = function
  | Invalid_name -> "http: invalid Cookie.Name"
  | Invalid_expires -> "http: invalid Cookie.Expires"
  | Invalid_value b -> Printf.sprintf "http: invalid byte %C in Cookie.Value" b
  | Invalid_path b -> Printf.sprintf "http: invalid byte %C in Cookie.Path" b
  | Invalid_domain -> "http: invalid Cookie.Domain"
  | Partitioned_without_secure ->
      "http: partitioned cookies must be set with Secure"

let valid c =
  if not (is_token c.name) then Error Invalid_name
  else if c.expires <> 0. && not (valid_cookie_expires c.expires) then
    Error Invalid_expires
  else
    let invalid_value =
      let bad = ref None in
      String.iter
        (fun b ->
          if !bad = None && not (valid_cookie_value_byte b) then bad := Some b)
        c.value;
      !bad
    in
    match invalid_value with
    | Some b -> Error (Invalid_value b)
    | None -> (
        let invalid_path =
          if String.length c.path > 0 then begin
            let bad = ref None in
            String.iter
              (fun b ->
                if !bad = None && not (valid_cookie_path_byte b) then
                  bad := Some b)
              c.path;
            !bad
          end
          else None
        in
        match invalid_path with
        | Some b -> Error (Invalid_path b)
        | None ->
            if String.length c.domain > 0 && not (valid_cookie_domain c.domain)
            then Error Invalid_domain
            else if c.partitioned && not c.secure then
              Error Partitioned_without_secure
            else Ok ())

module Private = struct
  let sanitize_cookie_path = sanitize_cookie_path
end
