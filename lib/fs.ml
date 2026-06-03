(* Port of the core file-serving path of go/src/net/http/fs.go. See fs.mli for
   the surface and the list of branches stubbed for Tickets 4 (preconditions)
   and 5 (ranges). *)

open Lwt.Infix

type file_info = {
  fi_name : string;
  fi_size : int64;
  fi_mod_time : float;
  fi_is_dir : bool;
}

type file = {
  stat : unit -> file_info Lwt.t;
  read_window : off:int64 -> len:int -> string Lwt.t;
  readdir : unit -> file_info list Lwt.t;
  close : unit -> unit Lwt.t;
}

type file_system = { open_ : string -> (file, exn) result Lwt.t }

exception Invalid_unsafe_path

(* ---- containsDotDot / isSlashRune ---- *)

let is_slash_rune c = c = '/' || c = '\\'

(* Go's containsDotDot. *)
let contains_dot_dot v =
  let contains_dotdot =
    let rec scan i =
      if i + 1 >= String.length v then false
      else if v.[i] = '.' && v.[i + 1] = '.' then true
      else scan (i + 1)
    in
    scan 0
  in
  if not contains_dotdot then false
  else begin
    (* split on '/' or '\\' (FieldsFuncSeq drops empty fields) and look for ".." *)
    let n = String.length v in
    let found = ref false in
    let i = ref 0 in
    while !i < n && not !found do
      (* skip separators *)
      while !i < n && is_slash_rune v.[!i] do
        incr i
      done;
      let start = !i in
      while !i < n && not (is_slash_rune v.[!i]) do
        incr i
      done;
      if !i > start && String.sub v start (!i - start) = ".." then found := true
    done;
    !found
  end

(* ---- Dir (native filesystem) ---- *)

(* Window read of a regular file: seek to [off], read up to [len] bytes. *)
let read_window_of_fd fd ~off ~len =
  Lwt_unix.LargeFile.lseek fd off Unix.SEEK_SET >>= fun _ ->
  let buf = Bytes.create len in
  let rec loop got =
    if got >= len then Lwt.return got
    else
      Lwt_unix.read fd buf got (len - got) >>= fun n ->
      if n = 0 then Lwt.return got else loop (got + n)
  in
  loop 0 >>= fun got -> Lwt.return (Bytes.sub_string buf 0 got)

let file_info_of_stat name (st : Lwt_unix.stats) =
  {
    fi_name = name;
    fi_size = Int64.of_int st.Lwt_unix.st_size;
    fi_mod_time = st.Lwt_unix.st_mtime;
    fi_is_dir = st.Lwt_unix.st_kind = Unix.S_DIR;
  }

(* Build a {!file} over an opened native path. We keep the open fd for content
   reads and re-open the directory on demand for listings. *)
let file_of_path full_name : (file, exn) result Lwt.t =
  Lwt.catch
    (fun () ->
      Lwt_unix.stat full_name >>= fun st ->
      let base = Filename.basename full_name in
      let info = file_info_of_stat base st in
      if info.fi_is_dir then begin
        (* directory: no fd; readdir reads entries with their own stats *)
        let readdir () =
          Lwt_unix.opendir full_name >>= fun dh ->
          let rec loop acc =
            Lwt.catch
              (fun () -> Lwt_unix.readdir dh >>= fun n -> Lwt.return (Some n))
              (function End_of_file -> Lwt.return None | e -> Lwt.fail e)
            >>= function
            | None -> Lwt.return (List.rev acc)
            | Some "." | Some ".." -> loop acc
            | Some name ->
                Lwt.catch
                  (fun () ->
                    Lwt_unix.stat (Filename.concat full_name name)
                    >>= fun est ->
                    Lwt.return (file_info_of_stat name est :: acc))
                  (* Pretend it doesn't exist, like os.File Readdir does. *)
                  (fun _ -> Lwt.return acc)
                >>= fun acc -> loop acc
          in
          Lwt.finalize (fun () -> loop []) (fun () -> Lwt_unix.closedir dh)
        in
        Lwt.return
          (Ok
             {
               stat = (fun () -> Lwt.return info);
               read_window = (fun ~off:_ ~len:_ -> Lwt.return "");
               readdir;
               close = (fun () -> Lwt.return_unit);
             })
      end
      else begin
        Lwt_unix.openfile full_name [ Unix.O_RDONLY ] 0 >>= fun fd ->
        let closed = ref false in
        let close () =
          if !closed then Lwt.return_unit
          else begin
            closed := true;
            Lwt_unix.close fd
          end
        in
        Lwt.return
          (Ok
             {
               stat = (fun () -> Lwt.return info);
               read_window = read_window_of_fd fd;
               readdir =
                 (fun () ->
                   (* Readdir on a non-directory: like os, an error. *)
                   Lwt.fail (Failure "not a directory"));
               close;
             })
      end)
    (fun exn ->
      match exn with
      | Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) ->
          Lwt.return (Error Not_found)
      | Unix.Unix_error ((Unix.EACCES | Unix.EPERM), _, _) ->
          Lwt.return (Error exn)
      | e -> Lwt.return (Error e))

let dir root =
  let open_ name =
    (* path.Clean("/" + name)[1:] *)
    let cleaned = Pattern.path_clean ("/" ^ name) in
    let path =
      if String.length cleaned >= 1 then
        String.sub cleaned 1 (String.length cleaned - 1)
      else ""
    in
    let path = if path = "" then "." else path in
    (* filepath.Localize rejects paths that escape (".." element). On POSIX a
       clean rooted path can't contain "..", but guard like Go's Localize. *)
    if contains_dot_dot path then Lwt.return (Error Invalid_unsafe_path)
    else begin
      let dir = if root = "" then "." else root in
      let full_name = Filename.concat dir path in
      file_of_path full_name
    end
  in
  { open_ }

(* ---- toHTTPError / localRedirect ---- *)

let to_http_error = function
  | Not_found -> ("404 page not found", Status.status_not_found)
  | Invalid_unsafe_path -> ("404 page not found", Status.status_not_found)
  | Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) ->
      ("404 page not found", Status.status_not_found)
  | Unix.Unix_error ((Unix.EACCES | Unix.EPERM), _, _) ->
      ("403 Forbidden", Status.status_forbidden)
  | _ -> ("500 Internal Server Error", Status.status_internal_server_error)

