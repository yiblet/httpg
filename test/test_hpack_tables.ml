(* Ported from golang.org/x/net/http2/hpack tables_test.go and the Huffman
   cases of hpack_test.go (TestHuffmanRoundtrip / TestHuffmanDecode /
   TestHuffmanEncode). Pure tests. *)

open Gohttp_http2
module H = Hpack_huffman
module T = Hpack_tables

let hf ?(sensitive = false) name value : T.header_field =
  { name; value; sensitive }

(* hex-encode a string for readable failure messages *)
let to_hex s =
  String.concat ""
    (List.init (String.length s) (fun i ->
         Printf.sprintf "%02x" (Char.code s.[i])))

let of_hex h =
  let n = String.length h / 2 in
  String.init n (fun i ->
      Char.chr (int_of_string ("0x" ^ String.sub h (i * 2) 2)))

(* ---- Huffman ---- *)

let huffman_roundtrip () =
  (* Representative strings, incl. ones that exercise different EOS padding. *)
  let cases =
    [
      "";
      "a";
      "ab";
      "abc";
      "www.example.com";
      "no-cache";
      "custom-key";
      "custom-value";
      "Mon, 21 Oct 2013 20:13:21 GMT";
      "https://www.example.com";
      "302";
      "private";
      "gzip";
      "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1";
      "\x00\x01\x02\xfd\xfe\xff";
      (* high-code symbols (long codes) *)
      String.init 256 Char.chr;
      (* every byte value *)
    ]
  in
  List.iter
    (fun s ->
      let enc = H.encode s in
      let dec =
        match H.decode enc with
        | Ok d -> d
        | Error _ -> Alcotest.failf "roundtrip %S: unexpected decode error" s
      in
      Alcotest.(check string) (Printf.sprintf "roundtrip %S" s) s dec;
      Alcotest.(check int)
        (Printf.sprintf "encoded_len %S" s)
        (String.length enc) (H.encoded_len s))
    cases

(* RFC 7541 C.4.1: "www.example.com" Huffman-encodes to these bytes. *)
let huffman_rfc_vector () =
  let expected = of_hex "f1e3c2e5f23a6ba0ab90f4ff" in
  let enc = H.encode "www.example.com" in
  Alcotest.(check string)
    (Printf.sprintf "C.4.1 encode (got %s)" (to_hex enc))
    expected enc;
  Alcotest.(check string)
    "C.4.1 decode" "www.example.com"
    (Result.get_ok (H.decode expected))

(* RFC 7541 C.4.2: "no-cache" -> a8eb1064 9cbf *)
let huffman_rfc_vector2 () =
  let expected = of_hex "a8eb10649cbf" in
  Alcotest.(check string) "C.4.2 encode" expected (H.encode "no-cache");
  Alcotest.(check string)
    "C.4.2 decode" "no-cache"
    (Result.get_ok (H.decode expected))

let huffman_decode_invalid () =
  (* Overlong padding: a full 0xff byte cannot be valid EOS padding because the
     leftover bits exceed 7. Mirrors Go ErrInvalidHuffman cases. *)
  let bad_cases =
    [
      "\xff\xff\xff\xff";
      (* all ones: incomplete symbol / overlong padding *)
      "\x00";
      (* '0' code is 5 bits 00000; trailing 3 zero bits are not an
                 EOS prefix -> invalid *)
    ]
  in
  List.iter
    (fun s ->
      match H.decode s with
      | Error H.Invalid_huffman -> ()
      | Error H.String_too_long ->
          Alcotest.failf
            "invalid huffman %s: expected Invalid_huffman, got String_too_long"
            (to_hex s)
      | Ok _ ->
          Alcotest.failf "invalid huffman %s: expected Error, got Ok" (to_hex s))
    bad_cases

(* Named test (Result migration T3): invalid Huffman input -> Error; a valid
   round-trip -> Ok. *)
let decode_invalid () =
  (match H.decode "\xff\xff\xff\xff" with
  | Error H.Invalid_huffman -> ()
  | Error H.String_too_long -> Alcotest.fail "expected Invalid_huffman"
  | Ok _ -> Alcotest.fail "expected Error Invalid_huffman");
  let enc = H.encode "www.example.com" in
  match H.decode enc with
  | Ok "www.example.com" -> ()
  | Ok other -> Alcotest.failf "round-trip mismatch: %S" other
  | Error _ -> Alcotest.fail "valid round-trip unexpectedly Error"

(* ---- Static table ---- *)

