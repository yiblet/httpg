(* Shared HTTP-date formatting/parsing, mirroring go/src/net/http's
   [http.TimeFormat] and [http.ParseTime]. See http_time.mli.

   Civil-date <-> Unix-seconds conversion and date validation are delegated to
   [Ptime] (Go's time package handles this internally); only the HTTP-specific
   layout assembly and the per-format tokenizers (RFC1123 / RFC850 / asctime)
   are hand-written here, since [Ptime] emits/parses only RFC3339. *)

let days_in_month = [| 31; 28; 31; 30; 31; 30; 31; 31; 30; 31; 30; 31 |]
let is_leap y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0

(* Convert civil date+time (UTC) to Unix seconds. Mirrors Go's
   time.Date(...).Unix(): the caller has already validated the components (via
   {!make_time} on the parse paths), so an out-of-range date here is a bug. *)
let unix_of_utc y mo d h mi s =
  match Ptime.of_date_time ((y, mo, d), ((h, mi, s), 0)) with
  | Some t -> Ptime.to_float_s t
  | None ->
      invalid_arg
        (Printf.sprintf
           "Http_time.unix_of_utc: invalid date %04d-%02d-%02d %02d:%02d:%02d" y
           mo d h mi s)

(* Inverse: Unix seconds -> (year, month, day, hour, min, sec, weekday).
   weekday: 0=Sunday .. 6=Saturday (same numbering as {!Ptime.weekday_num}). *)
let utc_of_unix t =
  match Ptime.of_float_s t with
  | None ->
      invalid_arg
        (Printf.sprintf "Http_time.utc_of_unix: %f out of Ptime range" t)
  | Some pt ->
      let (y, mo, d), ((h, mi, s), _tz) = Ptime.to_date_time pt in
      let weekday = Ptime.weekday_num pt in
      (y, mo, d, h, mi, s, weekday)

let weekday_names = [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |]

let weekday_long_names =
  [|
    "Sunday"; "Monday"; "Tuesday"; "Wednesday"; "Thursday"; "Friday"; "Saturday";
  |]

let month_names =
  [|
    "Jan";
    "Feb";
    "Mar";
    "Apr";
    "May";
    "Jun";
    "Jul";
    "Aug";
    "Sep";
    "Oct";
    "Nov";
    "Dec";
  |]

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
    month_names.(mo - 1)
    y h mi s

(* ---- parsing ---- *)

(* Validate a fully decomposed date/time and return Some unix seconds.
   [Ptime.of_date_time] returns [None] on an invalid date (bad month, day out of
   range for the month/year, out-of-range time), which subsumes the hand-rolled
   leap-year / days-in-month / range checks. *)
let make_time y m d h mi s =
  match Ptime.of_date_time ((y, m, d), ((h, mi, s), 0)) with
  | Some t -> Some (Ptime.to_float_s t)
  | None -> None

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

let split_ws s = String.split_on_char ' ' s |> List.filter (fun x -> x <> "")

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
      match parse_rfc850 s with Some _ as r -> r | None -> parse_asctime s)

let _ = weekday_long_names
