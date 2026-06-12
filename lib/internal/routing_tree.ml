(* Port of go/src/net/http/routing_tree.go.

   The decision tree used by ServeMux. Each node is both leaf and interior:
   a leaf holds a pattern + handler; an interior node maps request parts to
   children. Special children keys: "/" is a trailing slash (from {$}), ""
   is a single wildcard. *)

type 'h node = {
  (* leaf fields *)
  mutable leaf : (Pattern.t * 'h) option;
  (* interior fields *)
  children : (string, 'h node) Mapping.t;
  mutable multi_child : 'h node option; (* child with multi wildcard *)
  mutable empty_child : 'h node option; (* optimization: child with key "" *)
}

type 'h t = 'h node

let make_node () =
  {
    leaf = None;
    children = Mapping.create ();
    multi_child = None;
    empty_child = None;
  }

let create = make_node

(* set sets the pattern and handler for n, which must be a leaf node. *)
let set n p h =
  if n.leaf <> None then failwith "non-nil leaf fields";
  n.leaf <- Some (p, h)

(* findChild returns the child with the given key, or None. *)
let find_child n key =
  if key = "" then n.empty_child else Mapping.find n.children key

(* addChild adds a child node with the given key if absent, returns it. *)
let add_child n key =
  if key = "" then (
    match n.empty_child with
    | Some c -> c
    | None ->
        let c = make_node () in
        n.empty_child <- Some c;
        c)
  else
    match find_child n key with
    | Some c -> c
    | None ->
        let c = make_node () in
        Mapping.add n.children key c;
        c

(* addSegments adds the given segments to the tree rooted at n. *)
let rec add_segments n (segs : Pattern.segment list) p h =
  match segs with
  | [] -> set n p h
  | seg :: rest ->
      if seg.Pattern.multi then begin
        if rest <> [] then failwith "multi wildcard not last";
        let c = make_node () in
        n.multi_child <- Some c;
        set c p h
      end
      else if seg.Pattern.wild then add_segments (add_child n "") rest p h
      else add_segments (add_child n seg.Pattern.s) rest p h

(* addPattern: host -> method -> path. *)
let add_pattern root (p : Pattern.t) h =
  let n = add_child root p.Pattern.host in
  let n = add_child n (Httpg_base.Method.to_string p.Pattern.method_) in
  add_segments n p.Pattern.segments p h

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
        match match_path (find_child n seg) rest matches with
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
                        when (Pattern.last_segment p).Pattern.s <> "" ->
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
let match_method_and_path (n : 'h node option) method_ path =
  match n with
  | None -> None
  | Some n -> (
      match match_path (find_child n method_) path [] with
      | Some _ as r -> r
      | None -> (
          let head_result =
            if method_ = "HEAD" then match_path (find_child n "GET") path []
            else None
          in
          match head_result with
          | Some _ as r -> r
          | None -> match_path n.empty_child path []))

let match_ ?host root ~method_ ~path =
  let method_ = Httpg_base.Method.to_string method_ in
  match host with
  | Some host when host <> "" ->
      begin match match_method_and_path (find_child root host) method_ path with
      | Some _ as r -> r
      | None -> match_method_and_path root.empty_child method_ path
      end
  | _ -> match_method_and_path root.empty_child method_ path

(* matchingMethodsPath. *)
let matching_methods_path (n : 'h node option) path set =
  match n with
  | None -> ()
  | Some n ->
      Mapping.each_pair n.children (fun method_ c ->
          (match match_path (Some c) path [] with
          | Some _ ->
              Hashtbl.replace set (Httpg_base.Method.of_string method_) true
          | None -> ());
          true)

let matching_methods root ?host ~path set =
  (match host with
  | Some host when host <> "" ->
      matching_methods_path (find_child root host) path set
  | _ -> ());
  matching_methods_path root.empty_child path set;
  if Hashtbl.mem set Httpg_base.Method.Get then
    Hashtbl.replace set Httpg_base.Method.Head true

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
  Mapping.each_pair n.children (fun k _ ->
      keys := k :: !keys;
      true);
  let keys = List.sort String.compare !keys in
  List.iter
    (fun k ->
      Buffer.add_string w (Printf.sprintf "%s%s:\n" indent (go_quote k));
      match Mapping.find n.children k with
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
