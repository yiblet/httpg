(* Lwt socket + TLS substrate. No direct 1:1 Go source counterpart: Go's
   net/http builds on the stdlib [net] package and [crypto/tls]. This provides
   only what the server/client tickets need: TCP listen/accept, client connect
   (optionally TLS), and [Lwt_io] channel wrapping (the bufio analogue). *)

let default_backlog = 128

(* Resolve [host]/[port] to a single [Unix.sockaddr]. We use [getaddrinfo]
   restricted to TCP and pick the first result, mirroring how Go's dialer
   resolves and connects in order. *)
let resolve host port =
  let open Lwt.Syntax in
  let* infos =
    Lwt_unix.getaddrinfo host (string_of_int port)
      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  in
  match infos with
  | { Unix.ai_addr; _ } :: _ -> Lwt.return ai_addr
  | [] -> Lwt.fail_with (Printf.sprintf "Net.resolve: cannot resolve %s:%d" host port)

let listen ?(backlog = default_backlog) host port =
  let open Lwt.Syntax in
  let* addr = resolve host port in
  let domain = Unix.domain_of_sockaddr addr in
  let fd = Lwt_unix.socket domain Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true;
  let* () = Lwt_unix.bind fd addr in
  Lwt_unix.listen fd backlog;
  Lwt.return fd

let accept fd = Lwt_unix.accept fd

let channels_of_fd fd =
  let ic = Lwt_io.of_fd ~mode:Lwt_io.input fd in
  let oc = Lwt_io.of_fd ~mode:Lwt_io.output fd in
  (ic, oc)

(* The mirage-crypto RNG must be seeded before any TLS handshake or X509 key
   generation. [use_default] is idempotent in practice (it just (re)installs
   the default Fortuna generator), so callers may invoke this freely. Go's
   crypto/rand needs no such explicit init; this is the OCaml-stack analogue. *)
let ensure_rng () = Mirage_crypto_rng_unix.use_default ()

