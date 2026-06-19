(* Port of go/src/net/http/server.go's ServeMux: the HTTP request multiplexer —
   pattern registration with conflict detection, the routing-tree match with
   trailing-slash / clean-path redirection, and ServeMux.ServeHTTP dispatch.
   Split out of {!Server} (Go keeps it in the same file); it builds on
   {!Server.handler} and the server.go helpers {!Server.error} /
   {!Server.not_found_handler} / {!Server.redirect_handler}. *)

(* Routing internals live in the private httpg_internal library (Go keeps
   pattern.go / routingNode / mapping.go unexported in net/http). *)
module Pattern = Httpg_internal.Pattern
module Routing_tree = Httpg_internal.Routing_tree

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

type t = { tree : Server.handler Routing_tree.t; patterns : Pattern.t list }

let empty = { tree = Routing_tree.empty; patterns = [] }

type error = Register of string

let error_to_string = function Register s -> s

(* Go's registerErr: parse, conflict-check, add to the tree. *)
let register mux patstr handler : (t, error) result =
  if patstr = "" then Error (Register "http: invalid pattern")
  else
    match Pattern.parse patstr with
    | Error e ->
        Error
          (Register
             (Printf.sprintf "parsing %S: %s" patstr
                (Pattern.error_to_string e)))
    | Ok pat -> (
        let conflict =
          List.find_opt
            (fun pat2 -> Pattern.conflicts_with pat pat2)
            mux.patterns
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
            Ok { tree; patterns })

let handle mux pattern handler = register mux pattern handler

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

let find_handler_finish mux ~host ~path m =
  match m with
  | Some ((_pat, h), _captures) -> h
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
let serve_http mux ~sw (r : Request.t) : Response.t =
  if r.request_uri = "*" then begin
    let resp =
      Response.create () |> Response.with_status Httpg_base.Status.BadRequest
    in
    if Request.proto_at_least r 1 1 then
      Response.with_set_header "Connection" "close" resp
    else resp
  end
  else (find_handler mux r) ~sw r

(* A mux viewed as a handler (Go's ServeMux implements Handler). *)
let handler mux : Server.handler = serve_http mux
