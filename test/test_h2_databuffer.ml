(* Ported from go/src/net/http/internal/http2/databuffer_test.go.
   Write spanning chunk boundaries + read at several read sizes; read-empty.
   The Go tests also reflect.DeepEqual the internal chunk layout; that internal
   slice is not exposed here, so we assert the observable contract (the bytes
   read back match, across read sizes that cross chunk boundaries) which is
   exactly what Go's testDataBuffer helper validates. *)

module DB = Gohttp.H2_databuffer

let repeat c n = String.make n c

(* testDataBuffer: read the buffer fully at each read size and compare to
   wantBytes. Reading stops at Read_empty. *)
let check_data_buffer ~name (want : string) (setup : unit -> DB.t) =
  List.iter
    (fun read_size ->
      let b = setup () in
      let got = Buffer.create (String.length want) in
      let continue = ref true in
      while !continue do
        match DB.read_string b read_size with
        | "" ->
            (* a zero-length read with data present can't happen for
               read_size>0; an empty buffer raises Read_empty. *)
            continue := false
        | s -> Buffer.add_string got s
        | exception DB.Read_empty -> continue := false
      done;
      Alcotest.(check string)
        (Printf.sprintf "%s ReadSize=%d" name read_size)
        want (Buffer.contents got))
    [ 1; 2; 1 * 1024; 32 * 1024 ]

(* TestDataBufferAllocation *)
let test_allocation () =
  let writes =
    [
      repeat 'a' ((1 * 1024) - 1);
      "a";
      repeat 'b' ((4 * 1024) - 1);
      "b";
      repeat 'c' ((8 * 1024) - 1);
      "c";
      repeat 'd' ((16 * 1024) - 1);
      "d";
      repeat 'e' (32 * 1024);
    ]
  in
  let want = String.concat "" writes in
  check_data_buffer ~name:"allocation" want (fun () ->
      let b = DB.create () in
      List.iter
        (fun p ->
          let n = DB.write_string b p in
          Alcotest.(check int) "write n" (String.length p) n)
        writes;
      b)

(* TestDataBufferAllocationWithExpected *)
let test_allocation_with_expected () =
  let writes =
    [
      repeat 'a' (1 * 1024);
      repeat 'b' (14 * 1024);
      repeat 'c' (15 * 1024);
      repeat 'd' (2 * 1024);
      repeat 'e' (1 * 1024);
    ]
  in
  let want = String.concat "" writes in
  check_data_buffer ~name:"allocation_expected" want (fun () ->
      let b = DB.create ~expected:(Int64.of_int (32 * 1024)) () in
      List.iter
        (fun p ->
          let n = DB.write_string b p in
          Alcotest.(check int) "write n" (String.length p) n)
        writes;
      b)

(* TestDataBufferWriteAfterPartialRead *)
let test_write_after_partial_read () =
  check_data_buffer ~name:"write_after_partial_read" "cdxyz" (fun () ->
      let b = DB.create () in
      Alcotest.(check int) "write abcd" 4 (DB.write_string b "abcd");
      let p = DB.read_string b 2 in
      Alcotest.(check string) "read ab" "ab" p;
      Alcotest.(check int) "write xyz" 3 (DB.write_string b "xyz");
      b)

(* errReadEmpty on an empty buffer *)
let test_read_empty () =
  let b = DB.create () in
  Alcotest.(check int) "len 0" 0 (DB.len b);
  Alcotest.check_raises "read empty" DB.Read_empty (fun () ->
      ignore (DB.read_string b 4));
  (* and after draining all data *)
  ignore (DB.write_string b "hi");
  Alcotest.(check int) "len 2" 2 (DB.len b);
  Alcotest.(check string) "drain" "hi" (DB.read_string b 8);
  Alcotest.(check int) "len 0 after drain" 0 (DB.len b);
  Alcotest.check_raises "read empty again" DB.Read_empty (fun () ->
      ignore (DB.read_string b 4))

let tests =
  [
    ("allocation", `Quick, test_allocation);
    ("allocation_with_expected", `Quick, test_allocation_with_expected);
    ("write_after_partial_read", `Quick, test_write_after_partial_read);
    ("read_empty", `Quick, test_read_empty);
  ]
