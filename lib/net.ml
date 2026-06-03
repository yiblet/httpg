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

(* A null authenticator: accept any peer certificate without verification.
   Acceptable for the smoke-test substrate only -- a production client must
   supply a real authenticator (e.g. X509 system trust). *)
let null_authenticator : X509.Authenticator.t =
  fun ?ip:_ ~host:_ _certs -> Ok None

let connect ~host ~port ?(tls = false) () =
  let open Lwt.Syntax in
  let* addr = resolve host port in
  let domain = Unix.domain_of_sockaddr addr in
  let fd = Lwt_unix.socket domain Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.connect fd addr in
  if not tls then Lwt.return (channels_of_fd fd)
  else
    let cfg =
      match Tls.Config.client ~authenticator:null_authenticator () with
      | Ok c -> c
      | Error (`Msg m) ->
          failwith (Printf.sprintf "Net.connect: bad TLS config: %s" m)
    in
    let host_dn =
      match Domain_name.of_string host with
      | Ok dn -> ( match Domain_name.host dn with Ok h -> Some h | Error _ -> None)
      | Error _ -> None
    in
    let* t = Tls_lwt.Unix.client_of_fd cfg ?host:host_dn fd in
    Lwt.return (Tls_lwt.of_t t)

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
