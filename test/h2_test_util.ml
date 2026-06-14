(* Shared loopback harness for the raw-socket HTTP/2 integration suites
   (test_h2_server, test_h2_transport, test_stream_h2, test_abuse_h2).

   An H2_server.serve runs in its own fiber over a real loopback TCP socket pair;
   the test's client body runs against it. When the client body returns the
   server fiber is cancelled — bounding the server's lifetime to the client's so
   the harness never blocks waiting for the server to observe a natural EOF.
   All bounded by an outer timeout so a genuine hang fails. *)

open Httpg
module S = Httpg_http2.H2_server
module H2_transport = Httpg_http2.H2_transport

(* Run [client r w] against [S.serve ?max_concurrent_streams ?max_header_bytes
   handler] over a loopback socket pair, returning the client body's result. The
   server fiber is cancelled once [client] returns. *)
let with_h2_raw ?max_concurrent_streams ?max_header_bytes ?(timeout = 15.)
    ~handler client =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock timeout @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let lsock = Net.listen ~sw net "127.0.0.1" 0 in
  let port = Net.bound_port lsock in
  (* Run the client body and the server concurrently; once the client returns,
     [Fiber.first] cancels the still-blocked server fiber. *)
  Eio.Fiber.first
    (fun () ->
      let flow =
        match Net.connect ~sw net ~host:"127.0.0.1" ~port with
        | Ok x -> x
        | Error e -> failwith ("net: " ^ Net.error_to_string e)
      in
      Net.with_connection flow (fun r w -> client r w))
    (fun () ->
      (* Accept and serve inline (not via accept_fork) so the serve runs in this
         very fiber — the one [Fiber.first] cancels when the client wins. *)
      (try
         let flow, _peer = Net.accept ~sw lsock in
         Net.with_connection flow (fun r w ->
             S.serve ?max_concurrent_streams ?max_header_bytes r w ~handler)
       with _ -> ());
      (* Serve only returns on a clean EOF / fatal error before the client is
         done; park so [Fiber.first] decides the result via the client side. *)
      Eio.Fiber.await_cancel ())

(* As [with_h2_raw] but the client body is given an established
   {!H2_transport.client_conn} (under its own switch) rather than raw channels. *)
let with_h2_server ?max_concurrent_streams ?(timeout = 15.) ~handler client =
  with_h2_raw ?max_concurrent_streams ~timeout ~handler (fun r w ->
      Eio.Switch.run @@ fun cc_sw ->
      let cc = H2_transport.new_client_conn ~sw:cc_sw r w in
      let result = client cc in
      (try H2_transport.close cc with _ -> ());
      result)
