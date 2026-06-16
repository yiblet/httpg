(* Eio socket + TLS substrate. No 1:1 Go source counterpart: Go's net/http
   builds on the stdlib [net] package and [crypto/tls]. This provides only what
   the server/client tickets need: TCP listen/accept, client connect (optionally
   TLS), and [Eio.Buf_read]/[Eio.Buf_write] wrapping (the bufio analogue used by
   [Io]). TLS is hand-driven over the sans-io [Tls.Engine] state machine the way
   Go's crypto/tls drives a [net.Conn] -- read raw, feed the engine, write what it
   produces -- so [Io] is oblivious to whether a connection is plain or TLS. *)

module Buf_read = Eio.Buf_read
module Buf_write = Eio.Buf_write

(* INTERNAL-ONLY exceptions (NOT in net.mli — they never appear on the public
   surface). The public, handleable failure of the resolve/handshake path is the
   {!error} variant threaded as [(_, error) result] by the client entry points
   ([connect]/[connect_tls]/[connect_alpn]) — those have no [exception] at all.
   These two exceptions exist solely for the handful of internal call sites that
   honor non-[result] signatures forced on us by Eio and the startup contracts,
   and the raise is converted/swallowed before it could ever escape [Net] as a
   public contract:

   - [Tls_flow.single_read] / [raise_tls]: Eio's [Flow.SOURCE.read] cannot return
     a [result], so a mid-stream modeled TLS failure re-raises [Internal_tls_error]
     here; the [connect_*] boundary's [run_buffered_result] catches it and maps it
     back to [Error (Tls _)] (see there). It never escapes [Net].
   - [listen] (resolve/bind failure): a [result]-free startup contract; a bad bind
     address re-raises [Internal_dial_error] (a startup config error, like
     {!bound_port}'s [Failure]).
   - [accept_tls] (per-connection handshake failure): a [result]-free
     per-connection contract; re-raises [Internal_tls_error], which the server's
     per-conn [on_error] swallows (one failed handshake must not kill the accept
     loop) — there is no buffered channel to respond over, so it is dropped, as in
     Go.

   Carries the underlying [Tls.Engine.string_of_failure] / host:port text.
   Distinct from the bare [Failure] kept for genuine usage bugs
   (write-before-handshake, bad TLS config). *)
exception Internal_tls_error of string
exception Internal_dial_error of string

(* Public, handleable failure of the client connect entry points, mirroring Go's
   [Dial]/[tls.Conn.Handshake] returning an [error]. The inner resolve/handshake
   helpers thread this [result] directly. Each variant carries Go's message
   text. *)
type error = Dial of string | Tls of string

let error_to_string = function Dial s -> s | Tls s -> s
let default_backlog = 128

(* Buf_read's own buffer cap. Io owns the real header budget
   (max_header_bytes + 4096 "bufio slop") and surfaces a typed 431/413; this cap
   only guards against runaway input, so we size it well above any legal head so
   Buf_read never truncates before Io's budget triggers. 16 MiB. *)
let buf_read_max_size = 16 * 1024 * 1024

(* ----- RNG ----- *)

(* Seed the mirage-crypto RNG before any TLS handshake or X509 key generation.
   [use_default] = [use_getentropy]: it installs a STATELESS generator whose
   [generate] calls the OS getrandom(2) syscall directly (no Fortuna, no shared
   mutable PRNG state). That is what makes multicore TLS safe: the K per-domain
   accept loops (server.ml) all draw from this one generator concurrently, but
   since each draw is just a reentrant kernel syscall there is no cross-domain
   race — unlike a Fortuna [default_generator] (its state is documented unlocked,
   "XXX Locking!!"). So each domain calls [ensure_rng] at the top of its accept
   loop. Idempotent; callers may invoke freely. Go's crypto/rand needs no
   analogue. *)
let ensure_rng () = Mirage_crypto_rng_unix.use_default ()

(* ----- Address helpers ----- *)

let resolve net host port : (Eio.Net.Sockaddr.stream, error) result =
  match Eio.Net.getaddrinfo_stream ~service:(string_of_int port) net host with
  | addr :: _ -> Ok addr
  | [] -> Error (Dial (Printf.sprintf "cannot resolve %s:%d" host port))

let sockaddr_to_string : Eio.Net.Sockaddr.stream -> string = function
  | `Tcp (ip, port) ->
      let host = Format.asprintf "%a" Eio.Net.Ipaddr.pp ip in
      (* Bracket IPv6 literals, mirroring Go's net.JoinHostPort. *)
      if String.contains host ':' then Printf.sprintf "[%s]:%d" host port
      else Printf.sprintf "%s:%d" host port
  | `Unix path -> path

let bound_port sock =
  match Eio.Net.listening_addr sock with
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "Net.bound_port: not a TCP socket"

(* ----- Plain buffered wrapping ----- *)

(* Wrap a stream flow in (Buf_read, Buf_write) and run [fn] with the writer's
   background flusher fiber live (Buf_write.with_flow). On return both halves are
   flushed/closed; the flow itself is owned by [sw]. Reused for plain and TLS. *)
let with_buffered (flow : _ Eio.Flow.two_way) fn =
  let r = Buf_read.of_flow ~max_size:buf_read_max_size flow in
  Buf_write.with_flow flow (fun w -> fn r w)

(* ----- TCP ----- *)

let listen ?(backlog = default_backlog) ~sw net host port =
  (* [listen] is a [result]-free startup contract; [resolve] threads a [result],
     so on an unresolvable bind address re-raise the INTERNAL exception (a
     startup config error that never crosses the public surface — see the
     exception block above). *)
  match resolve net host port with
  | Ok addr -> Eio.Net.listen ~reuse_addr:true ~backlog ~sw net addr
  | Error (Dial s) -> raise (Internal_dial_error s)
  | Error (Tls s) -> raise (Internal_tls_error s)

let accept ~sw listen_sock = Eio.Net.accept ~sw listen_sock

(* Go's [go c.serve]: accept and handle each connection in its own fiber, the
   accepted socket closed when [fn] returns (defer c.close()). *)
let accept_fork ~sw ~on_error listen_sock fn =
  Eio.Net.accept_fork ~sw ~on_error listen_sock fn

let ( let* ) = Result.bind

let connect ~sw net ~host ~port =
  let* addr = resolve net host port in
  Ok (Eio.Net.connect ~sw net addr)

(* ----- TLS engine driver (hand-driven sans-io Tls.Engine) ----- *)

(* A [Flow.two_way] backed by a [Tls.Engine.state] over an underlying flow. We
   drive the engine by hand: raw bytes read from the flow are fed to
   [handle_tls], which yields records to write back ([`Response]) and decrypted
   application data ([`Data]); writes encrypt via [send_application_data]. *)
module Tls_flow = struct
  type t = {
    flow : Eio.Flow.two_way_ty Eio.Resource.t;
    mutable state : Tls.Engine.state;
    mutable inbuf : string; (* decrypted plaintext not yet handed to reader *)
    mutable eof : bool; (* peer sent close_notify / EOF *)
    rawbuf : Cstruct.t; (* scratch for raw socket reads *)
  }

  let raw_chunk = 0x4000

  let create flow state =
    { flow; state; inbuf = ""; eof = false; rawbuf = Cstruct.create raw_chunk }

  let write_raw t s =
    if String.length s > 0 then Eio.Flow.write t.flow [ Cstruct.of_string s ]

  (* Read one batch of raw bytes from the flow ([""] at EOF). *)
  let read_raw t =
    match Eio.Flow.single_read t.flow t.rawbuf with
    | 0 -> ""
    | n -> Cstruct.to_string (Cstruct.sub t.rawbuf 0 n)
    | exception End_of_file -> ""

  let fail f : (_, error) result = Error (Tls (Tls.Engine.string_of_failure f))

  (* Bound on consecutive raw reads that decode but neither hand app data to the
     reader nor advance the handshake; past it a pathological peer streaming such
     records is cut off. (* crypto/tls common.go:73 maxUselessRecords *)
     Go counts complete non-advancing records; the sans-io engine hides record
     boundaries (one read may carry several records or buffer a partial one), so
     we bound non-advancing *reads* -- a close, conservative proxy: any legit
     flight advances within a read or two, only an abusive trickle reaches 16. *)
  let max_useless_records = 16

  (* Cut off a peer streaming non-advancing records: send a close_notify (Go's
     alertUnexpectedMessage) then fail. (* crypto/tls conn.go:795 *) *)
  let too_many_ignored t : (_, error) result =
    let state', out = Tls.Engine.send_close_notify t.state in
    t.state <- state';
    (try write_raw t out with _ -> ());
    Error (Tls "too many ignored records")

  (* Feed one raw chunk to the engine, applying its outputs; returns whether the
     step advanced (produced app data or a response flight) so the read/handshake
     pumps can bound non-advancing records. (* crypto/tls conn.go:698 *) *)
  let handle t raw : (bool, error) result =
    match Tls.Engine.handle_tls t.state raw with
    | Ok (state', eof, `Response resp, `Data data) ->
        t.state <- state';
        (match resp with Some s -> write_raw t s | None -> ());
        (match data with Some d -> t.inbuf <- t.inbuf ^ d | None -> ());
        if eof <> None then t.eof <- true;
        (* app data or a reply flight is state-advancing; reset the counter. *)
        Ok (resp <> None || data <> None)
    | Error (f, `Response resp) ->
        write_raw t resp;
        fail f

  (* Drive the handshake to completion. The engine returns its first flight (for
     a client) at construction; pump read->feed->write until established. *)
  let handshake t : (unit, error) result =
    (* Recursive pump (the result threading replaces the old [while] loop): each
       step feeds one raw chunk; a modeled Tls failure / spin-guard short-circuits
       to [Error]. [useless] bounds consecutive non-advancing reads. *)
    let rec pump useless =
      if (not (Tls.Engine.handshake_in_progress t.state)) || t.eof then Ok ()
      else
        match read_raw t with
        | "" ->
            t.eof <- true;
            Ok ()
        | raw ->
            let before = Tls.Engine.handshake_in_progress t.state in
            let* advanced = handle t raw in
            (* progress = a reply flight, handshake completion, or app data. *)
            if
              advanced
              || (before && not (Tls.Engine.handshake_in_progress t.state))
            then pump 0
            else if useless + 1 > max_useless_records then too_many_ignored t
            else pump (useless + 1)
    in
    let* () = pump 0 in
    if Tls.Engine.handshake_in_progress t.state then
      Error (Tls "connection closed during handshake")
    else Ok ()

  let negotiated_alpn t =
    match Tls.Engine.epoch t.state with
    | Ok ed -> ed.Tls.Core.alpn_protocol
    | Error () -> None

  (* Flow.SOURCE: hand out decrypted plaintext, decrypting more as needed.
     Progress here is app data reaching [inbuf]; records that decode but yield
     none (warning alerts, key updates) are bounded. (* crypto/tls conn.go:791 *) *)
  (* Mid-stream TLS failures discovered while pulling decrypted plaintext can't
     return a [result] through Eio's Flow.SOURCE interface (its [read] must
     raise), so the modeled [Error (Tls _)] from [handle]/[too_many_ignored] is
     re-raised as the INTERNAL [Internal_tls_error] here. It is caught and mapped
     back to [Error] at the [connect_*] boundary ([run_buffered_result]); it
     never escapes [Net]. This is the philosophy's fiber-control exemption: a
     raise forced by an Eio interface ([Flow.SOURCE.read]) that cannot return a
     [result], not a modeled failure surfaced as an exception. *)
  let raise_tls = function
    | Ok v -> v
    | Error (Tls s) -> raise (Internal_tls_error s)
    | Error (Dial s) -> raise (Internal_dial_error s)

  let single_read t buf =
    let useless = ref 0 in
    while t.inbuf = "" && not t.eof do
      match read_raw t with
      | "" -> t.eof <- true
      | raw ->
          ignore (raise_tls (handle t raw) : bool);
          if t.inbuf <> "" then useless := 0
          else begin
            incr useless;
            if !useless > max_useless_records then
              raise_tls (too_many_ignored t)
          end
    done;
    if t.inbuf = "" then raise End_of_file
    else begin
      let n = min (Cstruct.length buf) (String.length t.inbuf) in
      Cstruct.blit_from_string t.inbuf 0 buf 0 n;
      t.inbuf <- String.sub t.inbuf n (String.length t.inbuf - n);
      n
    end

  (* Flow.SINK: encrypt and write. *)
  let single_write t bufs =
    let s = Cstruct.copyv bufs in
    (match Tls.Engine.send_application_data t.state [ s ] with
    | Some (state', out) ->
        t.state <- state';
        write_raw t out
    | None -> failwith "Net TLS: write before handshake complete");
    String.length s

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src

  let shutdown t = function
    | `Send | `All ->
        let state', out = Tls.Engine.send_close_notify t.state in
        t.state <- state';
        write_raw t out;
        Eio.Flow.shutdown t.flow `Send
    | `Receive -> Eio.Flow.shutdown t.flow `Receive

  let read_methods = []

  module Two_way = struct
    type nonrec t = t

    let single_read = single_read
    let single_write = single_write
    let copy = copy
    let shutdown = shutdown
    let read_methods = read_methods
  end

  let handler = Eio.Flow.Pi.two_way (module Two_way)

  (* Build the engine flow, run the handshake, return it + negotiated ALPN. *)
  let establish flow state : (_ * string option, error) result =
    let flow = (flow :> Eio.Flow.two_way_ty Eio.Resource.t) in
    let t = create flow state in
    let* () = handshake t in
    Ok (Eio.Resource.T (t, handler), negotiated_alpn t)
end

(* ----- Verification policy ----- *)

(* Accept any peer certificate without verification: the explicit, documented
   insecure opt-out (Go's tls.Config.InsecureSkipVerify = true). NOT default. *)
let null_authenticator : X509.Authenticator.t = fun ?ip:_ ~host:_ _ -> Ok None

(* SECURE default authenticator from the OS trust store via ca-certs (checks
   expiry and, with ~host at handshake time, the certificate name) -- the
   analogue of Go's http.Client verifying against the system roots. *)
let default_authenticator () : X509.Authenticator.t =
  match Ca_certs.authenticator () with
  | Ok auth -> auth
  | Error (`Msg m) ->
      failwith
        (Printf.sprintf
           "Net: cannot load the system trust store for TLS verification: %s" m)

(* Precedence (mirroring Go's tls.Config): explicit [?authenticator] wins;
   else [~insecure:true] selects the null authenticator; else the secure
   system-trust default. *)
let resolve_authenticator ?authenticator ?(insecure = false) () =
  match authenticator with
  | Some a -> a
  | None -> if insecure then null_authenticator else default_authenticator ()

let host_to_domain_name host =
  match Domain_name.of_string host with
  | Ok dn -> (
      match Domain_name.host dn with Ok h -> Some h | Error _ -> None)
  | Error _ -> None

let client_config ?(alpn = []) ?authenticator ?insecure ~peer_name () =
  let alpn_protocols = match alpn with [] -> None | l -> Some l in
  let authenticator = resolve_authenticator ?authenticator ?insecure () in
  match Tls.Config.client ~authenticator ?peer_name ?alpn_protocols () with
  | Ok c -> c
  | Error (`Msg m) ->
      failwith (Printf.sprintf "Net.connect: bad TLS config: %s" m)

(* ----- Client connect ----- *)

(* Run a buffered-channel callback and convert a MID-STREAM modeled TLS/dial
   failure to [Error]. Resolve and the handshake driver already thread [result]
   (no boundary catch), but the Flow.SOURCE read ([Tls_flow.single_read]) cannot
   return a [result] through Eio's interface: its spin-guard / decode failures
   re-raise the INTERNAL [Internal_tls_error] while [fn] is streaming over the
   connection (the [tls_spin_guard] test exercises exactly this -- a guard
   tripped after the handshake, during a [Buf_read.line]). This narrow catch
   maps those modeled mid-stream raises back to [Error (Tls/Dial _)]; anything
   else (raw [End_of_file], [Eio.Cancel], usage [Failure]) propagates
   unchanged. *)
let run_buffered_result fn : (_, error) result =
  match fn () with
  | v -> Ok v
  | exception Internal_tls_error s -> Error (Tls s)
  | exception Internal_dial_error s -> Error (Dial s)

(* [connect_alpn ... fn] dials [host]/[port], optionally upgrades to TLS
   (advertising [alpn] and verifying per the secure-by-default policy), and runs
   [fn ~proto r w] with buffered channels over the (TLS or plain) connection.
   [proto] is the negotiated ALPN protocol ([None] for plain / none agreed). *)
let connect_alpn ~sw net ~host ~port ?(tls = false) ?(alpn = []) ?authenticator
    ?insecure fn =
  let* addr = resolve net host port in
  let flow = Eio.Net.connect ~sw net addr in
  if not tls then
    run_buffered_result (fun () ->
        with_buffered flow (fun r w -> fn ~proto:None r w))
  else begin
    ensure_rng ();
    let peer_name = host_to_domain_name host in
    let cfg = client_config ~alpn ?authenticator ?insecure ~peer_name () in
    let state, first = Tls.Engine.client cfg in
    (* The client's initial hello must hit the wire before we read. *)
    Eio.Flow.write flow [ Cstruct.of_string first ];
    let* tls_flow, proto = Tls_flow.establish flow state in
    run_buffered_result (fun () ->
        Fun.protect
          ~finally:(fun () ->
            try Eio.Flow.shutdown tls_flow `Send with _ -> ())
          (fun () -> with_buffered tls_flow (fun r w -> fn ~proto r w)))
  end

let connect_tls ~sw net ~host ~port ?(tls = false) ?authenticator ?insecure fn =
  connect_alpn ~sw net ~host ~port ~tls ?authenticator ?insecure
    (fun ~proto:_ r w -> fn r w)

(* ----- Server-side TLS + ALPN ----- *)

(* Mint a fresh self-signed cert + key at runtime (no files on disk), the
   OCaml-stack analogue of Go's net/http/internal/testcert: RSA-2048,
   CN=localhost, SAN DNS=localhost, valid ~ten years. The matching client uses
   the null authenticator, so the cert only satisfies the handshake's
   server-certificate step. *)
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
  (* A fixed wide window that contains "now", mirroring Go's
     net/http/internal/testcert (NotBefore 1970, NotAfter ~2084). Anchoring to
     the epoch keeps this [unit]-pure (no clock) while guaranteeing the cert is
     valid during any real test run -- the old epoch..epoch+3650d window was
     already expired (~1979). *)
  let valid_from = Ptime.epoch in
  let valid_until =
    match Ptime.add_span valid_from (Ptime.Span.v (36525, 0L)) with
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

type 'tag tls_server = {
  listen_sock : 'tag Eio.Net.listening_socket_ty Eio.Resource.t;
  config : Tls.Config.server;
}

let listen_tls ?(backlog = default_backlog) ~sw ~certificates ~alpn net host
    port =
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
  let listen_sock = listen ~backlog ~sw net host port in
  { listen_sock; config }

let tls_listen_sock s = s.listen_sock

(* Handshake an already-accepted server connection and run [fn ~proto r w].
   [accept_tls] is given the accepted [flow]/[peer] (so the server can fork a
   fiber per connection before handshaking -- the handshake must not run on the
   accept loop). *)
let accept_tls s (flow : _ Eio.Net.stream_socket) fn =
  ensure_rng ();
  let state = Tls.Engine.server s.config in
  (* [accept_tls]'s public contract is [result]-free (it returns ['a]); a
     server-side handshake failure re-raises the INTERNAL exception, which the
     server's per-conn [on_error] swallows (one bad handshake must not kill the
     accept loop, and there is no buffered channel to respond over). The
     [result] threading is confined to the client entry points. *)
  let tls_flow, proto =
    match Tls_flow.establish flow state with
    | Ok v -> v
    | Error (Tls s) -> raise (Internal_tls_error s)
    | Error (Dial s) -> raise (Internal_dial_error s)
  in
  Fun.protect
    ~finally:(fun () -> try Eio.Flow.shutdown tls_flow `Send with _ -> ())
    (fun () -> with_buffered tls_flow (fun r w -> fn ~proto r w))

(* Plaintext: wrap an accepted/connected stream socket in buffered channels and
   run [fn r w]. Reused by the plain server/client paths (the TLS paths wrap the
   engine flow instead). *)
let with_connection (flow : _ Eio.Net.stream_socket) fn = with_buffered flow fn

(* ----- Timeout ----- *)

(* [with_timeout clock secs fn] runs [fn ()] and returns [Ok] its result, or
   [Error `Timeout] if it has not finished within [secs] seconds. *)
let with_timeout clock secs fn =
  Eio.Time.with_timeout clock secs (fun a -> fn a |> Result.ok)
