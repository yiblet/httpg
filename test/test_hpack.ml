(* Ported from golang.org/x/net/http2/hpack hpack_test.go and encode_test.go.
   Includes the RFC 7541 appendix C examples (C.2 through C.6). Pure. *)

open Gohttp_http2
module H = Hpack

let hf ?(sensitive = false) name value : H.header_field =
  { name; value; sensitive }

let to_hex s =
  String.concat ""
    (List.init (String.length s) (fun i ->
         Printf.sprintf "%02x" (Char.code s.[i])))

let of_hex h =
  (* allow spaces / newlines in the hex literal *)
  let h =
    String.concat ""
      (String.split_on_char ' ' h |> List.concat_map (String.split_on_char '\n'))
  in
  let n = String.length h / 2 in
  String.init n (fun i ->
      Char.chr (int_of_string ("0x" ^ String.sub h (i * 2) 2)))

let hex =
  Alcotest.testable (fun fmt s -> Format.fprintf fmt "%s" (to_hex s)) ( = )

let field_t =
  Alcotest.testable
    (fun fmt (f : H.header_field) ->
      Format.fprintf fmt "{%S=%S sens=%b}" f.name f.value f.sensitive)
    (fun (a : H.header_field) b ->
      a.name = b.name && a.value = b.value && a.sensitive = b.sensitive)

let fields_t = Alcotest.list field_t

(* decode_full returns a result now; unwrap for the success-path tests. *)
let decode_full dec s =
  match H.decode_full dec s with
  | Ok fs -> fs
  | Error e -> Alcotest.failf "decode_full: %s" (H.error_to_string e)

(* ---------- integer primitive (RFC 7541 5.1) ---------- *)

let var_int_roundtrip () =
  let check n i =
    let buf = Buffer.create 8 in
    H.append_var_int buf n i;
    let s = Buffer.contents buf in
    match H.read_var_int n s 0 with
    | Ok (v, p) ->
        Alcotest.(check int) (Printf.sprintf "n=%d i=%d value" n i) i v;
        Alcotest.(check int) "consumed all" (String.length s) p
    | Error _ -> Alcotest.fail "read_var_int unexpected error"
  in
  List.iter
    (fun (n, i) -> check n i)
    [
      (5, 10);
      (* RFC C.1.1: 10 fits in 5-bit prefix *)
      (5, 1337);
      (* RFC C.1.2: 0x1f 0x9a 0x0a *)
      (8, 42);
      (* RFC C.1.3 *)
      (7, 0);
      (7, 126);
      (7, 127);
      (7, 128);
      (1, 0);
      (1, 1);
      (1, 100000);
      (5, 0xFFFFFF);
    ]

let var_int_rfc_c11 () =
  (* C.1.1: encode 10 with 5-bit prefix -> 0x0a *)
  let buf = Buffer.create 4 in
  H.append_var_int buf 5 10;
  Alcotest.check hex "C.1.1" (of_hex "0a") (Buffer.contents buf)

let var_int_rfc_c12 () =
  (* C.1.2: encode 1337 with 5-bit prefix -> 31 154 10 *)
  let buf = Buffer.create 4 in
  H.append_var_int buf 5 1337;
  Alcotest.check hex "C.1.2" (of_hex "1f9a0a") (Buffer.contents buf)

let var_int_need_more () =
  (* a multi-byte varint that is truncated -> raises the internal Need_more
     sentinel (kept as an exception; not part of [error]). *)
  let buf = Buffer.create 4 in
  H.append_var_int buf 5 1337;
  let s = String.sub (Buffer.contents buf) 0 1 in
  match H.read_var_int 5 s 0 with
  | (_ : (int * int, H.error) result) -> Alcotest.fail "expected Need_more"
  | exception H.Need_more -> ()

(* ---------- RFC 7541 C.2 — literal representations ---------- *)

(* These run with a fresh encoder/decoder each (C.2 has independent cases). *)

