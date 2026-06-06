(* Port of the form-parsing half of go/src/net/http/request.go: ParseForm,
   parsePostForm, ParseMultipartForm, FormValue, PostFormValue, FormFile, and
   the multipartReader content-type check. URL-encoded parsing is a faithful
   port via {!Values}; multipart/form-data parsing is delegated to the sans-io
   [multipart_form] core (the plan's fidelity stand-in for Go's
   mime/multipart). *)

(* defaultMaxMemory (request.go). *)
let default_max_memory = Int64.mul 32L (Int64.of_int (1 lsl 20))

type error = Form of string | Not_multipart

let error_to_string = function
  | Form s -> s
  | Not_multipart -> "request Content-Type isn't multipart/form-data"

(* Pure media-type parse keeps Go's error-as-exception shape; the
   result-returning entrypoints catch it into [Form]. *)
exception Media_type_error of string

(* ---- mime.ParseMediaType (mime/mediatype.go), trimmed to what ParseForm
   needs: the bare type (lowercased) plus the boundary parameter, and the
   "invalid media parameter" error for a parameter with no value. *)

let ascii_lower s = String.lowercase_ascii s

let trim s =
  let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
  let n = String.length s in
  let i = ref 0 and j = ref (n - 1) in
  while !i < n && is_ws s.[!i] do
    incr i
  done;
  while !j >= !i && is_ws s.[!j] do
    decr j
  done;
  if !j < !i then "" else String.sub s !i (!j - !i + 1)

(* Returns (media_type, parameters) or raises Media_type_error mirroring Go's
   "mime: <reason>" messages for the cases ParseForm exercises. *)
let parse_media_type (v : string) : string * (string * string) list =
  let base, rest =
    match String.index_opt v ';' with
    | None -> (v, "")
    | Some i ->
        (String.sub v 0 i, String.sub v (i + 1) (String.length v - i - 1))
  in
  let mediatype = ascii_lower (trim base) in
  let params = ref [] in
  let rest = ref rest in
  let continue = ref true in
  while !continue && trim !rest <> "" do
    let s = trim !rest in
    match String.index_opt s '=' with
    | None -> raise (Media_type_error "mime: invalid media parameter")
    | Some eq ->
        let key = ascii_lower (trim (String.sub s 0 eq)) in
        let after = String.sub s (eq + 1) (String.length s - eq - 1) in
        let value, remainder =
          if String.length after > 0 && after.[0] = '"' then begin
            (* quoted string *)
            let buf = Buffer.create 16 in
            let i = ref 1 and finished = ref false in
            let n = String.length after in
            while (not !finished) && !i < n do
              let c = after.[!i] in
              if c = '\\' && !i + 1 < n then begin
                Buffer.add_char buf after.[!i + 1];
                i := !i + 2
              end
              else if c = '"' then begin
                finished := true;
                incr i
              end
              else begin
                Buffer.add_char buf c;
                incr i
              end
            done;
            let rem =
              match String.index_from_opt after !i ';' with
              | None -> ""
              | Some j -> String.sub after (j + 1) (String.length after - j - 1)
            in
            (Buffer.contents buf, rem)
          end
          else begin
            let tok_end, rem =
              match String.index_opt after ';' with
              | None -> (String.length after, "")
              | Some j ->
                  (j, String.sub after (j + 1) (String.length after - j - 1))
            in
            (trim (String.sub after 0 tok_end), rem)
          end
        in
        (* Go: an empty parameter value (e.g. "boundary=") is invalid. *)
        if value = "" then
          raise (Media_type_error "mime: invalid media parameter");
        params := (key, value) :: !params;
        rest := remainder
  done;
  (mediatype, List.rev !params)

