(* Port of the read/write halves of request.go and response.go, over Lwt_io
   channels: readRequest / ReadRequest, Request.Write, ReadResponse,
   Response.Write.

   Read bodies {b stream} — they are not materialized in memory. {!read_request}
   and {!read_response} return a {!Body.Stream} that pulls bytes lazily from the
   connection (wrapping [Transfer.read_transfer]'s incremental reader). For a
   chunked body, reaching EOF reads the trailing trailer block and merges it into
   the message's [trailer] field (Go's [body.readTrailer] / [mergeSetHeader]), so
   the trailer is only populated once the body has been consumed to EOF. Use
   {!Body.read_all} to collect a whole body or {!Body.drain} to consume-and-
   discard it. *)

(** A parse / protocol error, carrying Go's message text (Go's
    [ProtocolError] / [badStringError]).

    {b Retained} for the {b mid-stream} body thunk (errors discovered after the
    read boundary returned [Ok] keep raising) and as the internal raise
    mechanism for the linear parse path; the handleable boundary error is
    {!error} below. {!Transport} also raises it to carry a round-trip failure
    message through its exception-based error flow. *)
exception Protocol_error of string

(** Retained for the {b mid-stream} body thunk; the handleable boundary error is
    {!error}'s {!Missing_host} arm. *)
exception Missing_host

(** Handleable error at the request/response read/write boundary. Lower-level
    framing failures are embedded via the {!Transfer} arm.

    {b Mid-stream policy (Resolution #1):} errors discovered inside a {!Body.t}
    [Stream] thunk {b after} {!read_request}/{!read_response} returned [Ok] keep
    {b raising} (the faithful analogue of Go's "a later [Read] returns an
    error"). Only the header / initial-parse boundary surfaces [Error]. *)
type error =
  | Protocol of string  (** malformed MIME header / request line; was {!Protocol_error} *)
  | Missing_host  (** {!write_request}: no Host / URL host (Go's [errMissingHost]) *)
  | Transfer of Transfer.error  (** embedded framing error from {!Transfer.read_transfer} *)
  | Unexpected_eof  (** clean EOF before a full message (Go's [io.ErrUnexpectedEOF]) *)

(** Render an {!error} as its Go message text. *)
val error_to_string : error -> string

(** [read_mime_header ic] reads a CRLF-terminated header block (until the blank
    line), folding obs-fold continuation lines, into a {!Header.t}. Port of
    [textproto.Reader.ReadMIMEHeader]. A malformed line short-circuits as
    [Error (Protocol _)]. *)
val read_mime_header : Lwt_io.input_channel -> (Header.t, error) result Lwt.t

(** [read_request ic] is [ReadRequest]: parse the request line, headers
    (Host promoted to [host] and deleted from the header map), and body framing
    from [ic]. The body is a streaming {!Body.Stream} reading lazily from [ic];
    it is not buffered. Consume it to EOF ({!Body.read_all}/{!Body.drain}) to
    reach the next message boundary and populate any chunked trailer.

    Header / initial-parse errors short-circuit as [Error]; see {!error} for the
    mid-stream policy. *)
val read_request : Lwt_io.input_channel -> (Body.t Request.t, error) result Lwt.t

(** [read_response ?request ic] is [ReadResponse]: parse the status line,
    headers and body framing. [request] optionally supplies the corresponding
    request (for HEAD body suppression); a GET is assumed otherwise. The body is
    a streaming {!Body.Stream} reading lazily from [ic] (not buffered); consume
    it to EOF to reach the next message boundary and read any chunked trailer. *)
val read_response :
  ?request:Body.t Request.t -> Lwt_io.input_channel -> (Body.t Response.t, error) result Lwt.t

(** [write_request oc r] is [Request.Write]: write the request line, Host /
    User-Agent / framing headers, the remaining headers and the body. Always
    emits ["HTTP/1.1"]. Returns [Error Missing_host] when no host is available. *)
val write_request : Lwt_io.output_channel -> Body.t Request.t -> (unit, error) result Lwt.t

(** [write_response oc r] is [Response.Write]: write the status line, framing
    headers, the remaining headers and the body, applying Go's zero-length-body
    probe and the HTTP/1.1 unknown-length [Connection: close] rule. *)
val write_response : Lwt_io.output_channel -> Body.t Response.t -> unit Lwt.t