let c2_1_literal_with_indexing () =
  (* C.2.1: custom-key: custom-header, incremental indexing, no Huffman *)
  let expected =
    of_hex "400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572"
  in
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  let got = decode_full dec expected in
  Alcotest.check fields_t "C.2.1 decode" [ hf "custom-key" "custom-header" ] got;
  (* dynamic table now has the entry, size 55 *)
  ignore got

let c2_2_literal_without_indexing () =
  (* C.2.2: :path: /sample/path, indexed name 4, without indexing *)
  let expected = of_hex "040c 2f73 616d 706c 652f 7061 7468" in
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  let got = decode_full dec expected in
  Alcotest.check fields_t "C.2.2 decode" [ hf ":path" "/sample/path" ] got

let c2_3_literal_never_indexed () =
  (* C.2.3: password: secret, never indexed (sensitive) *)
  let expected = of_hex "1008 7061 7373 776f 7264 0673 6563 7265 74" in
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  let got = decode_full dec expected in
  Alcotest.check fields_t "C.2.3 decode"
    [ hf ~sensitive:true "password" "secret" ]
    got

let c2_4_indexed () =
  (* C.2.4: :method: GET, indexed field 2 *)
  let expected = of_hex "82" in
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  let got = decode_full dec expected in
  Alcotest.check fields_t "C.2.4 decode" [ hf ":method" "GET" ] got

(* ---------- RFC 7541 C.3 — request sequence (no Huffman) ---------- *)

let c3_request_sequence () =
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  (* C.3.1 *)
  let b1 = of_hex "8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d" in
  let g1 = decode_full dec b1 in
  Alcotest.check fields_t "C.3.1"
    [
      hf ":method" "GET";
      hf ":scheme" "http";
      hf ":path" "/";
      hf ":authority" "www.example.com";
    ]
    g1;
  (* C.3.2 *)
  let b2 = of_hex "8286 84be 5808 6e6f 2d63 6163 6865" in
  let g2 = decode_full dec b2 in
  Alcotest.check fields_t "C.3.2"
    [
      hf ":method" "GET";
      hf ":scheme" "http";
      hf ":path" "/";
      hf ":authority" "www.example.com";
      hf "cache-control" "no-cache";
    ]
    g2;
  (* C.3.3 *)
  let b3 =
    of_hex
      "8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d 7661 6c75 65"
  in
  let g3 = decode_full dec b3 in
  Alcotest.check fields_t "C.3.3"
    [
      hf ":method" "GET";
      hf ":scheme" "https";
      hf ":path" "/index.html";
      hf ":authority" "www.example.com";
      hf "custom-key" "custom-value";
    ]
    g3

(* ---------- RFC 7541 C.4 — request sequence WITH Huffman ---------- *)

let c4_request_sequence_huffman () =
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  (* C.4.1 *)
  let b1 = of_hex "8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff" in
  let g1 = decode_full dec b1 in
  Alcotest.check fields_t "C.4.1"
    [
      hf ":method" "GET";
      hf ":scheme" "http";
      hf ":path" "/";
      hf ":authority" "www.example.com";
    ]
    g1;
  (* C.4.2 *)
  let b2 = of_hex "8286 84be 5886 a8eb 1064 9cbf" in
  let g2 = decode_full dec b2 in
  Alcotest.check fields_t "C.4.2"
    [
      hf ":method" "GET";
      hf ":scheme" "http";
      hf ":path" "/";
      hf ":authority" "www.example.com";
      hf "cache-control" "no-cache";
    ]
    g2;
  (* C.4.3 *)
  let b3 =
    of_hex "8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf"
  in
  let g3 = decode_full dec b3 in
  Alcotest.check fields_t "C.4.3"
    [
      hf ":method" "GET";
      hf ":scheme" "https";
      hf ":path" "/index.html";
      hf ":authority" "www.example.com";
      hf "custom-key" "custom-value";
    ]
    g3

(* ---------- RFC 7541 C.5 — response sequence with eviction (no Huffman) ---- *)

