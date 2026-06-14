(* multipart/form-data parsing as a composable, incremental sequence of parts
   over a [Body.t] (Httpg deviation from Go's Request-mutating
   ParseMultipartForm). A multipart body IS a [(part, error) result Seq.t]: each
   forced element parses the next part, buffering its body {b in memory}. Errors
   are per-element because delivery is incremental — a malformed part surfaces as
   [Error] after the well-formed parts before it were already delivered.

   {b No file spillover (for now):} every part is held in memory, so a very large
   upload buffers whole. Go spills oversized parts to temp files past a
   [maxMemory] budget; re-adding that here — bounded and via [Eio.Path] rather
   than blocking stdlib IO — is tracked in TODO. Consequently [of_body] needs no
   switch and is pure.

   The underlying parser is the sans-io [multipart_form] core (the fidelity
   stand-in for Go's mime/multipart): a push decoder whose per-part pusher gets
   the part's chunks then [None] at end-of-part — which is how we know a part has
   settled and can be yielded. *)

module MF = Multipart_form

type part = {
  name : string option;
  filename : string option;
  header : Header.t;
  body : string;
}

type t = part Seq.t
type error = Not_multipart | Parse of string

let error_to_string = function
  | Not_multipart -> "request Content-Type isn't multipart/form-data"
  | Parse s -> s

(* The boundary parameter of a multipart/form-data Content-Type (Go's
   multipartReader content-type check). We let the [multipart_form] core parse
   the media type rather than re-implementing mime.ParseMediaType: it lowercases
   the type/param keys, handles quoted/token values, and reports malformed input.
   [Not_multipart] if the type isn't multipart/form-data or the boundary is
   absent; [Parse] on a genuinely malformed Content-Type. *)
let boundary ~content_type : (string, error) result =
  if content_type = "" then Error Not_multipart
  else
    (* of_string wants the value terminated with CRLF (header values don't carry
       it). *)
    match MF.Content_type.of_string (content_type ^ "\r\n") with
    | Error (`Msg m) -> Error (Parse m)
    | Ok ct -> (
        let is_form_data =
          ct.MF.Content_type.ty = `Multipart
          &&
          match ct.MF.Content_type.subty with
          | `Iana_token s | `Ietf_token s | `X_token s ->
              String.lowercase_ascii s = "form-data"
        in
        if not is_form_data then Error Not_multipart
        else
          match List.assoc_opt "boundary" ct.MF.Content_type.parameters with
          | Some (MF.Content_type.Parameters.String b)
          | Some (MF.Content_type.Parameters.Token b)
            when b <> "" ->
              Ok b
          | _ -> Error Not_multipart)

(* Issue 45789: strip any directory path from an (attacker-controlled) multipart
   filename, trimming trailing separators first. Hand-rolled rather than
   [Filename.basename] on purpose: that is OS-dependent (on Unix it splits on '/'
   only), whereas this strips both '/' and '\' regardless of host OS — the
   server's platform must not decide whether a Windows-style path is sanitised. *)
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

(* (name, filename) from a part's Content-Disposition. *)
let part_meta (h : MF.Header.t) =
  match MF.Header.content_disposition h with
  | Some cd ->
      ( MF.Content_disposition.name cd,
        Option.map base_filename (MF.Content_disposition.filename cd) )
  | None -> (None, None)

(* Convert a part's MIME header into a public {!Header.t}. The structured fields
   (Content-Type/-Disposition/-Transfer-Encoding) are rendered via their
   to_string; unstructured custom part fields are dropped (a simplification —
   form-data parts rarely carry them, and reaching their value would pull in the
   [unstrctrd] dependency). *)
let header_of_part (h : MF.Header.t) : Header.t =
  let value_only s =
    (* to_string may include the field-name and/or a trailing CRLF; keep only the
       value after the first ':' and trim. *)
    let v =
      match String.index_opt s ':' with
      | Some i -> String.sub s (i + 1) (String.length s - i - 1)
      | None -> s
    in
    String.trim v
  in
  List.fold_left
    (fun acc (MF.Field.Field (fname, witness, v)) ->
      let name = (fname :> string) in
      match witness with
      | MF.Field.Content_type ->
          Header.add acc name (value_only (MF.Content_type.to_string v))
      | MF.Field.Content_encoding ->
          Header.add acc name (value_only (MF.Content_encoding.to_string v))
      | MF.Field.Content_disposition ->
          Header.add acc name (value_only (MF.Content_disposition.to_string v))
      | MF.Field.Field -> acc)
    (Header.create ()) (MF.Header.to_list h)

(* [of_body ~boundary body] parses [body] as multipart/form-data and returns its
   parts as a [(part, error) result Seq.t]. Each forced element drives the parser
   until the next part has fully arrived, buffering its body in memory. Delivery
   is incremental: a parse failure appears as a single [Error] element after the
   well-formed parts preceding it, then the sequence ends. The Seq is effectful
   (a stateful parser underneath) and single-use. *)
let of_body ~boundary (body : Body.t) : (part, error) result Seq.t =
  (* We already hold the boundary, so build the [Content_type.t] directly instead
     of formatting a header string and re-parsing it with [of_string] (no quoting
     to get right, no spurious parse-failure path). *)
  let content_type =
    MF.Content_type.make `Multipart (`Iana_token "form-data")
      MF.Content_type.Parameters.(of_list [ (k "boundary", v boundary) ])
  in
  let queue : part Queue.t = Queue.create () in
  let emitters (h : MF.Header.t) =
    let name, filename = part_meta h in
    let hdr = header_of_part h in
    let buf = Buffer.create 256 in
    let push = function
      | Some (chunk : string) -> Buffer.add_string buf chunk
      | None ->
          (* End of part: finalise into a settled [part] and enqueue it. *)
          Queue.add
            { name; filename; header = hdr; body = Buffer.contents buf }
            queue
    in
    (push, ())
  in
  let step = MF.parse ~emitters content_type in
  let stream = Body.to_stream body in
  let finished = ref false in
  let next_part () : (part option, error) result =
    let rec drive () =
      if not (Queue.is_empty queue) then Ok (Some (Queue.pop queue))
      else if !finished then Ok None
      else
        let input = match stream () with Some s -> `String s | None -> `Eof in
        match step input with
        | `Continue -> drive ()
        | `Done _tree ->
            finished := true;
            if Queue.is_empty queue then Ok None
            else Ok (Some (Queue.pop queue))
        | `Fail m ->
            finished := true;
            Error (Parse m)
    in
    try drive ()
    with e ->
      finished := true;
      Error (Parse (Printexc.to_string e))
  in
  (* next_part is stateful (sets [finished] on error), so after an [Error] the
     next call returns [Ok None] and the sequence terminates. *)
  Seq.unfold
    (fun () ->
      match next_part () with
      | Ok None -> None
      | Ok (Some p) -> Some (Ok p, ())
      | Error e -> Some (Error e, ()))
    ()

(* escapeQuotes (mime/multipart/writer.go): backslash and double-quote in a
   Content-Disposition parameter value are backslash-escaped. *)
let escape_quotes s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '\\' -> Buffer.add_string b "\\\\"
      | '"' -> Buffer.add_string b "\\\""
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

(* Encode one part to its own buffer: the boundary delimiter, the part header
   (Content-Disposition synthesized from name/filename — Go's
   CreateFormField/CreateFormFile — replacing any carried one, then the
   remaining fields), the blank line, the body, and a trailing CRLF. *)
let encode_part ~boundary (p : part) : string =
  let buf = Buffer.create 256 in
  Buffer.add_string buf ("--" ^ boundary ^ "\r\n");
  let header =
    match p.name with
    | Some name ->
        let cd =
          "form-data; name=\"" ^ escape_quotes name ^ "\""
          ^
          match p.filename with
          | Some fn -> "; filename=\"" ^ escape_quotes fn ^ "\""
          | None -> ""
        in
        Header.set
          (Header.del p.header "Content-Disposition")
          "Content-Disposition" cd
    | None -> p.header
  in
  Header.write header buf;
  Buffer.add_string buf "\r\n";
  Buffer.add_string buf p.body;
  Buffer.add_string buf "\r\n";
  Buffer.contents buf

let to_body ~boundary (parts : part Seq.t) : Body.t =
  (* Stream a chunk per part, then the closing delimiter. *)
  let closing = Seq.return ("--" ^ boundary ^ "--\r\n") in
  Body.of_seq (Seq.append (Seq.map (encode_part ~boundary) parts) closing)
