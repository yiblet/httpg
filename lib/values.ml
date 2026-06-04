(* Port of go/src/net/url/url.go: [Values] = map[string][]string and its
   methods (Get/Set/Add/Del/Has/Encode), plus ParseQuery. Per the project
   rule, Go's map is mirrored with a Hashtbl. Percent-decoding/encoding of
   query components is delegated to the [uri] library (the project's stand-in
   for net/url), matching Go's QueryUnescape/QueryEscape behavior. *)

type t = (string, string list) Hashtbl.t

let create () : t = Hashtbl.create 8

(* Values.Get: the first value for [key], or "". *)
let get (v : t) key =
  match Hashtbl.find_opt v key with Some (v0 :: _) -> v0 | Some [] | None -> ""

(* Values.Set: replace any existing values for [key]. *)
let set (v : t) key value = Hashtbl.replace v key [ value ]

(* Values.Add: append [value] to the list for [key]. *)
let add (v : t) key value =
  let existing = match Hashtbl.find_opt v key with Some l -> l | None -> [] in
  Hashtbl.replace v key (existing @ [ value ])

(* Values.Del: delete all values for [key]. *)
let del (v : t) key = Hashtbl.remove v key

(* Values.Has: whether [key] is set. *)
let has (v : t) key = Hashtbl.mem v key

(* All values for [key] (Go's [v[key]]); [] when absent. *)
let find (v : t) key = match Hashtbl.find_opt v key with Some l -> l | None -> []

let length (v : t) = Hashtbl.length v

(* copyValues(dst, src): append each src value list to dst (request.go). *)
let copy_values ~dst ~src =
  Hashtbl.iter (fun k vs -> List.iter (fun value -> add dst k value) vs) src

(* QueryUnescape: percent-decode a query component. [uri] decodes '+' as a
   space inside query components, matching Go's QueryUnescape. *)
let query_unescape s = Uri.pct_decode (String.map (function '+' -> ' ' | c -> c) s)

(* QueryEscape: percent-encode a query component (Go encodes space as '+'). We
   percent-encode spaces first (so uri does not), then rewrite "%20" -> "+". *)
let query_escape s =
  let enc = Uri.pct_encode ~component:`Query_value s in
  (* uri encodes ' ' as "%20"; Go uses '+' in query components. *)
  let buf = Buffer.create (String.length enc) in
  let n = String.length enc in
  let i = ref 0 in
  while !i < n do
    if !i + 2 < n && enc.[!i] = '%' && enc.[!i + 1] = '2' && enc.[!i + 2] = '0' then begin
      Buffer.add_char buf '+';
      i := !i + 3
    end
    else begin
      Buffer.add_char buf enc.[!i];
      incr i
    end
  done;
  Buffer.contents buf

(* strings.Cut(s, sep): (before, after, found). *)
let cut s sep =
  match String.index_opt s sep with
  | None -> (s, "", false)
  | Some i -> (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1), true)

(* parseQuery(m, query): mutate [m], returning the first error (if any).
   Semicolon separators are invalid (Go rejects a key containing ';'). *)
type error =
  | Invalid_semicolon_separator
  | Invalid_escape of string

let error_to_string = function
  | Invalid_semicolon_separator -> "invalid semicolon separator in query"
  | Invalid_escape s -> Printf.sprintf "invalid URL escape %S" s

let parse_query_into (m : t) (query : string) : (unit, error) result =
  let err = ref None in
  let set_err e = match !err with None -> err := Some e | Some _ -> () in
  let rec loop query =
    if query = "" then ()
    else begin
      let key, rest, _ = cut query '&' in
      if String.contains key ';' then begin
        set_err Invalid_semicolon_separator;
        loop rest
      end
      else if key = "" then loop rest
      else begin
        let k, value, _ = cut key '=' in
        let k = query_unescape k in
        let value = query_unescape value in
        add m k value;
        loop rest
      end
    end
  in
  loop query;
  match !err with None -> Ok () | Some e -> Error e

(* ParseQuery(query): always returns a non-nil map; Error carries the first
   decode error encountered. *)
let parse_query (query : string) : t * (unit, error) result =
  let m = create () in
  (m, parse_query_into m query)

(* Values.Encode: "k=v&..." sorted by key (Go's slices.Sort over keys). *)
let encode (v : t) =
  if length v = 0 then ""
  else begin
    let keys = Hashtbl.fold (fun k _ acc -> k :: acc) v [] in
    let keys = List.sort_uniq String.compare keys in
    let buf = Buffer.create 64 in
    List.iter
      (fun k ->
        let key_escaped = query_escape k in
        List.iter
          (fun value ->
            if Buffer.length buf > 0 then Buffer.add_char buf '&';
            Buffer.add_string buf key_escaped;
            Buffer.add_char buf '=';
            Buffer.add_string buf (query_escape value))
          (find v k))
      keys;
    Buffer.contents buf
  end