let c5_response_sequence () =
  let dec = H.new_decoder 256 (fun _ -> ()) in
  (* C.5.1 *)
  let b1 =
    of_hex
      "4803 3330 3258 0770 7269 7661 7465 611d 4d6f 6e2c 2032 3120 4f63 7420 \
       3230 3133 2032 303a 3133 3a32 3120 474d 546e 1768 7474 7073 3a2f 2f77 \
       7777 2e65 7861 6d70 6c65 2e63 6f6d"
  in
  let g1 = decode_full dec b1 in
  Alcotest.check fields_t "C.5.1"
    [
      hf ":status" "302";
      hf "cache-control" "private";
      hf "date" "Mon, 21 Oct 2013 20:13:21 GMT";
      hf "location" "https://www.example.com";
    ]
    g1;
  (* C.5.2 *)
  let b2 = of_hex "4803 3330 37c1 c0bf" in
  let g2 = decode_full dec b2 in
  Alcotest.check fields_t "C.5.2"
    [
      hf ":status" "307";
      hf "cache-control" "private";
      hf "date" "Mon, 21 Oct 2013 20:13:21 GMT";
      hf "location" "https://www.example.com";
    ]
    g2;
  (* C.5.3 *)
  let b3 =
    of_hex
      "88c1 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 \
       3220 474d 54c0 5a04 677a 6970 7738 666f 6f3d 4153 444a 4b48 514b 425a \
       584f 5157 454f 5049 5541 5851 5745 4f49 553b 206d 6178 2d61 6765 3d33 \
       3630 303b 2076 6572 7369 6f6e 3d31"
  in
  let g3 = decode_full dec b3 in
  Alcotest.check fields_t "C.5.3"
    [
      hf ":status" "200";
      hf "cache-control" "private";
      hf "date" "Mon, 21 Oct 2013 20:13:22 GMT";
      hf "location" "https://www.example.com";
      hf "content-encoding" "gzip";
      hf "set-cookie" "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1";
    ]
    g3

(* ---------- RFC 7541 C.6 — response sequence with eviction (Huffman) ---- *)

let c6_response_sequence_huffman () =
  let dec = H.new_decoder 256 (fun _ -> ()) in
  (* C.6.1 *)
  let b1 =
    of_hex
      "4882 6402 5885 aec3 771a 4b61 96d0 7abe 9410 54d4 44a8 2005 9504 0b81 \
       66e0 82a6 2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8 e9ae 82ae 43d3"
  in
  let g1 = decode_full dec b1 in
  Alcotest.check fields_t "C.6.1"
    [
      hf ":status" "302";
      hf "cache-control" "private";
      hf "date" "Mon, 21 Oct 2013 20:13:21 GMT";
      hf "location" "https://www.example.com";
    ]
    g1;
  (* C.6.2 *)
  let b2 = of_hex "4883 640e ffc1 c0bf" in
  let g2 = decode_full dec b2 in
  Alcotest.check fields_t "C.6.2"
    [
      hf ":status" "307";
      hf "cache-control" "private";
      hf "date" "Mon, 21 Oct 2013 20:13:21 GMT";
      hf "location" "https://www.example.com";
    ]
    g2;
  (* C.6.3 *)
  let b3 =
    of_hex
      "88c1 6196 d07a be94 1054 d444 a820 0595 040b 8166 e084 a62d 1bff c05a \
       839b d9ab 77ad 94e7 821d d7f2 e6c7 b335 dfdf cd5b 3960 d5af 2708 7f36 \
       72c1 ab27 0fb5 291f 9587 3160 65c0 03ed 4ee5 b106 3d50 07"
  in
  let g3 = decode_full dec b3 in
  Alcotest.check fields_t "C.6.3"
    [
      hf ":status" "200";
      hf "cache-control" "private";
      hf "date" "Mon, 21 Oct 2013 20:13:22 GMT";
      hf "location" "https://www.example.com";
      hf "content-encoding" "gzip";
      hf "set-cookie" "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1";
    ]
    g3

(* ---------- Encoder produces the RFC C.3 (no-Huffman) byte stream --------- *)