let static_lookup_by_index () =
  Alcotest.(check int) "static len" 61 T.static_table_len;
  let e1 = T.static_table_entry 1 in
  Alcotest.(check string) "idx1 name" ":authority" e1.name;
  Alcotest.(check string) "idx1 value" "" e1.value;
  let e2 = T.static_table_entry 2 in
  Alcotest.(check string) "idx2 name" ":method" e2.name;
  Alcotest.(check string) "idx2 value" "GET" e2.value;
  let e8 = T.static_table_entry 8 in
  Alcotest.(check string) "idx8 name" ":status" e8.name;
  Alcotest.(check string) "idx8 value" "200" e8.value;
  let e16 = T.static_table_entry 16 in
  Alcotest.(check string) "idx16 name" "accept-encoding" e16.name;
  Alcotest.(check string) "idx16 value" "gzip, deflate" e16.value;
  let e61 = T.static_table_entry 61 in
  Alcotest.(check string) "idx61 name" "www-authenticate" e61.name

let check_search msg t f exp_i exp_match =
  let i, m = T.search t f in
  Alcotest.(check int) (msg ^ " index") exp_i i;
  Alcotest.(check bool) (msg ^ " match") exp_match m

let check_static msg f exp_i exp_match =
  let i, m = T.static_search f in
  Alcotest.(check int) (msg ^ " index") exp_i i;
  Alcotest.(check bool) (msg ^ " match") exp_match m

let static_search_cases () =
  (* name+value match *)
  check_static ":method GET" (hf ":method" "GET") 2 true;
  check_static ":method POST" (hf ":method" "POST") 3 true;
  check_static ":status 200" (hf ":status" "200") 8 true;
  check_static "accept-encoding gzip,deflate"
    (hf "accept-encoding" "gzip, deflate")
    16 true;
  (* name-only match: ":method" with unknown value -> newest id (POST=3) *)
  check_static ":method PUT" (hf ":method" "PUT") 3 false;
  (* ":status" name-only -> newest id (500 = 14) *)
  check_static ":status 999" (hf ":status" "999") 14 false;
  (* no match *)
  check_static "nope" (hf "x-not-real" "v") 0 false;
  (* sensitive: never match name+value but still name *)
  check_static ":method GET sensitive"
    (hf ~sensitive:true ":method" "GET")
    3 false

(* ---- headerFieldTable add/search/idToIndex/evict (dynamic semantics) ---- *)

(* Mirrors Go TestHeaderFieldTable. *)
let dynamic_table_search () =
  let t = T.create_table () in
  let entries =
    [
      hf "key1" "value1-1";
      hf "key2" "value2-1";
      hf "key1" "value1-2";
      hf "key3" "value3-1";
      hf "key4" "value4-1";
      hf "key2" "value2-2";
      hf "key3" "value3-2";
    ]
  in
  List.iter (T.add_entry t) entries;
  Alcotest.(check int) "len" 7 (T.table_len t);
  (* newest entry has HPACK index 1; oldest index 7 *)
  check_search "key3 value3-2 (newest)" t (hf "key3" "value3-2") 1 true;
  check_search "key2 value2-2" t (hf "key2" "value2-2") 2 true;
  check_search "key4 value4-1" t (hf "key4" "value4-1") 3 true;
  check_search "key1 value1-2" t (hf "key1" "value1-2") 5 true;
  check_search "key1 value1-1 (oldest)" t (hf "key1" "value1-1") 7 true;
  (* name-only: newest matching name *)
  check_search "key1 name-only" t (hf "key1" "other") 5 false;
  check_search "key3 name-only" t (hf "key3" "other") 1 false;
  (* no match *)
  check_search "absent" t (hf "key9" "v") 0 false;
  (* evict 4 oldest; ids stable, indices recompute *)
  T.evict_oldest t 4;
  Alcotest.(check int) "len after evict" 3 (T.table_len t);
  (* remaining: key4/value4-1, key2/value2-2, key3/value3-2 (oldest..newest) *)
  check_search "key3 value3-2 after evict" t (hf "key3" "value3-2") 1 true;
  check_search "key2 value2-2 after evict" t (hf "key2" "value2-2") 2 true;
  check_search "key4 value4-1 after evict" t (hf "key4" "value4-1") 3 true;
  (* evicted entries no longer found *)
  check_search "key1 evicted" t (hf "key1" "value1-2") 0 false

(* ---- dynamic_table size accounting + eviction + set_max_size ---- *)

let field_size () =
  Alcotest.(check int)
    "size custom-key/custom-header"
    (10 + 13 + 32)
    (T.size (hf "custom-key" "custom-header"))

