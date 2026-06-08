(* Port of go/src/net/http/internal/ascii/print.go. *)

(* lower returns the ASCII lowercase version of b. *)
let lower b =
  if b >= 'A' && b <= 'Z' then
    Char.chr (Char.code b + (Char.code 'a' - Char.code 'A'))
  else b

(* hex_val decodes a single hex nibble: '0'..'9' -> 0..9, 'a'..'f'/'A'..'F' ->
   10..15, and [None] for any other byte. The per-nibble primitive shared by the
   faithful hex parsers (chunked length, URL/path unescape). *)
let hex_val c =
  if c >= '0' && c <= '9' then Some (Char.code c - Char.code '0')
  else if c >= 'a' && c <= 'f' then Some (Char.code c - Char.code 'a' + 10)
  else if c >= 'A' && c <= 'F' then Some (Char.code c - Char.code 'A' + 10)
  else None

(* EqualFold is strings.EqualFold, ASCII only. *)
let equal_fold s t =
  String.length s = String.length t
  &&
  let ok = ref true in
  String.iteri (fun i c -> if lower c <> lower t.[i] then ok := false) s;
  !ok

(* IsPrint returns whether s is ASCII and printable. *)
let is_print s =
  let ok = ref true in
  String.iter (fun c -> if c < ' ' || c > '~' then ok := false) s;
  !ok

(* Is returns whether s is ASCII. *)
let is s =
  let ok = ref true in
  String.iter (fun c -> if Char.code c > 0x7f then ok := false) s;
  !ok

(* ToLower returns the lowercase version of s if s is ASCII and printable. *)
let to_lower s =
  if not (is_print s) then ("", false) else (String.map lower s, true)
