(* Port of go/src/net/http/httptest/server.go (Server), restricted to the
   loopback-network path we support: [NewServer]/[NewTLSServer] bind an
   ephemeral 127.0.0.1 port, [Close] tears the listener down, and [Client]
   returns a [Client.t] suitable for hitting the server.

   Go's in-memory ("fakenet") network and the [NewUnstartedServer]+[Start]
   split are out of scope: httpg's [Server.listen_and_serve_started] binds and
   begins serving in one step, so a started [Server] is the only useful shape
   here (noted in the plan; [new_unstarted] omitted). *)
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

  let url s = s.url
  let port s = s.port
  let coerce_net net = (net :> [ `Generic ] Eio.Net.ty Eio.Resource.t)

  let coerce_clock clock =
    Option.map (fun c -> (c :> float Eio.Time.clock_ty Eio.Resource.t)) clock

  (* NewServer: bind 127.0.0.1:0, build the URL, serve in a fiber under [sw]. *)
  let new_server ~net ?clock ~sw (handler : Server.handler) : t =
    let srv, port, serve_loop =
      Server.listen_and_serve_started ~net ?clock ~sw ~addr:"127.0.0.1" ~port:0
        handler
    in
    Eio.Fiber.fork ~sw serve_loop;
    let url = Printf.sprintf "http://127.0.0.1:%d" port in
    {
      url;
      port;
      tls = false;
      srv;
      close = (fun () -> Server.close srv);
      net = coerce_net net;
      clock = coerce_clock clock;
    }

  (* NewTLSServer: like [new_server] but over TLS with the self-signed
     [Net.test_server_certificate]; URL is "https://...". The matching [client]
     trusts the cert via [~insecure]. *)
  let new_tls_server ~net ?clock ~sw (handler : Server.handler) : t =
    let certificates = Net.test_server_certificate () in
    (* Advertise h2 + http/1.1 (Go's httptest StartTLS with HTTP/2 enabled) so
       ALPN can negotiate either. *)
    let srv, port, serve_loop =
      Server.listen_and_serve_tls_started ~net ?clock ~certificates
        ~alpn:[ "h2"; "http/1.1" ] ~sw ~addr:"127.0.0.1" ~port:0 handler
    in
    Eio.Fiber.fork ~sw serve_loop;
    let url = Printf.sprintf "https://127.0.0.1:%d" port in
    {
      url;
      port;
      tls = true;
      srv;
      close = (fun () -> Server.close srv);
      net = coerce_net net;
      clock = coerce_clock clock;
    }

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
