(* Port of golang.org/x/net/http2/hpack/encode.go (Encoder) and hpack.go
   (Decoder). Pure, no IO. Composes Hpack_huffman and Hpack_tables. *)

module T = Hpack_tables
module Huff = Hpack_huffman

type header_field = T.header_field = {
  name : string;
  value : string;
  sensitive : bool;
}

(* Go: encode.go constants. uint32Max as a plain (large) int sentinel. *)
let uint32_max = 0xFFFFFFFF
let initial_header_table_size = 4096

exception Decoding_error of string
exception Invalid_indexed of int
exception String_too_long

(* errNeedMore is an internal sentinel: not enough data yet. *)
exception Need_more

(* errVarintOverflow *)
let varint_overflow = Decoding_error "varint integer overflow"

(* ===================== primitives ===================== *)

(* Go: appendVarInt. The first byte's high (prefix) bits are left 0; the
   caller ORs in any representation flag afterward. *)
let append_var_int buf n i =
  let k = (1 lsl n) - 1 in
  if i < k then Buffer.add_char buf (Char.chr (i land 0xff))
  else begin
    Buffer.add_char buf (Char.chr k);
    let i = ref (i - k) in
    while !i >= 128 do
      Buffer.add_char buf (Char.chr (0x80 lor (!i land 0x7f)));
      i := !i lsr 7
    done;
    Buffer.add_char buf (Char.chr (!i land 0xff))
  end

(* Go: readVarInt. n must be 1..8. Returns Ok (value, next_pos) or
   Error exn (Need_more / varint_overflow). *)
let read_var_int n s pos =
  if n < 1 || n > 8 then invalid_arg "read_var_int: bad n";
  let len = String.length s in
  if pos >= len then Error Need_more
  else begin
    let i0 = Char.code s.[pos] in
    let i0 = if n < 8 then i0 land ((1 lsl n) - 1) else i0 in
    if i0 < (1 lsl n) - 1 then Ok (i0, pos + 1)
    else begin
      let i = ref i0 in
      let m = ref 0 in
      let p = ref (pos + 1) in
      let result = ref None in
      (try
         while !p < len do
           let b = Char.code s.[!p] in
           incr p;
           i := !i + ((b land 127) lsl !m);
           if b land 128 = 0 then begin
             result := Some (Ok (!i, !p));
             raise Exit
           end;
           m := !m + 7;
           if !m >= 63 then begin
             result := Some (Error varint_overflow);
             raise Exit
           end
         done
       with Exit -> ());
      match !result with Some r -> r | None -> Error Need_more
    end
  end

(* Go: encodeTypeByte *)
let encode_type_byte ~indexing ~sensitive =
  if sensitive then 0x10 else if indexing then 0x40 else 0

(* Go: appendHpackString. Huffman only when strictly shorter. *)
let append_hpack_string buf s =
  let huffman_length = Huff.encoded_len s in
  if huffman_length < String.length s then begin
    let first = Buffer.length buf in
    append_var_int buf 7 huffman_length;
    Buffer.add_string buf (Huff.encode s);
    (* OR 0x80 into the first byte of this string's length prefix *)
    let bytes_ = Buffer.to_bytes buf in
    Bytes.set bytes_ first
      (Char.chr (Char.code (Bytes.get bytes_ first) lor 0x80));
    Buffer.clear buf;
    Buffer.add_bytes buf bytes_
  end
  else begin
    append_var_int buf 7 (String.length s);
    Buffer.add_string buf s
  end

(* ===================== Encoder ===================== *)

type encoder = {
  dyn_tab : T.dynamic_table;
  mutable min_size : int;
  mutable max_size_limit : int;
  mutable table_size_update : bool;
  enc_buf : Buffer.t;
  mutable writer : string -> unit;
}

(* Go: NewEncoder. Encoder's dynamic table tracks max_size only (the encoder
   never indexes by combined index, so allowed_max_size is irrelevant). *)
let new_encoder () =
  let dyn_tab = T.create_dynamic_table 0 in
  T.set_max_size dyn_tab initial_header_table_size;
  {
    dyn_tab;
    min_size = uint32_max;
    max_size_limit = initial_header_table_size;
    table_size_update = false;
    enc_buf = Buffer.create 64;
    writer = (fun _ -> ());
  }

let set_writer e f = e.writer <- f
let encoder_bytes e = Buffer.contents e.enc_buf

(* Go: appendTableSize *)
let append_table_size buf v =
  let first = Buffer.length buf in
  append_var_int buf 5 v;
  let bytes_ = Buffer.to_bytes buf in
  Bytes.set bytes_ first
    (Char.chr (Char.code (Bytes.get bytes_ first) lor 0x20));
  Buffer.clear buf;
  Buffer.add_bytes buf bytes_

(* Go: appendIndexed *)
let append_indexed buf i =
  let first = Buffer.length buf in
  append_var_int buf 7 i;
  let bytes_ = Buffer.to_bytes buf in
  Bytes.set bytes_ first
    (Char.chr (Char.code (Bytes.get bytes_ first) lor 0x80));
  Buffer.clear buf;
  Buffer.add_bytes buf bytes_

