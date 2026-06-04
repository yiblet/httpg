(* Port of golang.org/x/net/http2/hpack/static_table.go and the table
   machinery of tables.go (+ HeaderField/dynamicTable from hpack.go). Pure. *)

type header_field = { name : string; value : string; sensitive : bool }

(* Go: HeaderField.IsPseudo *)
let is_pseudo hf = String.length hf.name <> 0 && hf.name.[0] = ':'

(* Go: HeaderField.Size = len(name) + len(value) + 32 *)
let size hf = String.length hf.name + String.length hf.value + 32

(* Go: headerFieldTable. [ents] is the oldest-first list; for dynamic tables
   it is logically reversed (newest entry is HPACK index 1). Unique ids are
   1-based and stable across evictions: the id for ents[k] is
   [k + evict_count + 1]. *)
type header_field_table = {
  mutable ents : header_field list; (* oldest first; kept as a growable array view *)
  mutable ents_arr : header_field array; (* mirror of [ents] for O(1) index *)
  mutable evict_count : int;
  by_name : (string, int) Hashtbl.t; (* name -> newest unique id *)
  by_name_value : (string * string, int) Hashtbl.t; (* (name,value) -> newest id *)
  is_static : bool;
}

let make_table ~is_static () =
  {
    ents = [];
    ents_arr = [||];
    evict_count = 0;
    by_name = Hashtbl.create 16;
    by_name_value = Hashtbl.create 16;
    is_static;
  }

let create_table () = make_table ~is_static:false ()

(* Go: headerFieldTable.len *)
let table_len t = Array.length t.ents_arr

(* Go: headerFieldTable.addEntry *)
let add_entry t f =
  let id = table_len t + t.evict_count + 1 in
  Hashtbl.replace t.by_name f.name id;
  Hashtbl.replace t.by_name_value (f.name, f.value) id;
  t.ents <- t.ents @ [ f ];
  t.ents_arr <- Array.append t.ents_arr [| f |]

(* Go: headerFieldTable.evictOldest *)
let evict_oldest t n =
  if n > table_len t then
    invalid_arg
      (Printf.sprintf "evictOldest(%d) on table with %d entries" n (table_len t));
  for k = 0 to n - 1 do
    let f = t.ents_arr.(k) in
    let id = t.evict_count + k + 1 in
    (match Hashtbl.find_opt t.by_name f.name with
     | Some v when v = id -> Hashtbl.remove t.by_name f.name
     | _ -> ());
    match Hashtbl.find_opt t.by_name_value (f.name, f.value) with
    | Some v when v = id -> Hashtbl.remove t.by_name_value (f.name, f.value)
    | _ -> ()
  done;
  let len = table_len t in
  t.ents_arr <- Array.sub t.ents_arr n (len - n);
  t.ents <- Array.to_list t.ents_arr;
  t.evict_count <- t.evict_count + n

(* Go: headerFieldTable.idToIndex *)
let id_to_index t id =
  if id <= t.evict_count then
    invalid_arg (Printf.sprintf "id (%d) <= evictCount (%d)" id t.evict_count);
  let k = id - t.evict_count - 1 in
  if not t.is_static then table_len t - k (* dynamic table *) else k + 1

(* Go: headerFieldTable.search *)
let search t f =
  let by_value =
    if not f.sensitive then Hashtbl.find_opt t.by_name_value (f.name, f.value)
    else None
  in
  match by_value with
  | Some id when id <> 0 -> (id_to_index t id, true)
  | _ -> (
      match Hashtbl.find_opt t.by_name f.name with
      | Some id when id <> 0 -> (id_to_index t id, false)
      | _ -> (0, false))

