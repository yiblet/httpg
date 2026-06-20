(* Port of go/src/net/http/routing_tree.go.

   The decision tree used by ServeMux. Each node is both leaf and interior:
   a leaf holds a pattern + handler; an interior node maps request parts to
   children. Special children keys: "/" is a trailing slash (from {$}), ""
   is a single wildcard. *)

module Method = Httpg_base.Method
module Pattern = Httpg_base.Pattern

module ChildKey = struct
  type t = Meth of Method.t | Literal of string | Empty

  let of_string = function "" -> Empty | s -> Literal s

  (* A pattern's host/method are options where [None] = "any" (Go's empty
     string). Both collapse to [Empty], the slot the match fallback consults. *)
  let of_host = function None -> Empty | Some h -> of_string h
  let of_method = function None -> Empty | Some m -> Meth m

  let to_string = function
    | Empty -> ""
    | Literal s -> s
    | Meth m -> Method.to_string m

  let compare a b =
    match (a, b) with
    | Empty, Empty -> 0
    | Empty, _ -> -1
    | _, Empty -> 1
    | Meth m1, Meth m2 ->
        String.compare (Method.to_string m1) (Method.to_string m2)
    | Meth _, _ -> -1
    | _, Meth _ -> 1
    | Literal s1, Literal s2 -> String.compare s1 s2
end

module ChildKeyMap = Map.Make (ChildKey)

let each_pair f m =
  let exception Stop in
  try ChildKeyMap.iter (fun k v -> if not (f k v) then raise Stop) m
  with Stop -> ()

type 'h node = {
  (* leaf fields *)
  leaf : (Pattern.t * 'h) option;
  (* interior fields *)
  children : 'h node ChildKeyMap.t;
  multi_child : 'h node option; (* child with multi wildcard *)
  empty_child : 'h node option; (* optimization: child with key "" *)
}

let rec map f n =
  {
    leaf = Option.map (fun (p, h) -> (p, f p h)) n.leaf;
    children = ChildKeyMap.map (fun n -> map f n) n.children;
    multi_child = Option.map (map f) n.multi_child;
    empty_child = Option.map (map f) n.empty_child;
  }

let to_seq n =
  let rec walk_children ck =
    ChildKeyMap.to_seq ck |> Seq.flat_map (fun (_, child) -> walk child)
  and walk (n : 'h node) : (Pattern.t * 'h) Seq.t =
    let leaf = Option.map Seq.return n.leaf in
    let children = Option.some (walk_children n.children) in
    let multi_child = Option.map walk n.multi_child in
    let empty_child = Option.map walk n.empty_child in
    [ leaf; children; multi_child; empty_child ]
    |> List.filter_map Fun.id |> List.to_seq |> Seq.concat
  in
  walk n

type 'h t = 'h node

let make_node =
  {
    leaf = None;
    children = ChildKeyMap.empty;
    multi_child = None;
    empty_child = None;
  }

let empty = make_node

(* set sets the pattern and handler for n, which must be a leaf node. *)
let set p h n : 'a t =
  if n.leaf <> None then failwith "non-nil leaf fields";
  { n with leaf = Some (p, h) }

(* findChild returns the child with the given key, or None. *)
let find_child n (key : ChildKey.t) =
  if key = ChildKey.Empty then n.empty_child
  else ChildKeyMap.find_opt key n.children

(* addChild adds a child node with the given key if absent, returns it. *)
let upsert_child (key : ChildKey.t) (update : 'a t -> 'a t) n =
  (* helper function to convert None to make_node. *)
  let node_opt = Option.value ~default:make_node in
  if key = ChildKey.Empty then
    { n with empty_child = Some (update (node_opt n.empty_child)) }
  else
    let child = ChildKeyMap.find_opt key n.children in
    {
      n with
      children = ChildKeyMap.add key (update (node_opt child)) n.children;
    }

