(* Port of go/src/net/http/httptest. [Server] is a test HTTP/HTTPS server (Go's
   [httptest.Server]) the httpg [Client] can round-trip against, over either a
   loopback socket ({!Server.new_server}) or an in-memory socketpair network
   ({!Server.new_test_server}, Go's [NewTestServer]).
   (Go's [ResponseRecorder] is omitted: with [Request -> Response] handlers a
   handler is tested by calling it directly and inspecting the returned
   {!Response.t}.) *)

(** Go's [httptest.Server]: a test server reachable via the httpg [Client].
    [new_server]/[new_tls_server] bind an ephemeral [127.0.0.1] port;
    [new_test_server]/[new_test_tls_server] serve over an in-memory "fakenet"
    network (no loopback/DNS/ports). Only the started path is supported (the
    [NewUnstartedServer]+[Start] split is omitted). The server runs its accept
    loop in a fiber forked under the caller-supplied [Eio.Switch];
    {!Server.val-close} stops it. *)
module Server : sig
  type t = {
    url : string;
    port : int;
    tls : bool;
    srv : Server.t;
    close : unit -> unit;
    net : [ `Generic ] Eio.Net.ty Eio.Resource.t;
    clock : float Eio.Time.clock_ty Eio.Resource.t option;
  }
  (** A running test server.
      - [url] is Go's [Server.URL] (["http://127.0.0.1:PORT"], or
        ["https://..."] for a TLS server), with no trailing slash.
      - [port] is the bound ephemeral port.
      - [tls] is whether this is a TLS server.
      - [srv] is the underlying running {!Httpg.Server.t} (Go's [Config]).
      - [close] stops the server / closes the listener (Go's [Server.Close]).
      - [net]/[clock] are the captured capabilities, reused by {!client}. *)

  val url : t -> string
  (** [url s] is [s.url]. *)

  val port : t -> int
  (** [port s] is [s.port]. *)

  val new_server :
    net:_ Eio.Net.t ->
    ?clock:_ Eio.Time.clock ->
    sw:Eio.Switch.t ->
    Server.handler ->
    t
  (** Go's [NewServer]: bind [127.0.0.1:0], build [url] and serve [handler] in a
      fiber forked under [sw] (Go's [goServe]); does not block. The listener and
      serve fiber live under [sw]; {!val-close} (or [sw] finishing) stops them.
  *)

  val new_tls_server :
    net:_ Eio.Net.t ->
    ?clock:_ Eio.Time.clock ->
    sw:Eio.Switch.t ->
    Server.handler ->
    t
  (** Go's [NewTLSServer]: like {!new_server} but over TLS using the self-signed
      {!Net.test_server_certificate} (Go's [testcert.LocalhostCert]); [url] is
      ["https://..."]. The matching {!client} trusts the cert via [~insecure].
  *)

  val new_test_server :
    sw:Eio.Switch.t -> ?clock:_ Eio.Time.clock -> Server.handler -> t
  (** Go's [NewTestServer]: serve [handler] over an in-memory network
      ({!Httpg_internal.Socketpair_net}) instead of a loopback socket. No port,
      DNS, or loopback is used; [url] is ["http://example.com"] and {!val-port}
      is [0] (there is no real port). The matching {!client} dials the same
      in-memory network. The serve fiber lives under [sw]; {!val-close} (or [sw]
      finishing) stops it.

      Unlike {!new_server} no [~net] is taken: the in-memory network is created
      internally and shared between the server and its {!client}. The full HTTP
      stack (request/response serialization, server parse loop, keep-alive)
      still runs -- only the transport is in-memory. *)

  val new_test_tls_server :
    sw:Eio.Switch.t -> ?clock:_ Eio.Time.clock -> Server.handler -> t
  (** Like {!new_test_server} but over TLS using the self-signed
      {!Net.test_server_certificate} and advertising ALPN [["h2"; "http/1.1"]];
      [url] is ["https://example.com"]. The matching {!client} trusts the cert
      via [~insecure]. *)

  val client : t -> Client.t
  (** Go's [Server.Client]: a {!Client.t} configured to talk to this server. For
      a TLS server it is built with [~insecure:true] (the faithful analogue of
      Go pre-loading the server's self-signed certificate into the client's
      [RootCAs]); for an HTTP server it is a plain default-shaped client. The
      client captures the same network as the server, so an in-memory server
      ({!new_test_server}) is dialed over its in-memory network. *)

  val close : t -> unit
  (** Go's [Server.Close]: stop accepting and close the listening socket. *)
end
