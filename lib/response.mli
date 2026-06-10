(* Port of go/src/net/http/response.go: the Response type and pure helpers.

   v2 of {!Response} (parallel-module rewrite, docs/module-rewrite-pattern.md):
   the same record plus an immutable builder so axum-style handlers build and
   return a response instead of mutating a writer. Will be renamed to
   [Response]. *)

type t = {
  mutable status : Httpg_base.Status.t;
  mutable proto : Httpg_base.Protocol.t;
  mutable header : Header.t;
  mutable body : Body.t;
  mutable content_length : int64 option;
      (** [None] = unknown (Go's [-1]); [Some n] = known length ([Some 0L] =
          genuinely empty body) *)
  mutable transfer_encoding : string list;
  mutable close : bool;
  mutable uncompressed : bool;
  mutable trailer : Header.t option;
  mutable request : Request.t option;
}
(** A response mirroring Go's [Response] struct. *)

val create : unit -> t
(** [create ()] is a fresh 200 response: empty header, [Body.Empty],
    [content_length = Some 0L], HTTP/1.1. The base for the builder. *)

val with_status : Httpg_base.Status.t -> t -> t
(** [with_status code r] is [r] with its status set to [code]. *)

val with_header : string -> string -> t -> t
(** [with_header key value r] returns [r] with [value] appended for [key]
    (copy-on-write: [r]'s header is not mutated). *)

val with_set_header : string -> string -> t -> t
(** [with_set_header key value r] returns [r] with [key]'s values replaced by
    [value] (copy-on-write). *)

val with_body : Body.t -> t -> t
(** [with_body body r] returns [r] carrying [body], with [content_length]
    derived from it ([String] → [Some] its length, [Empty] → [Some 0L], [Stream]
    → [None] = unknown). *)

val with_body_string : string -> t -> t
(** [with_body_string s r] is [with_body (Body.String s) r]. *)

val with_trailer : Header.t -> t -> t
(** [with_trailer t r] returns [r] with its trailer set to [t]. *)

val cookies : t -> Cookie.t list
(** [Response.Cookies]: cookies from the "Set-Cookie" headers. *)

val proto_at_least : t -> int -> int -> bool
(** [Response.ProtoAtLeast]. *)

val location : t -> Uri.t option
(** [Response.Location]: the "Location" header resolved against the request URL,
    or [None] (Go's [ErrNoLocation]) when absent. *)
