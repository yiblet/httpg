(* Port of the core file-serving path of go/src/net/http/fs.go:
   [FileSystem]/[File]/[Dir], [ServeContent], [serveFile]/[FileServer],
   [dirList], [toHTTPError], [localRedirect], the path-cleaning +
   [containsDotDot] traversal guard.

   The conditional-request branch ([checkPreconditions] — If-Match /
   If-Unmodified-Since / If-None-Match / If-Modified-Since / If-Range, 304 / 412)
   and the byte-range branch ([parseRange]/[httpRange], 206 / multipart/byteranges
   / 416) are fully ported. A single satisfiable range yields {b 206} +
   [Content-Range], a single body window; multiple ranges yield {b 206}
   [multipart/byteranges]; an unsatisfiable range yields {b 416} +
   [Content-Range: bytes */SIZE]. [If-Range] (handled in {!check_preconditions})
   gates whether the range applies.

   Direct-style over Eio: file IO uses the [Eio.Path] filesystem capability; a
   regular file is opened {b once} (under a switch) and bodies stream
   window-by-window by [pread]ing that single handle (Go keeps one [*os.File]
   and seeks within it), closed after the body is served on every path. *)

type file_info = {
  fi_name : string;  (** base name (Go [FileInfo.Name]) *)
  fi_size : int64;  (** length in bytes (Go [FileInfo.Size]) *)
  fi_mod_time : float;
      (** modification time, Unix-epoch seconds (Go [ModTime]) *)
  fi_is_dir : bool;  (** whether it is a directory (Go [IsDir]) *)
}
(** Go's [fs.FileInfo] subset that this port needs: the bits [serveFile] reads
    off a [Stat]. *)

