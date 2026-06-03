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
(* Port of httpguts.isTokenTable / ValidHeaderFieldName (== isToken). *)
let is_token_byte b =
  match b with
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_'
  | '`' | '|' | '~' ->
      true
  | '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z' -> true
  | _ -> false

let is_token v =
  if String.length v = 0 then false
  else
    let ok = ref true in
    String.iter (fun c -> if not (is_token_byte c) then ok := false) v;
    !ok

let is_cookie_name_valid = is_token

(* ---- string helpers mirroring textproto / strings ---- *)

(* textproto.TrimString: trim leading/trailing ' ' and '\t'. *)
let trim_string s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && (s.[!i] = ' ' || s.[!i] = '\t') do
    incr i
  done;
  let j = ref (n - 1) in
  while !j >= !i && (s.[!j] = ' ' || s.[!j] = '\t') do
    decr j
  done;
  String.sub s !i (!j - !i + 1)

(* strings.Cut(s, sep): returns (before, after, found). *)
let cut s sep =
  match String.index_opt s sep with
  | Some i ->
      (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1), true)
  | None -> (s, "", false)

(* strings.Count(s, ";") *)
let count_char s c =
  let n = ref 0 in
  String.iter (fun x -> if x = c then incr n) s;
  !n

(* strings.Split(s, ";") *)
let split_char s c =
  String.split_on_char c s

(* ascii.ToLower: returns (lowered, ok) where ok=false if s is not ASCII
   printable. *)
let ascii_to_lower = Gohttp_internal.Ascii.to_lower

let contains_any s set =
  let found = ref false in
  String.iter (fun c -> if String.contains set c then found := true) s;
  !found

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
     String.iter (fun c -> if not (valid c) then (ok := false; raise Exit)) v
   with Exit -> ());
  if !ok then v
  else
    let buf = Buffer.create (String.length v) in
    String.iter (fun c -> if valid c then Buffer.add_char buf c) v;
    Buffer.contents buf

let sanitize_cookie_value v ~quoted =
  let v = sanitize_or_warn valid_cookie_value_byte v in
  if contains_any v " ," || quoted then "\"" ^ v ^ "\"" else v

let sanitize_cookie_path v = sanitize_or_warn valid_cookie_path_byte v

let cookie_name_sanitizer s =
  String.map (fun c -> match c with '\n' | '\r' -> '-' | _ -> c) s

let sanitize_cookie_name = cookie_name_sanitizer

(* parseCookieValue: returns Some (value, quoted) or None. *)
let parse_cookie_value raw ~allow_double_quote =
  let raw, quoted =
    if
      allow_double_quote && String.length raw > 1
      && raw.[0] = '"'
      && raw.[String.length raw - 1] = '"'
    then (String.sub raw 1 (String.length raw - 2), true)
    else (raw, false)
  in
  let ok = ref true in
  (try
     String.iter
       (fun c -> if not (valid_cookie_value_byte c) then (ok := false; raise Exit))
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
             if !last = '.' then (valid := false; raise Exit);
             incr partlen
         | '.' ->
             if !last = '.' || !last = '-' then (valid := false; raise Exit);
             if !partlen > 63 || !partlen = 0 then (valid := false; raise Exit);
             partlen := 0
         | _ -> valid := false; raise Exit);
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
          && int_of_string_opt p |> Option.fold ~none:false ~some:(fun n -> n <= 255))
        parts
  | _ -> false

let valid_cookie_domain v =
  if is_cookie_domain_name v then true
  else if is_ipv4 v && not (String.contains v ':') then true
  else false

(* ---- time formatting/parsing ---- *)

let days_in_month =
  [| 31; 28; 31; 30; 31; 30; 31; 31; 30; 31; 30; 31 |]

let is_leap y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0

