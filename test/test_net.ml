(* Integration smoke test for the Net socket substrate (Ticket 7).

   [loopback_roundtrip] binds an ephemeral loopback listener, accepts one
   connection that echoes a line, connects a client to the bound port, writes
   ["PING\r\n"], reads the echoed line, and asserts equality. The whole thing
   is bounded by [Net.with_timeout 5.] so a hang fails the test instead of
   blocking the suite.

   The TLS path of [Net.connect ~tls:true] is smoke-only (no local TLS server
   here), so it is intentionally not exercised. *)

open Httpg

let loopback_roundtrip () =
  let open Lwt.Syntax in
  let run () =
    let* listener = Net.listen "127.0.0.1" 0 in
    let port = Net.bound_port listener in
    (* Server fiber: accept one connection, read a line, echo it back. *)
    let server =
      let* conn, _peer = Net.accept listener in
      let ic, oc = Net.channels_of_fd conn in
      let* line = Lwt_io.read_line ic in
      let* () = Lwt_io.write_line oc line in
      let* () = Lwt_io.flush oc in
      Lwt_io.close oc
    in
    (* Client fiber: connect, send a line, read the echo. *)
    let client =
      let* cic, coc = Net.connect ~host:"127.0.0.1" ~port () in
      let* () = Lwt_io.write_line coc "PING" in
      let* () = Lwt_io.flush coc in
      let* echoed = Lwt_io.read_line cic in
      let* () = Lwt_io.close coc in
      Lwt.return echoed
    in
    let* echoed, () = Lwt.both client server in
    let* () = Lwt_unix.close listener in
    Lwt.return echoed
  in
  let echoed = Lwt_main.run (Net.with_timeout 5. (run ())) in
  Alcotest.(check string) "echoed line" "PING" echoed

let tests =
  [ Alcotest.test_case "loopback_roundtrip" `Quick loopback_roundtrip ]
