(* Integration tests for server-side TLS + ALPN in Net.

   There is no direct Go source file (Go uses crypto/tls); fidelity here means
   matching Go's behavior: the server advertises a list of ALPN protocols and
   selects one, exposing the negotiated protocol; the client advertises its own
   list and reads the negotiated protocol off the completed handshake.

   Each case mints a fresh self-signed cert via [Net.test_server_certificate],
   binds an ephemeral loopback TLS listener, and runs a client + server fiber
   concurrently. All cases are bounded by a timeout so a stuck handshake fails
   the test instead of hanging the suite. *)

open Httpg

(* Run [server]/[client] fibers against a fresh loopback TLS server advertising
   [server_alpn], with the client advertising [client_alpn]. Returns whatever
   the [client]/[server] callbacks produce (via refs). *)
let with_tls_pair ~server_alpn ~client_alpn ~server ~client () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 15. @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let certificates = Net.test_server_certificate () in
  let srv =
    Net.listen_tls ~sw ~certificates ~alpn:server_alpn net "127.0.0.1" 0
  in
  let port = Net.bound_port (Net.tls_listen_sock srv) in
  let cres = ref None and sres = ref None in
  let server_fiber () =
    let flow, _peer = Net.accept ~sw (Net.tls_listen_sock srv) in
    Net.accept_tls srv flow (fun ~proto r w -> sres := Some (server ~proto r w))
  in
  let client_fiber () =
    (* Self-signed loopback cert reached via an IP literal: verification would
       legitimately fail (untrusted chain + no hostname match), so the client
       opts out, the analogue of Go's tls.Config.InsecureSkipVerify. *)
    match
      Net.connect_alpn ~sw net ~host:"127.0.0.1" ~port ~tls:true
        ~alpn:client_alpn ~insecure:true (fun ~proto r w ->
          cres := Some (client ~proto r w))
    with
    | Ok () -> ()
    | Error e -> Alcotest.failf "net: %s" (Net.error_to_string e)
  in
  Eio.Fiber.both client_fiber server_fiber;
  (Option.get !cres, Option.get !sres)

(* (a) Both peers advertise ["h2"; "http/1.1"] => negotiated "h2". *)
let alpn_negotiates_h2 () =
  let server ~proto _r _w = proto in
  let client ~proto _r _w = proto in
  let cproto, sproto =
    with_tls_pair ~server_alpn:[ "h2"; "http/1.1" ]
      ~client_alpn:[ "h2"; "http/1.1" ] ~server ~client ()
  in
  Alcotest.(check (option string)) "client negotiated h2" (Some "h2") cproto;
  Alcotest.(check (option string)) "server negotiated h2" (Some "h2") sproto

(* (b) Server advertises ["h2"; "http/1.1"], client advertises only
   ["http/1.1"] => negotiated "http/1.1". *)
let alpn_negotiates_http11 () =
  let server ~proto _r _w = proto in
  let client ~proto _r _w = proto in
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
   buffered channels over the TLS session actually carry data. *)
let tls_byte_roundtrip () =
  let server ~proto:_ r w =
    let line = Eio.Buf_read.line r in
    Eio.Buf_write.string w (line ^ "\n");
    Eio.Buf_write.flush w
  in
  let client ~proto:_ r w =
    Eio.Buf_write.string w "PING-over-TLS\n";
    Eio.Buf_write.flush w;
    Eio.Buf_read.line r
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
