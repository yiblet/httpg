(* Ported from go/src/net/http/internal/http2/flow_test.go.
   Window add/take/available + int32 overflow semantics for inflow/outflow. *)

module Flow = Httpg_http2.H2_flow

let i32 = Alcotest.testable (Fmt.of_to_string Int32.to_string) Int32.equal

(* [err_code] testable for the [inflow_add] result (ticket 008). *)
let ec =
  Alcotest.testable
    (Fmt.of_to_string (fun c ->
         string_of_int (Httpg_http2.H2_error.err_code_to_int c)))
    ( = )

(* TestInFlowTake *)
let test_inflow_take () =
  let f = Flow.create_inflow () in
  Flow.inflow_init f 100l;
  Alcotest.(check bool) "take 40 from 100" true (Flow.inflow_take f 40);
  Alcotest.(check bool) "take 40 from 60" true (Flow.inflow_take f 40);
  Alcotest.(check bool) "take 40 from 20" false (Flow.inflow_take f 40);
  Alcotest.(check bool) "take 20 from 20" true (Flow.inflow_take f 20)

(* TestInflowAddSmall *)
let test_inflow_add_small () =
  let f = Flow.create_inflow () in
  Flow.inflow_init f 0l;
  (* Adding even a small amount when there is no flow causes an immediate
     send. *)
  Alcotest.check (Alcotest.result i32 ec) "add(1) to 1" (Ok 1l)
    (Flow.inflow_add f 1)

(* TestInflowAdd *)
let test_inflow_add () =
  let f = Flow.create_inflow () in
  Flow.inflow_init f (Int32.of_int (10 * Flow.Private.inflow_min_refresh));
  Alcotest.check (Alcotest.result i32 ec) "add(minRefresh-1)" (Ok 0l)
    (Flow.inflow_add f (Flow.Private.inflow_min_refresh - 1));
  Alcotest.check (Alcotest.result i32 ec) "add(1) reaches minRefresh"
    (Ok (Int32.of_int Flow.Private.inflow_min_refresh))
    (Flow.inflow_add f 1)

(* TestTakeInflows *)
let test_take_inflows () =
  let a = Flow.create_inflow () in
  let b = Flow.create_inflow () in
  Flow.inflow_init a 10l;
  Flow.inflow_init b 20l;
  Alcotest.(check bool) "take 5 from 10,20" true (Flow.take_inflows a b 5);
  Alcotest.(check bool) "take 6 from 5,15" false (Flow.take_inflows a b 6);
  Alcotest.(check bool) "take 5 from 5,15" true (Flow.take_inflows a b 5)

(* inflow add negative: a genuine programming bug, raised as Invalid_argument
   (Go panics "negative update", flow.go:35). *)
let test_inflow_add_negative () =
  let f = Flow.create_inflow () in
  Flow.inflow_init f 0l;
  Alcotest.check_raises "negative" (Invalid_argument "negative update")
    (fun () -> ignore (Flow.inflow_add f (-1)))

(* inflow add overflow: Go panics (flow.go:42), but to avoid crashing the
   serve fiber we surface a modeled FLOW_CONTROL_ERROR connection error as a
   typed [Error] that the serve loop converts to a GOAWAY (ticket 008). *)
let test_inflow_add_overflow () =
  let f = Flow.create_inflow () in
  Flow.inflow_init f (Int32.of_int Flow.max_window);
  Alcotest.check (Alcotest.result i32 ec) "overflow"
    (Error Httpg_http2.H2_error.FlowControlError) (Flow.inflow_add f 1)

(* TestOutFlow *)
let test_outflow () =
  let st = Flow.create_outflow () in
  let conn = Flow.create_outflow () in
  ignore (Flow.add st 3l);
  ignore (Flow.add conn 2l);
  Alcotest.check i32 "available = 3" 3l (Flow.available st);
  Flow.set_conn_flow st conn;
  Alcotest.check i32 "after parent setup, available = 2" 2l (Flow.available st);
  Flow.take st 2l;
  Alcotest.check i32 "after taking 2, conn = 0" 0l (Flow.available conn);
  Alcotest.check i32 "after taking 2, stream = 0" 0l (Flow.available st)

(* TestOutFlowAdd *)
let test_outflow_add () =
  let f = Flow.create_outflow () in
  Alcotest.(check bool) "add 1" true (Flow.add f 1l);
  Alcotest.(check bool) "add -1" true (Flow.add f (-1l));
  Alcotest.check i32 "available 0" 0l (Flow.available f);
  Alcotest.(check bool)
    "add 2^31-1" true
    (Flow.add f (Int32.of_int Flow.max_window));
  Alcotest.check i32 "available 2^31-1"
    (Int32.of_int Flow.max_window)
    (Flow.available f);
  Alcotest.(check bool) "adding 1 to max not allowed" false (Flow.add f 1l)

(* TestOutFlowAddOverflow *)
let test_outflow_add_overflow () =
  let f = Flow.create_outflow () in
  Alcotest.(check bool) "add 0" true (Flow.add f 0l);
  Alcotest.(check bool) "add -1" true (Flow.add f (-1l));
  Alcotest.(check bool) "add 0" true (Flow.add f 0l);
  Alcotest.(check bool) "add 1" true (Flow.add f 1l);
  Alcotest.(check bool) "add 1" true (Flow.add f 1l);
  Alcotest.(check bool) "add 0" true (Flow.add f 0l);
  Alcotest.(check bool) "add -3" true (Flow.add f (-3l));
  Alcotest.check i32 "available -2" (-2l) (Flow.available f);
  Alcotest.(check bool)
    "add 2^31-1" true
    (Flow.add f (Int32.of_int Flow.max_window));
  Alcotest.check i32 "available"
    (Int32.add (Int32.add 1l (-3l)) (Int32.of_int Flow.max_window))
    (Flow.available f)

let tests =
  [
    ("inflow_take", `Quick, test_inflow_take);
    ("inflow_add_small", `Quick, test_inflow_add_small);
    ("inflow_add", `Quick, test_inflow_add);
    ("take_inflows", `Quick, test_take_inflows);
    ("inflow_add_negative", `Quick, test_inflow_add_negative);
    ("inflow_add_overflow", `Quick, test_inflow_add_overflow);
    ("outflow", `Quick, test_outflow);
    ("outflow_add", `Quick, test_outflow_add);
    ("outflow_add_overflow", `Quick, test_outflow_add_overflow);
  ]