(* A null authenticator: accept any peer certificate without verification.
   Acceptable for the smoke-test substrate / explicit insecure opt-out only --
   a production client must supply a real authenticator (e.g. X509 system
   trust). This mirrors Go's [tls.Config.InsecureSkipVerify = true]. *)
let null_authenticator : X509.Authenticator.t =
  fun ?ip:_ ~host:_ _certs -> Ok None

(* Build an authenticator from the operating-system trust store via [ca-certs]
   (which also checks expiry and, when [~host] is supplied at handshake time,
   the certificate's name). This is the SECURE default, the analogue of Go's
   [http.Client] verifying the server certificate against the system roots
   unless [InsecureSkipVerify] is set. Raises [Failure] with a clear message if
   the trust store cannot be loaded. *)
let default_authenticator () : X509.Authenticator.t =
  match Ca_certs.authenticator () with
  | Ok auth -> auth
  | Error (`Msg m) ->
      failwith
        (Printf.sprintf
           "Net: cannot load the system trust store for TLS verification: %s" m)

let host_to_domain_name host =
  match Domain_name.of_string host with
  | Ok dn -> ( match Domain_name.host dn with Ok h -> Some h | Error _ -> None)
  | Error _ -> None

(* Dial a client TCP socket to a resolved [host]/[port]. *)
let dial host port =
  let open Lwt.Syntax in
  let* addr = resolve host port in
  let domain = Unix.domain_of_sockaddr addr in
  let fd = Lwt_unix.socket domain Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.connect fd addr in
  Lwt.return fd

(* Resolve the effective authenticator for a TLS client. Precedence (mirroring
   how Go composes [tls.Config]): an explicit [?authenticator] wins; otherwise
   [~insecure:true] selects {!null_authenticator}; otherwise the SECURE default
   built from the system trust store ({!default_authenticator}). *)
let resolve_authenticator ?authenticator ?(insecure = false) () =
  match authenticator with
  | Some a -> a
  | None -> if insecure then null_authenticator else default_authenticator ()

(* Build a [Tls.Config.client] with the resolved authenticator and optional
   ALPN. By default this verifies the server certificate chain against the
   system trust store (and, with [?host] at handshake time, the hostname). *)
let client_config ?(alpn = []) ?authenticator ?insecure () =
  let alpn_protocols = match alpn with [] -> None | l -> Some l in
  let authenticator = resolve_authenticator ?authenticator ?insecure () in
  match Tls.Config.client ~authenticator ?alpn_protocols () with
  | Ok c -> c
  | Error (`Msg m) ->
      failwith (Printf.sprintf "Net.connect: bad TLS config: %s" m)

(* The negotiated ALPN protocol of a completed TLS session, if any. Mirrors Go's
   [tls.ConnectionState.NegotiatedProtocol] (read off [Tls.Core.epoch_data]). *)
let negotiated_alpn (t : Tls_lwt.Unix.t) =
  match Tls_lwt.Unix.epoch t with
  | Ok ed -> ed.Tls.Core.alpn_protocol
  | Error () -> None

let connect_alpn ~host ~port ?(tls = false) ?(alpn = []) ?authenticator
    ?insecure () =
  let open Lwt.Syntax in
  let* fd = dial host port in
  if not tls then
    let ic, oc = channels_of_fd fd in
    Lwt.return (ic, oc, None)
  else begin
    ensure_rng ();
    let cfg = client_config ~alpn ?authenticator ?insecure () in
    let host_dn = host_to_domain_name host in
    let* t = Tls_lwt.Unix.client_of_fd cfg ?host:host_dn fd in
    let proto = negotiated_alpn t in
    let ic, oc = Tls_lwt.of_t t in
    Lwt.return (ic, oc, proto)
  end

let connect ~host ~port ?(tls = false) ?authenticator ?insecure () =
  let open Lwt.Syntax in
  let* ic, oc, _proto =
    connect_alpn ~host ~port ~tls ?authenticator ?insecure ()
  in
  Lwt.return (ic, oc)

(* ----- Server-side TLS + ALPN ----- *)

(* Mint a fresh self-signed certificate + key at runtime (no files on disk),
   the OCaml-stack analogue of Go's [net/http/internal/testcert]. Generates an
   RSA-2048 key, builds a PKCS#10 signing request for CN=localhost, and
   self-signs it valid for ~ten years, with SubjectAltName DNS=localhost so a
   (non-null) verifying client could match the name. For our tests the client
   uses {!null_authenticator}, so verification is skipped; the
   cert exists only to satisfy the TLS handshake's server-certificate step. *)
let test_server_certificate () : Tls.Config.certchain =
  ensure_rng ();
  let priv = X509.Private_key.generate ~bits:2048 `RSA in
  let dn =
    X509.Distinguished_name.
      [ Relative_distinguished_name.singleton (CN "localhost") ]
  in
  let csr =
    match X509.Signing_request.create dn priv with
    | Ok r -> r
    | Error (`Msg m) ->
        failwith (Printf.sprintf "Net.test_server_certificate: csr: %s" m)
  in
  let valid_from = Ptime.epoch in
  (* Roughly one year from the epoch is fine; the client does not verify. *)
  let valid_until =
    match Ptime.add_span valid_from (Ptime.Span.v (3650, 0L)) with
    | Some t -> t
    | None -> Ptime.max
  in
  let extensions =
    let sans = X509.General_name.(singleton DNS [ "localhost" ]) in
    X509.Extension.(
      singleton Subject_alt_name (false, sans)
      |> add Basic_constraints (true, (false, None)))
  in
  let cert =
    match
      X509.Signing_request.sign csr ~valid_from ~valid_until ~extensions priv dn
    with
    | Ok c -> c
    | Error e ->
        failwith
          (Printf.sprintf "Net.test_server_certificate: sign: %s"
             (Fmt.to_to_string X509.Validation.pp_signature_error e))
  in
  ([ cert ], priv)

type tls_server = {
  listen_fd : Lwt_unix.file_descr;
  config : Tls.Config.server;
}

let listen_tls ?(backlog = default_backlog) ~certificates ~alpn host port =
  let open Lwt.Syntax in
  ensure_rng ();
  let alpn_protocols = match alpn with [] -> None | l -> Some l in
  let config =
    match
      Tls.Config.server ~certificates:(`Single certificates) ?alpn_protocols ()
    with
    | Ok c -> c
    | Error (`Msg m) ->
        failwith (Printf.sprintf "Net.listen_tls: bad TLS config: %s" m)
  in
  let* listen_fd = listen ~backlog host port in
  Lwt.return { listen_fd; config }

let tls_listen_fd s = s.listen_fd

let accept_tls s =
  let open Lwt.Syntax in
  let* conn_fd, peer = accept s.listen_fd in
  let* t = Tls_lwt.Unix.server_of_fd s.config conn_fd in
  let proto = negotiated_alpn t in
  let ic, oc = Tls_lwt.of_t t in
  Lwt.return (ic, oc, proto, peer)

let local_addr fd = Lwt_unix.getsockname fd

let bound_port fd =
  match local_addr fd with
  | Unix.ADDR_INET (_, port) -> port
  | Unix.ADDR_UNIX _ -> failwith "Net.bound_port: not an INET socket"

let sockaddr_to_string = function
  | Unix.ADDR_INET (ip, port) ->
      let host = Unix.string_of_inet_addr ip in
      (* Bracket IPv6 literals, mirroring Go's net.JoinHostPort. *)
      if String.contains host ':' then Printf.sprintf "[%s]:%d" host port
      else Printf.sprintf "%s:%d" host port
  | Unix.ADDR_UNIX path -> path

let with_timeout secs t = Lwt_unix.with_timeout secs (fun () -> t)
