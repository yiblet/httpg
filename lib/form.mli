(* Port of the form-parsing half of go/src/net/http/request.go: ParseForm,
   ParseMultipartForm, FormValue, PostFormValue, FormFile. URL-encoded parsing
   is a faithful port (via {!Values}); multipart/form-data parsing is delegated
   to the [multipart_form-lwt] library (the plan's intentional fidelity
   stand-in for Go's mime/multipart). *)

(** A handleable form-parsing error.
    - {!constructor-Form} carries Go's error string for a media-type / form / multipart
      parse failure (e.g. "mime: invalid media parameter", "http: POST too
      large").
    - {!Not_multipart} is Go's [ErrNotMultipart]: [parse_multipart_form] on a
      non-multipart/form-data request. *)
type error = Form of string | Not_multipart

val error_to_string : error -> string
(** Render an {!error} as its Go message text. *)

exception Media_type_error of string
(** Raised by {!parse_media_type} on an invalid media parameter (Go's
    [mime.ParseMediaType] error). This pure helper keeps Go's error-as-exception
    shape; the result-returning entrypoints
    {!parse_form}/{!parse_multipart_form} catch it and surface {!constructor-Form}. *)

val default_max_memory : int64
(** [defaultMaxMemory] = 32 MB. *)

val parse_media_type : string -> string * (string * string) list
(** [mime.ParseMediaType v]: the lowercased bare media type and its parameters.
    Raises {!Media_type_error} for invalid parameters. *)

val parse_form : Body.t Request.t -> (unit, error) result Lwt.t
(** [Request.ParseForm]: populate [r.form] (query + urlencoded body) and
    [r.post_form] (body only). Idempotent. Returns the first error encountered
    instead of raising (mirroring Go's error return). For POST/PUT/PATCH with
    Content-Type application/x-www-form-urlencoded the body is read and parsed;
    body params take precedence in [r.form]. *)

val parse_multipart_form :
  Body.t Request.t -> max_memory:int64 -> (unit, error) result Lwt.t
(** [Request.ParseMultipartForm ~max_memory]: parse a multipart/form-data body
    into [r.multipart_form], also merging text values into
    [r.form]/[r.post_form] (Issue 9305). Calls {!parse_form} first. Returns
    [Error Not_multipart] for a non-multipart request or [Error (Form _)] on a
    parse failure. Idempotent. NOTE: [max_memory] is accepted for signature
    fidelity but the stand-in library materializes all parts in memory. *)

val form_value : Body.t Request.t -> string -> string Lwt.t
(** [Request.FormValue key]: the first value for [key], lazily parsing
    (ParseMultipartForm then ParseForm) and ignoring errors. "" if absent. *)

val post_form_value : Body.t Request.t -> string -> string Lwt.t
(** [Request.PostFormValue key]: the first body value for [key] (query ignored),
    lazily parsing and ignoring errors. "" if absent. *)

val form_file : Body.t Request.t -> string -> (string * string) option Lwt.t
(** [Request.FormFile key]: the first file for [key] as [(filename, content)] (a
    simplification of Go's [(multipart.File, *multipart.FileHeader)]), lazily
    parsing. [None] if absent. *)
