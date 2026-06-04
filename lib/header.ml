(* Port of go/src/net/http/header.go (and the textproto canonicalization /
   MIMEHeader methods it delegates to).

   A [t] represents the key-value pairs in an HTTP header, i.e. Go's
   [Header map[string][]string]. We back it with a [Hashtbl] keyed by canonical
   key, mirroring Go's hash map (one slice of values per key, mutated in place).
   Keys are expected to be in canonical form as produced by
   [canonical_header_key]. Iteration order is unspecified, matching Go; the wire
   format sorts keys ([write]/[write_subset]). *)

type t = (string, string list) Hashtbl.t

let create () : t = Hashtbl.create 8

(* Build a header from raw (key, values) entries, storing keys *verbatim*
   (no canonicalization), mirroring a Go map literal [map[string][]string{...}].
   Later duplicate keys overwrite earlier ones. *)
let of_list pairs : t =
  let h = Hashtbl.create (List.length pairs) in
  List.iter (fun (k, vs) -> Hashtbl.replace h k vs) pairs;
  h

(* All (key, values) entries, in unspecified order. *)
let to_list (h : t) = Hashtbl.fold (fun k vs acc -> (k, vs) :: acc) h []

(* Port of textproto.CanonicalMIMEHeaderKey, now living in the foundation
   library so the HTTP/2 stack can share it. *)
let canonical_header_key = Gohttp_base.Textproto.canonical_mime_header_key

(* Lookup helper operating on already-canonical keys. *)
let find_opt (h : t) key = Hashtbl.find_opt h key

(* MIMEHeader.Add: appends to any existing values associated with the canonical
   key. *)
let add h key value =
  let key = canonical_header_key key in
  match find_opt h key with
  | Some vs -> Hashtbl.replace h key (vs @ [ value ])
  | None -> Hashtbl.replace h key [ value ]

(* MIMEHeader.Set: replaces existing values with the single element value. *)
let set h key value = Hashtbl.replace h (canonical_header_key key) [ value ]

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
let del h key = Hashtbl.remove h (canonical_header_key key)

(* Header.has: whether the key is defined. *)
let has h key = Hashtbl.mem h (canonical_header_key key)

(* Header.Clone: a copy of h. Value lists are immutable, so a shallow table copy
   suffices. *)
let clone (h : t) = Hashtbl.copy h

(* httpguts.ValidHeaderFieldName: a non-empty token. *)
let valid_header_field_name s =
  String.length s > 0
  && String.for_all Gohttp_base.Textproto.valid_header_field_byte s

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
    Hashtbl.fold (fun k vs acc -> if excluded k then acc else (k, vs) :: acc) h []
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
