(* Unit tests for the ServeMux (go/src/net/http/server.go's ServeMux): pattern
   registration and conflicts, wildcard path values, subtree mounting, and
   middleware composition.

   These exercise routing decisions, not the HTTP/1 wire, so they need no socket
   or loopback server: with [Request -> Response] handlers a mux is tested by
   calling it directly ({!dispatch} = [Mux.handler]) and inspecting the returned
   {!Response.t} — the in-process analogue of Go's [httptest.ResponseRecorder],
   which this port omits for exactly this reason (see [httptest.mli]). The
   byte-level wire behaviour (status line, keep-alive framing) is covered over a
   real connection in {!Test_serve}. *)

open Httpg
module Method = Httpg_base.Method
module Status = Httpg_base.Status

let handle_func mux pattern f =
  Result.get_ok (Mux.handle pattern (fun _path_values -> f) mux)
(* Returns the updated mux; the mux is immutable. The registration ignores the
   wildcard captures (see {!path_value_test} for a route that uses them). *)

let contains haystack needle =
  match Str.search_forward (Str.regexp_string needle) haystack 0 with
  | _ -> true
  | exception Not_found -> false

(* Dispatch [meth path] against [mux] in-process and return the response plus
   its body read to a string. No network: [Mux.handler] maps the request to a
   response directly. The switch comes from {!Test_harness.with_env}, which also
   bounds the call with a deadline so a hang fails instead of blocking. *)
let dispatch ?(meth = Method.Get) mux path =
  Test_harness.with_env (fun ~net:_ ~clock:_ ~sw ->
      let req = Request.make ~meth (Uri.of_string path) in
      let resp = Mux.handler mux ~sw req in
      let body =
        match Body.read_all resp.body with
        | Ok s -> s
        | Error e -> Alcotest.failf "body: %s" (Body.error_to_string e)
      in
      (resp, body))

let check_status label expected (resp : Response.t) =
  Alcotest.(check int)
    label (Status.to_int expected)
    (Status.to_int resp.status)

(* ---- tests ---- *)

(* A request that matches no registered pattern dispatches to the 404 handler. *)
let not_found_test () =
  let mux =
    handle_func Mux.empty "/known" (fun ~sw:_ _r ->
        Response.with_body_string "ok" (Response.create ()))
  in
  let resp, body = dispatch mux "/missing" in
  check_status "404 status" Status.NotFound resp;
  Alcotest.(check string) "not-found body" "404 page not found\n" body

let mux_routing_test () =
  let mux =
    handle_func Mux.empty "/a" (fun ~sw:_ _r ->
        Response.with_body_string "handler-a" (Response.create ()))
  in
  let mux =
    handle_func mux "/b" (fun ~sw:_ _r ->
        Response.with_body_string "handler-b" (Response.create ()))
  in
  let mux =
    handle_func mux "POST /c" (fun ~sw:_ _r ->
        Response.with_body_string "handler-c-post" (Response.create ()))
  in
  let _, body_a = dispatch mux "/a" in
  Alcotest.(check string) "path /a" "handler-a" body_a;
  let _, body_b = dispatch mux "/b" in
  Alcotest.(check string) "path /b" "handler-b" body_b;
  let rc_get, _ = dispatch mux "/c" in
  check_status "GET /c 405" Status.MethodNotAllowed rc_get;
  Alcotest.(check (option string))
    "Allow header" (Some "POST")
    (Header.get rc_get.header "Allow");
  let _, body_post = dispatch ~meth:Method.Post mux "/c" in
  Alcotest.(check string) "POST /c" "handler-c-post" body_post

(* Registering two conflicting patterns returns [Error (Register _)]. *)
let handle_conflict_result () =
  let mux =
    match
      Mux.handle "/a/{x}"
        (fun _pv ~sw:_ _r -> Response.with_body_string "a" (Response.create ()))
        Mux.empty
    with
    | Ok mux -> mux
    | Error _ -> Alcotest.fail "first registration should succeed"
  in
  (match
     Mux.handle "/a/{y}"
       (fun _pv ~sw:_ _r -> Response.with_body_string "b" (Response.create ()))
       mux
   with
  | Error (Mux.Register msg) ->
      Alcotest.(check bool)
        "conflict message" true
        (contains msg "conflicts with")
  | Ok _ -> Alcotest.fail "conflicting registration should be Error");
  match
    Mux.handle ""
      (fun _pv ~sw:_ _r -> Response.with_body_string "c" (Response.create ()))
      mux
  with
  | Error (Mux.Register _) -> ()
  | Ok _ -> Alcotest.fail "empty pattern should be Error"

(* The registered builder receives the wildcard captures keyed by name. A single
   [{id}] wildcard and a trailing [{rest...}] multi-wildcard are both surfaced;
   the anonymous trailing slash contributes nothing. *)
let path_value_test () =
  let mux =
    Result.get_ok
      (Mux.handle "GET /items/{id}/files/{rest...}"
         (fun pv ~sw:_ _r ->
           let get k =
             match Mux.StringMap.find_opt k pv with
             | Some v -> v
             | None -> "<unset>"
           in
           Response.with_body_string
             (Printf.sprintf "id=%s rest=%s" (get "id") (get "rest"))
             (Response.create ()))
         Mux.empty)
  in
  let _, body = dispatch mux "/items/42/files/a/b/c" in
  Alcotest.(check string) "captured wildcards" "id=42 rest=a/b/c" body

(* [Mux.mount] re-registers every submux route under the subtree prefix. The
   submux's own [{id}] wildcard still resolves after the prefix is prepended. *)
let mount_test () =
  let submux =
    Result.get_ok
      (Mux.handle "/users/{id}"
         (fun pv ~sw:_ _r ->
           let id =
             Option.value ~default:"<unset>" (Mux.StringMap.find_opt "id" pv)
           in
           Response.with_body_string
             (Printf.sprintf "user=%s" id)
             (Response.create ()))
         Mux.empty)
  in
  let mux = Result.get_ok (Mux.mount "/api/" ~nested:submux Mux.empty) in
  let _, body = dispatch mux "/api/users/7" in
  Alcotest.(check string) "mounted route" "user=7" body

(* Mounting only prepends path segments, so the subtree pattern must carry no
   method or host; either is rejected with a clear message. *)
let mount_rejects_method_host_test () =
  let submux =
    Result.get_ok
      (Mux.handle "/x"
         (fun _pv ~sw:_ _r ->
           Response.with_body_string "x" (Response.create ()))
         Mux.empty)
  in
  let check label pat =
    match Mux.mount pat ~nested:submux Mux.empty with
    | Error (Mux.Register msg) ->
        Alcotest.(check bool)
          label true
          (contains msg "must not have a method or host")
    | Ok _ -> Alcotest.failf "%s: expected Error" label
  in
  check "method" "GET /api/";
  check "host" "example.com/api/"

(* A middleware that appends its [name] to the [X-Trace] response header, so the
   header values record which middlewares ran, in order. *)
let tag (name : string) : Middleware.t =
 fun next ~sw r -> Response.with_header "X-Trace" name (next ~sw r)

(* The middleware chain is built at dispatch time over the accumulated list, so
   [add_middleware] wraps every route regardless of whether it was registered
   before or after the call — not just the routes already in the tree. *)
let add_middleware_applies_to_all_routes_test () =
  let mux =
    handle_func Mux.empty "/before" (fun ~sw:_ _r ->
        Response.with_body_string "before" (Response.create ()))
  in
  let mux = Mux.add_middleware (tag "mw") mux in
  (* Registered after add_middleware: must still pick up the middleware. *)
  let mux =
    handle_func mux "/after" (fun ~sw:_ _r ->
        Response.with_body_string "after" (Response.create ()))
  in
  let r_before, body_before = dispatch mux "/before" in
  Alcotest.(check string) "before body" "before" body_before;
  Alcotest.(check (list string))
    "route registered before add_middleware is wrapped" [ "mw" ]
    (Header.values r_before.header "X-Trace");
  let r_after, body_after = dispatch mux "/after" in
  Alcotest.(check string) "after body" "after" body_after;
  Alcotest.(check (list string))
    "route registered after add_middleware is wrapped" [ "mw" ]
    (Header.values r_after.header "X-Trace")

(* A mounted submux carries its own middleware across the mount, and the parent
   mux's middleware still wraps the result — each applied exactly once (no drop,
   no double application). *)
let mount_carries_nested_middleware_test () =
  let submux =
    handle_func Mux.empty "/x" (fun ~sw:_ _r ->
        Response.with_body_string "x" (Response.create ()))
  in
  let submux = Mux.add_middleware (tag "nested") submux in
  let parent = Mux.add_middleware (tag "parent") Mux.empty in
  let parent = Result.get_ok (Mux.mount "/api/" ~nested:submux parent) in
  let resp, body = dispatch parent "/api/x" in
  Alcotest.(check string) "handler ran" "x" body;
  (* Parent middleware is outermost (applied at dispatch over the whole tree),
     nested is inner (baked into the mounted handler). The inner one returns
     first, so it appends its value first: [nested] then [parent]. Each appears
     once — no drop, no double application. *)
  Alcotest.(check (list string))
    "both middlewares applied once" [ "nested"; "parent" ]
    (Header.values resp.header "X-Trace")

let tests =
  [
    Alcotest.test_case "not_found" `Quick not_found_test;
    Alcotest.test_case "mux_routing" `Quick mux_routing_test;
    Alcotest.test_case "handle_conflict_result" `Quick handle_conflict_result;
    Alcotest.test_case "path_value" `Quick path_value_test;
    Alcotest.test_case "mount" `Quick mount_test;
    Alcotest.test_case "mount_rejects_method_host" `Quick
      mount_rejects_method_host_test;
    Alcotest.test_case "add_middleware_applies_to_all_routes" `Quick
      add_middleware_applies_to_all_routes_test;
    Alcotest.test_case "mount_carries_nested_middleware" `Quick
      mount_carries_nested_middleware_test;
  ]
