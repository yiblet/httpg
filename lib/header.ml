(* Port of go/src/net/http/header.go (and the textproto canonicalization /
   MIMEHeader methods it delegates to).

   A [t] represents the key-value pairs in an HTTP header, i.e. Go's
   [Header map[string][]string]. Unlike Go's mutable map we back it with a
   *persistent* [Map] keyed by canonical key (one value list per key), so the
   mutating helpers ([add]/[set]/[del]) return a new header and copy-on-write is
   free (structural sharing) — this is what lets [Response] be an immutable
   builder. Keys are expected to be in canonical form as produced by
   [canonical_header_key]. [Map] iterates in sorted key order, which is the order
   the wire format wants ([write]/[write_subset]). *)

module Canonical : sig
  type t

  val of_string : string -> t
  val to_string : t -> string
  val compare : t -> t -> int
end = struct
  type t = string

  let of_string s = Httpg_base.Textproto.canonical_mime_header_key s
  let to_string s = s
  let compare = String.compare
end

module M = Map.Make (Canonical)

type t = string list M.t

let create () : t = M.empty

(* Build a header from (key, values) entries (keys canonicalized). Later
   duplicate keys overwrite earlier ones. *)
let of_list pairs : t =
  List.fold_left
    (fun m (k, vs) -> M.add (Canonical.of_string k) vs m)
    M.empty pairs

(* All (key, values) entries, in sorted (canonical) key order. *)
let to_list (h : t) =
  List.map (fun (k, vs) -> (Canonical.to_string k, vs)) (M.bindings h)

(* Port of textproto.CanonicalMIMEHeaderKey, now living in the foundation
   library so the HTTP/2 stack can share it. *)
let canonical_header_key = Httpg_base.Textproto.canonical_mime_header_key

(* Lookup helper operating on already-canonical keys. *)
let find_opt (h : t) key = M.find_opt key h

(* MIMEHeader.Add: appends to any existing values associated with the canonical
   key. *)
let add h key value =
  let key = Canonical.of_string key in
  match find_opt h key with
  | Some vs -> M.add key (vs @ [ value ]) h
  | None -> M.add key [ value ] h

(* MIMEHeader.Set: replaces existing values with the single element value. *)
let set h key value = M.add (Canonical.of_string key) [ value ] h

(* Replace the whole value list for the canonical key (used to record a trailer
   key, possibly with [[]], and for header merges). *)
let set_values h key vs = M.add (Canonical.of_string key) vs h

(* MIMEHeader.Get: first value or "". *)
let get h key =
  match find_opt h (Canonical.of_string key) with Some (v :: _) -> v | _ -> ""

(* MIMEHeader.Values: all values for the key (or [] when absent). *)
let values h key =
  match find_opt h (Canonical.of_string key) with Some vs -> vs | None -> []

(* MIMEHeader.Del. *)
let del h key = M.remove (Canonical.of_string key) h

(* Header.has: whether the key is defined. *)
let has h key = M.mem (Canonical.of_string key) h

(* Whether the header has no entries. *)
let is_empty (h : t) = M.is_empty h

(* Number of distinct keys. *)
let cardinal (h : t) = M.cardinal h

(* Iterate over (key, values) entries in sorted key order. *)
let iter f (h : t) =
  let f' k = Canonical.to_string k |> f in
  M.iter f' h

(* Fold over (key, values) entries in sorted key order. *)
let fold f (h : t) acc =
  let f' k = Canonical.to_string k |> f in
  M.fold f' h acc

(* httpguts.ValidHeaderFieldName: a non-empty token. *)
let valid_header_field_name s =
  String.length s > 0
  && String.for_all Httpg_base.Textproto.valid_header_field_byte s

(* headerNewlineToSpace: replace '\n' and '\r' with ' '. *)
let newline_to_space s = String.map (function '\n' | '\r' -> ' ' | c -> c) s

(* textproto.TrimString: trim leading/trailing ' ' and '\t'. *)
let trim_string = Httpg_base.Textproto.trim_string

(* Header.writeSubset: write keys (sorted) not present in [exclude], one
   [Key: value\r\n] line per value, dropping keys with invalid field names. The
   [Map] already iterates in sorted key order. *)
let write_subset h buf ~exclude =
  let module Set = Set.Make (Canonical) in
  let exclude_canonical = Set.of_list (List.map Canonical.of_string exclude) in
  let excluded k = Set.mem k exclude_canonical in
  M.iter
    (fun key vals ->
      if
        (not (excluded key))
        && valid_header_field_name (Canonical.to_string key)
      then
        List.iter
          (fun v ->
            let v = trim_string (newline_to_space v) in
            Buffer.add_string buf (Canonical.to_string key);
            Buffer.add_string buf ": ";
            Buffer.add_string buf v;
            Buffer.add_string buf "\r\n")
          vals)
    h

(* Header.Write / Header.write. *)
let write h buf = write_subset h buf ~exclude:[]
