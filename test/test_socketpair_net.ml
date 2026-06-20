(* Unit tests for the in-memory ("fakenet") network substrate
   {!Httpg_internal.Socketpair_net}: a custom [Eio.Net.t] whose connections are
   kernel socketpairs, with no loopback / DNS / ports. Exercised through the
   public {!Httpg.Net} listen/accept/connect helpers, which is exactly how the
   server and client reach it. *)

open Httpg
module Spn = Httpg_internal.Socketpair_net

(* A server fiber accepts one connection and echoes a single line; a client
   fiber connects to the same host name, sends a line, and reads it back. The
   bytes travel over the in-memory connection, proving listen/connect rendezvous
   and real bidirectional transfer. *)
let roundtrip () =
  Test_harness.with_env (fun ~net:_ ~clock:_ ~sw ->
      let mem = Spn.net (Spn.create ()) in
      let listen_sock =
        match Net.listen ~sw mem "example.com" 80 with
        | Ok l -> l
        | Error e -> Alcotest.failf "listen: %s" (Net.error_to_string e)
      in
      let received = ref "" in
      Eio.Fiber.both
        (fun () ->
          let flow, _peer = Net.accept ~sw listen_sock in
          Net.with_connection flow (fun r w ->
              let line = Eio.Buf_read.line r in
              Eio.Buf_write.string w (line ^ "\n");
              Eio.Buf_write.flush w))
        (fun () ->
          let flow =
            match Net.connect ~sw mem ~host:"example.com" ~port:80 with
            | Ok f -> f
            | Error e -> Alcotest.failf "connect: %s" (Net.error_to_string e)
          in
          Net.with_connection flow (fun r w ->
              Eio.Buf_write.string w "ping\n";
              Eio.Buf_write.flush w;
              received := Eio.Buf_read.line r));
      Alcotest.(check string) "echo roundtrip" "ping" !received)

(* Connecting to an address with no bound listener fails (the in-memory analogue
   of a refused dial) rather than hanging. *)
let connect_refused () =
  Test_harness.with_env (fun ~net:_ ~clock:_ ~sw ->
      let mem = Spn.net (Spn.create ()) in
      match Net.connect ~sw mem ~host:"absent.example" ~port:80 with
      | exception _ -> ()
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "expected connect with no listener to fail")

let tests =
  [
    Alcotest.test_case "roundtrip" `Quick roundtrip;
    Alcotest.test_case "connect_refused" `Quick connect_refused;
  ]
