(* Port of go/src/net/http/server.go's ServeMux: the HTTP request multiplexer —
   pattern registration with conflict detection, the routing-tree match with
   trailing-slash / clean-path redirection, and ServeMux.ServeHTTP dispatch.
   Split out of {!Server} (Go keeps it in the same file); it builds on
   {!Server.handler} and the server.go helpers {!Server.error} /
   {!Server.not_found_handler} / {!Server.redirect_handler}. *)

(* Routing internals live in the private httpg_internal library (Go keeps
   pattern.go / routingNode / mapping.go unexported in net/http). *)
module Pattern = Httpg_base.Pattern
module Routing_tree = Httpg_internal.Routing_tree

(* Captured wildcard values, keyed by wildcard name (Go exposes these through
   [Request.PathValue]; we hand them to the registered builder instead). *)
module StringMap = Map.Make (String)

(* Go's cleanPath: canonical path, eliminating . and .. and preserving a
   trailing slash. *)
let clean_path = Pattern.clean_path

(* Go's stripHostPort: drop a trailing ":<port>". *)
let strip_host_port h =
  if not (String.contains h ':') then h
  else
    match String.rindex_opt h ':' with
    | None -> h
    | Some i ->
        let host = String.sub h 0 i in
        if
          String.length host >= 2
          && host.[0] = '['
          && host.[String.length host - 1] = ']'
        then String.sub host 1 (String.length host - 2)
        else host

(* Registrations are [StringMap.t -> Server.handler]: the routing match
   resolves the wildcard captures, then applies the builder to obtain the
   request handler. *)
type path_handler = string StringMap.t -> Server.handler

type t = {
  tree : path_handler Routing_tree.t;
  patterns : Pattern.t list;
  middlewares : Middleware.t list;
}

let empty = { tree = Routing_tree.empty; patterns = []; middlewares = [] }

type error = Register of string

let error_to_string = function Register s -> s

let handle_pattern (pat : Pattern.t) handler mux =
  let conflict =
    List.find_opt (fun pat2 -> Pattern.conflicts_with pat pat2) mux.patterns
  in
  match conflict with
  | Some pat2 ->
      Error
        (Register
           (Printf.sprintf "pattern %S conflicts with pattern %S:\n%s"
              (Pattern.to_string pat) (Pattern.to_string pat2)
              (Pattern.describe_conflict pat pat2)))
  | None ->
      let tree = Routing_tree.add_pattern pat handler mux.tree in
      let patterns = pat :: mux.patterns in
      Ok { tree; patterns; middlewares = mux.middlewares }

let handle patstr handler mux : (t, error) result =
  if patstr = "" then Error (Register "http: invalid pattern")
  else
    match Pattern.parse patstr with
    | Error e ->
        Error
          (Register
             (Printf.sprintf "parsing %S: %s" patstr
                (Pattern.error_to_string e)))
    | Ok pat -> handle_pattern pat handler mux

let try_fold (type e) (f : 'b -> 'a -> ('b, e) result) (acc : 'b) ls =
  let exception Stop of e in
  try
    Seq.fold_left
      (fun acc x ->
        match f acc x with Ok acc -> acc | Error err -> raise (Stop err))
      acc ls
    |> Result.ok
  with Stop err -> Error err

let add_middleware (middleware : Middleware.t) mux =
  { mux with middlewares = middleware :: mux.middlewares }

let mount_pattern (pat : Pattern.t) ~nested mux =
  (* Mounting is purely a path-prefix operation: only the subtree's path
     segments are prepended to the nested mux's patterns (see
     [prepend_segments]). A method or host on the mount pattern has nowhere to go
     and would be silently dropped, so reject it rather than mislead the
     caller. *)
  if Option.is_some (Pattern.method_ pat) || Option.is_some (Pattern.host pat)
  then Error (Register "http: mount pattern must not have a method or host")
  else
    match Pattern.Private.subtree_segments pat with
    | None ->
        Error
          (Register
             "http: mount pattern must end in a slash segment to indicate a \
              subtree")
    | Some segments ->
        let new_patterns =
          nested.tree |> Routing_tree.to_seq
          |> Seq.map (fun (p, h) ->
              let pattern = Pattern.Private.prepend_segments segments p in
              let handler ctx =
                Middleware.chain_left nested.middlewares (h ctx)
              in
              (pattern, handler))
        in
        try_fold (fun acc (p, h) -> handle_pattern p h acc) mux new_patterns

let mount (pat : string) ~nested mux =
  match Pattern.parse pat with
  | Error e ->
      Error
        (Register
           (Printf.sprintf "parsing %S: %s" pat (Pattern.error_to_string e)))
  | Ok pat -> mount_pattern pat ~nested mux

(* Go's exactMatch. *)
let exact_match (pat : Pattern.t) path =
  let last = Pattern.last_segment pat in
  if not (Pattern.Segment.is_multi last) then true
  else if String.length path > 0 && path.[String.length path - 1] <> '/' then
    false
  else begin
    let count = ref 0 in
    String.iter (fun c -> if c = '/' then incr count) path;
    List.length (Pattern.segments pat) = !count
  end

(* Go's matchingMethods. *)
let matching_methods mux host path =
  let ms = Hashtbl.create 8 in
  Routing_tree.matching_methods mux.tree ~host ~path ms;
  if not (String.length path > 0 && path.[String.length path - 1] = '/') then
    Routing_tree.matching_methods mux.tree ~host ~path:(path ^ "/") ms;
  let keys =
    Hashtbl.fold (fun k _ acc -> Httpg_base.Method.to_string k :: acc) ms []
  in
  List.sort String.compare keys

(* Go's matchOrRedirect: match in the tree, with trailing-slash redirection. *)
let match_or_redirect mux ~host ~method_ ~path ~try_redirect ~raw_query =
  let m = Routing_tree.match_ mux.tree ~host ~method_ ~path in
  let is_exact =
    match m with Some ((pat, _), _) -> exact_match pat path | None -> false
  in
  if
    (not is_exact) && try_redirect
    && (not (String.length path > 0 && path.[String.length path - 1] = '/'))
    && path <> ""
  then begin
    let path2 = path ^ "/" in
    let m2 = Routing_tree.match_ mux.tree ~host ~method_ ~path:path2 in
    match m2 with
    | Some ((pat2, _), _) when exact_match pat2 path2 ->
        let target = clean_path path ^ "/" in
        let target =
          if raw_query <> "" then target ^ "?" ^ raw_query else target
        in
        (m2, Some target)
    | _ -> (m, None)
  end
  else (m, None)

(* Pair the pattern's wildcard segments with the captured values (both in
   pattern order), keeping only the named ones. The anonymous trailing-slash
   [{...}] wildcard contributes no capture and carries no name, so the
   left-to-right zip stays aligned. Mirrors Go's [Request.patIndex], which
   indexes only wildcards with a non-empty name. *)
let path_values_of pat captures =
  let wilds = List.filter Pattern.Segment.is_wild (Pattern.segments pat) in
  let rec zip acc segs caps =
    match (segs, caps) with
    | seg :: segs', value :: caps' ->
        let name = Pattern.Segment.text seg in
        let acc = if name = "" then acc else StringMap.add name value acc in
        zip acc segs' caps'
    | _, _ -> acc
  in
  zip StringMap.empty wilds captures

let find_handler_finish mux ~host ~path m =
  match m with
  | Some ((pat, build), captures) ->
      let middleware = Middleware.chain_left mux.middlewares in
      middleware (build (path_values_of pat captures))
  | None ->
      let allowed = matching_methods mux host path in
      if List.length allowed > 0 then fun ~sw:_ _r ->
        Server.error
          (Httpg_base.Status.to_string Httpg_base.Status.MethodNotAllowed)
          Httpg_base.Status.MethodNotAllowed
        |> Response.with_set_header "Allow" (String.concat ", " allowed)
      else Server.not_found_handler ()

(* Go's findHandler. *)
let find_handler mux (r : Request.t) =
  let escaped_path = Uri.path r.url in
  let raw_query =
    match Uri.verbatim_query r.url with Some q -> q | None -> ""
  in
  if r.meth = Httpg_base.Method.Connect then begin
    let host = match Uri.host r.url with Some h -> h | None -> "" in
    let _, redir =
      match_or_redirect mux ~host ~method_:r.meth ~path:escaped_path
        ~try_redirect:true ~raw_query
    in
    match redir with
    | Some u -> Server.redirect_handler u Httpg_base.Status.TemporaryRedirect
    | None ->
        let host = Option.value ~default:"" r.host in
        let m, _ =
          match_or_redirect mux ~host ~method_:r.meth ~path:escaped_path
            ~try_redirect:false ~raw_query
        in
        find_handler_finish mux ~host ~path:escaped_path m
  end
  else begin
    let host = strip_host_port (Option.value ~default:"" r.host) in
    let path = clean_path escaped_path in
    let m, redir =
      match_or_redirect mux ~host ~method_:r.meth ~path ~try_redirect:true
        ~raw_query
    in
    match redir with
    | Some u -> Server.redirect_handler u Httpg_base.Status.TemporaryRedirect
    | None ->
        if path <> escaped_path then begin
          let u = if raw_query <> "" then path ^ "?" ^ raw_query else path in
          Server.redirect_handler u Httpg_base.Status.TemporaryRedirect
        end
        else find_handler_finish mux ~host ~path m
  end

(* Go's ServeMux.ServeHTTP. *)
let handler mux ~sw (r : Request.t) : Response.t =
  if r.request_uri = Some "*" then begin
    let resp =
      Response.create () |> Response.with_status Httpg_base.Status.BadRequest
    in
    if Request.proto_at_least r 1 1 then
      Response.with_set_header "Connection" "close" resp
    else resp
  end
  else (find_handler mux r) ~sw r
