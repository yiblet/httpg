(* A concrete HTTP message body over Lwt, the analogue of Go's
   [io.ReadCloser] body field. *)

(** [Empty] is the analogue of [http.NoBody]; [String s] an in-memory body;
    [Stream next] a streaming reader whose [next ()] yields successive chunks
    and finally [None] (the analogue of [io.EOF]).

    A body produced by a {b read path} — a server request body or a client
    response body (see {!Io.read_request}/{!Io.read_response}) — is a [Stream]
    that pulls bytes lazily {b from the underlying connection}; it is never
    materialized up front. Such a body must be consumed to EOF (via {!read_all}
    or {!drain}) to free the connection: reading to [None] runs the on-EOF
    action that reads any chunked trailer and releases the connection for
    keep-alive reuse (Go's [resp.Body.Close]). Until then the connection is held
    and is not reused. A handler/caller that returns without draining the body
    leaves it to the framework to drain (server side) or simply forgoes reuse
    (client side). *)
type t =
  | Empty
  | String of string
  | Stream of (unit -> string option Lwt.t)

(** The empty body. *)
val empty : t

(** [of_string s] is [String s]. *)
val of_string : string -> t

(** [of_stream next] is [Stream next]. *)
val of_stream : (unit -> string option Lwt.t) -> t

(** Read the entire body to a string. *)
val read_all : t -> string Lwt.t

(** [drain b] reads and discards the body until EOF. [Empty]/[String] are
    no-ops. For a [Stream] it pulls every chunk until [None] — the analogue of
    Go's [body.Close] consuming the body to EOF (and any chunked trailer),
    leaving a kept-alive connection at the next message boundary. *)
val drain : t -> unit Lwt.t

(** [iter f b] applies [f] to each successive chunk of the body, in order,
    until EOF. [Empty] yields no calls; [String s] yields exactly one call
    [f s]; a [Stream] yields one call per chunk until it returns [None]. This
    streams the body without materializing it (the analogue of Go's [io.Copy]
    pulling from a body reader chunk-by-chunk). *)
val iter : (string -> unit Lwt.t) -> t -> unit Lwt.t

(** [write oc b] writes the raw body bytes to [oc] with no transfer framing. *)
val write : Lwt_io.output_channel -> t -> unit Lwt.t
