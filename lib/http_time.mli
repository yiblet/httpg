(* Shared HTTP-date formatting/parsing, mirroring go/src/net/http's
   [http.TimeFormat] and [http.ParseTime]. Times are modeled as Unix-epoch
   seconds (UTC), as elsewhere in this port. Extracted from the hand-written
   GMT formatter/parser originally in {!Cookie}, so [Cookie] and [Fs] share it. *)

(** Go's [http.TimeFormat]: ["Mon, 02 Jan 2006 15:04:05 GMT"] (RFC1123 with a
    fixed GMT zone). [format_gmt t] formats the Unix-epoch time [t] (seconds,
    UTC) in that layout. *)
val format_gmt : float -> string

(** Go's [http.ParseTime]: parse an HTTP-date, trying in order
    [TimeFormat] (RFC1123 GMT), [time.RFC850]
    (["Monday, 02-Jan-06 15:04:05 GMT"]) and [time.ANSIC] asctime
    (["Mon Jan _2 15:04:05 2006"]). Returns [Some] Unix-epoch seconds (UTC) on
    success, or [None] if the string matches none of the layouts. *)
val parse_http_time : string -> float option

(* ---- civil-date primitives (shared with {!Cookie}) ---- *)

(** Days-in-month table for a non-leap year (index 0 = January). *)
val days_in_month : int array

(** Whether [y] is a Gregorian leap year. *)
val is_leap : int -> bool

(** [days_from_civil y m d] is the day count from 1970-01-01 to the civil date
    [y]-[m]-[d] (Howard Hinnant's algorithm). *)
val days_from_civil : int -> int -> int -> int

(** [unix_of_utc y mo d h mi s] is the Unix-epoch seconds for the UTC civil
    date/time. *)
val unix_of_utc : int -> int -> int -> int -> int -> int -> float

(** [utc_of_unix t] decomposes Unix-epoch seconds [t] into
    [(year, month, day, hour, min, sec, weekday)] where [weekday] is
    [0]=Sunday .. [6]=Saturday (UTC). *)
val utc_of_unix : float -> int * int * int * int * int * int * int

(** Abbreviated weekday names indexed by [0]=Sun .. [6]=Sat. *)
val weekday_names : string array

(** Abbreviated month names indexed by [0]=Jan .. [11]=Dec. *)
val month_names : string array

(** [month_of_name s] maps an abbreviated month name (e.g. ["Jan"]) to its
    1-based number, or [None]. *)
val month_of_name : string -> int option
