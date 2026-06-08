(* Port of go/src/net/http/pattern.go.

   Pattern parsing and the conflict/precedence helpers used by ServeMux. *)

type segment = { s : string; wild : bool; multi : bool }

type t = {
  str : string;
  method_ : Httpg_base.Method.t;
  host : string;
  segments : segment list;
}

let to_string p = p.str
let last_segment p = List.nth p.segments (List.length p.segments - 1)

(* --- helpers ported from Go --- *)

(* validMethod (request.go): isToken — a non-empty token (no CTLs/separators). *)
let valid_method method_ =
  method_ <> ""
  && String.for_all
       (fun c ->
         let b = Char.code c in
         b > 0x20 && b < 0x7f
         &&
         match c with
         | '(' | ')' | '<' | '>' | '@' | ',' | ';' | ':' | '\\' | '"' | '/'
         | '[' | ']' | '?' | '=' | '{' | '}' ->
             false
         | _ -> true)
       method_

(* isValidWildcardName: a valid Go identifier. Go uses unicode.IsLetter/IsDigit;
   we accept ASCII letters/digits plus '_' (sufficient for the parsed surface). *)
let is_valid_wildcard_name s =
  if s = "" then false
  else
    let ok = ref true in
    String.iteri
      (fun i c ->
        let is_letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') in
        let is_digit = c >= '0' && c <= '9' in
        if not (is_letter || c = '_' || (i <> 0 && is_digit)) then ok := false)
      s;
    !ok

(* Single hex-nibble decode; the per-nibble primitive lives in [Ascii]. *)
let hex_val = Ascii.hex_val

(* url.PathUnescape: decode %XX. On invalid escaping, return the original. *)
let path_unescape path =
  let buf = Buffer.create (String.length path) in
  let n = String.length path in
  let rec loop i =
    if i >= n then Some (Buffer.contents buf)
    else
      match path.[i] with
      | '%' -> (
          if i + 2 >= n then None
          else
            match (hex_val path.[i + 1], hex_val path.[i + 2]) with
            | Some hi, Some lo ->
                Buffer.add_char buf (Char.chr ((hi * 16) + lo));
                loop (i + 3)
            | _ -> None)
      | '+' ->
          (* PathUnescape (unlike QueryUnescape) keeps '+' literal. *)
          Buffer.add_char buf '+';
          loop (i + 1)
      | c ->
          Buffer.add_char buf c;
          loop (i + 1)
  in
  match loop 0 with Some s -> s | None -> path

(* cleanPath (server.go) via path.Clean, used to reject unclean non-CONNECT
   patterns. path.Clean equivalent. *)
let path_clean p =
  if p = "" then "."
  else begin
    let rooted = p.[0] = '/' in
    let n = String.length p in
    let out = Buffer.create n in
    (* dotdot is index in out (relative to start) up to which we cannot back up *)
    let dotdot = ref 0 in
    if rooted then begin
      Buffer.add_char out '/';
      dotdot := 1
    end;
    let r = ref 0 in
    while !r < n do
      if p.[!r] = '/' then incr r
      else if p.[!r] = '.' && (!r + 1 = n || p.[!r + 1] = '/') then incr r
      else if
        p.[!r] = '.' && p.[!r + 1] = '.' && (!r + 2 = n || p.[!r + 2] = '/')
      then begin
        r := !r + 2;
        if Buffer.length out > !dotdot then begin
          (* back up over previous element *)
          let s = Buffer.contents out in
          let len = ref (String.length s) in
          while !len > !dotdot && s.[!len - 1] <> '/' do
            decr len
          done;
          (* drop the trailing slash too unless we land at dotdot *)
          let newlen = if !len > !dotdot then !len - 1 else !len in
          Buffer.clear out;
          Buffer.add_string out (String.sub s 0 newlen)
        end
        else if not rooted then begin
          if Buffer.length out > 0 then Buffer.add_char out '/';
          Buffer.add_string out ".."
        end
      end
      else begin
        if
          (rooted && Buffer.length out <> 1)
          || ((not rooted) && Buffer.length out <> 0)
        then Buffer.add_char out '/';
        while !r < n && p.[!r] <> '/' do
          Buffer.add_char out p.[!r];
          incr r
        done
      end
    done;
    if Buffer.length out = 0 then "." else Buffer.contents out
  end

