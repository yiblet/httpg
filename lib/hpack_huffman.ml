(* Port of golang.org/x/net/http2/hpack/huffman.go (plus the [huffmanCodes]
   and [huffmanCodeLen] arrays from tables.go). Pure, no IO. *)

type error = Invalid_huffman

let error_to_string = function Invalid_huffman -> "invalid Huffman-coded data"

(* Internal sentinel used by the decoder loop to bail out to the [result]
   boundary. Not exposed; mapped to [Error Invalid_huffman] by {!decode}. *)
exception Invalid_huffman_exn

(* Go: var huffmanCodes = [256]uint32{...} (tables.go) *)
let huffman_codes =
  [|
    0x1ff8; 0x7fffd8; 0xfffffe2; 0xfffffe3; 0xfffffe4; 0xfffffe5; 0xfffffe6;
    0xfffffe7; 0xfffffe8; 0xffffea; 0x3ffffffc; 0xfffffe9; 0xfffffea;
    0x3ffffffd; 0xfffffeb; 0xfffffec; 0xfffffed; 0xfffffee; 0xfffffef;
    0xffffff0; 0xffffff1; 0xffffff2; 0x3ffffffe; 0xffffff3; 0xffffff4;
    0xffffff5; 0xffffff6; 0xffffff7; 0xffffff8; 0xffffff9; 0xffffffa;
    0xffffffb; 0x14; 0x3f8; 0x3f9; 0xffa; 0x1ff9; 0x15; 0xf8; 0x7fa; 0x3fa;
    0x3fb; 0xf9; 0x7fb; 0xfa; 0x16; 0x17; 0x18; 0x0; 0x1; 0x2; 0x19; 0x1a;
    0x1b; 0x1c; 0x1d; 0x1e; 0x1f; 0x5c; 0xfb; 0x7ffc; 0x20; 0xffb; 0x3fc;
    0x1ffa; 0x21; 0x5d; 0x5e; 0x5f; 0x60; 0x61; 0x62; 0x63; 0x64; 0x65; 0x66;
    0x67; 0x68; 0x69; 0x6a; 0x6b; 0x6c; 0x6d; 0x6e; 0x6f; 0x70; 0x71; 0x72;
    0xfc; 0x73; 0xfd; 0x1ffb; 0x7fff0; 0x1ffc; 0x3ffc; 0x22; 0x7ffd; 0x3;
    0x23; 0x4; 0x24; 0x5; 0x25; 0x26; 0x27; 0x6; 0x74; 0x75; 0x28; 0x29;
    0x2a; 0x7; 0x2b; 0x76; 0x2c; 0x8; 0x9; 0x2d; 0x77; 0x78; 0x79; 0x7a;
    0x7b; 0x7ffe; 0x7fc; 0x3ffd; 0x1ffd; 0xffffffc; 0xfffe6; 0x3fffd2;
    0xfffe7; 0xfffe8; 0x3fffd3; 0x3fffd4; 0x3fffd5; 0x7fffd9; 0x3fffd6;
    0x7fffda; 0x7fffdb; 0x7fffdc; 0x7fffdd; 0x7fffde; 0xffffeb; 0x7fffdf;
    0xffffec; 0xffffed; 0x3fffd7; 0x7fffe0; 0xffffee; 0x7fffe1; 0x7fffe2;
    0x7fffe3; 0x7fffe4; 0x1fffdc; 0x3fffd8; 0x7fffe5; 0x3fffd9; 0x7fffe6;
    0x7fffe7; 0xffffef; 0x3fffda; 0x1fffdd; 0xfffe9; 0x3fffdb; 0x3fffdc;
    0x7fffe8; 0x7fffe9; 0x1fffde; 0x7fffea; 0x3fffdd; 0x3fffde; 0xfffff0;
    0x1fffdf; 0x3fffdf; 0x7fffeb; 0x7fffec; 0x1fffe0; 0x1fffe1; 0x3fffe0;
    0x1fffe2; 0x7fffed; 0x3fffe1; 0x7fffee; 0x7fffef; 0xfffea; 0x3fffe2;
    0x3fffe3; 0x3fffe4; 0x7ffff0; 0x3fffe5; 0x3fffe6; 0x7ffff1; 0x3ffffe0;
    0x3ffffe1; 0xfffeb; 0x7fff1; 0x3fffe7; 0x7ffff2; 0x3fffe8; 0x1ffffec;
    0x3ffffe2; 0x3ffffe3; 0x3ffffe4; 0x7ffffde; 0x7ffffdf; 0x3ffffe5;
    0xfffff1; 0x1ffffed; 0x7fff2; 0x1fffe3; 0x3ffffe6; 0x7ffffe0; 0x7ffffe1;
    0x3ffffe7; 0x7ffffe2; 0xfffff2; 0x1fffe4; 0x1fffe5; 0x3ffffe8; 0x3ffffe9;
    0xffffffd; 0x7ffffe3; 0x7ffffe4; 0x7ffffe5; 0xfffec; 0xfffff3; 0xfffed;
    0x1fffe6; 0x3fffe9; 0x1fffe7; 0x1fffe8; 0x7ffff3; 0x3fffea; 0x3fffeb;
    0x1ffffee; 0x1ffffef; 0xfffff4; 0xfffff5; 0x3ffffea; 0x7ffff4; 0x3ffffeb;
    0x7ffffe6; 0x3ffffec; 0x3ffffed; 0x7ffffe7; 0x7ffffe8; 0x7ffffe9;
    0x7ffffea; 0x7ffffeb; 0xffffffe; 0x7ffffec; 0x7ffffed; 0x7ffffee;
    0x7ffffef; 0x7fffff0; 0x3ffffee;
  |]

