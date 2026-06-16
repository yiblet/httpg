(* Port of the read/write halves of request.go and response.go, over
   [Eio.Buf_read.t] / [Eio.Buf_write.t]: readRequest / ReadRequest,
   Request.Write, ReadResponse, Response.Write.

   Read bodies {b stream} — they are not materialized in memory. {!read_request}
   and {!read_response} return a streaming {!Body.t} that pulls bytes lazily
   from the connection (wrapping [Transfer.read_transfer]'s incremental reader).
   For a chunked body, reaching EOF reads the trailing trailer block and merges
   it into the message's [trailer] field (Go's [body.readTrailer] /
   [mergeSetHeader]), so the trailer is only populated once the body has been
   consumed to EOF. Use {!Body.read_all} to collect a whole body or
   {!Body.drain} to consume-and-discard it. *)

(** Handleable error at the request/response read/write boundary. Lower-level
    framing failures are embedded via the {!constructor-Transfer} arm.

    {b Mid-stream policy:} a framing failure discovered inside the streaming
    {!Body.t} {b after} {!read_request}/{!read_response} returned [Ok] surfaces
    as a terminal {!Body.error} element of the body's result-seq (typed data,
    the faithful analogue of Go's "a later [Read] returns an error"), never a
    raise. Only the header / initial-parse boundary uses this [error]. *)
type error =
  | Protocol of string
      (** malformed MIME header / request line (Go's [ProtocolError] /
          [badStringError]) *)
  | Missing_host
      (** {!write_request}: no Host / URL host (Go's [errMissingHost]) *)
  | Transfer of Transfer.error
      (** embedded framing error from {!Transfer.read_transfer} *)
  | Unexpected_eof
      (** clean EOF before a full message (Go's [io.ErrUnexpectedEOF]) *)
  | Request_too_large
      (** the request status line + header block exceeded the bounded read
          budget (Go's [errTooLarge], server.go:998); the server answers
          [431 Request Header Fields Too Large] and closes *)
  | Trailer_too_large
      (** the trailer block following a chunked body exceeded the bounded read
          budget (Go's "suspiciously long trailer after chunked body",
          transfer.go:934). The trailer is read {b mid-stream} (when the body
          reaches EOF), so the form callers observe is {!Body.Trailer_too_large}
          — a terminal [Error] element of the body's result-seq, not a boundary
          [Error] from {!read_request}/{!read_response}. This arm is retained for
          callers that classify a boundary {!error} alongside that case. *)
  | Malformed_host
      (** {!read_request}: the single inbound [Host] header value contained a
          byte outside Go's lenient host byte set ([httpguts.ValidHostHeader],
          httplex.go:209-263); the server answers [400 Bad Request]
          (server.go:1050-1051). A missing required Host (HTTP/1.1+,
          non-CONNECT, non-h2-upgrade) and an invalid header name/value
          (server.go:1045-1062) surface as {!Protocol} (also 400). *)
  | Response_header_too_large
      (** {!read_response}: the response status line + header block exceeded the
          bounded read budget (Go's [Transport.MaxResponseHeaderBytes], default
          [10 lsl 20], transport.go:275-280,:337-340,:364). The client-side
          mirror of {!Request_too_large}; the transport surfaces it as a modeled
          round-trip failure rather than buffering an unbounded head. *)

val error_to_string : error -> string
(** Render an {!error} as its Go message text. *)

val read_mime_header : Eio.Buf_read.t -> (Header.t, error) result
(** [read_mime_header r] reads a CRLF-terminated header block (until the blank
    line), folding obs-fold continuation lines, into a {!Header.t}. Port of
    [textproto.Reader.ReadMIMEHeader]. A malformed line short-circuits as
    [Error (Protocol _)]. *)

val read_request :
  ?max_header_bytes:int -> Eio.Buf_read.t -> (Request.t, error) result
(** [read_request ?max_header_bytes r] is [ReadRequest]: parse the request line,
    headers (Host promoted to [host] and deleted from the header map), and body
    framing from [ic]. The body is a streaming {!Body.t} reading lazily
    from [ic]; it is not buffered. Consume it to EOF
    ({!Body.read_all}/{!Body.drain}) to reach the next message boundary and
    populate any chunked trailer.

    [max_header_bytes] bounds the request line + header block cumulatively
    against [max_header_bytes + 4096] bytes (Go's [initialReadLimitSize], the
    "bufio slop", server.go:929); exceeding it short-circuits as
    [Error Request_too_large]. Omitting it leaves the head read unbounded.

    After the header block is parsed, a validation sweep mirroring Go's
    [conn.serve] (server.go:1045-1062) runs: a missing required [Host] on
    HTTP/1.1+ (non-CONNECT, non-h2-upgrade), an invalid header name or
    CTL-bearing header value short-circuit as [Error (Protocol _)], and a
    malformed [Host] value as [Error Malformed_host] — all answered 400.

    Header / initial-parse errors short-circuit as [Error]; see {!error} for the
    mid-stream policy. *)

val read_response :
  ?request:Request.t ->
  ?max_header_bytes:int ->
  Eio.Buf_read.t ->
  (Response.t, error) result
(** [read_response ?request ?max_header_bytes r] is [ReadResponse]: parse the
    status line, headers and body framing. [request] optionally supplies the
    corresponding request (for HEAD body suppression); a GET is assumed
    otherwise. The body is a streaming {!Body.t} reading lazily from [ic]
    (not buffered); consume it to EOF to reach the next message boundary and
    read any chunked trailer.

    [max_header_bytes] bounds the status line + header block cumulatively
    against [max_header_bytes + 4096] bytes — the client-side mirror of
    {!read_request}'s budget (Go's [Transport.MaxResponseHeaderBytes] /
    [pc.readLimit], transport.go:275-280,:337-340,:364); exceeding it
    short-circuits as [Error Response_header_too_large]. Omitting it leaves the
    head read unbounded. *)

val write_request : Eio.Buf_write.t -> Request.t -> (unit, error) result
(** [write_request w r] is [Request.Write]: write the request line, Host /
    User-Agent / framing headers, the remaining headers and the body. Always
    emits ["HTTP/1.1"]. Returns [Error Missing_host] when no host is available.
*)

module Private : sig
  (** Helpers exposed only for the ported white-box tests; not part of the
      public API. *)

  val write_response : Eio.Buf_write.t -> Response.t -> unit
  (** [write_response w r] is [Response.Write]: write the status line, framing
      headers, the remaining headers and the body, applying Go's
      zero-length-body probe and the HTTP/1.1 unknown-length [Connection: close]
      rule. *)
end
