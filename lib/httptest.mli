(* Port of go/src/net/http/httptest. [Server] is a loopback test HTTP/HTTPS
   server (Go's [httptest.Server]) the httpg [Client] can round-trip against.
   (Go's [ResponseRecorder] is omitted: with [Request -> Response] handlers a
   handler is tested by calling it directly and inspecting the returned
   {!Response.t}.) *)

(** Go's [httptest.Server]: a loopback test server bound to an ephemeral
    [127.0.0.1] port. Only the started, loopback-network path is supported (the
    in-memory "fakenet" network and the [NewUnstartedServer]+[Start] split are
    omitted). The server runs its accept loop in a fiber forked under the
    caller-supplied [Eio.Switch]; {!Server.val-close} stops it. *)
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

  val client : t -> Client.t
  (** Go's [Server.Client]: a {!Client.t} configured to talk to this server. For
      a TLS server it is built with [~insecure:true] (the faithful analogue of
      Go pre-loading the server's self-signed certificate into the client's
      [RootCAs]); for an HTTP server it is a plain default-shaped client. *)

  val close : t -> unit
  (** Go's [Server.Close]: stop accepting and close the listening socket. *)
end
