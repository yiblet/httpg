(* Port of the form-parsing half of go/src/net/http/request.go (deferred from
   Ticket 6): ParseForm, parsePostForm, ParseMultipartForm, FormValue,
   PostFormValue, FormFile, and the multipartReader content-type check.

   URL-encoded (application/x-www-form-urlencoded) parsing is ported faithfully
   via {!Values}. multipart/form-data parsing is delegated to the
   [multipart_form-lwt] opam library (the one intentional fidelity stand-in for
   Go's hand-rolled mime/multipart, per the plan's deviation note). *)

let ( >>= ) = Lwt.bind
let ( >|= ) p f = Lwt.map f p

(* defaultMaxMemory (request.go). *)
let default_max_memory = Int64.mul 32L (Int64.of_int (1 lsl 20))

exception Form_error of string

(* ---- mime.ParseMediaType (mime/mediatype.go), trimmed to what ParseForm
   needs: the bare type (lowercased) plus the boundary parameter, and the
   "invalid media parameter" error for a parameter with no value. *)

let ascii_lower s = String.lowercase_ascii s

let trim s =
  let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
  let n = String.length s in
  let i = ref 0 and j = ref (n - 1) in
  while !i < n && is_ws s.[!i] do incr i done;
  while !j >= !i && is_ws s.[!j] do decr j done;
  if !j < !i then "" else String.sub s !i (!j - !i + 1)

(* Returns (media_type, parameters) or raises Form_error mirroring Go's
   "mime: <reason>" messages for the cases ParseForm exercises. *)
let parse_media_type (v : string) : string * (string * string) list =
  let base, rest =
    match String.index_opt v ';' with
    | None -> (v, "")
    | Some i -> (String.sub v 0 i, String.sub v (i + 1) (String.length v - i - 1))
  in
  let mediatype = ascii_lower (trim base) in
  (* Parse parameters, "; key=value" repeated. We only need to validate them
     and surface the empty-value error; values are returned as-is. *)
  let params = ref [] in
  let rest = ref rest in
  let continue = ref true in
  while !continue && trim !rest <> "" do
    let s = trim !rest in
    (* split key=... *)
    match String.index_opt s '=' with
    | None ->
      (* a parameter with no '=' : Go treats as invalid media parameter *)
      raise (Form_error "mime: invalid media parameter")
    | Some eq ->
      let key = ascii_lower (trim (String.sub s 0 eq)) in
      let after = String.sub s (eq + 1) (String.length s - eq - 1) in
      ignore key;
      (* value: quoted-string or token, then up to next ';' *)
      let after = (* leading spaces already trimmed by [trim s] *) after in
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
          (* skip to next ';' *)
          let rem =
            match String.index_from_opt after !i ';' with
            | None -> ""
            | Some j -> String.sub after (j + 1) (String.length after - j - 1)
          in
          (Buffer.contents buf, rem)
        end
        else begin
          (* token value up to ';' *)
          let tok_end, rem =
            match String.index_opt after ';' with
            | None -> (String.length after, "")
            | Some j -> (j, String.sub after (j + 1) (String.length after - j - 1))
          in
          (trim (String.sub after 0 tok_end), rem)
        end
      in
      (* Go: an empty parameter value (e.g. "boundary=") is an invalid media
         parameter. *)
      if value = "" then raise (Form_error "mime: invalid media parameter");
      (* token-validity check on the value when unquoted is skipped; values are
         accepted. *)
      params := (key, value) :: !params;
      rest := remainder
  done;
  (mediatype, List.rev !params)

(* hasPrefix-style content-type check used by Go's multipartReader: the bare
   media type must be "multipart/form-data". *)
let content_type_is_multipart (mediatype : string) = mediatype = "multipart/form-data"

(* ---- parsePostForm: read & parse an application/x-www-form-urlencoded body.
   Returns the parsed Values and the first error (if any), mirroring Go. *)