let encoder_c3_request_sequence () =
  (* The Go encoder always Huffman-encodes when strictly shorter (as here for
     "custom-key"), so the bytes differ from the raw RFC C.2.1 example. We
     assert: (1) it uses the literal-with-incremental-indexing type (top two
     bits 0b01), and (2) it round-trips back to the original field. *)
  let e = H.new_encoder () in
  let out = H.encode_to_string e [ hf "custom-key" "custom-header" ] in
  Alcotest.(check int)
    "incremental-indexing type byte" 0x40
    (Char.code out.[0] land 0xc0);
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  Alcotest.check fields_t "encoder C.2.1 round-trip"
    [ hf "custom-key" "custom-header" ]
    (decode_full dec out)

(* ---------- Success Criterion: Hpack.roundtrip ---------- *)

let roundtrip_basic () =
  let fields =
    [
      hf ":method" "GET";
      hf ":scheme" "https";
      hf ":path" "/index.html";
      hf ":authority" "www.example.com";
      hf "custom-key" "custom-value";
      hf "accept" "*/*";
      hf ~sensitive:true "authorization" "Bearer secrettoken";
      hf "user-agent" "gohttp/1.0";
    ]
  in
  let e = H.new_encoder () in
  let encoded = H.encode_to_string e fields in
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  let decoded = decode_full dec encoded in
  Alcotest.check fields_t "roundtrip basic" fields decoded

let roundtrip_dynamic_two_passes () =
  (* Exercise the dynamic table across two encode/decode passes on the SAME
     encoder/decoder pair: the second pass should reference table entries
     created in the first, and still decode identically. *)
  let e = H.new_encoder () in
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  let fields1 =
    [
      hf ":method" "POST";
      hf ":authority" "api.example.com";
      hf "x-custom-header" "first-value";
      hf "cookie" "session=abc123";
    ]
  in
  let enc1 = H.encode_to_string e fields1 in
  let dec1 = decode_full dec enc1 in
  Alcotest.check fields_t "pass 1" fields1 dec1;
  (* Second pass repeats some headers (should index into the dynamic table) *)
  let fields2 =
    [
      hf ":method" "POST";
      hf ":authority" "api.example.com";
      hf "x-custom-header" "first-value";
      hf "x-second-header" "second-value";
    ]
  in
  let enc2 = H.encode_to_string e fields2 in
  let dec2 = decode_full dec enc2 in
  Alcotest.check fields_t "pass 2" fields2 dec2;
  (* Confirm the repeated headers were emitted as indexed (compression):
     enc2 should be much shorter than a naive literal of fields2. *)
  Alcotest.(check bool)
    "pass2 compressed" true
    (String.length enc2 < String.length enc1)

let roundtrip_table_size_update () =
  (* Encoder emits a dynamic-table-size-update; decoder must accept it. *)
  let e = H.new_encoder () in
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  H.set_max_dynamic_table_size e 1024;
  let fields = [ hf ":status" "200"; hf "content-type" "text/plain" ] in
  let encoded = H.encode_to_string e fields in
  let decoded = decode_full dec encoded in
  Alcotest.check fields_t "roundtrip after size update" fields decoded

(* ---------- decode error cases ---------- *)

(* Named test (Result migration T3, plan success criterion): an out-of-range
   indexed reference -> Error (Invalid_indexed _). *)
let decode_invalid_index () =
  (* index 0 is invalid for an indexed field; 0x80 = indexed, idx 0 *)
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  (match H.decode_full dec (of_hex "80") with
  | Error (H.Invalid_indexed 0) -> ()
  | Error e ->
      Alcotest.failf "expected Invalid_indexed 0, got %s" (H.error_to_string e)
  | Ok _ -> Alcotest.fail "expected Error Invalid_indexed");
  (* an index way past the table also maps to Invalid_indexed *)
  let dec2 = H.new_decoder 4096 (fun _ -> ()) in
  match H.decode_full dec2 (of_hex "ff49") with
  | Error (H.Invalid_indexed 200) -> ()
  | Error e ->
      Alcotest.failf "expected Invalid_indexed 200, got %s"
        (H.error_to_string e)
  | Ok _ -> Alcotest.fail "expected Error Invalid_indexed"

