(* A process-local [Eio.Net.t] whose connections are kernel socketpairs -- the
   httpg analogue of Go's httptest in-memory ("fakenet") network. Server,
   Client, Transport, and TLS run over it unchanged; only the [~net] capability
   is swapped. No loopback, DNS, or ports are used. See the [.ml] for the
   addressing scheme ([getaddrinfo] resolves every host to a synthetic loopback
   [`Tcp] address keyed by port, so listen/connect rendezvous in-process). *)

type t
(** A network: an in-process registry matching client connections to server
    listeners. *)

val create : unit -> t
(** A fresh, empty network. Listeners register themselves on [listen]; clients
    reach them on [connect] by the resolved address. *)

val net : t -> [ `Generic ] Eio.Net.ty Eio.Resource.t
(** The network as an [Eio.Net.t], usable anywhere httpg takes [~net]
    ({!Httpg.Server} entry points, {!Httpg.Client.create}, ...). A [connect] to
    an address with no bound listener raises [Eio.Net.Connection_failure]. *)