(* Go: static_table.go staticTable.ents *)
let static_table : header_field array =
  let f name value = { name; value; sensitive = false } in
  [|
    f ":authority" "";
    f ":method" "GET";
    f ":method" "POST";
    f ":path" "/";
    f ":path" "/index.html";
    f ":scheme" "http";
    f ":scheme" "https";
    f ":status" "200";
    f ":status" "204";
    f ":status" "206";
    f ":status" "304";
    f ":status" "400";
    f ":status" "404";
    f ":status" "500";
    f "accept-charset" "";
    f "accept-encoding" "gzip, deflate";
    f "accept-language" "";
    f "accept-ranges" "";
    f "accept" "";
    f "access-control-allow-origin" "";
    f "age" "";
    f "allow" "";
    f "authorization" "";
    f "cache-control" "";
    f "content-disposition" "";
    f "content-encoding" "";
    f "content-language" "";
    f "content-length" "";
    f "content-location" "";
    f "content-range" "";
    f "content-type" "";
    f "cookie" "";
    f "date" "";
    f "etag" "";
    f "expect" "";
    f "expires" "";
    f "from" "";
    f "host" "";
    f "if-match" "";
    f "if-modified-since" "";
    f "if-none-match" "";
    f "if-range" "";
    f "if-unmodified-since" "";
    f "last-modified" "";
    f "link" "";
    f "location" "";
    f "max-forwards" "";
    f "proxy-authenticate" "";
    f "proxy-authorization" "";
    f "range" "";
    f "referer" "";
    f "refresh" "";
    f "retry-after" "";
    f "server" "";
    f "set-cookie" "";
    f "strict-transport-security" "";
    f "transfer-encoding" "";
    f "user-agent" "";
    f "vary" "";
    f "via" "";
    f "www-authenticate" "";
  |]

let static_table_len = Array.length static_table

(* The global static table as a headerFieldTable, for search by the encoder.
   Mirrors Go's staticTable (with byName mapping to the *first* matching id
   for ":method" / ":path" / ":scheme" / ":status" as encoded by gen.go). *)
let static_field_table : header_field_table =
  let t = make_table ~is_static:true () in
  (* Populate by adding entries in order; byName/byNameValue end up mapping to
     the newest id with that name/value, exactly as Go's addEntry would.
     However Go's generated static_table.go pins byName to specific (newest)
     ids; addEntry reproduces that since later entries overwrite earlier. *)
  Array.iter (add_entry t) static_table;
  t

let static_table_entry i =
  if i < 1 || i > static_table_len then
    invalid_arg (Printf.sprintf "static_table_entry %d" i);
  static_table.(i - 1)

let static_search f = search static_field_table f

(* Go: dynamicTable *)
type dynamic_table = {
  table : header_field_table;
  mutable dsize : int; (* in bytes *)
  mutable max_size : int; (* current maxSize *)
  mutable allowed_max_size : int; (* maxSize may go up to this, inclusive *)
}

(* If we're too big, evict old stuff. Go: dynamicTable.evict *)
let dynamic_evict dt =
  let n = ref 0 in
  while dt.dsize > dt.max_size && !n < table_len dt.table do
    dt.dsize <- dt.dsize - size dt.table.ents_arr.(!n);
    incr n
  done;
  evict_oldest dt.table !n

(* Go: dynamicTable.setMaxSize *)
let set_max_size dt v =
  dt.max_size <- v;
  dynamic_evict dt

(* Go: NewDecoder dynTab setup *)
let create_dynamic_table max_dynamic_table_size =
  let dt =
    {
      table = create_table ();
      dsize = 0;
      max_size = 0;
      allowed_max_size = max_dynamic_table_size;
    }
  in
  set_max_size dt max_dynamic_table_size;
  dt

let dynamic_size dt = dt.dsize
let dynamic_max_size dt = dt.max_size
let dynamic_allowed_max_size dt = dt.allowed_max_size
let set_allowed_max_size dt v = dt.allowed_max_size <- v
let dynamic_len dt = table_len dt.table
let dynamic_table_of dt = dt.table

(* Go: dynamicTable.add *)
let dynamic_add dt f =
  add_entry dt.table f;
  dt.dsize <- dt.dsize + size f;
  dynamic_evict dt

(* Go: Decoder.maxTableIndex / Decoder.at *)
let at dt i =
  if i = 0 then None
  else if i <= static_table_len then Some static_table.(i - 1)
  else begin
    let max_index = table_len dt.table + static_table_len in
    if i > max_index then None
    else
      (* newer entries have lower indices; ents[0] is oldest. *)
      let len = table_len dt.table in
      Some dt.table.ents_arr.(len - (i - static_table_len))
  end
