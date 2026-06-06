(* Integration tests for server-side TLS + ALPN in Net (H2 Ticket 7).

   There is no direct Go source file (Go uses crypto/tls); fidelity here means
   matching Go's behavior: the server advertises a list of ALPN protocols and
   selects one, exposing the negotiated protocol; the client advertises its own
   list and reads the negotiated protocol off the completed handshake.

   Each case mints a fresh self-signed cert via [Net.test_server_certificate],
   binds an ephemeral loopback TLS listener, and runs a client + server fiber
   concurrently. All cases are bounded by [Net.with_timeout] so a stuck
   handshake fails the test instead of hanging the suite. *)

open Httpg

(* Run [server]/[client] fibers against a fresh loopback TLS server advertising
   [server_alpn], with the client advertising [client_alpn]. Returns whatever
   the [client] fiber produces. *)
let with_tls_pair ~server_alpn ~client_alpn ~server ~client () =
  let open Lwt.Syntax in
  let run () =
    let certificates = Net.test_server_certificate () in
    let* srv = Net.listen_tls ~certificates ~alpn:server_alpn "127.0.0.1" 0 in
    let port = Net.bound_port (Net.tls_listen_fd srv) in
    let server_fiber =
      let* ic, oc, proto, _peer = Net.accept_tls srv in
      server ~ic ~oc ~proto
    in
    let client_fiber =
      let* ic, oc, proto =
        (* Self-signed loopback cert reached via an IP literal: verification
           would legitimately fail (untrusted chain + no hostname match), so the
           client opts out, the analogue of Go's tls.Config.InsecureSkipVerify.
           The production default ([Net.connect_alpn] with no [?insecure])
           verifies against the system trust store. *)
        Net.connect_alpn ~host:"127.0.0.1" ~port ~tls:true ~alpn:client_alpn
          ~insecure:true ()
      in
      client ~ic ~oc ~proto
    in
    let* cres, sres = Lwt.both client_fiber server_fiber in
    let* () = Lwt_unix.close (Net.tls_listen_fd srv) in
    Lwt.return (cres, sres)
  in
  Lwt_main.run (Net.with_timeout 15. (run ()))

(* (a) Both peers advertise ["h2"; "http/1.1"] => negotiated "h2". *)
let alpn_negotiates_h2 () =
  let server ~ic:_ ~oc:_ ~proto = Lwt.return proto in
  let client ~ic:_ ~oc:_ ~proto = Lwt.return proto in
  let cproto, sproto =
    with_tls_pair ~server_alpn:[ "h2"; "http/1.1" ]
      ~client_alpn:[ "h2"; "http/1.1" ] ~server ~client ()
  in
  Alcotest.(check (option string)) "client negotiated h2" (Some "h2") cproto;
  Alcotest.(check (option string)) "server negotiated h2" (Some "h2") sproto

(* (b) Server advertises ["h2"; "http/1.1"], client advertises only
   ["http/1.1"] => negotiated "http/1.1". *)
let alpn_negotiates_http11 () =
  let server ~ic:_ ~oc:_ ~proto = Lwt.return proto in
  let client ~ic:_ ~oc:_ ~proto = Lwt.return proto in
  let cproto, sproto =
    with_tls_pair ~server_alpn:[ "h2"; "http/1.1" ] ~client_alpn:[ "http/1.1" ]
      ~server ~client ()
  in
  Alcotest.(check (option string))
    "client negotiated http/1.1" (Some "http/1.1") cproto;
  Alcotest.(check (option string))
    "server negotiated http/1.1" (Some "http/1.1") sproto

(* (c) A byte round-trip over the TLS channels: the client writes a line, the
   server reads it and echoes it back, the client reads the echo. Proves the
   buffered [Lwt_io] channels over the TLS session actually carry data. *)
let tls_byte_roundtrip () =
  let open Lwt.Syntax in
  let server ~ic ~oc ~proto:_ =
    let* line = Lwt_io.read_line ic in
    let* () = Lwt_io.write_line oc line in
    let* () = Lwt_io.flush oc in
    Lwt.return ()
  in
  let client ~ic ~oc ~proto:_ =
    let* () = Lwt_io.write_line oc "PING-over-TLS" in
    let* () = Lwt_io.flush oc in
    let* echoed = Lwt_io.read_line ic in
    Lwt.return echoed
  in
  let echoed, () =
    with_tls_pair ~server_alpn:[ "h2"; "http/1.1" ]
      ~client_alpn:[ "h2"; "http/1.1" ] ~server ~client ()
  in
  Alcotest.(check string) "echoed line over TLS" "PING-over-TLS" echoed

let tests =
  [
    Alcotest.test_case "alpn_negotiates_h2" `Quick alpn_negotiates_h2;
    Alcotest.test_case "alpn_negotiates_http11" `Quick alpn_negotiates_http11;
    Alcotest.test_case "tls_byte_roundtrip" `Quick tls_byte_roundtrip;
  ]
