(* Port of go/src/net/http/mapping.go.

   A mapping stores entries in a slice ([s]) while small, switching to a
   Hashtbl ([m]) once more than [max_slice] pairs are present. This mirrors
   Go's hybrid [mapping[K, V]] struct (slice for few pairs, map for many). *)

type ('k, 'v) entry = { key : 'k; value : 'v }

type ('k, 'v) t = {
  (* for few pairs; stored most-recent-last like Go's append *)
  mutable s : ('k, 'v) entry list;
  (* for many pairs *)
  mutable m : ('k, 'v) Hashtbl.t option;
}

(* maxSlice is the maximum number of pairs for which a slice is used. *)
let max_slice = 8

let create () = { s = []; m = None }

let using_map h = h.m <> None

(* add adds a key-value pair to the mapping. *)
let add h k v =
  match h.m with
  | None when List.length h.s < max_slice ->
    (* append to slice *)
    h.s <- h.s @ [ { key = k; value = v } ]
  | _ ->
    let tbl =
      match h.m with
      | Some tbl -> tbl
      | None ->
        let tbl = Hashtbl.create 16 in
        List.iter (fun e -> Hashtbl.replace tbl e.key e.value) h.s;
        h.s <- [];
        h.m <- Some tbl;
        tbl
    in
    Hashtbl.replace tbl k v

(* find returns the value corresponding to the given key. *)
let find h k =
  match h.m with
  | Some tbl -> Hashtbl.find_opt tbl k
  | None ->
    let rec loop = function
      | [] -> None
      | e :: rest -> if e.key = k then Some e.value else loop rest
    in
    loop h.s

(* eachPair calls f for each pair. If f returns false, iteration stops. *)
let each_pair h f =
  match h.m with
  | Some tbl ->
    let exception Stop in
    (try Hashtbl.iter (fun k v -> if not (f k v) then raise Stop) tbl
     with Stop -> ())
  | None ->
    let rec loop = function
      | [] -> ()
      | e :: rest -> if f e.key e.value then loop rest
    in
    loop h.s
