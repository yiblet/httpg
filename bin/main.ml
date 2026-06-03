(* End-to-end demo: start a gohttp Server on an ephemeral loopback port, then
   issue a gohttp Client GET against it and print status + body. *)

open Gohttp
open Lwt.Infix

let handler =
  Server.handler_func (fun w r ->
      w.Server.write (Printf.sprintf "Hello from gohttp! You requested %s\n"
        (Uri.path r.Request.url)))

let main () =
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

let () = Lwt_main.run (Net.with_timeout 10. (main ()))
