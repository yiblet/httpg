(* Port of go/src/net/http/response.go: the Response type and pure helpers.

   v2 of {!Response} (parallel-module rewrite, docs/module-rewrite-pattern.md):
   the same record plus an immutable builder so axum-style handlers build and
   return a response instead of mutating a writer. Will be renamed to
   [Response]. *)

type 'body t = {
  mutable status : Httpg_base.Status.t;
  mutable proto : Httpg_base.Protocol.t;
  mutable header : Header.t;
  mutable body : 'body;
  mutable content_length : int64;  (** -1 means unknown *)
  mutable transfer_encoding : string list;
  mutable close : bool;
  mutable uncompressed : bool;
  mutable trailer : Header.t option;
  mutable request : 'body Request.t option;
}
(** A response mirroring Go's [Response] struct. The body field is parametric;
    {!Io} instantiates ['body] to {!Body.t}. *)

val create : unit -> Body.t t
(** [create ()] is a fresh 200 response: empty header, [Body.Empty],
    [content_length = 0], HTTP/1.1. The base for the builder. *)

val with_status : Httpg_base.Status.t -> 'b t -> 'b t
(** [with_status code r] is [r] with its status set to [code]. *)

val with_header : string -> string -> 'b t -> 'b t
(** [with_header key value r] returns [r] with [value] appended for [key]
    (copy-on-write: [r]'s header is not mutated). *)

val with_set_header : string -> string -> 'b t -> 'b t
(** [with_set_header key value r] returns [r] with [key]'s values replaced by
    [value] (copy-on-write). *)

val with_body : Body.t -> Body.t t -> Body.t t
(** [with_body body r] returns [r] carrying [body], with [content_length]
    derived from it ([String] → its length, [Empty] → 0, [Stream] → -1). *)

val with_body_string : string -> Body.t t -> Body.t t
(** [with_body_string s r] is [with_body (Body.String s) r]. *)

val with_trailer : Header.t -> 'b t -> 'b t
(** [with_trailer t r] returns [r] with its trailer set to [t]. *)

val cookies : 'a t -> Cookie.t list
(** [Response.Cookies]: cookies from the "Set-Cookie" headers. *)

val proto_at_least : 'a t -> int -> int -> bool
(** [Response.ProtoAtLeast]. *)

val location : 'a t -> Uri.t option
(** [Response.Location]: the "Location" header resolved against the request URL,
    or [None] (Go's [ErrNoLocation]) when absent. *)