let decode_index_too_large () =
  (* indexed field referencing index way past the table *)
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  match H.decode_full dec (of_hex "ff49") with
  | Error (H.Invalid_indexed 200) -> ()
  | _ -> Alcotest.fail "expected Error (Invalid_indexed 200)"

let decode_truncated () =
  (* literal with incremental indexing but truncated value -> Close errors *)
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  (* 0x40 new name, name len 10 but only 2 bytes follow *)
  match H.decode_full dec (of_hex "400a6375") with
  | Error (H.Decoding "truncated headers") -> ()
  | _ -> Alcotest.fail "expected Error (Decoding \"truncated headers\")"

(* Named test (Result migration T3): name/value over the max string length
   -> Error String_too_long. *)
let decode_string_too_long () =
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  H.set_max_string_length dec 5;
  (* C.2.1 has name "custom-key" (10 bytes) -> too long *)
  let b =
    of_hex "400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572"
  in
  match H.decode_full dec b with
  | Error H.String_too_long -> ()
  | _ -> Alcotest.fail "expected Error String_too_long"

let decode_size_update_too_large () =
  (* dynamic table size update of 5 (0x25 = 0b001_00101) but allowed max
     is the decoder's table size; set allowed to 0 then send update 5. *)
  let dec = H.new_decoder 0 (fun _ -> ()) in
  match H.decode_full dec (of_hex "25") with
  | Error (H.Decoding "dynamic table size update too large") -> ()
  | _ -> Alcotest.fail "expected Error (Decoding size-update-too-large)"

let decode_size_update_not_first () =
  (* A dynamic table size update after a field has been processed and the
     dynamic table is non-empty must error. *)
  let dec = H.new_decoder 4096 (fun _ -> ()) in
  (* literal w/ incremental indexing custom-key/custom-header (fills table),
     then a size update 0x3f... at non-first position *)
  let b =
    of_hex "400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572 20"
  in
  (* trailing 0x20 = dynamic table size update of 0 at non-first field *)
  match H.decode_full dec b with
  | Error
      (H.Decoding
         "dynamic table size update MUST occur at the beginning of a header \
          block") ->
      ()
  | _ -> Alcotest.fail "expected Error (Decoding size-update-not-at-start)"

let tests =
  [
    ("var_int_roundtrip", `Quick, var_int_roundtrip);
    ("var_int_rfc_C11", `Quick, var_int_rfc_c11);
    ("var_int_rfc_C12", `Quick, var_int_rfc_c12);
    ("var_int_need_more", `Quick, var_int_need_more);
    ("rfc_C21_literal_with_indexing", `Quick, c2_1_literal_with_indexing);
    ("rfc_C22_literal_without_indexing", `Quick, c2_2_literal_without_indexing);
    ("rfc_C23_literal_never_indexed", `Quick, c2_3_literal_never_indexed);
    ("rfc_C24_indexed", `Quick, c2_4_indexed);
    ("rfc_C3_request_sequence", `Quick, c3_request_sequence);
    ("rfc_C4_request_sequence_huffman", `Quick, c4_request_sequence_huffman);
    ("rfc_C5_response_sequence", `Quick, c5_response_sequence);
    ("rfc_C6_response_sequence_huffman", `Quick, c6_response_sequence_huffman);
    ("encoder_C21", `Quick, encoder_c3_request_sequence);
    ("roundtrip_basic", `Quick, roundtrip_basic);
    ("roundtrip_dynamic_two_passes", `Quick, roundtrip_dynamic_two_passes);
    ("roundtrip_table_size_update", `Quick, roundtrip_table_size_update);
    ("decode_invalid_index", `Quick, decode_invalid_index);
    ("decode_index_too_large", `Quick, decode_index_too_large);
    ("decode_truncated", `Quick, decode_truncated);
    ("decode_string_too_long", `Quick, decode_string_too_long);
    ("decode_size_update_too_large", `Quick, decode_size_update_too_large);
    ("decode_size_update_not_first", `Quick, decode_size_update_not_first);
  ]
