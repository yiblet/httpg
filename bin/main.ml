(* End-to-end demo: start a gohttp Server on an ephemeral loopback port, then
   issue a gohttp Client GET against it and print status + body. Runs once over
   plaintext HTTP/1.1 and once over TLS+ALPN negotiating HTTP/2. *)

open Gohttp
open Lwt.Infix

let handler =
  Server.handler_func (fun w r ->
      w.Server.write (Printf.sprintf "Hello from gohttp! You requested %s\n"
        (Uri.path r.Request.url)))

(* Plaintext HTTP/1.1 round trip. *)
let demo_http () =
  Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 handler
  >>= fun (srv, port, serve_loop) ->
  Lwt.async (fun () -> serve_loop);
  let url = Printf.sprintf "http://127.0.0.1:%d/demo" port in
  Lwt.finalize
    (fun () ->
      Client.get Client.default_client url >>= fun resp ->
      Body.read_all resp.Response.body >>= fun body ->
      Lwt_io.printf "GET %s\n-> %d %s\n%s" url resp.Response.status_code
        (Status.status_text resp.Response.status_code) body)
    (fun () -> Server.close srv)

(* TLS + ALPN round trip: the server advertises ["h2"; "http/1.1"] and the
   client (https) negotiates h2 and multiplexes a GET over it. *)
let demo_h2 () =
  let certificates = Net.test_server_certificate () in
  Server.listen_and_serve_tls_started ~certificates ~addr:"127.0.0.1" ~port:0
    handler
  >>= fun (srv, port, serve_loop) ->
  Lwt.async (fun () -> serve_loop);
  let transport = Transport.create ~insecure:true () in
  let client = Client.create ~transport () in
  let url = Printf.sprintf "https://127.0.0.1:%d/h2-demo" port in
  Lwt.finalize
    (fun () ->
      Client.get client url >>= fun resp ->
      Body.read_all resp.Response.body >>= fun body ->
      Lwt_io.printf "GET %s (h2 round trips: %d)\n-> %d %s\n%s" url
        (Transport.h2_round_trip_count transport) resp.Response.status_code
        (Status.status_text resp.Response.status_code) body)
    (fun () -> Server.close srv)

let main () =
  demo_http () >>= fun () -> Lwt_io.printf "\n" >>= fun () -> demo_h2 ()

let () = Lwt_main.run (Net.with_timeout 30. (main ()))