let local_redirect w (r : Body.t Request.t) new_path =
  let new_path =
    match Uri.verbatim_query r.Request.url with
    | Some q when q <> "" -> new_path ^ "?" ^ q
    | _ -> new_path
  in
  let h = w.Server.header () in
  Header.set h "Location" new_path;
  w.Server.write_header Status.status_moved_permanently;
  Lwt.return_unit

(* ---- dirList ---- *)

(* Go's url.URL{Path: name}.String(): percent-escape a path segment so that
   '?'/'#'/etc remain part of the path, not a query/fragment. *)
let escape_path_href name =
  Uri.pct_encode ~component:`Path name

(* Go's htmlReplacer (the escaper dirList uses for the link text). Mirrors the
   server's htmlEscape; kept local since it is not exported. *)
let html_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | '"' -> Buffer.add_string buf "&#34;"
      | '\'' -> Buffer.add_string buf "&#39;"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let dir_list w (r : Body.t Request.t) (f : file) =
  Lwt.catch
    (fun () -> f.readdir () >>= fun entries -> Lwt.return (Ok entries))
    (fun e -> Lwt.return (Error e))
  >>= function
  | Error _ ->
      Server.error w "Error reading directory"
        Status.status_internal_server_error
  | Ok entries ->
      let entries =
        List.sort (fun a b -> compare a.fi_name b.fi_name) entries
      in
      let h = w.Server.header () in
      Header.set h "Content-Type" "text/html; charset=utf-8";
      ignore r;
      w.Server.write "<!doctype html>\n" >>= fun () ->
      w.Server.write "<meta name=\"viewport\" content=\"width=device-width\">\n"
      >>= fun () ->
      w.Server.write "<pre>\n" >>= fun () ->
      Lwt_list.iter_s
        (fun e ->
          let name = if e.fi_is_dir then e.fi_name ^ "/" else e.fi_name in
          let href = escape_path_href name in
          w.Server.write
            ("<a href=\"" ^ href ^ "\">" ^ html_escape name ^ "</a>\n"))
        entries
      >>= fun () -> w.Server.write "</pre>\n"

(* ---- preconditions (Go fs.go: checkPreconditions + helpers) ---- *)

(* Go isZeroTime: t is obviously unspecified (zero or Unix()=0). Our modtime is
   Unix-epoch seconds, so both collapse to 0.0. *)
let is_zero_time t = t = 0.0

(* textproto.TrimString: trim leading/trailing ' ' and '\t'. *)
let trim_string s =
  let n = String.length s in
  let is_ws c = c = ' ' || c = '\t' in
  let i = ref 0 in
  while !i < n && is_ws s.[!i] do
    incr i
  done;
  let j = ref (n - 1) in
  while !j >= !i && is_ws s.[!j] do
    decr j
  done;
  if !j < !i then "" else String.sub s !i (!j - !i + 1)

(* Go scanETag: returns Some (etag, remain) if a syntactically valid ETag is
   present at the start of [s] (after trimming), else None. An ETag is either
   W/"text" or "text" (RFC 7232 2.3). *)
let scan_etag s =
  let s = trim_string s in
  let n = String.length s in
  let start =
    if n >= 2 && s.[0] = 'W' && s.[1] = '/' then 2 else 0
  in
  if n - start < 2 || s.[start] <> '"' then None
  else begin
    (* scan from start+1 for the closing quote, validating ETag chars *)
    let rec loop i =
      if i >= n then None
      else
        let c = Char.code s.[i] in
        if c = 0x21 || (c >= 0x23 && c <= 0x7E) || c >= 0x80 then loop (i + 1)
        else if s.[i] = '"' then
          Some (String.sub s 0 (i + 1), String.sub s (i + 1) (n - i - 1))
        else None
    in
    loop (start + 1)
  end

(* Go etagStrongMatch: a == b && a != "" && a[0] == '"'. *)
let etag_strong_match a b =
  a = b && a <> "" && a.[0] = '"'

(* Go etagWeakMatch: strings.TrimPrefix(a,"W/") == strings.TrimPrefix(b,"W/"). *)
let etag_weak_match a b =
  let strip s =
    if String.length s >= 2 && s.[0] = 'W' && s.[1] = '/' then
      String.sub s 2 (String.length s - 2)
    else s
  in
  strip a = strip b

(* condResult. *)
type cond_result = Cond_none | Cond_true | Cond_false

(* Go checkIfMatch. *)
let check_if_match w (r : Body.t Request.t) =
  let im = Header.get r.Request.header "If-Match" in
  if im = "" then Cond_none
  else begin
    let etag_hdr = Header.get (w.Server.header ()) "Etag" in
    let rec loop im =
      let im = trim_string im in
      if String.length im = 0 then Cond_false
      else if im.[0] = ',' then loop (String.sub im 1 (String.length im - 1))
      else if im.[0] = '*' then Cond_true
      else
        match scan_etag im with
        | None -> Cond_false
        | Some (etag, remain) ->
            if etag_strong_match etag etag_hdr then Cond_true
            else loop remain
    in
    loop im
  end

(* Go checkIfUnmodifiedSince. *)
let check_if_unmodified_since (r : Body.t Request.t) ~modtime =
  let ius = Header.get r.Request.header "If-Unmodified-Since" in
  if ius = "" || is_zero_time modtime then Cond_none
  else
    match Http_time.parse_http_time ius with
    | None -> Cond_none
    | Some t ->
        (* Last-Modified truncates sub-second precision; truncate modtime too. *)
        let modtime = Float.of_int (int_of_float (Float.floor modtime)) in
        if modtime <= t then Cond_true else Cond_false

(* Go checkIfNoneMatch. *)
let check_if_none_match w (r : Body.t Request.t) =
  let inm = Header.get r.Request.header "If-None-Match" in
  if inm = "" then Cond_none
  else begin
    let etag_hdr = Header.get (w.Server.header ()) "Etag" in
    let rec loop buf =
      let buf = trim_string buf in
      if String.length buf = 0 then Cond_true
      else if buf.[0] = ',' then loop (String.sub buf 1 (String.length buf - 1))
      else if buf.[0] = '*' then Cond_false
      else
        match scan_etag buf with
        | None -> Cond_true
        | Some (etag, remain) ->
            if etag_weak_match etag etag_hdr then Cond_false else loop remain
    in
    loop inm
  end

(* Go checkIfModifiedSince. *)
let check_if_modified_since (r : Body.t Request.t) ~modtime =
  if r.Request.meth <> "GET" && r.Request.meth <> "HEAD" then Cond_none
  else begin
    let ims = Header.get r.Request.header "If-Modified-Since" in
    if ims = "" || is_zero_time modtime then Cond_none
    else
      match Http_time.parse_http_time ims with
      | None -> Cond_none
      | Some t ->
          let modtime = Float.of_int (int_of_float (Float.floor modtime)) in
          if modtime <= t then Cond_false else Cond_true
  end

(* Go checkIfRange. *)
let check_if_range w (r : Body.t Request.t) ~modtime =
  if r.Request.meth <> "GET" && r.Request.meth <> "HEAD" then Cond_none
  else begin
    let ir = Header.get r.Request.header "If-Range" in
    if ir = "" then Cond_none
    else begin
      match scan_etag ir with
      | Some (etag, _) when etag <> "" ->
          if etag_strong_match etag (Header.get (w.Server.header ()) "Etag")
          then Cond_true
          else Cond_false
      | _ ->
          (* The If-Range value is typically the ETag, but may also be the
             modtime date. *)
          if is_zero_time modtime then Cond_false
          else
            match Http_time.parse_http_time ir with
            | None -> Cond_false
            | Some t ->
                if int_of_float t = int_of_float modtime then Cond_true
                else Cond_false
    end
  end

(* Go writeNotModified: clears representation metadata and writes 304. *)
let write_not_modified w =
  let h = w.Server.header () in
  Header.del h "Content-Type";
  Header.del h "Content-Length";
  Header.del h "Content-Encoding";
  if Header.get h "Etag" <> "" then Header.del h "Last-Modified";
  w.Server.write_header Status.status_not_modified

(* Go checkPreconditions: evaluates request preconditions and reports whether a
   precondition resulted in 304/412. Returns [(done_, range_header)]. Follows
   RFC 7232 section 6: If-Match → If-Unmodified-Since → If-None-Match →
   If-Modified-Since, then If-Range gates the Range header. *)
let check_preconditions w (r : Body.t Request.t) ~modtime =
  let ch = check_if_match w r in
  let ch =
    if ch = Cond_none then check_if_unmodified_since r ~modtime else ch
  in
  if ch = Cond_false then begin
    w.Server.write_header Status.status_precondition_failed;
    (true, "")
  end
  else begin
    match check_if_none_match w r with
    | Cond_false ->
        if r.Request.meth = "GET" || r.Request.meth = "HEAD" then begin
          write_not_modified w;
          (true, "")
        end
        else begin
          w.Server.write_header Status.status_precondition_failed;
          (true, "")
        end
    | Cond_none ->
        if check_if_modified_since r ~modtime = Cond_false then begin
          write_not_modified w;
          (true, "")
        end
        else begin
          let range_header = Header.get r.Request.header "Range" in
          let range_header =
            if range_header <> "" && check_if_range w r ~modtime = Cond_false
            then ""
            else range_header
          in
          (false, range_header)
        end
    | Cond_true ->
        let range_header = Header.get r.Request.header "Range" in
        let range_header =
          if range_header <> "" && check_if_range w r ~modtime = Cond_false then
            ""
          else range_header
        in
        (false, range_header)
  end

(* ---- MIME by extension (stand-in for mime.TypeByExtension) ---- *)

(* A small built-in extension→type table. This is a deliberate stand-in for
   Go's mime.TypeByExtension database (we do not port the mime package); the
   Sniff fallback covers everything not listed here. *)
let mime_by_ext ext =
  match String.lowercase_ascii ext with
  | ".html" | ".htm" -> Some "text/html; charset=utf-8"
  | ".css" -> Some "text/css; charset=utf-8"
  | ".js" | ".mjs" -> Some "text/javascript; charset=utf-8"
  | ".json" -> Some "application/json"
  | ".png" -> Some "image/png"
  | ".jpg" | ".jpeg" -> Some "image/jpeg"
  | ".gif" -> Some "image/gif"
  | ".svg" -> Some "image/svg+xml"
  | ".txt" -> Some "text/plain; charset=utf-8"
  | ".xml" -> Some "text/xml; charset=utf-8"
  | ".pdf" -> Some "application/pdf"
  | ".wasm" -> Some "application/wasm"
  | ".ico" -> Some "image/vnd.microsoft.icon"
  | ".woff" -> Some "font/woff"
  | ".woff2" -> Some "font/woff2"
  | _ -> None

let ext_of name =
  match String.rindex_opt name '.' with
  | Some i ->
      (* extension only if the '.' is in the final path element *)
      let after_slash =
        match String.rindex_opt name '/' with Some s -> s < i | None -> true
      in
      if after_slash then String.sub name i (String.length name - i) else ""
  | None -> ""

(* ---- setLastModified ---- *)

let set_last_modified w modtime =
  if not (is_zero_time modtime) then
    Header.set (w.Server.header ()) "Last-Modified" (Http_time.format_gmt modtime)

(* Sniff probe length, mirroring internal.SniffLen (512). *)
let sniff_len = 512

(* ---- serveContent (Ticket 3: full 200, no ranges) ---- *)

let serve_content w (r : Body.t Request.t) ~name ~modtime ~size ~read_window =
  set_last_modified w modtime;
  let done_, _range_req = check_preconditions w r ~modtime in
  (* TICKET 4 HOOK: when [done_], a precondition already wrote 304/412. *)
  if done_ then Lwt.return_unit
  else begin
    let h = w.Server.header () in
    (* Content-Type: ext table → Sniff fallback, unless the handler set it. *)
    let have_type = Header.has h "Content-Type" in
    (if have_type then Lwt.return_unit
     else
       match mime_by_ext (ext_of name) with
       | Some ctype ->
           Header.set h "Content-Type" ctype;
           Lwt.return_unit
       | None ->
           let probe = if size < Int64.of_int sniff_len then Int64.to_int size else sniff_len in
           read_window ~off:0L ~len:probe >>= fun buf ->
           Header.set h "Content-Type" (Sniff.detect_content_type buf);
           Lwt.return_unit)
    >>= fun () ->
    let code = Status.status_ok in
    Header.set h "Accept-Ranges" "bytes";
    (* TICKET 5 HOOK: parse [_range_req] here and switch [code] to 206 (single
       range / multipart/byteranges) or 416, adjusting Content-Range and the
       streamed window. For now we always send the whole file. *)
    let send_size = size in
    if Header.get h "Content-Encoding" = "" then
      Header.set h "Content-Length" (Int64.to_string send_size);
    w.Server.write_header code;
    if r.Request.meth = "HEAD" then Lwt.return_unit
    else begin
      (* Stream the whole content in bounded windows. *)
      let chunk = 32 * 1024 in
      let rec loop off remaining =
        if remaining <= 0L then Lwt.return_unit
        else begin
          let len =
            if remaining < Int64.of_int chunk then Int64.to_int remaining
            else chunk
          in
          read_window ~off ~len >>= fun data ->
          if data = "" then Lwt.return_unit
          else
            w.Server.write data >>= fun () ->
            loop
              (Int64.add off (Int64.of_int (String.length data)))
              (Int64.sub remaining (Int64.of_int (String.length data)))
        end
      in
      loop 0L send_size
    end
  end

(* ---- serveFile ---- *)

let index_page = "/index.html"

let path_base p =
  (* path.Base: last element of a '/'-path; "/" or "" → "/" or "." per Go. *)
  if p = "" then "."
  else begin
    (* strip trailing slashes *)
    let p =
      let n = ref (String.length p) in
      while !n > 0 && p.[!n - 1] = '/' do
        decr n
      done;
      if !n = 0 then "/" else String.sub p 0 !n
    in
    if p = "/" then "/"
    else
      match String.rindex_opt p '/' with
      | Some i -> String.sub p (i + 1) (String.length p - i - 1)
      | None -> p
  end

let ends_with s suffix =
  let ls = String.length s and lf = String.length suffix in
  ls >= lf && String.sub s (ls - lf) lf = suffix

let trim_suffix s suffix =
  if ends_with s suffix then String.sub s 0 (String.length s - String.length suffix)
  else s

let serve_file w (r : Body.t Request.t) (fs : file_system) name ~redirect =
  let upath = Uri.path r.Request.url in
  (* redirect .../index.html to .../ *)
  if ends_with upath index_page then local_redirect w r "./"
  else
    fs.open_ name >>= function
    | Error e ->
        let msg, code = to_http_error e in
        Server.error w msg code
    | Ok f ->
        Lwt.finalize
          (fun () ->
            f.stat () >>= fun d ->
            (* canonical-path redirects *)
            let redirected =
              if not redirect then None
              else begin
                let url = upath in
                if d.fi_is_dir then begin
                  if
                    String.length url > 0
                    && url.[String.length url - 1] <> '/'
                  then Some (`Local (path_base url ^ "/"))
                  else None
                end
                else if
                  String.length url > 0 && url.[String.length url - 1] = '/'
                then begin
                  let base = path_base url in
                  if base = "/" || base = "." then Some `NonDir
                  else Some (`Local ("../" ^ base))
                end
                else None
              end
            in
            match redirected with
            | Some `NonDir ->
                Server.error w "http: attempting to traverse a non-directory"
                  Status.status_internal_server_error
            | Some (`Local target) -> local_redirect w r target
            | None ->
                (* directory: redirect if no trailing slash, else index/list *)
                if d.fi_is_dir
                   && (upath = ""
                      || upath.[String.length upath - 1] <> '/')
                then local_redirect w r (path_base upath ^ "/")
                else begin
                  (* try index.html for a directory *)
                  (if d.fi_is_dir then begin
                     let index = trim_suffix name "/" ^ index_page in
                     fs.open_ index >>= function
                     | Ok ff ->
                         ff.stat () >>= fun dd ->
                         Lwt.return (Some (ff, dd))
                     | Error _ -> Lwt.return None
                   end
                   else Lwt.return None)
                  >>= fun index_opt ->
                  match index_opt with
                  | Some (ff, dd) when not dd.fi_is_dir ->
                      Lwt.finalize
                        (fun () ->
                          serve_content w r ~name:dd.fi_name
                            ~modtime:dd.fi_mod_time ~size:dd.fi_size
                            ~read_window:ff.read_window)
                        (fun () -> ff.close ())
                  | index_opt -> (
                      (* close an opened-but-unusable index *)
                      (match index_opt with
                      | Some (ff, _) -> ff.close ()
                      | None -> Lwt.return_unit)
                      >>= fun () ->
                      if d.fi_is_dir then begin
                        if
                          check_if_modified_since r ~modtime:d.fi_mod_time
                          = Cond_false
                        then begin
                          write_not_modified w;
                          Lwt.return_unit
                        end
                        else begin
                          set_last_modified w d.fi_mod_time;
                          dir_list w r f
                        end
                      end
                      else
                        serve_content w r ~name:d.fi_name
                          ~modtime:d.fi_mod_time ~size:d.fi_size
                          ~read_window:f.read_window)
                end)
          (fun () -> f.close ())

(* ---- FileServer ---- *)

let file_server root =
  let serve_http w (r : Body.t Request.t) =
    let upath = Uri.path r.Request.url in
    (* Go: if !strings.HasPrefix(upath, "/") { upath = "/"+upath; r.URL.Path = upath } *)
    let has_prefix = String.length upath > 0 && upath.[0] = '/' in
    let upath = if not has_prefix then "/" ^ upath else upath in
    if not has_prefix then r.Request.url <- Uri.with_path r.Request.url upath;
    let cleaned = Pattern.path_clean upath in
    serve_file w r root cleaned ~redirect:true
  in
  Server.handler_func serve_http
