(* End-to-end streaming demo for gohttp.

   Three round trips, all bounded by [Net.with_timeout] so the process always
   terminates:

   1. {!demo_stream} — the headline: a server handler writes several chunks,
      calling [w.flush] between them (so the response is framed chunked and the
      bytes leave the server as the handler runs, not at completion). The gohttp
      [Client] GETs it and consumes the response [Body.Stream] *incrementally*,
      printing each chunk as it arrives — demonstrating the body is not
      pre-buffered. The connection is released back to the transport pool only
      after the body reaches EOF (Go's [resp.Body.Close]).
   2. {!demo_http} — a plain HTTP/1.1 GET, body read whole with [Body.read_all].
   3. {!demo_h2} — a TLS+ALPN GET negotiating HTTP/2. *)

open Gohttp
open Lwt.Infix

let handler =
  Server.handler_func (fun w r ->
      w.Server.write
        (Printf.sprintf "Hello from gohttp! You requested %s\n"
           (Uri.path r.Request.url)))

(* Streaming handler: emit a sequence of chunks, flushing between each so the
   client can observe them before the handler returns. *)
let streaming_handler =
  Server.handler_func (fun w _r ->
      let chunks = [ "chunk-1\n"; "chunk-2\n"; "chunk-3\n"; "chunk-4\n" ] in
      Lwt_list.iter_s
        (fun c ->
          w.Server.write c >>= fun () ->
          (* flush pushes this chunk out now (and on the first call forces the
             framing decision -> Transfer-Encoding: chunked). *)
          w.Server.flush ())
        chunks)

(* Headline demo: stream the response body chunk-by-chunk on the client side. *)
let demo_stream () =
  Server.listen_and_serve_started ~addr:"127.0.0.1" ~port:0 streaming_handler
  >>= fun (srv, port, serve_loop) ->
  Lwt.async (fun () -> serve_loop);
  let url = Printf.sprintf "http://127.0.0.1:%d/stream" port in
  Lwt.finalize
    (fun () ->
      Lwt_io.printf "Streaming GET %s\n" url >>= fun () ->
      Client.get Client.default_client url >>= fun resp ->
      Lwt_io.printf "-> %d %s (consuming body incrementally)\n"
        resp.Response.status_code
        (Status.status_text resp.Response.status_code)
      >>= fun () ->
      (* Pull the streaming body one chunk at a time, printing as each
         arrives. We never call [Body.read_all], so nothing is pre-buffered. *)
      match resp.Response.body with
      | Body.Stream next ->
          let rec loop n =
            next () >>= function
            | None -> Lwt_io.printf "  [EOF after %d chunk(s)]\n" n
            | Some chunk ->
                Lwt_io.printf "  [chunk %d arrived] %s" (n + 1) chunk
                >>= fun () -> loop (n + 1)
          in
          loop 0
      | Body.String s -> Lwt_io.printf "  [string body] %s" s
      | Body.Empty -> Lwt_io.printf "  [empty body]\n")
    (fun () -> Server.close srv)

(* Plaintext HTTP/1.1 round trip, body read whole. *)
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
        (Status.status_text resp.Response.status_code)
        body)
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
        (Transport.h2_round_trip_count transport)
        resp.Response.status_code
        (Status.status_text resp.Response.status_code)
        body)
    (fun () -> Server.close srv)

let main () =
  let append_line_before i demo =
    if i <> 0 then Lwt_io.printf "\n" >>= demo else demo ()
  in
  Lwt_list.iteri_s append_line_before [ demo_stream; demo_http; demo_h2 ]

let () = Lwt_main.run (Net.with_timeout 30. (main ()))
