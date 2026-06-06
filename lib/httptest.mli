(* Port of go/src/net/http/httptest. [Response_recorder] is an in-memory
   {!Server.response_writer} that records a handler's status code, headers and
   body for inspection in tests; [Server] is a loopback test HTTP/HTTPS server
   (Go's [httptest.Server]) the gohttp [Client] can round-trip against. *)

module Response_recorder : sig
  type t = {
    mutable code : int;
    header : Header.t;
    body : Buffer.t;
    mutable flushed : bool;
    mutable wrote_header : bool;
    mutable snap_header : Header.t option;
    mutable default_remote_addr : string;
  }
  (** Go's [httptest.ResponseRecorder]. [code] is the status set by
      [write_header] (default 200, like [NewRecorder]); [header] is the header
      map the handler mutates; [body] accumulates [write] bytes; [flushed]
      records whether [flush] was called; [wrote_header] is set once the
      framing/status has been committed (Go's [wroteHeader]). [snap_header] is
      the snapshot of [header] taken at the first commit, used by {!result}. *)

  val default_remote_addr_const : string
  (** Go's [DefaultRemoteAddr] (["1.2.3.4"]). *)

  val create : unit -> t
  (** Go's [NewRecorder]: a fresh recorder with [code = 200] and empty
      header/body. *)

  val to_response_writer : t -> Server.response_writer
  (** Adapt the recorder to a {!Gohttp.Server.response_writer} so a handler can run
      against it unchanged. *)

  val result : t -> Body.t Response.t
  (** Go's [ResponseRecorder.Result]: snapshot the handler's response into a
      {!Response.t} (status code/line, a header snapshot, body as
      {!Body.String}). A default code of 200 is applied; Content-Type is sniffed
      from the body when unset (and no Transfer-Encoding) at first write;
      Content-Length is taken from the header. proto is ["HTTP/1.1"]. *)

  val code : t -> int
  (** The recorded status code (Go's [Code] field; 0 if never committed via a
      constructor other than {!create}). *)

  val body_string : t -> string
  (** The accumulated body bytes (Go's [Body.String()]). *)

  val header : t -> Header.t
  (** The live header map the handler mutates (Go's [HeaderMap]). *)
end

(** Go's [httptest.Server]: a loopback test server bound to an ephemeral
    [127.0.0.1] port. Only the started, loopback-network path is supported (the
    in-memory "fakenet" network and the [NewUnstartedServer]+[Start] split are
    omitted, since {!Gohttp.Server.listen_and_serve_started} binds and serves in one
    step). *)
module Server : sig
  type t = {
    url : string;
    port : int;
    tls : bool;
    srv : Server.t;
    serve : unit Lwt.t;
    close : unit -> unit Lwt.t;
  }
  (** A running test server.
      - [url] is Go's [Server.URL] (["http://127.0.0.1:PORT"], or
        ["https://..."] for a TLS server), with no trailing slash.
      - [port] is the bound ephemeral port.
      - [tls] is whether this is a TLS server.
      - [srv] is the underlying running {!Gohttp.Server.t} (Go's [Config]).
      - [serve] is the background serve-loop promise (Go's [goServe]).
      - [close] stops the server / closes the listener (Go's [Server.Close]). *)

  val url : t -> string
  (** [url s] is [s.url]. *)

  val port : t -> int
  (** [port s] is [s.port]. *)

  val new_server : Server.handler -> t Lwt.t
  (** Go's [NewServer]: bind [127.0.0.1:0], build [url], and serve [handler] in
      the background (does not block). The caller must {!val-close} it when done. *)

  val new_tls_server : Server.handler -> t Lwt.t
  (** Go's [NewTLSServer]: like {!new_server} but over TLS using the self-signed
      {!Net.test_server_certificate} (Go's [testcert.LocalhostCert]); [url] is
      ["https://..."]. The matching {!client} trusts the cert via [~insecure].
  *)

  val client : t -> Client.t
  (** Go's [Server.Client]: a {!Client.t} configured to talk to this server. For
      a TLS server it is built with [~insecure:true] (the faithful analogue of
      Go pre-loading the server's self-signed certificate into the client's
      [RootCAs]); for an HTTP server it is a plain default-shaped client. *)

  val close : t -> unit Lwt.t
  (** Go's [Server.Close]: stop accepting and close the listening socket. *)
end
