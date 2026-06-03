(* A concrete HTTP message body over Lwt, the analogue of Go's
   [io.ReadCloser] body field. *)

(** [Empty] is the analogue of [http.NoBody]; [String s] an in-memory body;
    [Stream next] a streaming reader whose [next ()] yields successive chunks
    and finally [None] (the analogue of [io.EOF]). *)
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

(** [write oc b] writes the raw body bytes to [oc] with no transfer framing. *)
val write : Lwt_io.output_channel -> t -> unit Lwt.t
