(* Port of go/src/net/http/mapping.go.

   A mapping stores entries in a slice ([s]) while small, switching to a
   Hashtbl ([m]) once more than [max_slice] pairs are present. This mirrors
   Go's hybrid [mapping[K, V]] struct (slice for few pairs, map for many). *)

type ('k, 'v) entry = { key : 'k; value : 'v }

type ('k, 'v) layout =
  | Empty
  | Small of ('k, 'v) entry Dynarray.t
  | Large of ('k, 'v) Hashtbl.t

type ('k, 'v) t = ('k, 'v) layout ref

(* maxSlice is the maximum number of pairs for which a slice is used. *)
let max_slice = 8
let create () = ref Empty
let using_map h = match !h with Large _ -> true | _ -> false

let length h =
  match !h with
  | Empty -> 0
  | Small v -> Dynarray.length v
  | Large h -> Hashtbl.length h

(* add adds a key-value pair to the mapping. *)
let add (h : ('k, 'v) t) k v =
  h :=
    match !h with
    | Empty -> Small (Dynarray.make 1 { key = k; value = v })
    | Small d when Dynarray.length d < max_slice ->
        Small
          (Dynarray.add_last d { key = k; value = v };
           d)
    | Small d -> begin
        let seq = d |> Dynarray.to_seq |> Seq.map (fun e -> (e.key, e.value)) in
        Large (Hashtbl.of_seq (Seq.cons (k, v) seq))
      end
    | Large h ->
        Large
          (Hashtbl.replace h k v;
           h)

(* find returns the value corresponding to the given key. *)
let find h k =
  match !h with
  | Empty -> None
  | Small d ->
      Dynarray.find_opt (fun e -> e.key = k) d |> Option.map (fun e -> e.value)
  | Large h -> Hashtbl.find_opt h k

(* eachPair calls f for each pair. If f returns false, iteration stops. *)
let each_pair h f =
  let exception Stop in
  try
    match !h with
    | Empty -> ()
    | Small d ->
        Dynarray.iter (fun e -> if not (f e.key e.value) then raise Stop) d
    | Large h -> Hashtbl.iter (fun k v -> if not (f k v) then raise Stop) h
  with Stop -> ()

module Private = struct
  let max_slice = max_slice
end
