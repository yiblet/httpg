(* Port of go/src/net/http/header.go (and the textproto canonicalization /
   MIMEHeader methods it delegates to).

   A [t] represents the key-value pairs in an HTTP header, i.e. Go's
   [Header map[string][]string]. Keys are expected to be in canonical form as
   produced by [canonical_header_key]. We back the map with an association list
   keyed by canonical key; this preserves Go's "one slice of values per key"
   semantics. Ordering of insertion is preserved but is irrelevant to the wire
   format, which sorts keys ([write]/[write_subset]). *)

type t = { mutable entries : (string * string list) list }

let create () = { entries = [] }

(* validHeaderFieldByte: RFC 7230 token characters.
   tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
           "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA *)
let valid_header_field_byte c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_'
  | '`' | '|' | '~' ->
      true
  | _ -> false

let to_lower = Char.code 'a' - Char.code 'A'

(* canonicalMIMEHeaderKey for the case where [s] is known to contain only valid
   header field bytes: upper-case the first letter and any letter after '-',
   lower-case the rest. ASCII only. *)
let canonicalize_valid s =
  let b = Bytes.of_string s in
  let upper = ref true in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let c =
      if !upper && c >= 'a' && c <= 'z' then Char.chr (Char.code c - to_lower)
      else if (not !upper) && c >= 'A' && c <= 'Z' then
        Char.chr (Char.code c + to_lower)
      else c
    in
    Bytes.set b i c;
    upper := c = '-'
  done;
  Bytes.unsafe_to_string b

(* Port of textproto.CanonicalMIMEHeaderKey. If [s] contains a space or invalid
   header field bytes, it is returned unchanged. *)
let canonical_header_key s =
  let len = String.length s in
  (* Quick check for canonical encoding, mirroring CanonicalMIMEHeaderKey. *)
  let rec scan i upper =
    if i >= len then s
    else
      let c = s.[i] in
      if not (valid_header_field_byte c) then s
      else if upper && c >= 'a' && c <= 'z' then canonicalize_valid s
      else if (not upper) && c >= 'A' && c <= 'Z' then canonicalize_valid s
      else scan (i + 1) (c = '-')
  in
  scan 0 true

(* Lookup helpers operating on already-canonical keys. *)
let find_opt h key = List.assoc_opt key h.entries

let set_entry h key values =
  let rec replace = function
    | [] -> [ (key, values) ]
    | (k, _) :: rest when k = key -> (key, values) :: rest
    | kv :: rest -> kv :: replace rest
  in
  h.entries <- replace h.entries

let remove_entry h key =
  h.entries <- List.filter (fun (k, _) -> k <> key) h.entries

(* MIMEHeader.Add: appends to any existing values associated with the canonical
   key. *)
let add h key value =
  let key = canonical_header_key key in
  match find_opt h key with
  | Some vs -> set_entry h key (vs @ [ value ])
  | None -> set_entry h key [ value ]

(* MIMEHeader.Set: replaces existing values with the single element value. *)
let set h key value = set_entry h (canonical_header_key key) [ value ]

(* MIMEHeader.Get: first value or "". *)
let get h key =
  match find_opt h (canonical_header_key key) with
  | Some (v :: _) -> v
  | _ -> ""

(* MIMEHeader.Values: all values for the key (or [] when absent). *)
let values h key =
  match find_opt h (canonical_header_key key) with
  | Some vs -> vs
  | None -> []

(* MIMEHeader.Del. *)
let del h key = remove_entry h (canonical_header_key key)

(* Header.has: whether the key is defined (even with a 0-length slice). *)
let has h key = List.mem_assoc (canonical_header_key key) h.entries

(* Header.Clone: a copy of h. We have no nil header concept, so an empty header
   clones to an empty header. Value lists are copied. *)
let clone h =
  { entries = List.map (fun (k, vs) -> (k, List.map Fun.id vs)) h.entries }

(* httpguts.ValidHeaderFieldName: a non-empty token. *)
let valid_header_field_name s =
  String.length s > 0 && String.for_all valid_header_field_byte s

(* headerNewlineToSpace: replace '\n' and '\r' with ' '. *)
let newline_to_space s =
  String.map (function '\n' | '\r' -> ' ' | c -> c) s

(* textproto.TrimString: trim leading/trailing ' ' and '\t'. *)
let trim_string s =
  let is_ws c = c = ' ' || c = '\t' in
  let n = String.length s in
  let i = ref 0 in
  while !i < n && is_ws s.[!i] do
    incr i
  done;
  let j = ref (n - 1) in
  while !j >= !i && is_ws s.[!j] do
    decr j
  done;
  String.sub s !i (!j - !i + 1)

(* Header.writeSubset: write keys (sorted) not present in [exclude], one
   [Key: value\r\n] line per value, dropping keys with invalid field names. *)
let write_subset h buf ~exclude =
  let excluded k = List.mem k exclude in
  let kvs =
    List.filter (fun (k, _) -> not (excluded k)) h.entries
  in
  let kvs = List.sort (fun (a, _) (b, _) -> String.compare a b) kvs in
  List.iter
    (fun (key, vals) ->
      if valid_header_field_name key then
        List.iter
          (fun v ->
            let v = trim_string (newline_to_space v) in
            Buffer.add_string buf key;
            Buffer.add_string buf ": ";
            Buffer.add_string buf v;
            Buffer.add_string buf "\r\n")
          vals)
    kvs

(* Header.Write / Header.write. *)
let write h buf = write_subset h buf ~exclude:[]
