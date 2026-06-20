(* A process-local [Eio.Net.t] whose connections are kernel socketpairs.
   The httpg analogue of Go's httptest in-memory ("fakenet") network
   (go/src/net/http/httptest/server.go + internal/nettest): a client [connect]
   and a server [listen]/[accept] are matched in-process, and each connection is
   an [Eio_unix.Net.socketpair_stream] pair. No loopback, DNS, or ports are
   involved -- the only OS resource is the socketpair(2) byte plumbing.

   Because it implements the [Eio.Net.t] interface, the existing Server, Client,
   Transport, and TLS code run over it unchanged: only the [~net] capability is
   swapped (mirroring Go, which swaps the transport's DialContext, not the
   handler or RoundTripper).

   Addressing: [getaddrinfo host] resolves every host to [`Unix host], so a
   server bound on a host name and a client dialing the same name rendezvous on
   that key regardless of the (irrelevant) port. *)

open Eio.Std

(* An accepted connection waiting in a listener's queue: the server-side socket
   plus the peer address reported to [accept]. *)
type conn =
  [ `Generic | `Unix ] Eio.Net.stream_socket_ty r * Eio.Net.Sockaddr.stream

module Listening_socket = struct
  type t = {
    addr : Eio.Net.Sockaddr.stream;
    queue : conn Eio.Stream.t;
    on_close : unit -> unit;
  }

  type tag = [ `Generic | `Unix ]

  (* Block until a client [connect] enqueues a connection (Go's listener
     Accept). The socket was attached to the connecting fiber's switch when the
     socketpair was created, so [~sw] here is unused. *)
  let accept t ~sw:_ = Eio.Stream.take t.queue
  let close t = t.on_close ()
  let listening_addr t = t.addr
end

let listening_handler = Eio.Net.Pi.listening_socket (module Listening_socket)

module Impl = struct
  (* The registry maps a bound address to its accept queue. *)
  type t = (Eio.Net.Sockaddr.stream, conn Eio.Stream.t) Hashtbl.t
  type tag = [ `Generic | `Unix ]

  let listen reg ~reuse_addr:_ ~reuse_port:_ ~backlog ~sw:_ addr =
    let queue = Eio.Stream.create backlog in
    Hashtbl.replace reg addr queue;
    let on_close () = Hashtbl.remove reg addr in
    let ls = { Listening_socket.addr; queue; on_close } in
    (Eio.Resource.T (ls, listening_handler)
      :> tag Eio.Net.listening_socket_ty r)

  let connect reg ~sw addr =
    match Hashtbl.find_opt reg addr with
    | None ->
        (* No server bound on this address: the in-memory analogue of a refused
           dial. *)
        raise (Eio.Net.err (Connection_failure No_matching_addresses))
    | Some queue ->
        let client_end, server_end = Eio_unix.Net.socketpair_stream ~sw () in
        let server_end = (server_end :> tag Eio.Net.stream_socket_ty r) in
        Eio.Stream.add queue (server_end, addr);
        (client_end :> tag Eio.Net.stream_socket_ty r)

  let datagram_socket _ ~reuse_addr:_ ~reuse_port:_ ~sw:_ _ =
    invalid_arg "Socketpair_net: datagram sockets are not supported"

  (* Resolve every host to a synthetic loopback [`Tcp] address keyed by port, so
     [listen] and [connect] agree on the rendezvous address. We use [`Tcp]
     (rather than [`Unix host]) because the server requires a TCP-bound listener
     ([Net.bound_port]); the address never reaches the network -- [connect] is a
     socketpair regardless. Each network has its own registry, so a constant IP
     cannot collide across servers. *)
  let getaddrinfo _reg ~service host =
    ignore host;
    let port = Option.value ~default:0 (int_of_string_opt service) in
    [ `Tcp (Eio.Net.Ipaddr.V4.loopback, port) ]

  let getnameinfo _reg = function
    | `Tcp (ip, port) ->
        (Format.asprintf "%a" Eio.Net.Ipaddr.pp ip, string_of_int port)
    | _ -> ("", "")
end

let network_handler = Eio.Net.Pi.network (module Impl)

type t = Impl.t

let create () : t = Hashtbl.create 8

let net (reg : t) : [ `Generic ] Eio.Net.ty Eio.Resource.t =
  (Eio.Resource.T (reg, network_handler)
    :> [ `Generic ] Eio.Net.ty Eio.Resource.t)
