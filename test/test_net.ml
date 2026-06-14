(* Integration smoke test for the Net socket substrate.

   [loopback_roundtrip] binds an ephemeral loopback listener, accepts one
   connection that echoes a line, connects a client to the bound port, writes
   ["PING"], reads the echoed line, and asserts equality. Bounded by a timeout
   (Test_harness.with_env) so a hang fails the test instead of blocking.

   [tls_spin_guard] checks Net's port of crypto/tls's maxUselessRecords (=16):
   after the handshake a hand-driven server floods the client with TLS 1.3
   KeyUpdate records -- records that decode but carry no application data and
   need no reply (non-advancing). The client's [Tls_flow.single_read] must cut
   the peer off with [Net.Tls_error "too many ignored records"] after the
   bounded count, rather than spinning unbounded. *)

open Httpg

let loopback_roundtrip () =
  let echoed =
    Test_harness.with_env ~secs:5. (fun ~net ~clock:_ ~sw ->
        let listener = Net.listen ~sw net "127.0.0.1" 0 in
        let port = Net.bound_port listener in
        (* Server fiber: accept one connection, read a line, echo it back. *)
        let server () =
          let flow, _peer = Net.accept ~sw listener in
          Net.with_connection flow (fun r w ->
              let line = Eio.Buf_read.line r in
              Eio.Buf_write.string w (line ^ "\n"))
        in
        (* Client: connect, send a line, read the echo. *)
        let client () =
          let flow =
            match Net.connect ~sw net ~host:"127.0.0.1" ~port with
            | Ok x -> x
            | Error e -> Alcotest.failf "net: %s" (Net.error_to_string e)
          in
          Net.with_connection flow (fun r w ->
              Eio.Buf_write.string w "PING\n";
              (* flush so the server sees the line. *)
              Eio.Buf_write.flush w;
              Eio.Buf_read.line r)
        in
        let echoed = ref "" in
        Eio.Fiber.both server (fun () -> echoed := client ());
        !echoed)
  in
  Alcotest.(check string) "echoed line" "PING" echoed

(* Hand-drive a server-side [Tls.Engine] over [flow]: handshake to completion,
   then return the established state. Mirrors what [Tls_flow] does, but kept in
   the test so we can inject non-advancing records the [Tls_flow] driver never
   would. *)
let server_handshake flow state =
  let rawbuf = Cstruct.create 0x4000 in
  let write s =
    if String.length s > 0 then Eio.Flow.write flow [ Cstruct.of_string s ]
  in
  let read () =
    match Eio.Flow.single_read flow rawbuf with
    | 0 -> ""
    | n -> Cstruct.to_string (Cstruct.sub rawbuf 0 n)
    | exception End_of_file -> ""
  in
  let st = ref state in
  while Tls.Engine.handshake_in_progress !st do
    match read () with
    | "" -> failwith "server: peer closed during handshake"
    | raw -> (
        match Tls.Engine.handle_tls !st raw with
        | Ok (st', _eof, `Response resp, `Data _) -> (
            st := st';
            match resp with Some s -> write s | None -> ())
        | Error _ -> failwith "server: handshake error")
  done;
  (!st, write)

let tls_spin_guard () =
  let result =
    Test_harness.with_env ~secs:10. (fun ~net ~clock ~sw ->
        Net.ensure_rng ();
        let certificates = Net.test_server_certificate () in
        let listener = Net.listen ~sw net "127.0.0.1" 0 in
        let port = Net.bound_port listener in
        let caught = ref None in
        let server () =
          let flow, _peer = Net.accept ~sw listener in
          let cfg =
            match Tls.Config.server ~certificates:(`Single certificates) () with
            | Ok c -> c
            | Error (`Msg m) -> failwith m
          in
          let state, write = server_handshake flow (Tls.Engine.server cfg) in
          (* Empty application_data records: each decrypts to zero plaintext, so
             the client hands no app data to its reader -- non-advancing, but
             uses the established key (no ratchet, no MAC desync). Flood well past
             maxUselessRecords. *)
          let st = ref state in
          try
            for _ = 1 to 40 do
              match Tls.Engine.send_application_data !st [ "" ] with
              | Some (st', out) ->
                  st := st';
                  write out;
                  (* Pace the records so each lands in its own client raw read
                      (one [handle_tls] batch) -- otherwise loopback coalesces
                      them into a single non-advancing batch. *)
                  Eio.Time.sleep clock 0.002
              | None -> ()
            done
          with _ -> ()
        in
        let client () =
          (* The spin guard trips inside the TLS read while [fn] runs, so the
             handleable [Net.Tls_error] is converted at the public boundary into
             [Error (Net.Tls _)]. A stray [End_of_file] (no guard) is captured
             separately so the failure mode is distinguishable. *)
          match
            try
              `Res
                (Net.connect_tls ~sw net ~host:"127.0.0.1" ~port ~tls:true
                   ~insecure:true (fun r _w ->
                     (* Try to read a line; the server never sends app data,
                        only KeyUpdates, so the spin guard must trip. *)
                     ignore (Eio.Buf_read.line r)))
            with End_of_file -> `Eof
          with
          | `Res (Ok ()) -> caught := Some `Ok
          | `Res (Error (Net.Tls msg)) -> caught := Some (`Tls msg)
          | `Res (Error (Net.Dial msg)) -> caught := Some (`Dial msg)
          | `Eof -> caught := Some `Eof
        in
        Eio.Fiber.both server client;
        !caught)
  in
  match result with
  | Some (`Tls msg) ->
      Alcotest.(check string) "spin guard error" "too many ignored records" msg
  | Some `Eof ->
      Alcotest.fail "got End_of_file, expected Error (Net.Tls _) spin guard"
  | Some (`Dial _) -> Alcotest.fail "unexpected Net.Dial error"
  | Some `Ok ->
      Alcotest.fail "expected the spin guard to trip, but read succeeded"
  | None -> Alcotest.fail "expected the spin guard to trip, but read succeeded"

(* A dial to an unresolvable host surfaces the typed, handleable [Error (Net.Dial
   _)] (the analogue of Go's [Dial] returning a [*net.DNSError] "no such host") --
   not a raise. We use a [.invalid] TLD (RFC 6761 §6.4: guaranteed never to
   resolve) so the resolver returns no address and the boundary converts the
   internal sentinel to the typed result. *)
let dial_failure_is_typed () =
  let caught =
    Test_harness.with_env ~secs:5. (fun ~net ~clock:_ ~sw ->
        match Net.connect ~sw net ~host:"no-such-host.invalid" ~port:80 with
        | Ok _flow -> `Ok
        | Error (Net.Dial _) -> `Dial
        | Error (Net.Tls _) -> `Tls
        | exception e -> `Raised e)
  in
  match caught with
  | `Dial -> ()
  | `Tls -> Alcotest.fail "expected Error (Net.Dial _), got Error (Net.Tls _)"
  | `Raised e ->
      Alcotest.failf "expected Error (Net.Dial _), got raise %s"
        (Printexc.to_string e)
  | `Ok -> Alcotest.fail "expected Error (Net.Dial _), but the dial succeeded"

let tests =
  [
    Alcotest.test_case "loopback_roundtrip" `Quick loopback_roundtrip;
    Alcotest.test_case "tls_spin_guard" `Quick tls_spin_guard;
    Alcotest.test_case "dial_failure_is_typed" `Quick dial_failure_is_typed;
  ]
