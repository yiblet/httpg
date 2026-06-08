(* Shared HTTP-date formatting/parsing, mirroring go/src/net/http's
   [http.TimeFormat] and [http.ParseTime]. Times are modeled as Unix-epoch
   seconds (UTC), as elsewhere in this port. Extracted from the hand-written
   GMT formatter/parser originally in {!Cookie}, so [Cookie] and [Fs] share it. *)

val format_gmt : float -> string
(** Go's [http.TimeFormat]: ["Mon, 02 Jan 2006 15:04:05 GMT"] (RFC1123 with a
    fixed GMT zone). [format_gmt t] formats the Unix-epoch time [t] (seconds,
    UTC) in that layout. *)

val parse_http_time : string -> float option
(** Go's [http.ParseTime]: parse an HTTP-date, trying in order [TimeFormat]
    (RFC1123 GMT), [time.RFC850] (["Monday, 02-Jan-06 15:04:05 GMT"]) and
    [time.ANSIC] asctime (["Mon Jan _2 15:04:05 2006"]). Returns [Some]
    Unix-epoch seconds (UTC) on success, or [None] if the string matches none of
    the layouts. *)

(* ---- civil-date primitives (shared with {!Cookie}) ---- *)

val days_in_month : int array
(** Days-in-month table for a non-leap year (index 0 = January). *)

val is_leap : int -> bool
(** Whether [y] is a Gregorian leap year. *)

val unix_of_utc : int -> int -> int -> int -> int -> int -> float
(** [unix_of_utc y mo d h mi s] is the Unix-epoch seconds for the UTC civil
    date/time (via {!Ptime.of_date_time}). The components must form a valid
    date/time — {!invalid_arg} is raised otherwise (callers on parse paths
    validate first via {!make_time}). *)

val utc_of_unix : float -> int * int * int * int * int * int * int
(** [utc_of_unix t] decomposes Unix-epoch seconds [t] into
    [(year, month, day, hour, min, sec, weekday)] where [weekday] is [0]=Sunday
    .. [6]=Saturday (UTC), via {!Ptime.to_date_time}/{!Ptime.weekday_num}. *)

val make_time : int -> int -> int -> int -> int -> int -> float option
(** [make_time y mo d h mi s] is [Some] the Unix-epoch seconds for the UTC civil
    date/time, or [None] if the components do not form a valid date/time
    (delegated to {!Ptime.of_date_time}). *)

val weekday_names : string array
(** Abbreviated weekday names indexed by [0]=Sun .. [6]=Sat. *)

val month_names : string array
(** Abbreviated month names indexed by [0]=Jan .. [11]=Dec. *)

val month_of_name : string -> int option
(** [month_of_name s] maps an abbreviated month name (e.g. ["Jan"]) to its
    1-based number, or [None]. *)
