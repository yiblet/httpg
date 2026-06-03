(* Port of the [ResponseRecorder] half of go/src/net/http/httptest. A
   [ResponseRecorder] is an in-memory {!Server.response_writer} that records a
   handler's status code, headers and body for inspection in tests. The
   loopback [Server] half is a separate ticket. *)

module Response_recorder : sig
  (** Go's [httptest.ResponseRecorder]. [code] is the status set by
      [write_header] (default 200, like [NewRecorder]); [header] is the header
      map the handler mutates; [body] accumulates [write] bytes; [flushed]
      records whether [flush] was called; [wrote_header] is set once the
      framing/status has been committed (Go's [wroteHeader]). [snap_header] is
      the snapshot of [header] taken at the first commit, used by {!result}. *)
  type t = {
    mutable code : int;
    header : Header.t;
    body : Buffer.t;
    mutable flushed : bool;
    mutable wrote_header : bool;
    mutable snap_header : Header.t option;
    mutable default_remote_addr : string;
  }

  (** Go's [DefaultRemoteAddr] (["1.2.3.4"]). *)
  val default_remote_addr_const : string

  (** Go's [NewRecorder]: a fresh recorder with [code = 200] and empty
      header/body. *)
  val create : unit -> t

  (** Adapt the recorder to a {!Server.response_writer} so a handler can run
      against it unchanged. *)
  val to_response_writer : t -> Server.response_writer

  (** Go's [ResponseRecorder.Result]: snapshot the handler's response into a
      {!Response.t} (status code/line, a header snapshot, body as
      {!Body.String}). A default code of 200 is applied; Content-Type is
      sniffed from the body when unset (and no Transfer-Encoding) at first
      write; Content-Length is taken from the header. proto is ["HTTP/1.1"]. *)
  val result : t -> Body.t Response.t

  (** The recorded status code (Go's [Code] field; 0 if never committed via a
      constructor other than {!create}). *)
  val code : t -> int

  (** The accumulated body bytes (Go's [Body.String()]). *)
  val body_string : t -> string

  (** The live header map the handler mutates (Go's [HeaderMap]). *)
  val header : t -> Header.t
end