(* Go: appendNewName *)
let append_new_name buf f ~indexing =
  Buffer.add_char buf
    (Char.chr (encode_type_byte ~indexing ~sensitive:f.sensitive));
  append_hpack_string buf f.name;
  append_hpack_string buf f.value

(* Go: appendIndexedName *)
let append_indexed_name buf f i ~indexing =
  let first = Buffer.length buf in
  let n = if indexing then 6 else 4 in
  append_var_int buf n i;
  let bytes_ = Buffer.to_bytes buf in
  Bytes.set bytes_ first
    (Char.chr
       (Char.code (Bytes.get bytes_ first)
       lor encode_type_byte ~indexing ~sensitive:f.sensitive));
  Buffer.clear buf;
  Buffer.add_bytes buf bytes_;
  append_hpack_string buf f.value

(* Go: searchTable. Static first; then dynamic, with the dynamic index
   offset by staticTable.len(). *)
let search_table e f =
  let i, name_value_match = T.static_search f in
  if name_value_match then (i, true)
  else begin
    let j, nvm = T.search (T.dynamic_table_of e.dyn_tab) f in
    if nvm || (i = 0 && j <> 0) then (j + T.static_table_len, nvm)
    else (i, false)
  end

(* Go: shouldIndex *)
let should_index e f = (not f.sensitive) && T.size f <= T.dynamic_max_size e.dyn_tab

(* Go: WriteField *)
let write_field e f =
  Buffer.clear e.enc_buf;
  let buf = e.enc_buf in
  if e.table_size_update then begin
    e.table_size_update <- false;
    if e.min_size < T.dynamic_max_size e.dyn_tab then
      append_table_size buf e.min_size;
    e.min_size <- uint32_max;
    append_table_size buf (T.dynamic_max_size e.dyn_tab)
  end;
  let idx, name_value_match = search_table e f in
  if name_value_match then append_indexed buf idx
  else begin
    let indexing = should_index e f in
    if indexing then T.dynamic_add e.dyn_tab f;
    if idx = 0 then append_new_name buf f ~indexing
    else append_indexed_name buf f idx ~indexing
  end;
  e.writer (Buffer.contents buf)

let encode_to_string e fs =
  let acc = Buffer.create 64 in
  let saved = e.writer in
  e.writer <- (fun s -> Buffer.add_string acc s);
  List.iter (fun f -> write_field e f) fs;
  e.writer <- saved;
  Buffer.contents acc

(* Go: SetMaxDynamicTableSize *)
let set_max_dynamic_table_size e v =
  let v = if v > e.max_size_limit then e.max_size_limit else v in
  if v < e.min_size then e.min_size <- v;
  e.table_size_update <- true;
  T.set_max_size e.dyn_tab v

let max_dynamic_table_size e = T.dynamic_max_size e.dyn_tab

(* Go: SetMaxDynamicTableSizeLimit *)
let set_max_dynamic_table_size_limit e v =
  e.max_size_limit <- v;
  if T.dynamic_max_size e.dyn_tab > v then begin
    e.table_size_update <- true;
    T.set_max_size e.dyn_tab v
  end

(* ===================== Decoder ===================== *)

