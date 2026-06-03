(* Port of the core file-serving path of go/src/net/http/fs.go:
   [FileSystem]/[File]/[Dir], [ServeContent] (full-body, no ranges yet),
   [serveFile]/[FileServer], [dirList], [toHTTPError], [localRedirect], the
   path-cleaning + [containsDotDot] traversal guard.

   {b Stubbed for later tickets:} the conditional-request branch
   ([checkPreconditions] — If-Match / If-Unmodified-Since / If-None-Match /
   If-Modified-Since, 304 / 412) is reduced to {!check_preconditions} which
   currently never short-circuits (always "serve full 200") — Ticket 4 fills it
   in. The byte-range branch ([parseRange]/[httpRange]/If-Range, 206 /
   multipart/byteranges / 416) is omitted here: {!serve_content} always sends a
   full 200 with [Accept-Ranges: bytes] — Ticket 5 fills it in. A clear hook is
   left in {!serve_content} where the range header is read. *)

(** Go's [fs.FileInfo] subset that this port needs: the bits [serveFile] reads
    off a [Stat]. *)
type file_info = {
  fi_name : string;  (** base name (Go [FileInfo.Name]) *)
  fi_size : int64;  (** length in bytes (Go [FileInfo.Size]) *)
  fi_mod_time : float;  (** modification time, Unix-epoch seconds (Go [ModTime]) *)
  fi_is_dir : bool;  (** whether it is a directory (Go [IsDir]) *)
}

(** Go's [http.File]: a file returned by a {!file_system}'s open, served by the
    [FileServer]. Models the [io.Closer]/[io.Reader]/[io.Seeker] + [Readdir] +
    [Stat] interface over the underlying OS file. *)
type file = {
  stat : unit -> file_info Lwt.t;  (** Go [File.Stat]. *)
  read_window : off:int64 -> len:int -> string Lwt.t;
      (** Read up to [len] bytes starting at byte offset [off] (a seek + read;
          Go's [Seek]+[Read]). Returns fewer bytes only at EOF. *)
  readdir : unit -> file_info list Lwt.t;
      (** Go [File.Readdir(-1)]: all directory entries. *)
  close : unit -> unit Lwt.t;  (** Go [File.Close]. *)
}

(** Go's [http.FileSystem]: access to a collection of named, '/'-separated
    files. *)
type file_system = {
  open_ : string -> (file, exn) result Lwt.t;  (** Go [FileSystem.Open]. *)
}

(** Go's [Dir]: a {!file_system} backed by the native filesystem rooted at the
    given directory. The open path is cleaned and {b rejected if it escapes the
    root} (contains a [".."] element, mirroring Go's [path.Clean("/"+name)] +
    [containsDotDot] guard). OS errors map to {!Not_found} (missing) or a
    permission error. An empty root is treated as ["."]. *)
val dir : string -> file_system

(** Raised by {!dir}'s open for a path that cannot be represented / is unsafe
    (Go's [errInvalidUnsafePath]); {!to_http_error} maps it to 404. *)
exception Invalid_unsafe_path

(** Go's [containsDotDot]: whether the '/'- or '\'-separated path [v] has a
    [".."] element. *)
val contains_dot_dot : string -> bool

(** Go's [toHTTPError]: map an open/stat error to a (message, status) pair —
    {!Not_found}/{!Invalid_unsafe_path} → ["404 page not found"]/404, a
    permission error → ["403 Forbidden"]/403, else ["500 Internal Server
    Error"]/500. *)
val to_http_error : exn -> string * int

(** Go's [localRedirect]: a 301 Moved Permanently to [new_path], preserving the
    request's raw query, {b without} converting the path to absolute (unlike
    {!Server.redirect}). *)
val local_redirect :
  Server.response_writer -> Body.t Request.t -> string -> unit Lwt.t

(** Go's [dirList]: write an HTML [<pre>] listing of the directory [f]'s
    entries as escaped links; sets [Content-Type: text/html; charset=utf-8]. *)
val dir_list :
  Server.response_writer -> Body.t Request.t -> file -> unit Lwt.t

(** [check_preconditions w r ~modtime] is the Ticket-3 stub of Go's
    [checkPreconditions]: it returns [(done_, range_header)] where [done_] is
    whether a precondition already produced the whole response (currently always
    [false]) and [range_header] is the request's [Range] header passed through
    (currently the raw value; the If-Range gate is added in Ticket 5). Ticket 4
    replaces the body with the real RFC 7232 precondition machinery. *)
val check_preconditions :
  Server.response_writer -> Body.t Request.t -> modtime:float -> bool * string

(** Go's [ServeContent] core (full-body 200, no ranges yet). Sets
    [Content-Type] (a small extension→MIME table, falling back to
    {!Sniff.detect_content_type} on the first bytes when the handler left it
    unset), [Last-Modified] (via {!Http_time.format_gmt}, unless [modtime] is
    the zero/epoch time), [Accept-Ranges: bytes] and [Content-Length] = [size],
    then streams the whole content (skipping the body for a HEAD request).
    [read_window] reads a bounded window of the content (used both for the
    sniff probe and the body stream). Calls {!check_preconditions} first. *)
val serve_content :
  Server.response_writer ->
  Body.t Request.t ->
  name:string ->
  modtime:float ->
  size:int64 ->
  read_window:(off:int64 -> len:int -> string Lwt.t) ->
  unit Lwt.t

(** Go's [serveFile]: serve [name] from [fs]. Redirects [".../index.html"] to
    ["./"]; when [redirect] is set, redirects a directory URL lacking a trailing
    slash to [dir/] (and a file URL with a trailing slash to [../base]). A
    directory serves its [index.html] if present, else {!dir_list}; a regular
    file is served via {!serve_content}. Open/stat errors go through
    {!to_http_error}. *)
val serve_file :
  Server.response_writer ->
  Body.t Request.t ->
  file_system ->
  string ->
  redirect:bool ->
  unit Lwt.t

(** Go's [FileServer]: a {!Server.handler} serving the file system rooted at
    [root]. Cleans the request path and dispatches via {!serve_file} with
    [redirect:true] (so [dir]→[dir/] and [/index.html]→[./] redirects fire). *)
val file_server : file_system -> Server.handler
