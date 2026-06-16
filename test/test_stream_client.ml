(* Streaming client response bodies (HTTP/1.x): the Client/Transport return a
   streaming [Response.body] whose EOF/drain action governs connection reuse,
   and a per-request timeout firing mid-body aborts the in-flight read.

   These tests start a real loopback server on an ephemeral port and drive it
   with the httpg [Client]:

   - client_body_streamed: a handler streams many flushed chunks; the client
     obtains a [Body.Stream] whose first chunk is readable while the handler is
     still suspended mid-body, and draining yields the full payload.
   - reuse_after_drain: two sequential [Client.get]s; after the first body is
     drained the second reuses the pooled connection (dial count stays 1).
   - cancel_mid_body: an [Eio.Time.with_timeout] around a body that streams one
     chunk then stalls aborts with [Eio.Time.Timeout].

   Bounded by Test_harness.with_env. *)

open Httpg

(* Unwrap a happy-path client result, failing the test on a transport/redirect
   error. *)
let ok_resp = function
  | Ok resp -> resp
  | Error e -> Alcotest.failf "client: %s" (Client.error_to_string e)

let with_server ?(secs = 10.0) handler client =
  Test_harness.with_env ~secs (fun ~net ~clock ~sw ->
      let srv, port, serve_loop =
        Server.listen_and_serve_started ~net ~clock ~sw ~addr:"127.0.0.1"
          ~port:0 handler
      in
      Eio.Fiber.fork ~sw serve_loop;
      Fun.protect
        (fun () -> client ~net ~sw ~clock ~port)
        ~finally:(fun () -> Server.close srv))

(* Pull one chunk from a body, failing the test on a mid-stream error. *)
let next_chunk b =
  match Body.to_stream b () with
  | Some (Ok s) -> Some s
  | Some (Error e) -> Alcotest.failf "body: %s" (Body.error_to_string e)
  | None -> None

let read_body b =
  match Body.read_all b with
  | Ok s -> s
  | Error e -> Alcotest.failf "body: %s" (Body.error_to_string e)

(* ---- Stream.client_body_streamed ---- *)
(* The handler flushes a first chunk, then blocks on [released] which the test
   resolves ONLY after reading that early chunk — proving the body is not
   pre-materialized. After release the handler streams the rest. *)
let client_body_streamed () =
  let released, release = Eio.Promise.create () in
  let n_more = 200 in
  let more_chunk = String.make 1024 'x' in
  let handler =
   fun ~sw:_ _r ->
    let phase = ref `First and more = ref n_more in
    let next () =
      match !phase with
      | `First ->
          phase := `More;
          Some "FIRST"
      | `More ->
          (* block once, after FIRST has been flushed, before the rest. *)
          if !more = n_more then Eio.Promise.await released;
          if !more > 0 then begin
            decr more;
            Some more_chunk
          end
          else None
    in
    Response.create () |> Response.with_body (Body.of_stream next)
  in
  let client ~net ~sw ~clock ~port =
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    let resp = ok_resp (Client.get ~sw (Client.create ~net ~clock ()) url) in
    (* Read the first chunk BEFORE releasing the still-suspended handler. *)
    let first = next_chunk resp.Response.body in
    let handler_done_early = Eio.Promise.is_resolved released in
    Eio.Promise.resolve release ();
    let rest = read_body resp.Response.body in
    (first, handler_done_early, rest)
  in
  let first, handler_done_early, rest = with_server handler client in
  Alcotest.(check bool)
    "first chunk readable" true
    (first <> None && first <> Some "");
  Alcotest.(check bool)
    "first chunk arrived before handler completed" false handler_done_early;
  let first_s = match first with Some s -> s | None -> "" in
  let full = first_s ^ rest in
  let expected =
    "FIRST" ^ String.concat "" (List.init n_more (fun _ -> more_chunk))
  in
  Alcotest.(check int)
    "full body length" (String.length expected) (String.length full);
  Alcotest.(check string) "full body content" expected full

(* ---- Stream.reuse_after_drain ---- *)
let reuse_after_drain () =
  let handler =
   fun ~sw:_ _r -> Response.create () |> Response.with_body_string "hello"
  in
  let client ~net ~sw ~clock ~port =
    let transport = Transport.create ~net ~clock () in
    let c = Client.create ~net ~clock ~transport () in
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    let resp1 = ok_resp (Client.get ~sw c url) in
    ignore (Body.drain resp1.Response.body);
    let dials_after_1 = Transport.dial_count transport in
    let idle_after_1 =
      Transport.idle_count transport
        (Transport.conn_key ~scheme:"http" ~host:"127.0.0.1" ~port)
    in
    let resp2 = ok_resp (Client.get ~sw c url) in
    let b2 = read_body resp2.Response.body in
    let dials_after_2 = Transport.dial_count transport in
    (dials_after_1, idle_after_1, b2, dials_after_2)
  in
  let dials_after_1, idle_after_1, b2, dials_after_2 =
    with_server handler client
  in
  Alcotest.(check int) "first request dialed once" 1 dials_after_1;
  Alcotest.(check int) "connection pooled after drain" 1 idle_after_1;
  Alcotest.(check string) "resp2 body" "hello" b2;
  Alcotest.(check int)
    "second request reused the connection (no new dial)" 1 dials_after_2

(* ---- Stream.cancel_mid_body ---- *)
(* The handler streams one chunk, flushes, then stalls past the timeout. The
   client reads the first chunk fine, but the next body read races the (now
   expired) timeout and fails with Eio.Time.Timeout. *)
let cancel_mid_body () =
  let first, outcome =
    Test_harness.with_env (fun ~net ~clock ~sw ->
        let handler =
         fun ~sw:_ _r ->
          let phase = ref `Early in
          let next () =
            match !phase with
            | `Early ->
                phase := `Late;
                Some "early"
            | `Late ->
                Eio.Time.sleep clock 5.0;
                phase := `Done;
                Some "late"
            | `Done -> None
          in
          Response.create () |> Response.with_body (Body.of_stream next)
        in
        let srv, port, serve_loop =
          Server.listen_and_serve_started ~net ~clock ~sw ~addr:"127.0.0.1"
            ~port:0 handler
        in
        Eio.Fiber.fork ~sw serve_loop;
        Fun.protect
          ~finally:(fun () -> Server.close srv)
          (fun () ->
            let url = Printf.sprintf "http://127.0.0.1:%d/" port in
            let resp =
              ok_resp (Client.get ~sw (Client.create ~net ~clock ()) url)
            in
            let first = next_chunk resp.Response.body in
            let outcome =
              try
                Eio.Time.with_timeout_exn clock 0.3 (fun () ->
                    ignore (Body.read_all resp.Response.body);
                    `No_error)
              with
              | Eio.Time.Timeout -> `Deadline
              | e -> `Other (Printexc.to_string e)
            in
            (first, outcome)))
  in
  Alcotest.(check bool)
    "first chunk readable" true
    (first <> None && first <> Some "");
  match outcome with
  | `Deadline -> ()
  | `No_error -> Alcotest.fail "expected Timeout mid-body, got full body"
  | `Other s -> Alcotest.failf "expected Timeout mid-body, got %s" s

let tests =
  [
    Alcotest.test_case "client_body_streamed" `Quick client_body_streamed;
    Alcotest.test_case "reuse_after_drain" `Quick reuse_after_drain;
    Alcotest.test_case "cancel_mid_body" `Slow cancel_mid_body;
  ]
