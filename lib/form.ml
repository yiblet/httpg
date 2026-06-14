(* Form values: the port of go/src/net/url [Values] (= map[string][]string) and
   ParseQuery/Encode, together with the application/x-www-form-urlencoded body
   parser {!of_body}. One module because a query string and a urlencoded body are
   the same wire format — both decode into the same multimap; the only difference
   is the source (URL vs request body).

   Like {!Header}, and unlike Go's mutable map, the multimap is a *persistent*
   [Map] (keyed by the raw, case-sensitive key — form keys are not canonicalized)
   whose mutators [add]/[set]/[del] return a new value, so a {!t} can be shared
   and forked freely. Httpg deviates from Go's Request-mutating ParseForm:
   parsing is a pure function returning a {!t}, not a cache on the Request, and
   there is no source-blind [Form]/[PostForm] merge — compose the query half
   ({!parse_query} on [Uri.verbatim_query req.url]) with the body half
   ({!of_body}) explicitly via {!merge} if wanted. multipart/form-data is in
   {!Multipart}.

   Percent decoding/encoding of query components is delegated to the [uri]
   library. Decoding accepts '+' as a space (Go/browser compatible); encoding
   deviates from Go by emitting "%20" for space (both valid; "%20" avoids the
   '+'/space ambiguity). *)

module M = Map.Make (String)

type t = string list M.t

let create () : t = M.empty

(* Values.Get: the first value for [key], or "". *)
let get (v : t) key =
  match M.find_opt key v with Some (v0 :: _) -> v0 | Some [] | None -> ""

(* Values.Set: replace any existing values for [key]. *)
let set (v : t) key value = M.add key [ value ] v

(* Values.Add: append [value] to the list for [key]. *)
let add (v : t) key value =
  match M.find_opt key v with
  | Some vs -> M.add key (vs @ [ value ]) v
  | None -> M.add key [ value ] v

(* Values.Del: delete all values for [key]. *)
let del (v : t) key = M.remove key v

(* Values.Has: whether [key] is set. *)
let has (v : t) key = M.mem key v

(* All values for [key] (Go's [v[key]]); [] when absent. *)
let find (v : t) key = match M.find_opt key v with Some l -> l | None -> []
let length (v : t) = M.cardinal v

(* copyValues(dst, src) (request.go), functional: [merge a b] returns [a] with
   each of [b]'s values appended per key ([a]'s values first). Used to combine
   the query and body halves into the Go-style merged [Form] when wanted. *)
let merge (a : t) (b : t) : t =
  let helper _ a_entry b_entry =
    match (a_entry, b_entry) with
    | Some a, Some b -> Some (a @ b)
    | Some a, _ -> Some a
    | _, Some b -> Some b
    | _, _ -> None
  in
  M.merge helper a b

(* Decode a query component. We still accept '+' as a space (what browsers and
   Go's QueryEscape emit), so form bodies from any client parse correctly. *)
let query_unescape s =
  Uri.pct_decode (String.map (function '+' -> ' ' | c -> c) s)

(* Encode a query component. Deliberate deviation from Go: we encode space as
   "%20" rather than '+'. Both are valid, and "%20" avoids the '+'/space
   ambiguity entirely. [uri] already does the right thing for round-tripping
   through {!query_unescape}: space -> "%20" and a literal '+' -> "%2B" (so we
   never emit a bare '+' that decode would turn back into a space). *)
let query_escape s = Uri.pct_encode ~component:`Query_value s

(* strings.Cut(s, sep): (before, after, found). *)
let cut = Httpg_base.Textproto.cut

(* A handleable form-parse failure.
   - [Invalid_semicolon_separator]/[Invalid_escape]: Go's ParseQuery errors.
   - [Too_large]: an urlencoded body over [max_form_size] ({!of_body} only). *)
type error =
  | Invalid_semicolon_separator
  | Invalid_escape of string
  | Too_large

let error_to_string = function
  | Invalid_semicolon_separator -> "invalid semicolon separator in query"
  | Invalid_escape s -> Printf.sprintf "invalid URL escape %S" s
  | Too_large -> "http: POST too large"

(* ParseQuery(query): build a {!t} from a query string, returning it together
   with the first decode error (if any). Semicolon separators are invalid (Go
   rejects a key containing ';'). *)
let parse_query (query : string) : t * error option =
  let err = ref None in
  let set_err e = match !err with None -> err := Some e | Some _ -> () in
  let rec loop (m : t) query =
    if query = "" then m
    else
      let key, rest, _ = cut query '&' in
      if String.contains key ';' then begin
        set_err Invalid_semicolon_separator;
        loop m rest
      end
      else if key = "" then loop m rest
      else
        let k, value, _ = cut key '=' in
        let m = add m (query_unescape k) (query_unescape value) in
        loop m rest
  in
  let m = loop (create ()) query in
  (m, !err)

(* Values.Encode: "k=v&..." sorted by key. The persistent [Map] already iterates
   in sorted key order (Go's slices.Sort over keys). *)
let to_string (v : t) =
  let buf = Buffer.create 64 in
  M.iter
    (fun k values ->
      let key_escaped = query_escape k in
      List.iter
        (fun value ->
          if Buffer.length buf > 0 then Buffer.add_char buf '&';
          Buffer.add_string buf key_escaped;
          Buffer.add_char buf '=';
          Buffer.add_string buf (query_escape value))
        values)
    v;
  Buffer.contents buf

(* Go's maxFormSize (request.go): an urlencoded body larger than 10 MB is
   rejected rather than parsed. *)
let max_form_size = 10 * 1024 * 1024

(* Parse an application/x-www-form-urlencoded [body] into a {!t} (Go's
   parsePostForm, minus the content-type gate — that is the caller's concern).
   [Error Too_large] if the body exceeds [max_form_size]; otherwise the first
   decode error from {!parse_query}, if any. *)
(* Strict parse of a query/urlencoded string: the sibling of {!of_body} for a
   raw string. [Ok m] on a clean parse, else the first decode error. *)
let of_string (s : string) : (t, error) result =
  let m, res = parse_query s in
  Option.fold ~none:(Ok m) ~some:(fun e -> Error e) res

let of_body (body : Body.t) : (t, error) result =
  let s, remainder = Body.read_until body max_form_size in
  if Option.is_some remainder then Error Too_large else of_string s

let to_body (v : t) =
  Body.of_lazy_string (Lazy.from_fun (fun () -> to_string v))