let index_any s chars =
  let n = String.length s in
  let rec loop i =
    if i >= n then -1
    else if String.contains chars s.[i] then i
    else loop (i + 1)
  in
  loop 0

let index_byte s c = try String.index s c with Not_found -> -1

(* CutSuffix("name...", "...") *)
let cut_suffix s suffix =
  if String.ends_with ~suffix s then
    (String.sub s 0 (String.length s - String.length suffix), true)
  else (s, false)

(* --- parsePattern --- *)

type error =
  | Empty_pattern
  | Invalid_method of string
  | Missing_path of int
  | Host_has_brace of int
  | Unclean_path of int
  | Bad_wildcard of int * string
  | Duplicate_wildcard of int * string

let error_to_string = function
  | Empty_pattern -> "empty pattern"
  | Invalid_method m -> Printf.sprintf "at offset 0: invalid method %S" m
  | Missing_path off -> Printf.sprintf "at offset %d: host/path missing /" off
  | Host_has_brace off ->
      Printf.sprintf "at offset %d: host contains '{' (missing initial '/'?)"
        off
  | Unclean_path off ->
      Printf.sprintf
        "at offset %d: non-CONNECT pattern with unclean path can never match"
        off
  | Bad_wildcard (off, why) -> Printf.sprintf "at offset %d: %s" off why
  | Duplicate_wildcard (off, name) ->
      Printf.sprintf "at offset %d: duplicate wildcard name %S" off name

exception Parse_error of error

let parse s : (t, error) result =
  if String.length s = 0 then Error Empty_pattern
  else begin
    let off = ref 0 in
    let fail e = raise (Parse_error e) in
    try
      let method_, rest, found =
        let i = index_any s " \t" in
        if i >= 0 then
          ( String.sub s 0 i,
            Httpg_base.Textproto.trim_left ~chars:" \t"
              (String.sub s (i + 1) (String.length s - i - 1)),
            true )
        else (s, "", false)
      in
      let method_, rest =
        if not found then ("", method_) else (method_, rest)
      in
      if method_ <> "" && not (valid_method method_) then
        fail (Invalid_method method_);
      if found then off := String.length method_ + 1;
      let i = index_byte rest '/' in
      if i < 0 then fail (Missing_path !off);
      let host = String.sub rest 0 i in
      let rest = ref (String.sub rest i (String.length rest - i)) in
      let j = index_byte host '{' in
      if j >= 0 then begin
        off := !off + j;
        fail (Host_has_brace !off)
      end;
      off := !off + i;
      (* An unclean path with a method other than CONNECT can never match. *)
      if method_ <> "" && method_ <> "CONNECT" && !rest <> path_clean !rest then
        fail (Unclean_path !off);
      let segments = ref [] in
      let push seg = segments := seg :: !segments in
      let seen_names = Hashtbl.create 8 in
      let break = ref false in
      while (not !break) && String.length !rest > 0 do
        (* Invariant: rest.[0] = '/'. *)
        rest := String.sub !rest 1 (String.length !rest - 1);
        off := String.length s - String.length !rest;
        if String.length !rest = 0 then begin
          push { s = ""; wild = true; multi = true };
          break := true
        end
        else begin
          let i = index_byte !rest '/' in
          let i = if i < 0 then String.length !rest else i in
          let seg = String.sub !rest 0 i in
          rest := String.sub !rest i (String.length !rest - i);
          let bi = index_byte seg '{' in
          if bi < 0 then
            push { s = path_unescape seg; wild = false; multi = false }
          else begin
            (* Wildcard. *)
            if bi <> 0 then
              fail
                (Bad_wildcard
                   (!off, "bad wildcard segment (must start with '{')"));
            if seg.[String.length seg - 1] <> '}' then
              fail
                (Bad_wildcard (!off, "bad wildcard segment (must end with '}')"));
            let name = String.sub seg 1 (String.length seg - 2) in
            if name = "$" then begin
              if String.length !rest <> 0 then
                fail (Bad_wildcard (!off, "{$} not at end"));
              push { s = "/"; wild = false; multi = false };
              break := true
            end
            else begin
              let name, multi = cut_suffix name "..." in
              if multi && String.length !rest <> 0 then
                fail (Bad_wildcard (!off, "{...} wildcard not at end"));
              if name = "" then fail (Bad_wildcard (!off, "empty wildcard"));
              if not (is_valid_wildcard_name name) then
                fail
                  (Bad_wildcard
                     (!off, Printf.sprintf "bad wildcard name %S" name));
              if Hashtbl.mem seen_names name then
                fail (Duplicate_wildcard (!off, name));
              Hashtbl.replace seen_names name ();
              push { s = name; wild = true; multi }
            end
          end
        end
      done;
      Ok
        {
          str = s;
          method_ = Httpg_base.Method.of_string method_;
          host;
          segments = List.rev !segments;
        }
    with Parse_error e -> Error e
  end