(* addSegments adds the given segments to the tree rooted at n. *)
let rec add_segments (segs : Pattern.Segment.t list) p h (n : 'h t) =
  match segs with
  | [] -> set p h n
  | seg :: rest -> (
      match seg with
      | Pattern.Segment.Multi _ ->
          if rest <> [] then failwith "multi wildcard not last";
          let c = make_node |> set p h in
          { n with multi_child = Some c }
      | Pattern.Segment.Wild _ ->
          upsert_child ChildKey.Empty (add_segments rest p h) n
      | Pattern.Segment.Lit s ->
          upsert_child (ChildKey.of_string s) (add_segments rest p h) n)

(* addPattern: host -> method -> path. *)
let add_pattern (p : Pattern.t) h root =
  upsert_child
    (ChildKey.of_host (Pattern.host p))
    (upsert_child
       (ChildKey.of_method (Pattern.method_ p))
       (add_segments (Pattern.segments p) p h))
    root

(* firstSegment splits path into its first segment and the rest. *)
let first_segment path =
  if path = "/" then ("/", "")
  else begin
    let path = String.sub path 1 (String.length path - 1) in
    let i = try String.index path '/' with Not_found -> String.length path in
    ( Pattern.path_unescape (String.sub path 0 i),
      String.sub path i (String.length path - i) )
  end

(* matchPath matches a path against node n. matches holds wildcard matches so
   far. Returns the leaf and the full matches list. *)
let rec match_path (n : 'h node option) path matches =
  match n with
  | None -> None
  | Some n ->
      if path = "" then
        match n.leaf with None -> None | Some (p, h) -> Some ((p, h), matches)
      else begin
        let seg, rest = first_segment path in
        (* Try a literal child first (more specific). *)
        match
          match_path (find_child n (ChildKey.of_string seg)) rest matches
        with
        | Some _ as r -> r
        | None -> (
            (* Try a single wildcard (empty-string child), unless trailing slash. *)
            let wild_result =
              if seg <> "/" then
                match_path n.empty_child rest (matches @ [ seg ])
              else None
            in
            match wild_result with
            | Some _ as r -> r
            | None -> (
                (* Lastly, the multi wildcard. *)
                match n.multi_child with
                | None -> None
                | Some c -> (
                    let matches =
                      match c.leaf with
                      | Some (p, _)
                        when Pattern.Segment.text (Pattern.last_segment p) <> ""
                        ->
                          matches
                          @ [
                              Pattern.path_unescape
                                (String.sub path 1 (String.length path - 1));
                            ]
                      | _ -> matches
                    in
                    match c.leaf with
                    | Some (p, h) -> Some ((p, h), matches)
                    | None -> None)))
      end

(* matchMethodAndPath matches the method and path. Receiver is a child of root. *)
let match_method_and_path (n : 'h node option) (method_ : Method.t) path =
  match n with
  | None -> None
  | Some n -> (
      match match_path (find_child n (ChildKey.Meth method_)) path [] with
      | Some _ as r -> r
      | None -> (
          let head_result =
            if method_ = Method.Head then
              match_path (find_child n (ChildKey.Meth Method.Get)) path []
            else None
          in
          match head_result with
          | Some _ as r -> r
          | None -> match_path n.empty_child path []))

let match_ root ~host ~method_ ~path =
  if host <> "" then
    match
      match_method_and_path
        (find_child root (ChildKey.of_string host))
        method_ path
    with
    | Some _ as r -> r
    | None -> match_method_and_path root.empty_child method_ path
  else match_method_and_path root.empty_child method_ path

(* matchingMethodsPath. *)
let matching_methods_path (n : 'h node option) path set =
  match n with
  | None -> ()
  | Some n ->
      each_pair
        (fun method_ c ->
          (match (method_, match_path (Some c) path []) with
          | ChildKey.Meth m, Some _ -> Hashtbl.replace set m true
          | _ -> ());
          true)
        n.children

let matching_methods root ~host ~path (set : (Method.t, bool) Hashtbl.t) =
  if host <> "" then
    matching_methods_path (find_child root (ChildKey.of_string host)) path set;
  matching_methods_path root.empty_child path set;
  if Hashtbl.mem set Method.Get then Hashtbl.replace set Method.Head true

(* print: Go's routingNode.print. Renders patterns/keys with Go %q quoting. *)
let go_quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | '\r' -> Buffer.add_string b "\\r"
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let rec print_node n w level =
  let indent = String.concat "" (List.init level (fun _ -> "    ")) in
  (match n.leaf with
  | Some (p, _) ->
      Buffer.add_string w
        (Printf.sprintf "%s%s\n" indent (go_quote (Pattern.to_string p)))
  | None -> ());
  (match n.empty_child with
  | Some c ->
      Buffer.add_string w (Printf.sprintf "%s%s:\n" indent (go_quote ""));
      print_node c w (level + 1)
  | None -> ());
  let keys = ref [] in
  each_pair
    (fun k _ ->
      keys := k :: !keys;
      true)
    n.children;
  let keys = List.sort ChildKey.compare !keys in
  List.iter
    (fun (k : ChildKey.t) ->
      Buffer.add_string w
        (Printf.sprintf "%s%s:\n" indent (go_quote (ChildKey.to_string k)));
      match ChildKeyMap.find_opt k n.children with
      | Some c -> print_node c w (level + 1)
      | None -> ())
    keys;
  match n.multi_child with
  | Some c ->
      Buffer.add_string w (Printf.sprintf "%sMULTI:\n" indent);
      print_node c w (level + 1)
  | None -> ()

let print root w = print_node root w 0

module Private = struct
  let first_segment = first_segment
  let print = print
end
