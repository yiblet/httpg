(* Port of go/src/net/http/response.go: the Response type and pure helpers.
   The IO halves (ReadResponse / Response.Write) live in {!Io}. The TLS field
   is intentionally omitted (deferred). *)

type 'body t = {
  mutable status : Httpg_base.Status.t;
      (** Go [Status]/[StatusCode], collapsed; the wire reason phrase is the
          canonical {!Httpg_base.Status.to_string} *)
  mutable proto : Httpg_base.Protocol.t;
      (** Go [Proto]/[ProtoMajor]/[ProtoMinor], collapsed *)
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

val cookies : 'a t -> Cookie.t list
(** [Response.Cookies]: cookies from the "Set-Cookie" headers. *)

val proto_at_least : 'a t -> int -> int -> bool
(** [Response.ProtoAtLeast]. *)

val location : 'a t -> Uri.t option
(** [Response.Location]: the "Location" header resolved against the request URL,
    or [None] (Go's [ErrNoLocation]) when absent. *)
