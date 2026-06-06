(* End-to-end demo for httpg, in Eio's direct style.

   Three round trips, all bounded by [Eio.Time.with_timeout] so the process
   always terminates:

   1. {!demo_stream} — the headline: a server handler writes several chunks,
      calling [w.flush] between them (so the response is framed chunked and the
      bytes leave the server as the handler runs, not at completion). The httpg
      [Client] GETs it and consumes the response [Body.Stream] *incrementally*,
      printing each chunk as it arrives — demonstrating the body is not
      pre-buffered. The connection returns to the transport pool only after the
      body reaches EOF (Go's [resp.Body.Close]).
   2. {!demo_http} — a plain HTTP/1.1 GET, body read whole with [Body.read_all].
   3. {!demo_h2} — a TLS+ALPN GET negotiating HTTP/2. *)

open Httpg

let handler =
  Server.handler_func (fun w r ->
      w.Server.write
        (Printf.sprintf "Hello from httpg! You requested %s\n"
           (Uri.path r.Request.url)))

(* Streaming handler: emit a sequence of chunks, flushing between each so the
   client can observe them before the handler returns. *)
let streaming_handler =
  Server.handler_func (fun w _r ->
      List.iter
        (fun c ->
          w.Server.write c;
          (* flush pushes this chunk out now (and on the first call forces the
             framing decision -> Transfer-Encoding: chunked). *)
          w.Server.flush ())
        [ "chunk-1\n"; "chunk-2\n"; "chunk-3\n"; "chunk-4\n" ])

(* Bind an ephemeral server, fork its accept loop under [sw], run [body url],
   then close. *)
let with_server ~net ~clock ~sw ~tls path handler body =
  let srv, port, serve_loop =
    if tls then
      Server.listen_and_serve_tls_started ~net ~clock
        ~certificates:(Net.test_server_certificate ())
        ~sw ~addr:"127.0.0.1" ~port:0 handler
    else
      Server.listen_and_serve_started ~net ~clock ~sw ~addr:"127.0.0.1" ~port:0
        handler
  in
  Eio.Fiber.fork ~sw serve_loop;
  let scheme = if tls then "https" else "http" in
  let url = Printf.sprintf "%s://127.0.0.1:%d%s" scheme port path in
  Fun.protect ~finally:(fun () -> Server.close srv) (fun () -> body url)

(* Headline demo: stream the response body chunk-by-chunk on the client side. *)
let demo_stream ~net ~clock ~sw =
  let client = Client.create ~net ~clock () in
  with_server ~net ~clock ~sw ~tls:false "/stream" streaming_handler
  @@ fun url ->
  Printf.printf "Streaming GET %s\n" url;
  let resp = Client.get ~sw client url in
  Printf.printf "-> %d %s (consuming body incrementally)\n"
    resp.Response.status_code
    (Status.status_text resp.Response.status_code);
  (* Pull the streaming body one chunk at a time; we never call [read_all]. *)
  match resp.Response.body with
  | Body.Stream next ->
      let rec loop n =
        match next () with
        | None -> Printf.printf "  [EOF after %d chunk(s)]\n" n
        | Some chunk ->
            Printf.printf "  [chunk %d arrived] %s" (n + 1) chunk;
            loop (n + 1)
      in
      loop 0
  | Body.String s -> Printf.printf "  [string body] %s" s
  | Body.Empty -> Printf.printf "  [empty body]\n"

(* Plaintext HTTP/1.1 round trip, body read whole. *)
let demo_http ~net ~clock ~sw =
  let client = Client.create ~net ~clock () in
  with_server ~net ~clock ~sw ~tls:false "/demo" handler @@ fun url ->
  let resp = Client.get ~sw client url in
  let body = Body.read_all resp.Response.body in
  Printf.printf "GET %s\n-> %d %s\n%s" url resp.Response.status_code
    (Status.status_text resp.Response.status_code)
    body

(* TLS + ALPN round trip: the server advertises ["h2"; "http/1.1"] and the
   client (https) negotiates h2 and multiplexes a GET over it. *)
let demo_h2 ~net ~clock ~sw =
  let transport = Transport.create ~net ~clock ~insecure:true () in
  let client = Client.create ~net ~clock ~transport () in
  with_server ~net ~clock ~sw ~tls:true "/h2-demo" handler @@ fun url ->
  let resp = Client.get ~sw client url in
  let body = Body.read_all resp.Response.body in
  Printf.printf "GET %s (h2 round trips: %d)\n-> %d %s\n%s" url
    (Transport.h2_round_trip_count transport)
    resp.Response.status_code
    (Status.status_text resp.Response.status_code)
    body

let () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 30. @@ fun () ->
  List.iteri
    (fun i demo ->
      if i <> 0 then print_newline ();
      Eio.Switch.run (fun sw -> demo ~net ~clock ~sw))
    [ demo_stream; demo_http; demo_h2 ]