let parse_post_form (r : Body.t Request.t) : (Values.t * (unit, string) result) Lwt.t =
  let ct = Header.get r.Request.header "Content-Type" in
  let ct = if ct = "" then "application/octet-stream" else ct in
  match parse_media_type ct with
  | exception Form_error msg -> Lwt.return (Values.create (), Error msg)
  | mediatype, _params -> (
    if mediatype = "application/x-www-form-urlencoded" then begin
      let max_form_size = Int64.of_int (10 * 1024 * 1024) in
      Body.read_all r.Request.body >>= fun b ->
      if Int64.compare (Int64.of_int (String.length b)) max_form_size > 0 then
        Lwt.return (Values.create (), Error "http: POST too large")
      else
        let m, res = Values.parse_query b in
        Lwt.return (m, res)
    end
    else
      (* multipart/form-data is handled by parse_multipart_form; other types are
         not read. Return an empty (but non-nil) Values, no error. *)
      Lwt.return (Values.create (), Ok ()))

(* ParseForm: populate r.Form and r.PostForm. Idempotent. Returns the first
   error encountered (as a result) without raising, mirroring Go's error
   return. *)
let parse_form (r : Body.t Request.t) : (unit, string) result Lwt.t =
  let err = ref (Ok ()) in
  let set_err e = match !err with Ok () -> err := e | Error _ -> () in
  let post_step =
    match r.Request.post_form with
    | Some _ -> Lwt.return_unit
    | None -> (
      let meth = r.Request.meth in
      (if meth = "POST" || meth = "PUT" || meth = "PATCH" then
         parse_post_form r >|= fun (pf, res) ->
         set_err res;
         r.Request.post_form <- Some pf
       else Lwt.return_unit)
      >|= fun () ->
      match r.Request.post_form with None -> r.Request.post_form <- Some (Values.create ()) | Some _ -> ())
  in
  post_step >|= fun () ->
  (match r.Request.form with
  | Some _ -> ()
  | None ->
    let post_form = match r.Request.post_form with Some pf -> pf | None -> Values.create () in
    let form =
      if Values.length post_form > 0 then begin
        let f = Values.create () in
        Values.copy_values ~dst:f ~src:post_form;
        Some f
      end
      else None
    in
    (* parse query from URL *)
    let raw_query = match Uri.verbatim_query r.Request.url with Some q -> q | None -> "" in
    let new_values, qres = Values.parse_query raw_query in
    set_err qres;
    (match form with
    | None -> r.Request.form <- Some new_values
    | Some f ->
      Values.copy_values ~dst:f ~src:new_values;
      r.Request.form <- Some f));
  !err

(* ---- multipart support via multipart_form-lwt. *)

