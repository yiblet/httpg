(* Port of the form-parsing half of go/src/net/http/request.go: ParseForm,
   ParseMultipartForm, FormValue, PostFormValue, FormFile. URL-encoded parsing
   is a faithful port (via {!Values}); multipart/form-data parsing is delegated
   to the [multipart_form-lwt] library (the plan's intentional fidelity
   stand-in for Go's mime/multipart). *)

(** Raised by parsing helpers on a media-type / multipart / form error,
    carrying Go's error string (e.g. "mime: invalid media parameter",
    "http: POST too large"). *)
exception Form_error of string

(** Raised when ParseMultipartForm is called on a non-multipart/form-data
    request (Go's [ErrNotMultipart]). *)
exception Not_multipart

(** [defaultMaxMemory] = 32 MB. *)
val default_max_memory : int64

(** [mime.ParseMediaType v]: the lowercased bare media type and its parameters.
    Raises {!Form_error} for invalid parameters. *)
val parse_media_type : string -> string * (string * string) list

(** [Request.ParseForm]: populate [r.form] (query + urlencoded body) and
    [r.post_form] (body only). Idempotent. Returns the first error encountered
    instead of raising (mirroring Go's error return). For POST/PUT/PATCH with
    Content-Type application/x-www-form-urlencoded the body is read and parsed;
    body params take precedence in [r.form]. *)
val parse_form : Body.t Request.t -> (unit, string) result Lwt.t

(** [Request.ParseMultipartForm ~max_memory]: parse a multipart/form-data body
    into [r.multipart_form], also merging text values into [r.form]/[r.post_form]
    (Issue 9305). Calls {!parse_form} first. Raises {!Not_multipart} for a
    non-multipart request or {!Form_error} on a parse failure. Idempotent.
    NOTE: [max_memory] is accepted for signature fidelity but the stand-in
    library materializes all parts in memory. *)
val parse_multipart_form : Body.t Request.t -> max_memory:int64 -> unit Lwt.t

(** [Request.FormValue key]: the first value for [key], lazily parsing
    (ParseMultipartForm then ParseForm) and ignoring errors. "" if absent. *)
val form_value : Body.t Request.t -> string -> string Lwt.t

(** [Request.PostFormValue key]: the first body value for [key] (query ignored),
    lazily parsing and ignoring errors. "" if absent. *)
val post_form_value : Body.t Request.t -> string -> string Lwt.t

(** [Request.FormFile key]: the first file for [key] as
    [(filename, content)] (a simplification of Go's
    [(multipart.File, *multipart.FileHeader)]), lazily parsing. [None] if
    absent. *)
val form_file : Body.t Request.t -> string -> (string * string) option Lwt.t
