(* Port of go/src/net/http/httptest/server.go (Server). Two transports are
   supported:
   - loopback: [new_server]/[new_tls_server] bind an ephemeral 127.0.0.1 port
     (for tests that assert real wire/port behavior);
   - in-memory: [new_test_server]/[new_test_tls_server] (Go's [NewTestServer])
     serve over the socketpair "fakenet" ({!Httpg_internal.Socketpair_net}) --
     no loopback, DNS, or ports, while still running the full HTTP/TLS/h2 stack.
   [Close] tears the server down; [Client] returns a [Client.t] capturing the
   same network, so it dials the server whichever transport it uses.

   Only Go's [NewUnstartedServer]+[Start] split remains out of scope: httpg's
   [Server.listen_and_serve_started] binds and begins serving in one step, so a
   started [Server] is the only useful shape here ([new_unstarted] omitted). *)
module Server = struct
  type t = {
    url : string;  (** Go's [Server.URL] ("http://127.0.0.1:PORT"). *)
    port : int;  (** the bound ephemeral port. *)
    tls : bool;  (** whether this is a TLS ([StartTLS]) server. *)
    srv : Server.t;  (** the running httpg [Server] (Go's [Config]). *)
    close : unit -> unit;  (** Go's [Server.Close]. *)
    (* Capabilities captured so {!client} can build a matching [Client.t]. *)
    net : [ `Generic ] Eio.Net.ty Eio.Resource.t;
    clock : float Eio.Time.clock_ty Eio.Resource.t option;
  }

  module Socketpair_net = Httpg_internal.Socketpair_net

  let url s = s.url
  let port s = s.port
  let coerce_net net = (net :> [ `Generic ] Eio.Net.ty Eio.Resource.t)

  let coerce_clock clock =
    Option.map (fun c -> (c :> float Eio.Time.clock_ty Eio.Resource.t)) clock

  (* Assemble the [t] record shared by every constructor, once the listener is
     bound and the serve fiber forked. *)
  let assemble ~tls ~url ~port ~srv ~net ~clock : t =
    {
      url;
      port;
      tls;
      srv;
      close = (fun () -> Server.close srv);
      net = coerce_net net;
      clock = coerce_clock clock;
    }

  (* NewServer: bind 127.0.0.1:0, build the URL, serve in a fiber under [sw]. *)
  let new_server ~net ?clock ~sw (handler : Server.handler) : t =
    match
      Server.listen_and_serve_started ~net ?clock ~sw ~addr:"127.0.0.1" ~port:0
        handler
    with
    (* The [Error] branch is unreachable here: an ephemeral [127.0.0.1:0] bind
       cannot fail to resolve or bind. Mirroring Go's [httptest.NewServer],
       which panics on a setup failure, keeps this constructor's no-error
       [-> t] signature honest. *)
    | Error e -> invalid_arg ("httptest: new_server: " ^ Net.error_to_string e)
    | Ok (srv, port, serve_loop) ->
        Eio.Fiber.fork ~sw serve_loop;
        let url = Printf.sprintf "http://127.0.0.1:%d" port in
        assemble ~tls:false ~url ~port ~srv ~net ~clock

  (* NewTLSServer: like [new_server] but over TLS with the self-signed
     [Net.test_server_certificate]; URL is "https://...". The matching [client]
     trusts the cert via [~insecure]. *)
  let new_tls_server ~net ?clock ~sw (handler : Server.handler) : t =
    let certificates = Net.test_server_certificate () in
    (* Advertise h2 + http/1.1 (Go's httptest StartTLS with HTTP/2 enabled) so
       ALPN can negotiate either. *)
    match
      Server.listen_and_serve_tls_started ~net ?clock ~certificates
        ~alpn:[ "h2"; "http/1.1" ] ~sw ~addr:"127.0.0.1" ~port:0 handler
    with
    (* The [Error] branch is unreachable here: a fixed-valid
       [test_server_certificate] cert + an ephemeral [127.0.0.1:0] bind cannot
       produce an invalid TLS config. Mirroring Go's [httptest.NewServer], which
       panics on a setup failure, keeps this constructor's no-error [-> t]
       signature honest. *)
    | Error e ->
        invalid_arg ("httptest: new_tls_server: " ^ Net.error_to_string e)
    | Ok (srv, port, serve_loop) ->
        Eio.Fiber.fork ~sw serve_loop;
        let url = Printf.sprintf "https://127.0.0.1:%d" port in
        assemble ~tls:true ~url ~port ~srv ~net ~clock

  (* NewTestServer: serve over an in-memory socketpair network instead of a
     loopback socket (Go's httptest fakenet). The network is created here and
     shared with [client] (it is captured in the record), so the client dials
     the same in-memory network. URL is "http://example.com" and [port] is 0:
     there is no real port. The full HTTP stack still runs over the in-memory
     connection. *)
  let new_test_server ~sw ?clock (handler : Server.handler) : t =
    let net = Socketpair_net.net (Socketpair_net.create ()) in
    match
      Server.listen_and_serve_started ~net ?clock ~sw ~addr:"example.com"
        ~port:80 handler
    with
    (* Unreachable: the in-memory [listen] cannot fail to resolve or bind. *)
    | Error e ->
        invalid_arg ("httptest: new_test_server: " ^ Net.error_to_string e)
    | Ok (srv, _port, serve_loop) ->
        Eio.Fiber.fork ~sw serve_loop;
        assemble ~tls:false ~url:"http://example.com" ~port:0 ~srv ~net ~clock

  (* NewTestServer + StartTLS: the in-memory variant over TLS, ALPN h2+http/1.1.
     URL is "https://example.com"; [client] trusts the self-signed cert via
     [~insecure]. *)
  let new_test_tls_server ~sw ?clock (handler : Server.handler) : t =
    let net = Socketpair_net.net (Socketpair_net.create ()) in
    let certificates = Net.test_server_certificate () in
    match
      Server.listen_and_serve_tls_started ~net ?clock ~certificates
        ~alpn:[ "h2"; "http/1.1" ] ~sw ~addr:"example.com" ~port:443 handler
    with
    (* Unreachable: fixed-valid cert + in-memory bind cannot fail. *)
    | Error e ->
        invalid_arg ("httptest: new_test_tls_server: " ^ Net.error_to_string e)
    | Ok (srv, _port, serve_loop) ->
        Eio.Fiber.fork ~sw serve_loop;
        assemble ~tls:true ~url:"https://example.com" ~port:0 ~srv ~net ~clock

  (* Server.Client: a client (capturing the same net/clock) configured to talk
     to this server. Go pre-loads the server's self-signed cert into the client's
     RootCAs; the faithful httpg analogue for a TLS server is a client that
     trusts it via [~insecure:true]. An HTTP server gets a plain client. *)
  let client (s : t) : Client.t =
    let net = s.net and clock = s.clock in
    if s.tls then Client.create ~net ?clock ~insecure:true ()
    else Client.create ~net ?clock ()

  let close (s : t) : unit = s.close ()
end
