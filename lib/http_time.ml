(* Shared HTTP-date formatting/parsing, mirroring go/src/net/http's
   [http.TimeFormat] and [http.ParseTime]. See http_time.mli. *)

let days_in_month = [| 31; 28; 31; 30; 31; 30; 31; 31; 30; 31; 30; 31 |]

let is_leap y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0

(* Days from civil date to days since 1970-01-01 (Howard Hinnant's algorithm). *)
let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = ((153 * (if m > 2 then m - 3 else m + 9) + 2) / 5) + d - 1 in
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
  let weekday = ((((days mod 7) + 4) mod 7) + 7) mod 7 in
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

let weekday_names = [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |]

let weekday_long_names =
  [| "Sunday"; "Monday"; "Tuesday"; "Wednesday"; "Thursday"; "Friday";
     "Saturday" |]

let month_names =
  [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"; "Oct";
     "Nov"; "Dec" |]

let month_of_name s =
  let rec find i =
    if i >= 12 then None
    else if month_names.(i) = s then Some (i + 1)
    else find (i + 1)
  in
  find 0

(* http.TimeFormat: "Mon, 02 Jan 2006 15:04:05 GMT". *)
let format_gmt t =
  let y, mo, d, h, mi, s, wd = utc_of_unix t in
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT" weekday_names.(wd) d
    month_names.(mo - 1) y h mi s

(* ---- parsing ---- *)

(* Validate a fully decomposed date/time and return Some unix seconds. *)
let make_time y m d h mi s =
  if
    m >= 1 && m <= 12
    && d >= 1
    && d <= (if m = 2 && is_leap y then 29 else days_in_month.(m - 1))
    && h < 24 && mi < 60 && s < 60
  then Some (unix_of_utc y m d h mi s)
  else None

(* Parse "HH:MM:SS" into (h,mi,s). *)
let parse_hms time =
  match String.split_on_char ':' time with
  | [ hh; mm; ss ] -> (
      match
        (int_of_string_opt hh, int_of_string_opt mm, int_of_string_opt ss)
      with
      | Some h, Some mi, Some s -> Some (h, mi, s)
      | _ -> None)
  | _ -> None

let split_ws s =
  String.split_on_char ' ' s |> List.filter (fun x -> x <> "")

(* RFC1123: "Mon, 02 Jan 2006 15:04:05 GMT". Day is zero-padded; weekday is the
   abbreviated form. We tolerate the comma and require a "GMT" zone token. *)
let parse_rfc1123 s =
  match String.index_opt s ',' with
  | None -> None
  | Some ci -> (
      let rest = String.sub s (ci + 1) (String.length s - ci - 1) in
      match split_ws rest with
      | [ dd; mon; yyyy; time; tz ] when tz = "GMT" -> (
          match
            ( int_of_string_opt dd,
              month_of_name mon,
              int_of_string_opt yyyy,
              parse_hms time )
          with
          | Some d, Some m, Some y, Some (h, mi, s) -> make_time y m d h mi s
          | _ -> None)
      | _ -> None)

(* RFC850: "Monday, 02-Jan-06 15:04:05 GMT". 2-digit year, full weekday name,
   date components separated by '-'. Go's time package interprets the 2-digit
   year via the reference year 2006 as: year >= 69 -> 1900+yy else 2000+yy. *)
let parse_rfc850 s =
  match String.index_opt s ',' with
  | None -> None
  | Some ci -> (
      let rest = String.sub s (ci + 1) (String.length s - ci - 1) in
      match split_ws rest with
      | [ date; time; tz ] when tz = "GMT" -> (
          match String.split_on_char '-' date with
          | [ dd; mon; yy ] -> (
              match
                ( int_of_string_opt dd,
                  month_of_name mon,
                  int_of_string_opt yy,
                  parse_hms time )
              with
              | Some d, Some m, Some yy, Some (h, mi, s) ->
                  let y = if yy >= 69 then 1900 + yy else 2000 + yy in
                  make_time y m d h mi s
              | _ -> None)
          | _ -> None)
      | _ -> None)

(* ANSI C asctime: "Mon Jan _2 15:04:05 2006". The day is space-padded (so
   single-digit days appear as e.g. "Jan  2"); collapsing runs of spaces makes
   the day a single token. *)
let parse_asctime s =
  match split_ws s with
  | [ _wd; mon; dd; time; yyyy ] -> (
      match
        ( month_of_name mon,
          int_of_string_opt dd,
          parse_hms time,
          int_of_string_opt yyyy )
      with
      | Some m, Some d, Some (h, mi, s), Some y -> make_time y m d h mi s
      | _ -> None)
  | _ -> None

let parse_http_time s =
  match parse_rfc1123 s with
  | Some _ as r -> r
  | None -> (
      match parse_rfc850 s with
      | Some _ as r -> r
      | None -> parse_asctime s)

let _ = weekday_long_names
