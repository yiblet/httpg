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
    [ProtocolError] / [badStringError]). *)
exception Protocol_error of string

(** Raised by {!write_request} when the request has no Host or URL host
    (Go's [errMissingHost]). *)
exception Missing_host

(** [read_mime_header ic] reads a CRLF-terminated header block (until the blank
    line), folding obs-fold continuation lines, into a {!Header.t}. Port of
    [textproto.Reader.ReadMIMEHeader]. *)
val read_mime_header : Lwt_io.input_channel -> Header.t Lwt.t

(** [read_request ic] is [ReadRequest]: parse the request line, headers
    (Host promoted to [host] and deleted from the header map), and body framing
    from [ic]. The body is a streaming {!Body.Stream} reading lazily from [ic];
    it is not buffered. Consume it to EOF ({!Body.read_all}/{!Body.drain}) to
    reach the next message boundary and populate any chunked trailer. *)
val read_request : Lwt_io.input_channel -> Body.t Request.t Lwt.t

(** [read_response ?request ic] is [ReadResponse]: parse the status line,
    headers and body framing. [request] optionally supplies the corresponding
    request (for HEAD body suppression); a GET is assumed otherwise. The body is
    a streaming {!Body.Stream} reading lazily from [ic] (not buffered); consume
    it to EOF to reach the next message boundary and read any chunked trailer. *)
val read_response : ?request:Body.t Request.t -> Lwt_io.input_channel -> Body.t Response.t Lwt.t

(** [write_request oc r] is [Request.Write]: write the request line, Host /
    User-Agent / framing headers, the remaining headers and the body. Always
    emits ["HTTP/1.1"]. Raises {!Missing_host} when no host is available. *)
val write_request : Lwt_io.output_channel -> Body.t Request.t -> unit Lwt.t

(** [write_response oc r] is [Response.Write]: write the status line, framing
    headers, the remaining headers and the body, applying Go's zero-length-body
    probe and the HTTP/1.1 unknown-length [Connection: close] rule. *)
val write_response : Lwt_io.output_channel -> Body.t Response.t -> unit Lwt.t