let dynamic_table_add_evict () =
  (* size of {":method","GET"} = 7 + 3 + 32 = 42 *)
  let m_get = hf ":method" "GET" in
  Alcotest.(check int) "method get size" 42 (T.size m_get);
  let dt = T.create_dynamic_table 100 in
  Alcotest.(check int) "init max" 100 (T.dynamic_max_size dt);
  Alcotest.(check int) "init size" 0 (T.dynamic_size dt);
  T.dynamic_add dt m_get;
  Alcotest.(check int) "size after 1 add" 42 (T.dynamic_size dt);
  Alcotest.(check int) "len after 1" 1 (T.dynamic_len dt);
  T.dynamic_add dt (hf ":path" "/");
  (* size 5+1+32 = 38; total 80 *)
  Alcotest.(check int) "size after 2 add" 80 (T.dynamic_size dt);
  Alcotest.(check int) "len after 2" 2 (T.dynamic_len dt);
  (* adding a 3rd -> total > 100 -> evict oldest *)
  T.dynamic_add dt (hf ":scheme" "https");
  (* 7+5+32 = 44 ; total 80+44=124 *)
  (* evict oldest only until <=100: remove GET(42) -> 82; stop. *)
  Alcotest.(check int) "size after evict" 82 (T.dynamic_size dt);
  Alcotest.(check int) "len after evict" 2 (T.dynamic_len dt);
  (* newest (:scheme/https) at static_len+1, then :path/ at static_len+2 *)
  (match T.at dt (T.static_table_len + 1) with
  | Some f ->
      Alcotest.(check string) "newest name" ":scheme" f.name;
      Alcotest.(check string) "newest value" "https" f.value
  | None -> Alcotest.fail "expected an entry at static_len+1");
  match T.at dt (T.static_table_len + 2) with
  | Some f ->
      Alcotest.(check string) "older name" ":path" f.name;
      Alcotest.(check string) "older value" "/" f.value
  | None -> Alcotest.fail "expected an entry at static_len+2"

let dynamic_set_max_size () =
  let dt = T.create_dynamic_table 4096 in
  T.dynamic_add dt (hf "a" "b");
  (* 1+1+32 = 34 *)
  T.dynamic_add dt (hf "c" "d");
  (* 34 ; total 68 *)
  Alcotest.(check int) "size" 68 (T.dynamic_size dt);
  Alcotest.(check int) "len" 2 (T.dynamic_len dt);
  (* shrink to 34 -> evict oldest (a/b) leaving c/d (34) *)
  T.set_max_size dt 34;
  Alcotest.(check int) "max after shrink" 34 (T.dynamic_max_size dt);
  Alcotest.(check int) "size after shrink" 34 (T.dynamic_size dt);
  Alcotest.(check int) "len after shrink" 1 (T.dynamic_len dt);
  (* shrink to 0 -> evict everything *)
  T.set_max_size dt 0;
  Alcotest.(check int) "size after 0" 0 (T.dynamic_size dt);
  Alcotest.(check int) "len after 0" 0 (T.dynamic_len dt)

let dynamic_at_combined_index () =
  let dt = T.create_dynamic_table 4096 in
  (* index 0 -> None *)
  Alcotest.(check bool) "at 0" true (T.at dt 0 = None);
  (* static index 1 *)
  (match T.at dt 1 with
  | Some f -> Alcotest.(check string) "at 1 name" ":authority" f.name
  | None -> Alcotest.fail "at 1");
  (* static index 61 *)
  (match T.at dt 61 with
  | Some f -> Alcotest.(check string) "at 61 name" "www-authenticate" f.name
  | None -> Alcotest.fail "at 61");
  (* out of range with empty dynamic table *)
  Alcotest.(check bool) "at 62 empty" true (T.at dt 62 = None);
  (* add two; newest is index 62 *)
  T.dynamic_add dt (hf "x-first" "1");
  T.dynamic_add dt (hf "x-second" "2");
  (match T.at dt 62 with
  | Some f -> Alcotest.(check string) "at 62 newest" "x-second" f.name
  | None -> Alcotest.fail "at 62");
  (match T.at dt 63 with
  | Some f -> Alcotest.(check string) "at 63 oldest" "x-first" f.name
  | None -> Alcotest.fail "at 63");
  Alcotest.(check bool) "at 64 oob" true (T.at dt 64 = None)

let is_pseudo_test () =
  Alcotest.(check bool) "pseudo :method" true (T.is_pseudo (hf ":method" "GET"));
  Alcotest.(check bool) "not pseudo host" false (T.is_pseudo (hf "host" "x"));
  Alcotest.(check bool) "empty not pseudo" false (T.is_pseudo (hf "" ""))

let tests =
  [
    ("huffman_roundtrip", `Quick, huffman_roundtrip);
    ("huffman_rfc_vector_C41", `Quick, huffman_rfc_vector);
    ("huffman_rfc_vector_C42", `Quick, huffman_rfc_vector2);
    ("huffman_decode_invalid", `Quick, huffman_decode_invalid);
    ("huffman_decode_invalid_result", `Quick, decode_invalid);
    ("static_lookup_by_index", `Quick, static_lookup_by_index);
    ("static_search", `Quick, static_search_cases);
    ("dynamic_table_search", `Quick, dynamic_table_search);
    ("field_size", `Quick, field_size);
    ("dynamic_table_add_evict", `Quick, dynamic_table_add_evict);
    ("dynamic_set_max_size", `Quick, dynamic_set_max_size);
    ("dynamic_at_combined_index", `Quick, dynamic_at_combined_index);
    ("is_pseudo", `Quick, is_pseudo_test);
  ]
