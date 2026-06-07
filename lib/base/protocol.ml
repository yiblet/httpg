(* The HTTP protocol version, Go's [Request.Proto]/[ProtoMajor]/[ProtoMinor]
   collapsed into one typed value. *)

type t =
  | Http10 (* "HTTP/1.0" *)
  | Http11 (* "HTTP/1.1" *)
  | Http20 (* "HTTP/2.0" *)
  | Other of int * int

let to_string = function
  | Http10 -> "HTTP/1.0"
  | Http11 -> "HTTP/1.1"
  | Http20 -> "HTTP/2.0"
  | Other (major, minor) -> Printf.sprintf "HTTP/%d.%d" major minor

(* normalize maps a parsed (major, minor) pair onto the named constructors so
   that [Other] never duplicates one of them. *)
let normalize = function
  | 1, 0 -> Http10
  | 1, 1 -> Http11
  | 2, 0 -> Http20
  | major, minor -> Other (major, minor)

(* ParseHTTPVersion(vers). *)
let of_string (vers : string) : t option =
  match vers with
  | "HTTP/1.1" -> Some Http11
  | "HTTP/1.0" -> Some Http10
  | _ ->
      let prefix = "HTTP/" in
      let n = String.length vers in
      if n <> String.length "HTTP/X.Y" then None
      else if not (String.length vers >= 5 && String.sub vers 0 5 = prefix) then
        None
      else if vers.[6] <> '.' then None
      else begin
        (* strconv.ParseUint on a single digit: reject non-digit, '+', leading
           signs. Single char so leading zeros are not an issue here. *)
        let parse_digit c =
          if c >= '0' && c <= '9' then Some (Char.code c - Char.code '0')
          else None
        in
        match (parse_digit vers.[5], parse_digit vers.[7]) with
        | Some maj, Some min -> Some (normalize (maj, min))
        | _ -> None
      end

let major = function
  | Http10 | Http11 -> 1
  | Http20 -> 2
  | Other (major, _) -> major

let minor = function
  | Http10 | Http20 -> 0
  | Http11 -> 1
  | Other (_, minor) -> minor

(* Request.ProtoAtLeast / Response.ProtoAtLeast. *)
let at_least t major_ minor_ =
  let maj = major t and min_ = minor t in
  maj > major_ || (maj = major_ && min_ >= minor_)

let http10 = Http10
let http11 = Http11
let http20 = Http20