(* Content_type.of_string needs the value terminated with "\r\n". *)
let to_content_type (v : string) : (Multipart_form.Content_type.t, string) result =
  let v = if String.length v >= 2 && String.sub v (String.length v - 2) 2 = "\r\n" then v else v ^ "\r\n" in
  match Multipart_form.Content_type.of_string v with
  | Ok ct -> Ok ct
  | Error (`Msg m) -> Error m

(* Extract (name, filename, header-fields) from a part's Header.t. *)
let part_meta (hdr : Multipart_form.Header.t) =
  let name, filename =
    match Multipart_form.Header.content_disposition hdr with
    | Some cd -> (Multipart_form.Content_disposition.name cd, Multipart_form.Content_disposition.filename cd)
    | None -> (None, None)
  in
  (name, filename)

(* Issue 45789: strip any directory path from a multipart filename. *)
let base_filename name =
  (* last element after '/' or '\\', then drop trailing slashes Go's
     filepath.Base would have removed: Go uses filepath.Base which trims
     trailing separators first. *)
  let strip_trailing s =
    let n = ref (String.length s) in
    while !n > 0 && (s.[!n - 1] = '/' || s.[!n - 1] = '\\') do decr n done;
    String.sub s 0 !n
  in
  let s = strip_trailing name in
  let last_sep =
    let r = ref (-1) in
    String.iteri (fun i c -> if c = '/' || c = '\\' then r := i) s;
    !r
  in
  if last_sep < 0 then s else String.sub s (last_sep + 1) (String.length s - last_sep - 1)

exception Not_multipart

(* multipartReader content-type check (request.go): error if not
   multipart/form-data (the form path; the general MultipartReader also accepts
   multipart/mixed, but ParseMultipartForm only deals with form-data). *)
let multipart_reader_check (r : Body.t Request.t) : (string, exn) result =
  let v = Header.get r.Request.header "Content-Type" in
  if v = "" then Error Not_multipart
  else
    match parse_media_type v with
    | exception Form_error msg -> Error (Form_error msg)
    | mediatype, _ -> if content_type_is_multipart mediatype then Ok v else Error Not_multipart

(* ParseMultipartForm: parse a multipart/form-data body, merging into Form and
   PostForm (Issue 9305). Calls parse_form first. Raises on parse failure
   (mirroring Go returning a non-nil error), but a ParseForm error is deferred
   to the end like Go. *)
let parse_multipart_form (r : Body.t Request.t) ~(max_memory : int64) : unit Lwt.t =
  ignore max_memory;
  (* If already parsed, no-op (idempotent). *)
  match r.Request.multipart_form with
  | Some _ -> Lwt.return_unit
  | None -> (
    let parse_form_step =
      match r.Request.form with Some _ -> Lwt.return (Ok ()) | None -> parse_form r
    in
    parse_form_step >>= fun parse_form_err ->
    match multipart_reader_check r with
    | Error e -> Lwt.fail e
    | Ok ct_value -> (
      match to_content_type ct_value with
      | Error m -> Lwt.fail (Form_error m)
      | Ok content_type ->
        Body.read_all r.Request.body >>= fun body_str ->
        let stream = Lwt_stream.of_list [ body_str ] in
        Multipart_form_lwt.of_stream_to_tree stream content_type >>= fun res ->
        (match res with
        | Error (`Msg m) -> Lwt.fail (Form_error m)
        | Ok tree ->
          let value = Values.create () in
          let file : (string, Request.file_header list) Hashtbl.t = Hashtbl.create 8 in
          let elts = Multipart_form.flatten tree in
          List.iter
            (fun (elt : string Multipart_form.elt) ->
              let name, filename = part_meta elt.Multipart_form.header in
              match (name, filename) with
              | Some n, None ->
                (* text field value *)
                Values.add value n elt.Multipart_form.body
              | Some n, Some fn ->
                (* file part *)
                let fh =
                  {
                    Request.filename = base_filename fn;
                    fh_header = [];
                    content = elt.Multipart_form.body;
                  }
                in
                let existing = match Hashtbl.find_opt file n with Some l -> l | None -> [] in
                Hashtbl.replace file n (existing @ [ fh ])
              | None, _ -> ())
            elts;
          let mf = { Request.value; file } in
          (* Merge text values into Form and PostForm (Issue 9305). *)
          let form = match r.Request.form with Some f -> f | None -> let f = Values.create () in r.Request.form <- Some f; f in
          let post_form =
            match r.Request.post_form with
            | Some pf -> pf
            | None -> let pf = Values.create () in r.Request.post_form <- Some pf; pf
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
          (match parse_form_err with Ok () -> Lwt.return_unit | Error m -> Lwt.fail (Form_error m)))))

(* ---- FormValue / PostFormValue / FormFile.
   These lazily parse and ignore errors (mirroring Go). *)

let ensure_parsed_for_form (r : Body.t Request.t) : unit Lwt.t =
  match r.Request.form with
  | Some _ -> Lwt.return_unit
  | None ->
    Lwt.catch
      (fun () -> parse_multipart_form r ~max_memory:default_max_memory)
      (fun _ -> Lwt.return_unit)

let form_value (r : Body.t Request.t) (key : string) : string Lwt.t =
  ensure_parsed_for_form r >|= fun () ->
  match r.Request.form with Some f -> Values.get f key | None -> ""

let post_form_value (r : Body.t Request.t) (key : string) : string Lwt.t =
  (match r.Request.post_form with
  | Some _ -> Lwt.return_unit
  | None ->
    Lwt.catch
      (fun () -> parse_multipart_form r ~max_memory:default_max_memory)
      (fun _ -> Lwt.return_unit))
  >|= fun () -> match r.Request.post_form with Some pf -> Values.get pf key | None -> ""

(* FormFile: simplified to (filename, content) of the first file for [key]. *)
let form_file (r : Body.t Request.t) (key : string) : (string * string) option Lwt.t =
  (match r.Request.multipart_form with
  | Some _ -> Lwt.return_unit
  | None ->
    Lwt.catch
      (fun () -> parse_multipart_form r ~max_memory:default_max_memory)
      (fun _ -> Lwt.return_unit))
  >|= fun () ->
  match r.Request.multipart_form with
  | None -> None
  | Some mf -> (
    match Hashtbl.find_opt mf.Request.file key with
    | Some (fh :: _) -> Some (fh.Request.filename, fh.Request.content)
    | _ -> None)