(* hasPrefix-style content-type check used by Go's multipartReader. *)
let content_type_is_multipart (mediatype : string) =
  mediatype = "multipart/form-data"

(* ---- parsePostForm: read & parse an application/x-www-form-urlencoded body. *)
let parse_post_form (r : Body.t Request.t) : Values.t * (unit, error) result =
  let ct = Header.get r.Request.header "Content-Type" in
  let ct = if ct = "" then "application/octet-stream" else ct in
  match parse_media_type ct with
  | exception Media_type_error msg -> (Values.create (), Error (Form msg))
  | mediatype, _params ->
      if mediatype = "application/x-www-form-urlencoded" then begin
        let max_form_size = Int64.of_int (10 * 1024 * 1024) in
        let b = Body.read_all r.Request.body in
        if Int64.compare (Int64.of_int (String.length b)) max_form_size > 0 then
          (Values.create (), Error (Form "http: POST too large"))
        else
          let m, res = Values.parse_query b in
          (m, Result.map_error (fun e -> Form (Values.error_to_string e)) res)
      end
      else
        (* multipart/form-data is handled elsewhere; other types are not read. *)
        (Values.create (), Ok ())

(* ParseForm: populate r.Form and r.PostForm. Idempotent. Returns the first
   error encountered (as a result) without raising, mirroring Go. *)
let parse_form (r : Body.t Request.t) : (unit, error) result =
  let err = ref (Ok ()) in
  let set_err e = match !err with Ok () -> err := e | Error _ -> () in
  (match r.Request.post_form with
  | Some _ -> ()
  | None -> (
      let meth = r.Request.meth in
      if meth = "POST" || meth = "PUT" || meth = "PATCH" then (
        let pf, res = parse_post_form r in
        set_err res;
        r.Request.post_form <- Some pf);
      match r.Request.post_form with
      | None -> r.Request.post_form <- Some (Values.create ())
      | Some _ -> ()));
  (match r.Request.form with
  | Some _ -> ()
  | None -> (
      let post_form =
        match r.Request.post_form with
        | Some pf -> pf
        | None -> Values.create ()
      in
      let form =
        if Values.length post_form > 0 then begin
          let f = Values.create () in
          Values.copy_values ~dst:f ~src:post_form;
          Some f
        end
        else None
      in
      let raw_query =
        match Uri.verbatim_query r.Request.url with Some q -> q | None -> ""
      in
      let new_values, qres = Values.parse_query raw_query in
      set_err (Result.map_error (fun e -> Form (Values.error_to_string e)) qres);
      match form with
      | None -> r.Request.form <- Some new_values
      | Some f ->
          Values.copy_values ~dst:f ~src:new_values;
          r.Request.form <- Some f));
  !err

(* ---- multipart support via the sans-io multipart_form core. *)

(* Content_type.of_string needs the value terminated with "\r\n". *)
let to_content_type (v : string) :
    (Multipart_form.Content_type.t, string) result =
  let v =
    if String.length v >= 2 && String.sub v (String.length v - 2) 2 = "\r\n"
    then v
    else v ^ "\r\n"
  in
  match Multipart_form.Content_type.of_string v with
  | Ok ct -> Ok ct
  | Error (`Msg m) -> Error m

(* Extract (name, filename) from a part's Header.t. *)
let part_meta (hdr : Multipart_form.Header.t) =
  match Multipart_form.Header.content_disposition hdr with
  | Some cd ->
      ( Multipart_form.Content_disposition.name cd,
        Multipart_form.Content_disposition.filename cd )
  | None -> (None, None)

(* Issue 45789: strip any directory path from a multipart filename
   (filepath.Base, which trims trailing separators first). *)
let base_filename name =
  let strip_trailing s =
    let n = ref (String.length s) in
    while !n > 0 && (s.[!n - 1] = '/' || s.[!n - 1] = '\\') do
      decr n
    done;
    String.sub s 0 !n
  in
  let s = strip_trailing name in
  let last_sep =
    let r = ref (-1) in
    String.iteri (fun i c -> if c = '/' || c = '\\' then r := i) s;
    !r
  in
  if last_sep < 0 then s
  else String.sub s (last_sep + 1) (String.length s - last_sep - 1)

(* multipartReader content-type check (request.go): error if not
   multipart/form-data. *)
let multipart_reader_check (r : Body.t Request.t) : (string, error) result =
  let v = Header.get r.Request.header "Content-Type" in
  if v = "" then Error Not_multipart
  else
    match parse_media_type v with
    | exception Media_type_error msg -> Error (Form msg)
    | mediatype, _ ->
        if content_type_is_multipart mediatype then Ok v
        else Error Not_multipart

(* Adapt a Body.t to multipart_form's [string stream] (unit -> string option),
   pulling chunks lazily so the body is not materialised. *)
let body_stream (b : Body.t) : unit -> string option =
  match b with
  | Body.Empty -> fun () -> None
  | Body.String s ->
      let sent = ref false in
      fun () ->
        if !sent then None
        else (
          sent := true;
          Some s)
  | Body.Stream next -> next

(* Per-part storage accumulated by the streaming emitter (formdata.go:140-208):
   bytes go to [buf] until the running [remaining] memory budget would be
   exceeded, then the part spills to a temp file at [tmpfile] and subsequent
   bytes are written straight to disk. [spilled] marks parts kept on disk. *)
type part_store = {
  ps_header : Multipart_form.Header.t;
  buf : Buffer.t;
  mutable tmpfile : string option;
  mutable oc : out_channel option;
  mutable spilled : bool;
}

(* Build the streaming [emitters]: for each part return a pusher that enforces
   the shared [remaining] budget, spilling the overflow to os.CreateTemp
   (formdata.go:177). [stores] collects every part so the tree leaves (the
   [part_store] ids) can be drained and so temp files can be cleaned on error. *)
let make_emitters ~max_memory ~(stores : part_store list ref) :
    part_store Multipart_form.emitters =
  let remaining = ref max_memory in
  fun header ->
    let st =
      {
        ps_header = header;
        buf = Buffer.create 256;
        tmpfile = None;
        oc = None;
        spilled = false;
      }
    in
    stores := st :: !stores;
    let push = function
      | None -> ( match st.oc with Some oc -> close_out oc | None -> ())
      | Some (chunk : string) -> (
          match st.oc with
          | Some oc -> output_string oc chunk (* already spilled *)
          | None ->
              let len = Int64.of_int (String.length chunk) in
              if Int64.compare len !remaining <= 0 then begin
                Buffer.add_string st.buf chunk;
                remaining := Int64.sub !remaining len
              end
              else begin
                (* Budget exhausted: spill this part to a temp file. *)
                let path = Filename.temp_file "multipart-" "" in
                let oc = open_out_bin path in
                output_string oc (Buffer.contents st.buf);
                Buffer.clear st.buf;
                output_string oc chunk;
                st.tmpfile <- Some path;
                st.oc <- Some oc;
                st.spilled <- true;
                remaining := 0L
              end)
    in
    (push, st)

(* ParseMultipartForm: parse a multipart/form-data body, merging text values
   into Form and PostForm (Issue 9305). Calls parse_form first. Returns the
   parse error, but a ParseForm error is deferred to the end like Go. File parts
   over [max_memory] are spilled to temp files (cleaned up via the request
   switch / {!Request.remove_multipart_temp_files}). *)
let parse_multipart_form (r : Body.t Request.t) ~(max_memory : int64) :
    (unit, error) result =
  match r.Request.multipart_form with
  | Some _ -> Ok ()
  | None -> (
      let parse_form_err =
        match r.Request.form with Some _ -> Ok () | None -> parse_form r
      in
      match multipart_reader_check r with
      | Error e -> Error e
      | Ok ct_value -> (
          match to_content_type ct_value with
          | Error m -> Error (Form m)
          | Ok content_type -> (
              let stream = body_stream r.Request.body in
              let stores = ref [] in
              let emitters = make_emitters ~max_memory ~stores in
              let step = Multipart_form.parse ~emitters content_type in
              let rec loop () =
                match
                  step
                    (match stream () with Some s -> `String s | None -> `Eof)
                with
                | `Continue -> loop ()
                | `Done tree -> Ok tree
                | `Fail m -> Error (`Msg m)
              in
              (* On any failure mid-stream, unlink whatever already spilled. *)
              let cleanup_stores () =
                List.iter
                  (fun st ->
                    (match st.oc with
                    | Some oc -> ( try close_out oc with _ -> ())
                    | None -> ());
                    match st.tmpfile with
                    | Some p -> ( try Sys.remove p with Sys_error _ -> ())
                    | None -> ())
                  !stores
              in
              match loop () with
              | Error (`Msg m) ->
                  cleanup_stores ();
                  Error (Form m)
              | Ok tree ->
                  let value = Values.create () in
                  let file : (string, Request.file_header list) Hashtbl.t =
                    Hashtbl.create 8
                  in
                  List.iter
                    (fun (elt : part_store Multipart_form.elt) ->
                      let st = elt.Multipart_form.body in
                      let name, filename = part_meta st.ps_header in
                      match (name, filename) with
                      | Some n, None ->
                          (* value part: always materialised in memory; a value
                             that spilled is read back and its temp file unlinked
                             (Go keeps form.Value as strings). *)
                          let v =
                            match st.tmpfile with
                            | None -> Buffer.contents st.buf
                            | Some p ->
                                let ic = open_in_bin p in
                                let len = in_channel_length ic in
                                let s = really_input_string ic len in
                                close_in ic;
                                (try Sys.remove p with Sys_error _ -> ());
                                st.tmpfile <- None;
                                s
                          in
                          Values.add value n v
                      | Some n, Some fn ->
                          let fh =
                            {
                              Request.filename = base_filename fn;
                              fh_header = [];
                              content =
                                (if st.spilled then ""
                                 else Buffer.contents st.buf);
                              tmpfile = st.tmpfile;
                            }
                          in
                          let existing =
                            Option.value ~default:[] (Hashtbl.find_opt file n)
                          in
                          Hashtbl.replace file n (existing @ [ fh ])
                      | None, _ -> ())
                    (Multipart_form.flatten tree);
                  let mf = { Request.value; file } in
                  (* Merge text values into Form and PostForm (Issue 9305). *)
                  let form =
                    match r.Request.form with
                    | Some f -> f
                    | None ->
                        let f = Values.create () in
                        r.Request.form <- Some f;
                        f
                  in
                  let post_form =
                    match r.Request.post_form with
                    | Some pf -> pf
                    | None ->
                        let pf = Values.create () in
                        r.Request.post_form <- Some pf;
                        pf
                  in
                  Hashtbl.iter
                    (fun k vs ->
                      List.iter
                        (fun v ->
                          Values.add form k v;
                          Values.add post_form k v)
                        vs)
                    value;
                  r.Request.multipart_form <- Some mf;
                  (* Defer the ParseForm error like Go (return parseFormErr). *)
                  parse_form_err)))