(* Days from civil date to days since 1970-01-01 (Howard Hinnant's algorithm). *)
let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = ((153 * ((if m > 2 then m - 3 else m + 9)) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

(* Convert civil date+time (UTC) to Unix seconds. *)
let unix_of_utc y mo d h mi s =
  let days = days_from_civil y mo d in
  Float.of_int ((((days * 24) + h) * 3600) + (mi * 60) + s)

(* Inverse: Unix seconds -> (year, month, day, hour, min, sec, weekday).
   weekday: 0=Sunday .. 6=Saturday. *)
let utc_of_unix t =
  let secs = int_of_float (Float.floor t) in
  let days = if secs >= 0 then secs / 86400 else (secs - 86399) / 86400 in
  let rem = secs - (days * 86400) in
  let h = rem / 3600 in
  let mi = rem mod 3600 / 60 in
  let s = rem mod 60 in
  (* 1970-01-01 is a Thursday (=4). *)
  let weekday = (((days mod 7) + 4) mod 7 + 7) mod 7 in
  (* civil_from_days (Hinnant). *)
  let z = days + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = if m <= 2 then y + 1 else y in
  (y, m, d, h, mi, s, weekday)

let weekday_names =
  [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |]

let month_names =
  [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"; "Oct";
     "Nov"; "Dec" |]

let month_of_name s =
  let rec find i = if i >= 12 then None else if month_names.(i) = s then Some (i + 1) else find (i + 1) in
  find 0

(* TimeFormat: "Mon, 02 Jan 2006 15:04:05 GMT". *)
let format_time t =
  let y, mo, d, h, mi, s, wd = utc_of_unix t in
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT" weekday_names.(wd) d
    month_names.(mo - 1) y h mi s

(* The year of an expires value, for validCookieExpires. *)
let year_of t =
  let y, _, _, _, _, _, _ = utc_of_unix t in
  y

(* validCookieExpires: year must be >= 1601 (RFC 6265 5.1.1.5). *)
let valid_cookie_expires t = year_of t >= 1601

(* Parse "Wdy, DD Mon YYYY HH:MM:SS GMT" (RFC1123) and
   "Wdy, DD-Mon-YYYY HH:MM:SS MST". Returns Some unix_seconds (UTC) or None. *)
let parse_expires raw =
  (* Find the comma + space, then parse the remainder. *)
  match String.index_opt raw ',' with
  | None -> None
  | Some ci ->
      let rest = String.sub raw (ci + 1) (String.length raw - ci - 1) in
      let rest = trim_string rest in
      (* rest is like "23-Nov-2011 01:05:03 GMT" or "10 Nov 2009 23:00:00 GMT".
         Normalize '-' between date components to spaces for the date part. *)
      (* Split on spaces first. *)
      let try_parse rest =
        (* Replace '-' with ' ' only in the leading date token group.
           Simpler: split into space-separated tokens; the date may itself be
           "DD-Mon-YYYY". *)
        let toks = String.split_on_char ' ' rest |> List.filter (fun s -> s <> "") in
        match toks with
        | [ date; time; _tz ] when String.contains date '-' ->
            (* DD-Mon-YYYY HH:MM:SS TZ *)
            (match String.split_on_char '-' date with
            | [ dd; mon; yyyy ] -> Some (dd, mon, yyyy, time)
            | _ -> None)
        | [ dd; mon; yyyy; time; _tz ] -> Some (dd, mon, yyyy, time)
        | _ -> None
      in
      (match try_parse rest with
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
                (int_of_string_opt hh, int_of_string_opt mi, int_of_string_opt ss)
              with
              | Some h, Some min_, Some s
                when d >= 1
                     && d
                        <= (if m = 2 && is_leap y then 29
                            else days_in_month.(m - 1))
                     && h < 24 && min_ < 60 && s < 60 ->
                  Some (unix_of_utc y m d h min_ s)
              | _ -> None)
          | _ -> None))

(* ---- ParseSetCookie ---- *)

let parse_set_cookie line =
  let parts = split_char (trim_string line) ';' in
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
              let c =
                ref
                  {
                    default with
                    name;
                    value;
                    quoted;
                    raw = line;
                  }
              in
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
                                c := { !c with same_site = Same_site_default_mode }
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
                          | "partitioned" ->
                              c := { !c with partitioned = true }
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
      (fun line -> match parse_set_cookie line with Ok c -> Some c | Error _ -> None)
      lines

(* ---- readCookies ---- *)

let read_cookies (h : Header.t) ~filter =
  let lines = Header.values h "Cookie" in
  if lines = [] then []
  else
    let cookie_count =
      List.fold_left (fun acc line -> acc + count_char line ';' + 1) 0 lines
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
    if String.length c.domain > 0 then begin
      if valid_cookie_domain c.domain then begin
        let d =
          if c.domain.[0] = '.' then
            String.sub c.domain 1 (String.length c.domain - 1)
          else c.domain
        in
        Buffer.add_string b "; Domain=";
        Buffer.add_string b d
      end
      (* else: invalid domain dropped (Go logs a warning; omitted). *)
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

let valid c =
  if not (is_token c.name) then Error "http: invalid Cookie.Name"
  else if c.expires <> 0. && not (valid_cookie_expires c.expires) then
    Error "http: invalid Cookie.Expires"
  else
    let invalid_value =
      let bad = ref None in
      String.iter
        (fun b ->
          if !bad = None && not (valid_cookie_value_byte b) then
            bad := Some b)
        c.value;
      !bad
    in
    match invalid_value with
    | Some b -> Error (Printf.sprintf "http: invalid byte %C in Cookie.Value" b)
    | None ->
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
        (match invalid_path with
        | Some b -> Error (Printf.sprintf "http: invalid byte %C in Cookie.Path" b)
        | None ->
            if String.length c.domain > 0 && not (valid_cookie_domain c.domain)
            then Error "http: invalid Cookie.Domain"
            else if c.partitioned && not c.secure then
              Error "http: partitioned cookies must be set with Secure"
            else Ok ())