(* Go: var huffmanCodeLen = [256]uint8{...} (tables.go) *)
let huffman_code_len =
  [|
    13; 23; 28; 28; 28; 28; 28; 28; 28; 24; 30; 28; 28; 30; 28; 28; 28; 28;
    28; 28; 28; 28; 30; 28; 28; 28; 28; 28; 28; 28; 28; 28; 6; 10; 10; 12;
    13; 6; 8; 11; 10; 10; 8; 11; 8; 6; 6; 6; 5; 5; 5; 6; 6; 6; 6; 6; 6; 6;
    7; 8; 15; 6; 12; 10; 13; 6; 7; 7; 7; 7; 7; 7; 7; 7; 7; 7; 7; 7; 7; 7;
    7; 7; 7; 7; 7; 7; 7; 7; 8; 7; 8; 13; 19; 13; 14; 6; 15; 5; 6; 5; 6; 5;
    6; 6; 6; 5; 7; 7; 6; 6; 6; 5; 6; 7; 6; 5; 5; 6; 7; 7; 7; 7; 7; 15; 11;
    14; 13; 28; 20; 22; 20; 20; 22; 22; 22; 23; 22; 23; 23; 23; 23; 23; 24;
    23; 24; 24; 22; 23; 24; 23; 23; 23; 23; 21; 22; 23; 22; 23; 23; 24; 22;
    21; 20; 22; 22; 23; 23; 21; 23; 22; 22; 24; 21; 22; 23; 23; 21; 21; 22;
    21; 23; 22; 23; 23; 20; 22; 22; 22; 23; 22; 22; 23; 26; 26; 20; 19; 22;
    23; 22; 25; 26; 26; 26; 27; 27; 26; 24; 25; 19; 21; 26; 27; 27; 26; 27;
    24; 21; 21; 26; 26; 28; 27; 27; 27; 20; 24; 20; 21; 22; 21; 21; 23; 22;
    22; 25; 25; 24; 24; 26; 23; 26; 27; 26; 26; 27; 27; 27; 27; 27; 28; 27;
    27; 27; 27; 27; 26;
  |]

(* Decoding tree, mirroring Go's [node] / [buildRootHuffmanNode]:
   internal nodes have a 256-entry children array; leaves carry [code_len]
   and the output symbol [sym]. *)
type node = {
  mutable children : node option array; (* [||] for leaves *)
  mutable code_len : int;
  mutable sym : int;
}

let new_internal_node () = { children = Array.make 256 None; code_len = 0; sym = 0 }
let is_leaf n = Array.length n.children = 0

(* Go: buildRootHuffmanNode (built once, lazily). *)
let build_root_huffman_node () =
  let root = new_internal_node () in
  (* allocate a leaf node for each of the 256 symbols *)
  let leaves =
    Array.init 256 (fun _ -> { children = [||]; code_len = 0; sym = 0 })
  in
  for sym = 0 to 255 do
    let code = huffman_codes.(sym) in
    let code_len = ref huffman_code_len.(sym) in
    let cur = ref root in
    while !code_len > 8 do
      code_len := !code_len - 8;
      let i = (code lsr !code_len) land 0xff in
      (match !cur.children.(i) with
       | None ->
         let n = new_internal_node () in
         !cur.children.(i) <- Some n;
         cur := n
       | Some n -> cur := n)
    done;
    let shift = 8 - !code_len in
    let start = (code lsl shift) land 0xff in
    let endn = 1 lsl shift in
    leaves.(sym).sym <- sym;
    leaves.(sym).code_len <- !code_len;
    for i = start to start + endn - 1 do
      !cur.children.(i) <- Some leaves.(sym)
    done
  done;
  root

let root_huffman_node = lazy (build_root_huffman_node ())

(* Go: huffmanDecode (maxLen = 0, i.e. unlimited). Raises the internal
   [Invalid_huffman_exn] sentinel on invalid data; {!decode} maps it to a
   [result]. *)