type decoder = {
  d_dyn_tab : T.dynamic_table;
  mutable emit : header_field -> unit;
  mutable emit_enabled : bool;
  mutable max_str_len : int; (* 0 = unlimited *)
  save_buf : Buffer.t; (* owned; data we couldn't fully parse *)
  mutable first_field : bool;
}

(* Go: NewDecoder *)
let new_decoder max_dynamic_table_size emit_func =
  let d_dyn_tab = T.create_dynamic_table max_dynamic_table_size in
  {
    d_dyn_tab;
    emit = emit_func;
    emit_enabled = true;
    max_str_len = 0;
    save_buf = Buffer.create 64;
    first_field = true;
  }

let set_max_string_length d n = d.max_str_len <- n
let set_emit_func d f = d.emit <- f
let set_emit_enabled d v = d.emit_enabled <- v
let emit_enabled d = d.emit_enabled
let set_max_dynamic_table_size_dec d v = T.set_max_size d.d_dyn_tab v
let set_allowed_max_dynamic_table_size d v = T.set_allowed_max_size d.d_dyn_tab v

(* Go: Decoder.at *)
let at d i = T.at d.d_dyn_tab i

type index_type = Indexed_true | Indexed_false | Indexed_never

let it_indexed = function Indexed_true -> true | _ -> false
let it_sensitive = function Indexed_never -> true | _ -> false

(* Go: undecodedString *)
type undecoded_string = { is_huff : bool; b : string }

(* Go: callEmit *)
let call_emit d hf =
  if d.max_str_len <> 0 then
    if String.length hf.name > d.max_str_len
       || String.length hf.value > d.max_str_len
    then raise String_too_long;
  if d.emit_enabled then d.emit hf

(* Go: decodeString *)
let decode_string _d u =
  if not u.is_huff then u.b
  else
    (* Go passes maxStrLen to huffmanDecode; our Huffman decoder is the
       maxLen=0 path. Enforce length post-decode in readString/callEmit. *)
    Huff.decode u.b

(* Go: readString. Returns (undecoded, next_pos). *)
let read_string d s pos =
  let len = String.length s in
  if pos >= len then Error Need_more
  else begin
    let is_huff = Char.code s.[pos] land 128 <> 0 in
    match read_var_int 7 s pos with
    | Error e -> Error e
    | Ok (str_len, p) ->
        if d.max_str_len <> 0 && str_len > d.max_str_len then
          Error String_too_long
        else if len - p < str_len then Error Need_more
        else Ok ({ is_huff; b = String.sub s p str_len }, p + str_len)
  end

(* Go: parseFieldIndexed. Returns (consumed_to_pos). *)
let parse_field_indexed d s pos =
  match read_var_int 7 s pos with
  | Error e -> Error e
  | Ok (idx, p) -> (
      match at d idx with
      | None -> raise (Invalid_indexed idx)
      | Some hf ->
          call_emit d { name = hf.name; value = hf.value; sensitive = false };
          Ok p)

(* Go: parseFieldLiteral *)
let parse_field_literal d s pos n it =
  match read_var_int n s pos with
  | Error e -> Error e
  | Ok (name_idx, p) -> (
      let want_str = d.emit_enabled || it_indexed it in
      (* read name (indexed or string) *)
      let name_res =
        if name_idx > 0 then
          match at d name_idx with
          | None -> raise (Invalid_indexed name_idx)
          | Some ihf -> Ok (ihf.name, None, p)
        else
          match read_string d s p with
          | Error e -> Error e
          | Ok (u, p') -> Ok ("", Some u, p')
      in
      match name_res with
      | Error e -> Error e
      | Ok (name0, undecoded_name, p) -> (
          match read_string d s p with
          | Error e -> Error e
          | Ok (undecoded_value, p) ->
              let name, value =
                if want_str then begin
                  let name =
                    if name_idx <= 0 then
                      match undecoded_name with
                      | Some u -> decode_string d u
                      | None -> name0
                    else name0
                  in
                  let value = decode_string d undecoded_value in
                  (name, value)
                end
                else (name0, "")
              in
              let hf = { name; value; sensitive = false } in
              if it_indexed it then T.dynamic_add d.d_dyn_tab hf;
              let hf = { hf with sensitive = it_sensitive it } in
              call_emit d hf;
              Ok p))

(* Go: parseDynamicTableSizeUpdate *)
let parse_dynamic_table_size_update d s pos =
  if (not d.first_field) && T.dynamic_size d.d_dyn_tab > 0 then
    raise
      (Decoding_error
         "dynamic table size update MUST occur at the beginning of a header \
          block");
  match read_var_int 5 s pos with
  | Error e -> Error e
  | Ok (size, p) ->
      if size > T.dynamic_allowed_max_size d.d_dyn_tab then
        raise (Decoding_error "dynamic table size update too large");
      T.set_max_size d.d_dyn_tab size;
      Ok p

(* Go: parseHeaderFieldRepr. Precondition: pos < length s. *)
let parse_header_field_repr d s pos =
  let b = Char.code s.[pos] in
  if b land 128 <> 0 then parse_field_indexed d s pos
  else if b land 192 = 64 then parse_field_literal d s pos 6 Indexed_true
  else if b land 240 = 0 then parse_field_literal d s pos 4 Indexed_false
  else if b land 240 = 16 then parse_field_literal d s pos 4 Indexed_never
  else if b land 224 = 32 then parse_dynamic_table_size_update d s pos
  else raise (Decoding_error "invalid encoding")

(* Go: Decoder.Write. Returns length p (bytes accepted). *)
let write d p =
  let plen = String.length p in
  if plen = 0 then 0
  else begin
    (* assemble the working buffer *)
    let buf =
      if Buffer.length d.save_buf = 0 then p
      else begin
        Buffer.add_string d.save_buf p;
        let b = Buffer.contents d.save_buf in
        Buffer.clear d.save_buf;
        b
      end
    in
    let buf_len = String.length buf in
    let pos = ref 0 in
    let continue = ref true in
    while !continue && !pos < buf_len do
      match parse_header_field_repr d buf !pos with
      | Ok next ->
          pos := next;
          d.first_field <- false
      | Error Need_more ->
          let var_int_overhead = 8 in
          let remaining = buf_len - !pos in
          if d.max_str_len <> 0
             && remaining > 2 * (d.max_str_len + var_int_overhead)
          then raise String_too_long;
          Buffer.add_substring d.save_buf buf !pos remaining;
          continue := false
      | Error e -> raise e
    done;
    plen
  end

(* Go: Decoder.Close *)
let close d =
  if Buffer.length d.save_buf > 0 then begin
    Buffer.clear d.save_buf;
    raise (Decoding_error "truncated headers")
  end;
  d.first_field <- true

(* Go: DecodeFull *)
let decode_full d p =
  let acc = ref [] in
  let saved = d.emit in
  d.emit <- (fun f -> acc := f :: !acc);
  Fun.protect
    ~finally:(fun () -> d.emit <- saved)
    (fun () ->
      let _ = write d p in
      close d;
      List.rev !acc)