(* --- relationships --- *)

type relationship =
  | Equivalent
  | More_general
  | More_specific
  | Disjoint
  | Overlaps

let relationship_to_string = function
  | Equivalent -> "equivalent"
  | More_general -> "moreGeneral"
  | More_specific -> "moreSpecific"
  | Disjoint -> "disjoint"
  | Overlaps -> "overlaps"

let inverse_relationship = function
  | More_specific -> More_general
  | More_general -> More_specific
  | r -> r

let combine_relationships r1 r2 =
  match r1 with
  | Equivalent -> r2
  | Disjoint -> Disjoint
  | Overlaps -> if r2 = Disjoint then Disjoint else Overlaps
  | More_general | More_specific -> (
      match r2 with
      | Equivalent -> r1
      | _ when r2 = inverse_relationship r1 -> Overlaps
      | _ -> r2)

let compare_methods p1 p2 =
  let open Httpg_base.Method in
  if p1.method_ = p2.method_ then Equivalent
  else if p1.method_ = Custom "" then More_general
  else if p2.method_ = Custom "" then More_specific
  else if p1.method_ = Get && p2.method_ = Head then More_general
  else if p2.method_ = Get && p1.method_ = Head then More_specific
  else Disjoint

let compare_segments s1 s2 =
  if s1.multi && s2.multi then Equivalent
  else if s1.multi then More_general
  else if s2.multi then More_specific
  else if s1.wild && s2.wild then Equivalent
  else if s1.wild then if s2.s = "/" then Disjoint else More_general
  else if s2.wild then if s1.s = "/" then Disjoint else More_specific
  else if s1.s = s2.s then Equivalent
  else Disjoint

let compare_paths p1 p2 =
  let len1 = List.length p1.segments and len2 = List.length p2.segments in
  if
    len1 <> len2 && (not (last_segment p1).multi) && not (last_segment p2).multi
  then Disjoint
  else begin
    (* Walk corresponding segments. *)
    let rec walk rel segs1 segs2 =
      match (segs1, segs2) with
      | s1 :: r1, s2 :: r2 ->
          let rel = combine_relationships rel (compare_segments s1 s2) in
          if rel = Disjoint then (Disjoint, [], []) else walk rel r1 r2
      | _ -> (rel, segs1, segs2)
    in
    let rel, segs1, segs2 = walk Equivalent p1.segments p2.segments in
    if rel = Disjoint then Disjoint
    else if segs1 = [] && segs2 = [] then rel
    else if List.length segs1 < List.length segs2 && (last_segment p1).multi
    then combine_relationships rel More_general
    else if List.length segs2 < List.length segs1 && (last_segment p2).multi
    then combine_relationships rel More_specific
    else Disjoint
  end

let compare_paths_and_methods p1 p2 =
  let mrel = compare_methods p1 p2 in
  if mrel = Disjoint then Disjoint
  else combine_relationships mrel (compare_paths p1 p2)