let huffman_decode (v : string) : string =
  let root = Lazy.force root_huffman_node in
  let buf = Buffer.create (String.length v) in
  let n = ref root in
  (* cur is the bit buffer; cbits valid low bits; sbits = symbol-prefix bits. *)
  let cur = ref 0 and cbits = ref 0 and sbits = ref 0 in
  String.iter
    (fun ch ->
      let b = Char.code ch in
      cur := (!cur lsl 8) lor b;
      cbits := !cbits + 8;
      sbits := !sbits + 8;
      while !cbits >= 8 do
        let idx = (!cur lsr (!cbits - 8)) land 0xff in
        (match !n.children.(idx) with
         | None -> raise Invalid_huffman_exn
         | Some child -> n := child);
        if is_leaf !n then begin
          Buffer.add_char buf (Char.chr !n.sym);
          cbits := !cbits - !n.code_len;
          n := root;
          sbits := !cbits
        end
        else cbits := !cbits - 8
      done)
    v;
  (try
     while !cbits > 0 do
       let idx = (!cur lsl (8 - !cbits)) land 0xff in
       (match !n.children.(idx) with
        | None -> raise Invalid_huffman_exn
        | Some child -> n := child);
       if (not (is_leaf !n)) || !n.code_len > !cbits then raise Exit;
       Buffer.add_char buf (Char.chr !n.sym);
       cbits := !cbits - !n.code_len;
       n := root;
       sbits := !cbits
     done
   with Exit -> ());
  if !sbits > 7 then
    (* Either an incomplete symbol, or overlong padding. *)
    raise Invalid_huffman_exn;
  let mask = (1 lsl !cbits) - 1 in
  if !cur land mask <> mask then
    (* Trailing bits must be a prefix of EOS. *)
    raise Invalid_huffman_exn;
  Buffer.contents buf

let decode (v : string) : (string, error) result =
  try Ok (huffman_decode v) with Invalid_huffman_exn -> Error Invalid_huffman

(* Shim: raises on invalid data. Removed once HTTP/2 callers migrate (T7). *)
let decode_exn (v : string) : string =
  match decode v with Ok s -> s | Error Invalid_huffman -> raise Invalid_huffman_exn

(* Go: AppendHuffmanString (starting from an empty dst). Uses 64-bit
   arithmetic faithfully via Int64; max code length is 30 so an Int64 buffer
   with < 32 valid bits can always accommodate another code. *)
let encode (s : string) : string =
  let open Int64 in
  let dst = Buffer.create (String.length s) in
  let x = ref 0L (* buffer *) and n = ref 0 (* number of valid bits in x *) in
  String.iter
    (fun ch ->
      let c = Char.code ch in
      let clen = huffman_code_len.(c) in
      n := !n + clen;
      x := shift_left !x (clen mod 64);
      x := logor !x (of_int huffman_codes.(c));
      if !n >= 32 then begin
        n := !n mod 32;
        let y = logand (shift_right_logical !x !n) 0xFFFFFFFFL in
        Buffer.add_char dst (Char.chr (to_int (logand (shift_right_logical y 24) 0xFFL)));
        Buffer.add_char dst (Char.chr (to_int (logand (shift_right_logical y 16) 0xFFL)));
        Buffer.add_char dst (Char.chr (to_int (logand (shift_right_logical y 8) 0xFFL)));
        Buffer.add_char dst (Char.chr (to_int (logand y 0xFFL)))
      end)
    s;
  (* Add padding bits if necessary. *)
  let over = !n mod 8 in
  if over > 0 then begin
    (* eosCode = 0x3fffffff, eosNBits = 30, eosPadByte = eosCode >> 22 = 0xff *)
    let eos_pad_byte = 0xff in
    let pad = 8 - over in
    x := logor (shift_left !x pad) (of_int (eos_pad_byte lsr over));
    n := !n + pad
  end;
  (* n in (0, 8, 16, 24, 32) *)
  let byte v = Char.chr (to_int (logand v 0xFFL)) in
  (match !n / 8 with
   | 0 -> ()
   | 1 -> Buffer.add_char dst (byte !x)
   | 2 ->
     Buffer.add_char dst (byte (shift_right_logical !x 8));
     Buffer.add_char dst (byte !x)
   | 3 ->
     Buffer.add_char dst (byte (shift_right_logical !x 16));
     Buffer.add_char dst (byte (shift_right_logical !x 8));
     Buffer.add_char dst (byte !x)
   | _ ->
     Buffer.add_char dst (byte (shift_right_logical !x 24));
     Buffer.add_char dst (byte (shift_right_logical !x 16));
     Buffer.add_char dst (byte (shift_right_logical !x 8));
     Buffer.add_char dst (byte !x));
  Buffer.contents dst

(* Go: HuffmanEncodeLength. *)
let encoded_len (s : string) : int =
  let n = ref 0 in
  String.iter (fun ch -> n := !n + huffman_code_len.(Char.code ch)) s;
  (!n + 7) / 8
