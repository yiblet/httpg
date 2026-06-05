(* Port of go/src/net/http/internal/sniff.go (DetectContentType). The public
   net/http wrapper lives at go/src/net/http/sniff.go (-> lib/sniff.ml). *)

(* The algorithm uses at most [sniff_len] bytes to make its decision. *)
let sniff_len = 512

(* isWS reports whether the provided byte is a whitespace byte (0xWS)
   as defined in https://mimesniff.spec.whatwg.org/#terminology. *)
let is_ws c =
  match c with '\t' | '\n' | '\x0c' | '\r' | ' ' -> true | _ -> false

(* isTT reports whether the provided byte is a tag-terminating byte (0xTT)
   as defined in https://mimesniff.spec.whatwg.org/#terminology. *)
let is_tt c = match c with ' ' | '>' -> true | _ -> false

(* A signature matcher: returns the MIME type of the data, or "" if unknown.
   [data] is the (already truncated) prefix; [first_non_ws] is the index of the
   first non-whitespace byte. *)
type sniff_sig = data:string -> first_non_ws:int -> string

(* exactSig: data has the given prefix. *)
let exact_sig sig_ ct : sniff_sig =
 fun ~data ~first_non_ws:_ ->
  let n = String.length sig_ in
  if String.length data >= n && String.sub data 0 n = sig_ then ct else ""

(* maskedSig: pattern matching algorithm section 6. *)
let masked_sig ?(skip_ws = false) ~mask ~pat ct : sniff_sig =
 fun ~data ~first_non_ws ->
  let data =
    if skip_ws then
      String.sub data first_non_ws (String.length data - first_non_ws)
    else data
  in
  if String.length pat <> String.length mask then ""
  else if String.length data < String.length pat then ""
  else begin
    let plen = String.length pat in
    let rec loop i =
      if i >= plen then ct
      else
        let masked_data = Char.code data.[i] land Char.code mask.[i] in
        if masked_data <> Char.code pat.[i] then "" else loop (i + 1)
    in
    loop 0
  end

(* htmlSig: case-insensitive tag prefix followed by a tag-terminating byte. *)
let html_sig h : sniff_sig =
 fun ~data ~first_non_ws ->
  let data = String.sub data first_non_ws (String.length data - first_non_ws) in
  let hlen = String.length h in
  if String.length data < hlen + 1 then ""
  else begin
    let rec loop i =
      if i >= hlen then
        (* Next byte must be a tag-terminating byte (0xTT). *)
        begin if not (is_tt data.[hlen]) then "" else "text/html; charset=utf-8"
        end
      else begin
        let b = Char.code h.[i] in
        let db = Char.code data.[i] in
        let db =
          if Char.code 'A' <= b && b <= Char.code 'Z' then db land 0xDF else db
        in
        if b <> db then "" else loop (i + 1)
      end
    in
    loop 0
  end

(* mp4Sig: https://mimesniff.spec.whatwg.org/#signature-for-mp4 *)
let mp4_sig : sniff_sig =
 fun ~data ~first_non_ws:_ ->
  if String.length data < 12 then ""
  else begin
    let box_size =
      (Char.code data.[0] lsl 24)
      lor (Char.code data.[1] lsl 16)
      lor (Char.code data.[2] lsl 8)
      lor Char.code data.[3]
    in
    if String.length data < box_size || box_size mod 4 <> 0 then ""
    else if String.sub data 4 4 <> "ftyp" then ""
    else begin
      let rec loop st =
        if st >= box_size then ""
        else if st = 12 then
          (* Ignore the four bytes for the version number of the major brand. *)
          loop (st + 4)
        else if String.sub data st 3 = "mp4" then "video/mp4"
        else loop (st + 4)
      in
      loop 8
    end
  end

(* textSig: c.f. section 5, step 4. *)
let text_sig : sniff_sig =
 fun ~data ~first_non_ws ->
  let len = String.length data in
  let rec loop i =
    if i >= len then "text/plain; charset=utf-8"
    else
      let b = Char.code data.[i] in
      if
        b <= 0x08 || b = 0x0B
        || (0x0E <= b && b <= 0x1A)
        || (0x1C <= b && b <= 0x1F)
      then ""
      else loop (i + 1)
  in
  loop first_non_ws

(* Data matching the table in section 6. Order matters. *)
let sniff_signatures : sniff_sig list =
  [
    html_sig "<!DOCTYPE HTML";
    html_sig "<HTML";
    html_sig "<HEAD";
    html_sig "<SCRIPT";
    html_sig "<IFRAME";
    html_sig "<H1";
    html_sig "<DIV";
    html_sig "<FONT";
    html_sig "<TABLE";
    html_sig "<A";
    html_sig "<STYLE";
    html_sig "<TITLE";
    html_sig "<B";
    html_sig "<BODY";
    html_sig "<BR";
    html_sig "<P";
    html_sig "<!--";
    masked_sig ~skip_ws:true ~mask:"\xFF\xFF\xFF\xFF\xFF" ~pat:"<?xml"
      "text/xml; charset=utf-8";
    exact_sig "%PDF-" "application/pdf";
    exact_sig "%!PS-Adobe-" "application/postscript";
    (* UTF BOMs. *)
    masked_sig ~mask:"\xFF\xFF\x00\x00" ~pat:"\xFE\xFF\x00\x00"
      "text/plain; charset=utf-16be";
    masked_sig ~mask:"\xFF\xFF\x00\x00" ~pat:"\xFF\xFE\x00\x00"
      "text/plain; charset=utf-16le";
    masked_sig ~mask:"\xFF\xFF\xFF\x00" ~pat:"\xEF\xBB\xBF\x00"
      "text/plain; charset=utf-8";
    (* Image types *)
    exact_sig "\x00\x00\x01\x00" "image/x-icon";
    exact_sig "\x00\x00\x02\x00" "image/x-icon";
    exact_sig "BM" "image/bmp";
    exact_sig "GIF87a" "image/gif";
    exact_sig "GIF89a" "image/gif";
    masked_sig ~mask:"\xFF\xFF\xFF\xFF\x00\x00\x00\x00\xFF\xFF\xFF\xFF\xFF\xFF"
      ~pat:"RIFF\x00\x00\x00\x00WEBPVP" "image/webp";
    exact_sig "\x89PNG\x0D\x0A\x1A\x0A" "image/png";
    exact_sig "\xFF\xD8\xFF" "image/jpeg";
    (* Audio and Video types *)
    masked_sig ~mask:"\xFF\xFF\xFF\xFF\x00\x00\x00\x00\xFF\xFF\xFF\xFF"
      ~pat:"FORM\x00\x00\x00\x00AIFF" "audio/aiff";
    masked_sig ~mask:"\xFF\xFF\xFF" ~pat:"ID3" "audio/mpeg";
    masked_sig ~mask:"\xFF\xFF\xFF\xFF\xFF" ~pat:"OggS\x00" "application/ogg";
    masked_sig ~mask:"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
      ~pat:"MThd\x00\x00\x00\x06" "audio/midi";
    masked_sig ~mask:"\xFF\xFF\xFF\xFF\x00\x00\x00\x00\xFF\xFF\xFF\xFF"
      ~pat:"RIFF\x00\x00\x00\x00AVI " "video/avi";
    masked_sig ~mask:"\xFF\xFF\xFF\xFF\x00\x00\x00\x00\xFF\xFF\xFF\xFF"
      ~pat:"RIFF\x00\x00\x00\x00WAVE" "audio/wave";
    (* 6.2.0.2. video/mp4 *)
    mp4_sig;
    (* 6.2.0.3. video/webm *)
    exact_sig "\x1A\x45\xDF\xA3" "video/webm";
    (* Font types *)
    masked_sig (* 34 NULL bytes followed by the string "LP" *)
      ~pat:
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00LP"
        (* 34 NULL bytes followed by \xFF\xFF *)
      ~mask:
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xFF\xFF"
      "application/vnd.ms-fontobject";
    exact_sig "\x00\x01\x00\x00" "font/ttf";
    exact_sig "OTTO" "font/otf";
    exact_sig "ttcf" "font/collection";
    exact_sig "wOFF" "font/woff";
    exact_sig "wOF2" "font/woff2";
    (* Archive types *)
    exact_sig "\x1F\x8B\x08" "application/x-gzip";
    exact_sig "PK\x03\x04" "application/zip";
    (* RAR v1.5-v4.0 / RAR v5+ (RAR Labs definition). *)
    exact_sig "Rar!\x1A\x07\x00" "application/x-rar-compressed";
    exact_sig "Rar!\x1A\x07\x01\x00" "application/x-rar-compressed";
    exact_sig "\x00\x61\x73\x6D" "application/wasm";
    text_sig (* should be last *);
  ]

(* DetectContentType: returns a valid MIME type for the given data prefix,
   defaulting to "application/octet-stream". *)
let detect_content_type data =
  let data =
    if String.length data > sniff_len then String.sub data 0 sniff_len else data
  in
  (* Index of the first non-whitespace byte in data. *)
  let len = String.length data in
  let first_non_ws = ref 0 in
  while !first_non_ws < len && is_ws data.[!first_non_ws] do
    incr first_non_ws
  done;
  let first_non_ws = !first_non_ws in
  let rec loop = function
    | [] -> "application/octet-stream" (* fallback *)
    | sig_ :: rest ->
        let ct = sig_ ~data ~first_non_ws in
        if ct <> "" then ct else loop rest
  in
  loop sniff_signatures