let conflicts_with p1 p2 =
  if p1.host <> p2.host then false
  else
    let rel = compare_paths_and_methods p1 p2 in
    rel = Equivalent || rel = Overlaps

(* --- describeConflict / commonPath / differencePath --- *)

let write_segment b s =
  Buffer.add_char b '/';
  if (not s.multi) && s.s <> "/" then Buffer.add_string b s.s

let write_matching_path b segs = List.iter (fun s -> write_segment b s) segs

let common_path p1 p2 =
  let b = Buffer.create 32 in
  let rec walk segs1 segs2 =
    match (segs1, segs2) with
    | s1 :: r1, s2 :: r2 ->
        if s1.wild then write_segment b s2 else write_segment b s1;
        walk r1 r2
    | _ -> (segs1, segs2)
  in
  let segs1, segs2 = walk p1.segments p2.segments in
  if segs1 <> [] then write_matching_path b segs1
  else if segs2 <> [] then write_matching_path b segs2;
  Buffer.contents b

let difference_path p1 p2 =
  let b = Buffer.create 32 in
  let exception Done in
  (try
     let rec walk segs1 segs2 =
       match (segs1, segs2) with
       | s1 :: r1, s2 :: r2 ->
           if s1.multi && s2.multi then begin
             Buffer.add_char b '/';
             raise Done
           end;
           if s1.multi && not s2.multi then begin
             Buffer.add_char b '/';
             if s2.s = "/" then
               if s1.s <> "" then Buffer.add_string b s1.s
               else Buffer.add_string b "x";
             raise Done
           end;
           if (not s1.multi) && s2.multi then write_segment b s1
           else if s1.wild && s2.wild then write_segment b s1
           else if s1.wild && not s2.wild then
             begin if s1.s <> s2.s then write_segment b s1
             else begin
               Buffer.add_char b '/';
               Buffer.add_string b (s2.s ^ "x")
             end
             end
           else if (not s1.wild) && s2.wild then write_segment b s1
           else begin
             (* both literals; precondition: same literal *)
             if s1.s <> s2.s then
               failwith (Printf.sprintf "literals differ: %S and %S" s1.s s2.s);
             write_segment b s1
           end;
           walk r1 r2
       | _ -> (segs1, segs2)
     in
     let segs1, segs2 = walk p1.segments p2.segments in
     if segs1 <> [] then write_matching_path b segs1
     else if segs2 <> [] then write_matching_path b segs2
   with Done -> ());
  Buffer.contents b

let describe_conflict p1 p2 =
  let mrel = compare_methods p1 p2 in
  let prel = compare_paths p1 p2 in
  let rel = combine_relationships mrel prel in
  if rel = Equivalent then
    Printf.sprintf "%s matches the same requests as %s" (to_string p1)
      (to_string p2)
  else if rel <> Overlaps then
    failwith "describeConflict called with non-conflicting patterns"
  else if prel = Overlaps then
    Printf.sprintf
      "%s and %s both match some paths, like %S.\n\
       But neither is more specific than the other.\n\
       %s matches %S, but %s doesn't.\n\
       %s matches %S, but %s doesn't."
      (to_string p1) (to_string p2) (common_path p1 p2) (to_string p1)
      (difference_path p1 p2) (to_string p2) (to_string p2)
      (difference_path p2 p1) (to_string p1)
  else if mrel = More_general && prel = More_specific then
    Printf.sprintf
      "%s matches more methods than %s, but has a more specific path pattern"
      (to_string p1) (to_string p2)
  else if mrel = More_specific && prel = More_general then
    Printf.sprintf
      "%s matches fewer methods than %s, but has a more general path pattern"
      (to_string p1) (to_string p2)
  else
    Printf.sprintf
      "bug: unexpected way for two patterns %s and %s to conflict: methods %s, \
       paths %s"
      (to_string p1) (to_string p2)
      (relationship_to_string mrel)
      (relationship_to_string prel)