(* Form.RemoveAll: drop the spilled temp files for [r]'s multipart form. *)
let remove_all (r : Body.t Request.t) : unit =
  Request.remove_multipart_temp_files r

(* ---- FormValue / PostFormValue / FormFile: lazily parse, ignoring errors. *)

let try_parse_multipart (r : Body.t Request.t) : unit =
  try ignore (parse_multipart_form r ~max_memory:default_max_memory)
  with _ -> ()

let ensure_parsed_for_form (r : Body.t Request.t) : unit =
  match r.Request.form with Some _ -> () | None -> try_parse_multipart r

let form_value (r : Body.t Request.t) (key : string) : string =
  ensure_parsed_for_form r;
  match r.Request.form with Some f -> Values.get f key | None -> ""

let post_form_value (r : Body.t Request.t) (key : string) : string =
  (match r.Request.post_form with
  | Some _ -> ()
  | None -> try_parse_multipart r);
  match r.Request.post_form with Some pf -> Values.get pf key | None -> ""

(* FormFile: simplified to (filename, content) of the first file for [key]. A
   part that spilled is read back from its temp file (Go's FileHeader.Open). *)
let form_file (r : Body.t Request.t) (key : string) : (string * string) option =
  (match r.Request.multipart_form with
  | Some _ -> ()
  | None -> try_parse_multipart r);
  match r.Request.multipart_form with
  | None -> None
  | Some mf -> (
      match Hashtbl.find_opt mf.Request.file key with
      | Some (fh :: _) ->
          let content =
            match fh.Request.tmpfile with
            | None -> fh.Request.content
            | Some p ->
                let ic = open_in_bin p in
                let len = in_channel_length ic in
                let s = really_input_string ic len in
                close_in ic;
                s
          in
          Some (fh.Request.filename, content)
      | _ -> None)