type file = {
  stat : unit -> file_info;  (** Go [File.Stat]. *)
  read_window : off:int64 -> len:int -> string;
      (** Read up to [len] bytes starting at byte offset [off] by [pread]ing the
          single open handle (Go's [Seek]+[Read]). Returns fewer bytes only at
          EOF. Valid until {!close}. *)
  readdir : unit -> file_info list;
      (** Go [File.Readdir(-1)]: all directory entries. *)
  close : unit -> unit;  (** Go [File.Close]. *)
}
(** Go's [http.File]: a file returned by a {!file_system}'s open, served by the
    [FileServer]. Models the [io.Closer]/[io.Reader]/[io.Seeker] + [Readdir] +
    [Stat] interface over the underlying OS file. *)

(** A handleable file-serving error. Covers the open/stat failures
    {!to_http_error} maps to an HTTP status ({!Invalid_unsafe_path}/{!Not_exist}
    → 404, {!Permission} → 403, {!Other} → 500) and the {!parse_range} failures
    ({!No_overlap} → 416 with [Content-Range: bytes */SIZE], {!Invalid_range} →
    416). *)
type error =
  | Invalid_unsafe_path
      (** Go's [errInvalidUnsafePath]: path escapes the root. *)
  | Not_exist  (** Go's [fs.ErrNotExist]: no such file/dir. *)
  | Permission  (** Go's [fs.ErrPermission]. *)
  | Other of string  (** any other open/stat error (→ 500). *)
  | No_overlap
      (** Go's [errNoOverlap]: no requested range overlaps the content. *)
  | Invalid_range of string
      (** Go's ["invalid range"]: malformed Range header. *)

val error_to_string : error -> string
(** Render an {!error} as its Go message text. *)

type file_system = { open_ : sw:Eio.Switch.t -> string -> (file, error) result }
(** Go's [http.FileSystem]: access to a collection of named, '/'-separated
    files. The returned {!file}'s handle is opened under [sw]; it lives until
    {!file.close} or [sw] teardown, so a regular file is read from one fd. *)

val dir : Eio.Fs.dir_ty Eio.Path.t -> file_system
(** Go's [Dir]: a {!file_system} backed by the native filesystem rooted at the
    given [Eio.Path] directory capability. The open path is cleaned and
    {b rejected if it escapes the root} (contains a [".."] element, mirroring
    Go's [path.Clean("/"+name)] + [containsDotDot] guard). OS errors map to
    {!Not_exist} (missing) or {!Permission}. *)

val contains_dot_dot : string -> bool
(** Go's [containsDotDot]: whether the '/'- or '\'-separated path [v] has a
    [".."] element. *)

val to_http_error : error -> string * Httpg_base.Status.t
(** Go's [toHTTPError]: map an open/stat {!error} to a (message, status) pair —
    {!Not_exist}/{!Invalid_unsafe_path} → ["404 page not found"]/404,
    {!Permission} → ["403 Forbidden"]/403, else
    ["500 Internal Server Error"]/500. *)

val local_redirect : Body.t Request.t -> string -> Body.t Response.t
(** Go's [localRedirect]: a 301 Moved Permanently response to [new_path],
    preserving the request's raw query, {b without} converting the path to
    absolute (unlike {!Server.redirect}). *)

val dir_list : Body.t Request.t -> file -> Body.t Response.t
(** Go's [dirList]: a [text/html] response with an HTML [<pre>] listing of the
    directory [f]'s entries as escaped links. *)

val scan_etag : string -> (string * string) option
(** Go's [scanETag]: if a syntactically valid ETag (either ["\"text\""] or
    [W/"text"], RFC 7232 2.3) is present at the start of the (trimmed) input,
    returns [Some (etag, remain)] with the matched ETag and the text after it;
    otherwise [None]. *)

val check_preconditions :
  header:Header.t ->
  etag:string ->
  Body.t Request.t ->
  modtime:float ->
  [ `Done of Body.t Response.t | `Range of string ]
(** Go's [checkPreconditions]: evaluate request preconditions per RFC 7232
    section 6 against [modtime] and [etag] (the response's [Etag]). [header] is
    the response header built so far, used to shape a short-circuit response.
    Returns [`Done resp] when a precondition short-circuits — {b 304} (clears
    Content-Type/Length/Encoding, drops Last-Modified when an Etag is set) for a
    matched If-None-Match/If-Modified-Since on GET/HEAD, or {b 412} Precondition
    Failed for a failed If-Match/If-Unmodified-Since (or a matched If-None-Match
    on a non-GET/HEAD method) — otherwise [`Range range_header], the request's
    [Range] blanked out when an If-Range condition fails. Precedence: If-Match →
    If-Unmodified-Since → If-None-Match → If-Modified-Since, then If-Range. *)

type http_range = { start : int64; length : int64 }
(** Go's [httpRange]: a single requested byte range, [start] inclusive, [length]
    bytes. *)

val content_range : http_range -> int64 -> string
(** Go's [httpRange.contentRange]: the [Content-Range] header value for the
    range against a content of the given size — ["bytes START-END/SIZE"]. *)

val mime_header :
  http_range -> content_type:string -> size:int64 -> (string * string) list
(** Go's [httpRange.mimeHeader]: the per-part headers for a
    [multipart/byteranges] response, in the order multipart.Writer emits them
    ([Content-Range] then [Content-Type]). *)

val parse_range : string -> int64 -> (http_range list, error) result
(** Go's [parseRange]: parse a [Range] header against a content of [size] bytes
    per RFC 7233. Accepts ["bytes="] then a comma list of [start-end] (both
    inclusive), [start-] (to EOF), or [-suffix] (last N bytes). Returns the
    satisfiable ranges (clamped to the content), or [Error (Invalid_range _)]
    for a malformed header / [Error No_overlap] when every range starts past the
    content. An empty header returns [Ok []]. *)

val serve_content :
  ?header:Header.t ->
  Body.t Request.t ->
  name:string ->
  modtime:float ->
  size:int64 ->
  read_window:(off:int64 -> len:int -> string) ->
  Body.t Response.t
(** Go's [ServeContent] core, building the response. [?header] carries
    caller-set fields ([Etag] for the precondition checks, an explicit
    [Content-Type]); it is taken as the starting response header (copied, not
    mutated). Sets [Content-Type] (a small extension→MIME table, falling back to
    {!Sniff.detect_content_type} on the first bytes when unset), [Last-Modified]
    (unless [modtime] is the zero/epoch time), [Accept-Ranges: bytes] and the
    Content-Length, with the body a {!Body.Stream} over [read_window] (empty for
    a HEAD). Evaluates {!check_preconditions} first (304/412). A satisfiable
    (If-Range gated) [Range] yields {b 206}: a single range with [Content-Range]
    and just that window, or multiple ranges as a [multipart/byteranges] body
    (deterministic boundary) assembled with {!Body.concat}; an unsatisfiable
    range yields {b 416} with [Content-Range: bytes */SIZE]. *)

val serve_file :
  sw:Eio.Switch.t ->
  Body.t Request.t ->
  file_system ->
  string ->
  redirect:bool ->
  Body.t Response.t
(** Go's [serveFile]: serve [name] from [fs] as a response. Files are opened
    under [~sw] (the request switch) so a streamed body outlives this call and
    the fd is closed when the request finishes. Redirects [".../index.html"] to
    ["./"]; when [redirect] is set, redirects a directory URL lacking a trailing
    slash to [dir/] (and a file URL with a trailing slash to [../base]). A
    directory serves its [index.html] if present, else {!dir_list}; a regular
    file is served via {!serve_content}. Open/stat errors go through
    {!to_http_error}. *)

val file_server : file_system -> Server.handler
(** Go's [FileServer]: a {!Server.handler} serving the file system rooted at
    [root]. Cleans the request path and dispatches via {!serve_file} with
    [redirect:true] (so [dir]→[dir/] and [/index.html]→[./] redirects fire). *)
