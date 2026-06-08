(* Port of the core file-serving path of go/src/net/http/fs.go. See fs.mli for
   the surface. Direct-style over Eio: file IO uses the [Eio.Path] capability. *)

(* [path_clean] (Go's path.Clean) lives with the routing internals. *)
module Pattern = Httpg_internal.Pattern

type file_info = {
  fi_name : string;
  fi_size : int64;
  fi_mod_time : float;
  fi_is_dir : bool;
}

type file = {
  stat : unit -> file_info;
  read_window : off:int64 -> len:int -> string;
  readdir : unit -> file_info list;
  close : unit -> unit;
}

type error =
  | Invalid_unsafe_path
  | Not_exist
  | Permission
  | Other of string
  | No_overlap
  | Invalid_range of string

let error_to_string = function
  | Invalid_unsafe_path -> "http: invalid or unsafe file path"
  | Not_exist -> "file does not exist"
  | Permission -> "permission denied"
  | Other s -> s
  | No_overlap -> "invalid range: failed to overlap"
  | Invalid_range s -> if s = "" then "invalid range" else s

type file_system = { open_ : sw:Eio.Switch.t -> string -> (file, error) result }

(* Build a response carrying [header] (taken verbatim), [body], and [status].
   [content_length] defaults to the body's known length ([Stream] → -1, i.e.
   chunked/close), but byte-range responses pass an explicit length so the
   stream is sent with an exact Content-Length. proto is left HTTP/1.1; the
   serve loop derives the wire proto from the request. *)
let respond ~header ?(body = Body.Empty) ?content_length status : Response.t =
  let content_length =
    match content_length with
    | Some n -> n
    | None -> (
        match body with
        | Body.String s -> Int64.of_int (String.length s)
        | Body.Empty -> 0L
        | Body.Stream _ -> -1L)
  in
  {
    Response.status;
    proto = Httpg_base.Protocol.Http11;
    header;
    body;
    content_length;
    transfer_encoding = [];
    close = false;
    uncompressed = false;
    trailer = None;
    request = None;
  }

(* Internal sentinel: [parse_range] raises this on a malformed Range header and
   [parse_range] maps it back to [Error (Invalid_range _)] at the boundary. *)
exception Invalid_range_sentinel of string

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

(* ---- Dir (Eio filesystem capability) ---- *)

let file_info_of_stat name (st : Eio.File.Stat.t) =
  {
    fi_name = name;
    fi_size = Int64.of_int (Optint.Int63.to_int st.Eio.File.Stat.size);
    fi_mod_time = st.Eio.File.Stat.mtime;
    fi_is_dir = st.Eio.File.Stat.kind = `Directory;
  }

(* Map an Eio IO failure to a handleable {!error}, mirroring Go's
   os.IsNotExist / os.IsPermission classification. *)
let error_of_exn = function
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Not_exist
  | Eio.Io (Eio.Fs.E (Eio.Fs.Permission_denied _), _) -> Permission
  | e -> Other (Printexc.to_string e)

(* Build a {!file} over a path under the root capability. A regular file is
   opened ONCE under [sw] (Go's os.Open at fs.go:92); each [read_window] is a
   pread into the single handle (Go's Seek+CopyN, fs.go:360,387,430). [close]
   releases the handle and [sw] teardown is the backstop, so the fd never
   outlives the serve on any path (EOF, abandon, error, cancel). Directories
   carry no handle. *)
let file_of_path ~sw (path : _ Eio.Path.t) base : (file, error) result =
  try
    let st = Eio.Path.stat ~follow:true path in
    let info = file_info_of_stat base st in
    if info.fi_is_dir then begin
      let readdir () =
        Eio.Path.read_dir path
        |> List.filter_map (fun name ->
            match Eio.Path.stat ~follow:true Eio.Path.(path / name) with
            | st -> Some (file_info_of_stat name st)
            (* like os.File.Readdir: skip entries that vanish. *)
            | exception _ -> None)
      in
      Ok
        {
          stat = (fun () -> info);
          read_window = (fun ~off:_ ~len:_ -> "");
          readdir;
          close = (fun () -> ());
        }
    end
    else begin
      let flow = Eio.Path.open_in ~sw path in
      let closed = ref false in
      let read_window ~off ~len =
        let buf = Cstruct.create len in
        let rec loop got =
          if got >= len then got
          else
            match
              Eio.File.pread flow
                ~file_offset:
                  (Optint.Int63.of_int64 (Int64.add off (Int64.of_int got)))
                [ Cstruct.sub buf got (len - got) ]
            with
            | 0 -> got
            | n -> loop (got + n)
            | exception End_of_file -> got
        in
        let got = loop 0 in
        Cstruct.to_string (Cstruct.sub buf 0 got)
      in
      let close () =
        if not !closed then begin
          closed := true;
          Eio.Resource.close flow
        end
      in
      Ok
        {
          stat = (fun () -> info);
          read_window;
          readdir = (fun () -> failwith "not a directory");
          close;
        }
    end
  with e -> Error (error_of_exn e)

let dir (root : Eio.Fs.dir_ty Eio.Path.t) =
  let open_ ~sw name =
    (* path.Clean("/" + name)[1:] *)
    let cleaned = Pattern.path_clean ("/" ^ name) in
    let path =
      if String.length cleaned >= 1 then
        String.sub cleaned 1 (String.length cleaned - 1)
      else ""
    in
    let path = if path = "" then "." else path in
    (* filepath.Localize rejects paths that escape (".." element). *)
    if contains_dot_dot path then Error Invalid_unsafe_path
    else file_of_path ~sw Eio.Path.(root / path) (Filename.basename path)
  in
  { open_ }

(* ---- toHTTPError / localRedirect ---- *)

let to_http_error = function
  | Not_exist | Invalid_unsafe_path ->
      ("404 page not found", Httpg_base.Status.NotFound)
  | Permission -> ("403 Forbidden", Httpg_base.Status.Forbidden)
  | No_overlap | Invalid_range _ | Other _ ->
      ("500 Internal Server Error", Httpg_base.Status.InternalServerError)

let local_redirect (r : Request.t) new_path : Response.t =
  let new_path =
    match Uri.verbatim_query r.Request.url with
    | Some q when q <> "" -> new_path ^ "?" ^ q
    | _ -> new_path
  in
  let h = Header.set (Header.create ()) "Location" new_path in
  respond ~header:h Httpg_base.Status.MovedPermanently

(* ---- dirList ---- *)

(* Go's url.URL{Path: name}.String(): percent-escape a path segment so that
   '?'/'#'/etc remain part of the path, not a query/fragment. *)
let escape_path_href name = Uri.pct_encode ~component:`Path name

(* Go's htmlReplacer (the escaper dirList uses for the link text). *)
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

let dir_list (_r : Request.t) (f : file) : Response.t =
  match f.readdir () with
  | exception _ ->
      Server.error "Error reading directory"
        Httpg_base.Status.InternalServerError
  | entries ->
      let entries =
        List.sort (fun a b -> compare a.fi_name b.fi_name) entries
      in
      let buf = Buffer.create 256 in
      Buffer.add_string buf "<!doctype html>\n";
      Buffer.add_string buf
        "<meta name=\"viewport\" content=\"width=device-width\">\n";
      Buffer.add_string buf "<pre>\n";
      List.iter
        (fun e ->
          let name = if e.fi_is_dir then e.fi_name ^ "/" else e.fi_name in
          let href = escape_path_href name in
          Buffer.add_string buf
            ("<a href=\"" ^ href ^ "\">" ^ html_escape name ^ "</a>\n"))
        entries;
      Buffer.add_string buf "</pre>\n";
      let h =
        Header.set (Header.create ()) "Content-Type" "text/html; charset=utf-8"
      in
      respond ~header:h
        ~body:(Body.String (Buffer.contents buf))
        Httpg_base.Status.Ok

(* ---- preconditions (Go fs.go: checkPreconditions + helpers) ---- *)

(* Go isZeroTime: t is obviously unspecified (zero or Unix()=0). Our modtime is
   Unix-epoch seconds, so both collapse to 0.0. *)
let is_zero_time t = t = 0.0

(* textproto.TrimString: trim leading/trailing ' ' and '\t'. *)
let trim_string = Httpg_base.Textproto.trim_string

let has_prefix s p =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* Go scanETag: Some (etag, remain) if a syntactically valid ETag (W/"text" or
   "text", RFC 7232 2.3) is present at the start of [s] (after trimming). *)
let scan_etag s =
  let s = trim_string s in
  let n = String.length s in
  let start = if n >= 2 && s.[0] = 'W' && s.[1] = '/' then 2 else 0 in
  if n - start < 2 || s.[start] <> '"' then None
  else begin
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
let etag_strong_match a b = a = b && a <> "" && a.[0] = '"'

(* Go etagWeakMatch: strings.TrimPrefix(a,"W/") == strings.TrimPrefix(b,"W/"). *)
let etag_weak_match a b =
  let strip s =
    if String.length s >= 2 && s.[0] = 'W' && s.[1] = '/' then
      String.sub s 2 (String.length s - 2)
    else s
  in
  strip a = strip b

type cond_result = Cond_none | Cond_true | Cond_false

(* Go checkIfMatch. *)
let check_if_match ~etag (r : Request.t) =
  let im = Header.get r.Request.header "If-Match" in
  if im = "" then Cond_none
  else begin
    let etag_hdr = etag in
    let rec loop im =
      let im = trim_string im in
      if String.length im = 0 then Cond_false
      else if im.[0] = ',' then loop (String.sub im 1 (String.length im - 1))
      else if im.[0] = '*' then Cond_true
      else
        match scan_etag im with
        | None -> Cond_false
        | Some (etag, remain) ->
            if etag_strong_match etag etag_hdr then Cond_true else loop remain
    in
    loop im
  end

(* Go checkIfUnmodifiedSince. *)
let check_if_unmodified_since (r : Request.t) ~modtime =
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
let check_if_none_match ~etag (r : Request.t) =
  let inm = Header.get r.Request.header "If-None-Match" in
  if inm = "" then Cond_none
  else begin
    let etag_hdr = etag in
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
let check_if_modified_since (r : Request.t) ~modtime =
  if
    r.Request.meth <> Httpg_base.Method.Get
    && r.Request.meth <> Httpg_base.Method.Head
  then Cond_none
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
let check_if_range ~etag (r : Request.t) ~modtime =
  if
    r.Request.meth <> Httpg_base.Method.Get
    && r.Request.meth <> Httpg_base.Method.Head
  then Cond_none
  else begin
    let ir = Header.get r.Request.header "If-Range" in
    if ir = "" then Cond_none
    else
      begin match scan_etag ir with
      | Some (etag', _) when etag' <> "" ->
          if etag_strong_match etag' etag then Cond_true else Cond_false
      | _ -> (
          if
            (* The If-Range value is typically the ETag, but may also be the
             modtime date. *)
            is_zero_time modtime
          then Cond_false
          else
            match Http_time.parse_http_time ir with
            | None -> Cond_false
            | Some t ->
                if int_of_float t = int_of_float modtime then Cond_true
                else Cond_false)
      end
  end

(* Go writeNotModified: clears representation metadata and writes 304. *)
(* Go writeNotModified: a 304 response, clearing representation metadata from
   the response header built so far. *)
let not_modified_response header : Response.t =
  let h = header in
  let h = Header.del h "Content-Type" in
  let h = Header.del h "Content-Length" in
  let h = Header.del h "Content-Encoding" in
  let h =
    if Header.get h "Etag" <> "" then Header.del h "Last-Modified" else h
  in
  respond ~header:h Httpg_base.Status.NotModified

(* Go checkPreconditions: evaluate request preconditions. Returns either a
   short-circuit 304/412 [`Done] response or the (If-Range-gated) [`Range]
   header to use for the body. RFC 7232 §6: If-Match → If-Unmodified-Since →
   If-None-Match → If-Modified-Since, then If-Range gates Range. [header] is the
   response header built so far (carrying Etag/Last-Modified); [etag] is its
   Etag. *)
let check_preconditions ~header ~etag (r : Request.t) ~modtime :
    [ `Done of Response.t | `Range of string ] =
  let precondition_failed () =
    `Done (respond ~header Httpg_base.Status.PreconditionFailed)
  in
  let gated_range () =
    let range_header = Header.get r.Request.header "Range" in
    if range_header <> "" && check_if_range ~etag r ~modtime = Cond_false then
      `Range ""
    else `Range range_header
  in
  let ch = check_if_match ~etag r in
  let ch =
    if ch = Cond_none then check_if_unmodified_since r ~modtime else ch
  in
  if ch = Cond_false then precondition_failed ()
  else
    match check_if_none_match ~etag r with
    | Cond_false ->
        if
          r.Request.meth = Httpg_base.Method.Get
          || r.Request.meth = Httpg_base.Method.Head
        then `Done (not_modified_response header)
        else precondition_failed ()
    | Cond_none ->
        if check_if_modified_since r ~modtime = Cond_false then
          `Done (not_modified_response header)
        else gated_range ()
    | Cond_true -> gated_range ()

(* ---- byte ranges (Go fs.go: httpRange / parseRange / mimeHeader) ---- *)

type http_range = { start : int64; length : int64 }

(* Go httpRange.contentRange: "bytes START-END/SIZE". *)
let content_range ra size =
  Printf.sprintf "bytes %Ld-%Ld/%Ld" ra.start
    (Int64.sub (Int64.add ra.start ra.length) 1L)
    size

(* Go httpRange.mimeHeader: keys emitted in sorted order (Content-Range <
   Content-Type), mirroring multipart.Writer.CreatePart. *)
let mime_header ra ~content_type ~size =
  [ ("Content-Range", content_range ra size); ("Content-Type", content_type) ]

(* Go strconv.ParseInt(s, 10, 64) for a non-negative decimal. *)
let parse_int64 s =
  if s = "" then None
  else
    let ok = ref true in
    String.iter (fun c -> if c < '0' || c > '9' then ok := false) s;
    if not !ok then None
    else match Int64.of_string_opt s with Some _ as r -> r | None -> None

(* Go parseRange: parse a Range header per RFC 7233. *)
let parse_range s size =
  if s = "" then Ok []
  else
    let b = "bytes=" in
    if not (has_prefix s b) then Error (Invalid_range "")
    else
      begin try
        let body =
          String.sub s (String.length b) (String.length s - String.length b)
        in
        let parts = String.split_on_char ',' body in
        let no_overlap = ref false in
        let ranges =
          List.fold_left
            (fun acc ra ->
              let ra = trim_string ra in
              if ra = "" then acc
              else
                begin match String.index_opt ra '-' with
                | None -> raise (Invalid_range_sentinel "")
                | Some dash ->
                    let start = trim_string (String.sub ra 0 dash) in
                    let end_ =
                      trim_string
                        (String.sub ra (dash + 1) (String.length ra - dash - 1))
                    in
                    if start = "" then begin
                      (* suffix-length: last N bytes *)
                      if end_ = "" || end_.[0] = '-' then
                        raise (Invalid_range_sentinel "");
                      match parse_int64 end_ with
                      | None -> raise (Invalid_range_sentinel "")
                      | Some i ->
                          let i = if i > size then size else i in
                          let st = Int64.sub size i in
                          { start = st; length = Int64.sub size st } :: acc
                    end
                    else
                      begin match parse_int64 start with
                      | None -> raise (Invalid_range_sentinel "")
                      | Some i ->
                          if i >= size then begin
                            no_overlap := true;
                            acc
                          end
                          else begin
                            let st = i in
                            if end_ = "" then
                              { start = st; length = Int64.sub size st } :: acc
                            else
                              match parse_int64 end_ with
                              | None -> raise (Invalid_range_sentinel "")
                              | Some j ->
                                  if st > j then
                                    raise (Invalid_range_sentinel "");
                                  let j =
                                    if j >= size then Int64.sub size 1L else j
                                  in
                                  {
                                    start = st;
                                    length = Int64.add (Int64.sub j st) 1L;
                                  }
                                  :: acc
                          end
                      end
                end)
            [] parts
        in
        let ranges = List.rev ranges in
        if !no_overlap && ranges = [] then Error No_overlap else Ok ranges
      with Invalid_range_sentinel m -> Error (Invalid_range m)
      end

let sum_ranges_size ranges =
  List.fold_left (fun acc ra -> Int64.add acc ra.length) 0L ranges

(* Fixed multipart boundary (Go uses a random 30-hex one; a fixed token keeps
   responses deterministic for tests). *)
let multipart_boundary = "HTTPG_BYTERANGES_BOUNDARY"

(* Go rangesMIMESize: total encoded size of a multipart/byteranges body. *)
let ranges_mime_size ranges ~content_type ~size =
  let buf = Buffer.create 256 in
  List.iteri
    (fun idx ra ->
      if idx = 0 then
        Buffer.add_string buf (Printf.sprintf "--%s\r\n" multipart_boundary)
      else
        Buffer.add_string buf (Printf.sprintf "\r\n--%s\r\n" multipart_boundary);
      List.iter
        (fun (k, v) -> Buffer.add_string buf (Printf.sprintf "%s: %s\r\n" k v))
        (mime_header ra ~content_type ~size);
      Buffer.add_string buf "\r\n")
    ranges;
  Buffer.add_string buf (Printf.sprintf "\r\n--%s--\r\n" multipart_boundary);
  let framing = Int64.of_int (Buffer.length buf) in
  Int64.add framing (sum_ranges_size ranges)

(* ---- MIME by extension (stand-in for mime.TypeByExtension) ---- *)

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
      let after_slash =
        match String.rindex_opt name '/' with Some s -> s < i | None -> true
      in
      if after_slash then String.sub name i (String.length name - i) else ""
  | None -> ""

(* ---- setLastModified ---- *)

(* Set Last-Modified on the response header being built (mutates [h]). *)
let set_last_modified h modtime =
  if not (is_zero_time modtime) then
    Header.set h "Last-Modified" (Http_time.format_gmt modtime)
  else h

(* Sniff probe length, mirroring internal.SniffLen (512). *)
let sniff_len = 512

(* ---- serveContent ---- *)

(* A streaming body over the byte window [start, start+length), read in bounded
   chunks (Go's io.CopyN over a seeked reader). The serve loop pulls it after the
   handler returns; the file stays open under the request switch until then. *)
let window_body ~read_window ~start ~length : Body.t =
  let chunk = 32 * 1024 in
  let off = ref start and remaining = ref length in
  Body.of_stream (fun () ->
      if !remaining <= 0L then None
      else begin
        let len =
          if !remaining < Int64.of_int chunk then Int64.to_int !remaining
          else chunk
        in
        let data = read_window ~off:!off ~len in
        if data = "" then None
        else begin
          off := Int64.add !off (Int64.of_int (String.length data));
          remaining := Int64.sub !remaining (Int64.of_int (String.length data));
          Some data
        end
      end)

(* Full-body 200 path (no range, or range ignored). *)
let serve_full (r : Request.t) ~h ~size ~read_window : Response.t =
  let h = Header.set h "Accept-Ranges" "bytes" in
  (* Go sends Content-Length only when there is no Content-Encoding. *)
  let content_length =
    if Header.get h "Content-Encoding" = "" then size else -1L
  in
  let body =
    if r.Request.meth = Httpg_base.Method.Head then Body.Empty
    else window_body ~read_window ~start:0L ~length:size
  in
  respond ~header:h ~body ~content_length Httpg_base.Status.Ok

let serve_content ?(header = Header.create ()) (r : Request.t) ~name ~modtime
    ~size ~read_window : Response.t =
  (* [header] carries caller-set fields (e.g. Etag, an explicit Content-Type).
     [h] is the response header we build up (a persistent value held in a ref so
     the conditional sets below read naturally). *)
  let h = ref (set_last_modified header modtime) in
  let etag = Header.get !h "Etag" in
  match check_preconditions ~header:!h ~etag r ~modtime with
  | `Done resp -> resp
  | `Range range_req ->
      (* Content-Type: ext table → Sniff fallback, unless the caller set it. *)
      (if not (Header.has !h "Content-Type") then
         match mime_by_ext (ext_of name) with
         | Some ctype -> h := Header.set !h "Content-Type" ctype
         | None ->
             let probe =
               if size < Int64.of_int sniff_len then Int64.to_int size
               else sniff_len
             in
             let buf = read_window ~off:0L ~len:probe in
             h := Header.set !h "Content-Type" (Sniff.detect_content_type buf));
      let ctype = Header.get !h "Content-Type" in
      let is_head = r.Request.meth = Httpg_base.Method.Head in
      (* parse the (If-Range-gated) Range header, then dispatch
         full-200 / single-206 / multipart-206 / 416. *)
      let range_error msg =
        Server.error msg Httpg_base.Status.RequestedRangeNotSatisfiable
      in
      begin match parse_range range_req size with
      | Error No_overlap when size = 0L ->
          (* Empty file + unsatisfiable range: ignore the range, serve 200. *)
          serve_full r ~h:!h ~size ~read_window
      | Error No_overlap ->
          range_error "invalid range: failed to overlap"
          |> Response.with_set_header "Content-Range"
               (Printf.sprintf "bytes */%Ld" size)
      | Error _ -> range_error "invalid range"
      | Ok ranges -> (
          (* If the total range size exceeds the file, treat as no range (Go). *)
          let ranges = if sum_ranges_size ranges > size then [] else ranges in
          h := Header.set !h "Accept-Ranges" "bytes";
          match ranges with
          | [] -> serve_full r ~h:!h ~size ~read_window
          | [ ra ] ->
              (* single range → 206 + Content-Range *)
              h := Header.set !h "Content-Range" (content_range ra size);
              let body =
                if is_head then Body.Empty
                else window_body ~read_window ~start:ra.start ~length:ra.length
              in
              respond ~header:!h ~body ~content_length:ra.length
                Httpg_base.Status.PartialContent
          | ranges ->
              (* multiple ranges → 206 multipart/byteranges *)
              let send_size =
                ranges_mime_size ranges ~content_type:ctype ~size
              in
              h :=
                Header.set !h "Content-Type"
                  ("multipart/byteranges; boundary=" ^ multipart_boundary);
              let body =
                if is_head then Body.Empty
                else
                  let parts =
                    List.concat
                      (List.mapi
                         (fun idx ra ->
                           let prefix =
                             if idx = 0 then
                               Printf.sprintf "--%s\r\n" multipart_boundary
                             else
                               Printf.sprintf "\r\n--%s\r\n" multipart_boundary
                           in
                           let hdrs =
                             List.fold_left
                               (fun acc (k, v) ->
                                 acc ^ Printf.sprintf "%s: %s\r\n" k v)
                               ""
                               (mime_header ra ~content_type:ctype ~size)
                           in
                           [
                             Body.String (prefix ^ hdrs ^ "\r\n");
                             window_body ~read_window ~start:ra.start
                               ~length:ra.length;
                           ])
                         ranges)
                  in
                  Body.concat
                    (parts
                    @ [
                        Body.String
                          (Printf.sprintf "\r\n--%s--\r\n" multipart_boundary);
                      ])
              in
              respond ~header:!h ~body ~content_length:send_size
                Httpg_base.Status.PartialContent)
      end

(* ---- serveFile ---- *)

let index_page = "/index.html"

let path_base p =
  (* path.Base: last element of a '/'-path; "/" or "" → "/" or "." per Go. *)
  if p = "" then "."
  else begin
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
  if ends_with s suffix then
    String.sub s 0 (String.length s - String.length suffix)
  else s

(* The request switch [~sw] owns any file opened here: a served body is a
   {!Body.Stream} the serve loop pulls *after* this returns, so the fd must
   outlive the call — [~sw] (released once the response is sent) replaces Go's
   [defer f.Close]. *)
let serve_file ~sw (r : Request.t) (fs : file_system) name ~redirect :
    Response.t =
  let upath = Uri.path r.Request.url in
  (* redirect .../index.html to .../ *)
  if ends_with upath index_page then local_redirect r "./"
  else
    match fs.open_ ~sw name with
    | Error e ->
        let msg, code = to_http_error e in
        Server.error msg code
    | Ok f -> (
        let d = f.stat () in
        (* canonical-path redirects *)
        let redirected =
          if not redirect then None
          else begin
            let url = upath in
            if d.fi_is_dir then
              begin if
                String.length url > 0 && url.[String.length url - 1] <> '/'
              then Some (`Local (path_base url ^ "/"))
              else None
              end
            else if String.length url > 0 && url.[String.length url - 1] = '/'
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
            Server.error "http: attempting to traverse a non-directory"
              Httpg_base.Status.InternalServerError
        | Some (`Local target) -> local_redirect r target
        | None ->
            (* directory: redirect if no trailing slash, else index/list *)
            if
              d.fi_is_dir
              && (upath = "" || upath.[String.length upath - 1] <> '/')
            then local_redirect r (path_base upath ^ "/")
            else begin
              (* try index.html for a directory *)
              let index_opt =
                if d.fi_is_dir then begin
                  let index = trim_suffix name "/" ^ index_page in
                  match fs.open_ ~sw index with
                  | Ok ff -> Some (ff, ff.stat ())
                  | Error _ -> None
                end
                else None
              in
              match index_opt with
              | Some (ff, dd) when not dd.fi_is_dir ->
                  serve_content r ~name:dd.fi_name ~modtime:dd.fi_mod_time
                    ~size:dd.fi_size ~read_window:ff.read_window
              | _ ->
                  if d.fi_is_dir then
                    if
                      check_if_modified_since r ~modtime:d.fi_mod_time
                      = Cond_false
                    then not_modified_response (Header.create ())
                    else begin
                      let resp = dir_list r f in
                      if is_zero_time d.fi_mod_time then resp
                      else
                        Response.with_set_header "Last-Modified"
                          (Http_time.format_gmt d.fi_mod_time)
                          resp
                    end
                  else
                    serve_content r ~name:d.fi_name ~modtime:d.fi_mod_time
                      ~size:d.fi_size ~read_window:f.read_window
            end)

(* ---- FileServer ---- *)

let file_server root =
  let serve_http ~sw (r : Request.t) =
    let upath = Uri.path r.Request.url in
    (* Go: if !strings.HasPrefix(upath, "/") { upath = "/"+upath; r.URL.Path = upath } *)
    let has_prefix = String.length upath > 0 && upath.[0] = '/' in
    let upath = if not has_prefix then "/" ^ upath else upath in
    if not has_prefix then r.Request.url <- Uri.with_path r.Request.url upath;
    let cleaned = Pattern.path_clean upath in
    serve_file ~sw r root cleaned ~redirect:true
  in
  serve_http
