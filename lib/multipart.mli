(* multipart/form-data parsing as a composable, incremental sequence of parts
   over a [Body.t]. Deviation from Go's Request-mutating [ParseMultipartForm]: a
   multipart body IS a [(part, error) result Seq.t], parsed on demand, with no
   cache on the Request. Backed by the sans-io [multipart_form] core (fidelity
   stand-in for Go's mime/multipart).

   {b No file spillover (for now):} every part body is buffered in memory, so a
   very large upload buffers whole. Re-adding Go's [maxMemory] temp-file spill —
   bounded and via [Eio.Path], not blocking stdlib IO — is tracked in TODO. *)

type part = {
  name : string option;
      (** the field name from the part's Content-Disposition, if any. *)
  filename : string option;
      (** the file name from Content-Disposition (basename only, Issue 45789),
          if this is a file part. *)
  header : Header.t;
      (** the part's MIME header (Content-Type/-Disposition/-Transfer-Encoding;
          unstructured custom fields are dropped). *)
  body : string;  (** the part's content, held in memory. *)
}
(** One part of a multipart/form-data body. *)

type t = part Seq.t

type error =
  | Not_multipart
  | Parse of string
      (** A handleable multipart error.
          - {!Not_multipart}: the Content-Type isn't multipart/form-data, or it
            carries no boundary (Go's [ErrNotMultipart]).
          - {!Parse}: a malformed multipart body (the parser's message). *)

val error_to_string : error -> string
(** Render an {!error} as its message text. *)

val boundary : content_type:string -> (string, error) result
(** [boundary ~content_type] extracts the boundary parameter from a
    multipart/form-data Content-Type header value (Go's multipartReader
    content-type check). [Error Not_multipart] if the media type isn't
    multipart/form-data or no boundary is present; [Error (Parse _)] on an
    invalid media parameter. The result feeds {!of_body}'s [~boundary]. *)

val of_body : boundary:string -> Body.t -> (part, error) result Seq.t
(** [of_body ~boundary body] parses [body] as multipart/form-data, yielding its
    parts one at a time. Each forced element drives the parser until the next
    part has fully arrived, buffering its body in memory.

    Delivery is incremental, so errors are per-element: a malformed part appears
    as a single [Error] {b after} the well-formed parts before it, and the
    sequence then ends. The returned sequence is effectful (a stateful parser
    underneath) and intended for a single forward traversal. *)

val to_body : boundary:string -> t -> Body.t
(** [to_body ~boundary parts] renders [parts] as a multipart/form-data {!Body.t}
    delimited by [boundary] (Go's [multipart.Writer]). The body {b streams}:
    each part is encoded into its own chunk on demand (an unknown-length stream
    via {!Body.of_string_seq}), followed by the closing delimiter. Each part's
    Content-Disposition is synthesized from its [name]/[filename] (replacing any
    carried one); the remaining header fields (e.g. Content-Type) are written
    as-is, then the part [body]. The inverse of {!of_body}: parsing the result
    with the same [boundary] yields the same parts. The caller is responsible
    for the matching ["multipart/form-data; boundary=..."] Content-Type. *)
