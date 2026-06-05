(* Ported from go/src/net/http/mapping_test.go. *)

open Gohttp

(* TestMapping: stays a slice up to max_slice, switches to map beyond. *)
let test_mapping () =
  let m = Mapping.create () in
  for i = 0 to Mapping.max_slice - 1 do
    Mapping.add m i (string_of_int i)
  done;
  Alcotest.(check bool) "still slice (m.m == nil)" false (Mapping.using_map m);
  for i = 0 to Mapping.max_slice - 1 do
    let g = Mapping.find m i in
    Alcotest.(check (option string))
      (Printf.sprintf "find %d" i)
      (Some (string_of_int i))
      g
  done;
  (* Adding one more switches to the map representation. *)
  Mapping.add m 4 "4";
  Alcotest.(check bool) "now map (m.m != nil)" true (Mapping.using_map m);
  Alcotest.(check (option string))
    "find 4 after switch" (Some "4") (Mapping.find m 4)

(* TestMappingEachPair: eachPair visits every pair (any order). *)
let test_each_pair () =
  let m = Mapping.create () in
  let want = Hashtbl.create 16 in
  for i = 0 to (Mapping.max_slice * 2) - 1 do
    let v = string_of_int i in
    Mapping.add m i v;
    Hashtbl.replace want i v
  done;
  Alcotest.(check bool) "switched to map" true (Mapping.using_map m);
  let got = Hashtbl.create 16 in
  Mapping.each_pair m (fun k v ->
      Hashtbl.replace got k v;
      true);
  (* Compare as sorted assoc lists. *)
  let to_sorted t =
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) t []
    |> List.sort (fun (a, _) (b, _) -> compare a b)
  in
  Alcotest.(check (list (pair int string)))
    "each_pair visits all" (to_sorted want) (to_sorted got)

(* eachPair early-exit (f returns false). *)
let test_each_pair_stop () =
  let m = Mapping.create () in
  for i = 0 to 2 do
    Mapping.add m i (string_of_int i)
  done;
  let count = ref 0 in
  Mapping.each_pair m (fun _ _ ->
      incr count;
      false);
  Alcotest.(check int) "stops after first" 1 !count

(* find on absent key, and in slice representation. *)
let test_find_absent () =
  let m = Mapping.create () in
  Mapping.add m 1 "one";
  Mapping.add m 2 "two";
  Alcotest.(check bool) "still slice" false (Mapping.using_map m);
  Alcotest.(check (option string)) "present" (Some "two") (Mapping.find m 2);
  Alcotest.(check (option string)) "absent" None (Mapping.find m 99)

let tests =
  [
    ("mapping_slice_to_map", `Quick, test_mapping);
    ("each_pair", `Quick, test_each_pair);
    ("each_pair_stop", `Quick, test_each_pair_stop);
    ("find_absent", `Quick, test_find_absent);
  ]
