(* Port of go/src/net/http/header.go (and the textproto canonicalization /
   MIMEHeader methods it delegates to).

   A [t] represents the key-value pairs in an HTTP header, i.e. Go's
   [Header map[string][]string]. Unlike Go's mutable map we back it with a
   *persistent* [Map] keyed by canonical key (one value list per key), so the
   mutating helpers ([add]/[set]/[del]) return a new header and copy-on-write is
   free (structural sharing) — this is what lets [Response] be an immutable
   builder. Keys are expected to be in canonical form as produced by
   [canonical_header_key]. [Map] iterates in sorted key order, which is the order
   the wire format wants ([write]/[write_subset]).

   Values for a key live in a [Semideq], which keeps the *first-added* element
   at the front (O(1) [get], matching Go's [Get] returning [v[0]]) and appends
   at the back in O(1) ([add]). Boundaries that expose or accept a value list
   ([values]/[to_list]/[iter]/[fold]/[write_subset] out; [of_list]/[set_values]
   in) work in insertion (wire) order. *)

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

(* A "semi-deque": an incomplete deque supporting O(1) peek at the front
   ([hd]) and O(1) push on the back ([add]), but no pop/peek at the back. *)
module Semideq = struct
  (* Some helpers ([to_seq]/[map]/...) have no callers yet; keep them quiet. *)
  [@@@warning "-32"]

  type 'a t =
    | Empty
    | One of 'a
    | (* 'a represents the first element, and then the list is in reverse so appending to the back O(1) *)
      Many of 'a * 'a list

  let empty = Empty
  let create x = One x
  let head = function Empty -> None | One x -> Some x | Many (x, _) -> Some x

  let add x = function
    | Empty -> One x
    | One y -> Many (y, [ x ])
    | Many (y, ys) -> Many (y, x :: ys)

  let of_list = List.fold_left (Fun.flip add) empty

  let to_list = function
    | Empty -> []
    | One x -> [ x ]
    | Many (x, xs) -> x :: List.rev xs

  let to_seq = function
    | Empty -> Seq.empty
    | One x -> Seq.return x
    | Many (x, xs) ->
        let rest () = (xs |> List.rev |> List.to_seq) () in
        fun () -> Seq.Cons (x, rest)

  let map f = function
    | Empty -> Empty
    | One x -> One (f x)
    | Many (x, xs) -> Many (f x, List.map f xs)

  let of_seq = Seq.fold_left (fun acc x -> add x acc) empty

  let filter_take_last f ls =
    let cur = ref None in
    let rec filter ls =
      match ls with
      | [] -> []
      | x :: xs when f x -> (
          let old = !cur in
          cur := Some x;
          match old with None -> filter xs | Some y -> y :: filter xs)
      | _ :: xs -> filter xs
    in
    let res = filter ls in
    let cur = !cur in
    (res, cur)

  let filter f = function
    | Empty -> Empty
    | One x -> if f x then One x else Empty
    | Many (x, rem) when f x -> (
        let new_rem = List.filter f rem in
        match new_rem with [] -> One x | _ -> Many (x, new_rem))
    | Many (_, rem) -> (
        let xs, last = filter_take_last f rem in
        match last with
        | None -> Empty
        | Some x when List.is_empty xs -> One x
        | Some x -> Many (x, xs))
end

type t = string Semideq.t M.t

let create () : t = M.empty

(* Build a header from (key, values) entries (keys canonicalized). Later
   duplicate keys overwrite earlier ones. *)
let of_list pairs : t =
  List.fold_left
    (fun m (k, vs) -> M.add (Canonical.of_string k) (Semideq.of_list vs) m)
    M.empty pairs

(* All (key, values) entries, in sorted (canonical) key order. *)
let to_list (h : t) =
  List.map
    (fun (k, vs) -> (Canonical.to_string k, Semideq.to_list vs))
    (M.bindings h)

(* Port of textproto.CanonicalMIMEHeaderKey, now living in the foundation
   library so the HTTP/2 stack can share it. *)
let canonical_header_key = Httpg_base.Textproto.canonical_mime_header_key

(* Lookup helper operating on already-canonical keys. *)
let find_opt (h : t) key = M.find_opt key h
let filter_key f (h : t) = M.filter (fun k _ -> f (Canonical.to_string k)) h

let filter f (h : t) =
  M.filter
    (fun k vs ->
      let k = Canonical.to_string k in
      let vs = Semideq.to_list vs in
      f k vs)
    h

(* MIMEHeader.Add: appends to any existing values associated with the canonical
   key. *)
let add h key value =
  let key = Canonical.of_string key in
  match find_opt h key with
  | Some vs -> M.add key (Semideq.add value vs) h
  | None -> M.add key (Semideq.create value) h

(* MIMEHeader.Set: replaces existing values with the single element value. *)
let set h key value = M.add (Canonical.of_string key) (Semideq.create value) h

(* Replace the whole value list for the canonical key (used to record a trailer
   key, possibly with [[]], and for header merges). [vs] is in insertion
   order. *)
let set_values h key vs = M.add (Canonical.of_string key) (Semideq.of_list vs) h

(* MIMEHeader.Get: Some first value or None. *)
let get h key =
  find_opt h (Canonical.of_string key) |> Fun.flip Option.bind Semideq.head

(* MIMEHeader.Values: all values for the key (or [] when absent), in insertion
   order. *)
let values h key =
  match find_opt h (Canonical.of_string key) with
  | Some vs -> Semideq.to_list vs
  | None -> []

(* MIMEHeader.Del. *)
let del h key = M.remove (Canonical.of_string key) h

(* Header.has: whether the key is defined. *)
let has h key = M.mem (Canonical.of_string key) h

(* Whether the header has no entries. *)
let is_empty (h : t) = M.is_empty h

(* Number of distinct keys. *)
let cardinal (h : t) = M.cardinal h

(* Iterate over (key, values) entries in sorted key order, values in insertion
   order. *)
let iter f (h : t) =
  let f' k vs = f (Canonical.to_string k) (Semideq.to_list vs) in
  M.iter f' h

(* Fold over (key, values) entries in sorted key order, values in insertion
   order. *)
let fold f (h : t) acc =
  let f' k vs = f (Canonical.to_string k) (Semideq.to_list vs) in
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
let write_subset (h : string Semideq.t M.t) buf ~exclude =
  let module Set = Set.Make (Canonical) in
  let exclude_canonical = Set.of_list (List.map Canonical.of_string exclude) in
  let excluded k = Set.mem k exclude_canonical in
  M.iter
    (fun key (vals : string Semideq.t) ->
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
          (Semideq.to_list vals))
    h

(* Header.Write / Header.write. *)
let write h buf = write_subset h buf ~exclude:[]
