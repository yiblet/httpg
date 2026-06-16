(* Error-policy guard suite (Result migration Ticket 8).

   This is a meta/regression test that locks in the project's error-handling
   philosophy (see [plans/error-handling-audit.md] and [CLAUDE.md]/[AGENTS.md]):

   - Handleable errors are surfaced as values: [('a, error) result] (direct
     style under Eio), with each module owning a typed [type error] (or, for the
     HTTP/2 frame layer, the unified [H2_error.t]).
   - Unhandleable errors (programmer bugs, invariant violations, internal
     control-flow sentinels) stay as exceptions, documented in their [.mli].

   The guard is file-based over the [lib/*.mli] / [lib/internal/*.mli] sources.
   It must stay robust: it tolerates whitespace and does not depend on the
   exact wording of declarations. It fails if:
     - any [.mli] reintroduces an [*_exn] shim identifier, or
     - a migrated module drops its declared error type. *)

(* ----------------------------------------------------------------------- *)
(* Locate the source [lib/] directory. Under [dune test] the runner's cwd is
   [_build/default/test]; the lib [.mli]s live at [../lib]. We also try a few
   other candidates so the suite is robust to where it is launched from. The
   [.mli] files are declared as deps of the test executable (see test/dune) so
   dune materializes them next to the runner. *)

let candidate_lib_dirs = [ "../lib"; "lib"; "../../lib"; "../default/lib" ]

let find_lib_dir () =
  match
    List.find_opt
      (fun d -> Sys.file_exists (Filename.concat d "io.mli"))
      candidate_lib_dirs
  with
  | Some d -> d
  | None ->
      Alcotest.failf
        "could not locate lib/ dir containing io.mli (cwd=%s; tried: %s)"
        (Sys.getcwd ())
        (String.concat ", " candidate_lib_dirs)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* Read [<lib>/<name>.mli], where [name] may be a nested path like
   "internal/chunked". *)
let read_mli lib name =
  let path = Filename.concat lib (name ^ ".mli") in
  if not (Sys.file_exists path) then
    Alcotest.failf "missing .mli: %s (cwd=%s)" path (Sys.getcwd ());
  read_file path

(* Substring search (whitespace-tolerant in the sense that we look for the
   token, not an exact line). *)
let contains ~needle haystack =
  let nlen = String.length needle and hlen = String.length haystack in
  if nlen = 0 then true
  else begin
    let found = ref false in
    let i = ref 0 in
    while (not !found) && !i <= hlen - nlen do
      if String.sub haystack !i nlen = needle then found := true;
      incr i
    done;
    !found
  end

(* ----------------------------------------------------------------------- *)
(* The modules migrated by the Result migration (Tickets 2-7) that must each
   declare a typed error type in their [.mli]. Most declare [type error];
   [h2_frame] uses the unified [H2_error.t] (so we require it to reference
   [H2_error.t] in its result-returning signatures); [h2_error] owns the
   unified type as [type t]. *)

(* The HTTP/2 stack lives in lib/internal/http2/ (its own httpg_http2 library);
   hpack/hpack_huffman/h2_frame/h2_error are reached by their nested path. *)
let modules_with_type_error =
  [
    "transfer";
    "io";
    "internal/http2/hpack";
    "internal/http2/hpack_huffman";
    "internal/pattern";
    "internal/httpcommon";
    "cookie";
    "fs";
    "form";
    "mux";
    "multipart";
  ]

(* All [.mli] files we sweep for the no-[_exn] guard. *)
let all_mli_modules =
  modules_with_type_error
  @ [
      "internal/http2/h2_frame";
      "internal/http2/h2_error";
      "client";
      "transport";
      "internal/chunked";
    ]

(* The unhandleable allowlist: modules whose surviving exceptions /
   invariants / control-flow sentinels are deliberately kept (never converted
   to Result). Enumerated here as a static, documented list mirroring
   [plans/error-handling-audit.md] "Unhandleable allowlist". *)
let unhandleable_allowlist =
  [
    "h2_flow";
    (* Invalid_argument: window-accounting invariant *)
    "h2_writesched";
    (* Failure: scheduler invariant *)
    "net";
    (* Failure: bound_port + TLS/csr setup misuse (write-before-handshake, bad
       config). Note: the handleable network failures are the typed [Net.error]
       variant ([Dial]/[Tls]) threaded as [(_, error) result] by the client
       entry points -- there is no public [exception] on [Net]. The only
       surviving Net raises are INTERNAL ([Internal_tls_error]/
       [Internal_dial_error], not in net.mli): the Eio-forced mid-stream
       Flow.SOURCE read (mapped back to [Error] at the connect boundary) and the
       [result]-free [listen]/[accept_tls] startup/per-conn contracts. *)
    "hpack_tables";
    (* Invalid_argument: table-index invariant (evict_oldest) *)
    "hpack";
    (* raise Exit: internal varint loop control flow; the decoder's incremental
       [write]/[close] path raises internal decode sentinels (not in the .mli)
       mapped back to [error] at the [result] boundary *)
    "hpack_huffman";
    (* raise Exit: internal loop control flow *)
    "pattern";
    (* let exception Done; failwith describeConflict invariants *)
    "mapping";
    (* let exception Stop: iteration control flow *)
    "cookie";
    (* raise Exit: String.iter early-exit *)
    "h2_frame";
    (* Invalid_argument "illegal window increment": write-side invariant *)
    "httptest";
    (* invalid_arg "invalid WriteHeader code": precondition *)
    "routing_tree";
    (* failwith: tree-construction invariant *)
    "h2_write";
    (* failwith "unexpected empty hpack": encoder invariant *)
    "h2_transport";
    (* internal conn-loop control-flow exceptions (boundary-only conv) *)
    "h2_server";
    (* internal conn-loop control-flow (boundary-only conv) *)
    (* [client] is intentionally NOT here: its public API is fully resulty
       ([do_]/[get]/[head]/[post] return [(Response.t, Client.error) result]);
       the former [exception Aborted] was retired in favour of the
       [Error (Redirect _)] arm. *)
  ]

(* ----------------------------------------------------------------------- *)

let test_no_handleable_raise_escapes () =
  let lib = find_lib_dir () in
  (* (a) No [*_exn] shim identifier survives in any swept [.mli]. The sole
     sanctioned [_exn] occurrence is [error_to_exn] — the inverse of
     [error_of_exn], the supported boundary bridge that re-raises a typed
     [error] as the exception it was mapped from (per the plan; same shape as
     [H2_transport.error_to_exn]). Strip it before the substring check so the
     guard still catches real [*_exn] result-bypassing shims. *)
  let strip_sanctioned src =
    Str.global_replace (Str.regexp_string "error_to_exn") "" src
  in
  List.iter
    (fun m ->
      let src = strip_sanctioned (read_mli lib m) in
      Alcotest.(check bool)
        (Printf.sprintf "%s.mli has no _exn identifier" m)
        false
        (contains ~needle:"_exn" src))
    all_mli_modules;
  (* (b) Each migrated module still declares its typed error type. *)
  List.iter
    (fun m ->
      let src = read_mli lib m in
      Alcotest.(check bool)
        (Printf.sprintf "%s.mli declares 'type error'" m)
        true
        (contains ~needle:"type error" src))
    modules_with_type_error;
  (* h2_error owns the unified handleable type as [type t]. *)
  let h2_error = read_mli lib "internal/http2/h2_error" in
  Alcotest.(check bool)
    "h2_error.mli declares 'type t'" true
    (contains ~needle:"type t" h2_error);
  (* h2_frame surfaces the unified [H2_error.t] at its read boundary. *)
  let h2_frame = read_mli lib "internal/http2/h2_frame" in
  Alcotest.(check bool)
    "h2_frame.mli references H2_error.t in a result" true
    (contains ~needle:"H2_error.t) result" h2_frame)

let test_unhandleable_allowlisted () =
  (* This test documents (and asserts the shape of) the unhandleable
     allowlist. It is intentionally a static enumeration that mirrors
     [plans/error-handling-audit.md]; if a surviving exception is added or
     removed, this list and the audit doc must be updated together. *)
  Alcotest.(check bool)
    "allowlist is non-empty" true
    (List.length unhandleable_allowlist > 0);
  (* No duplicates in the enumerated allowlist. *)
  let sorted = List.sort_uniq String.compare unhandleable_allowlist in
  Alcotest.(check int)
    "allowlist has no duplicates"
    (List.length unhandleable_allowlist)
    (List.length sorted);
  (* Spot-check the canonical entries called out by the plan are present. *)
  List.iter
    (fun expected ->
      Alcotest.(check bool)
        (Printf.sprintf "allowlist contains %s" expected)
        true
        (List.mem expected unhandleable_allowlist))
    [
      "h2_flow";
      "h2_writesched";
      "net";
      "hpack_tables";
      "hpack";
      "pattern";
      "mapping";
      "routing_tree";
      "h2_write";
      "httptest";
    ]

let tests =
  [
    Alcotest.test_case "no_handleable_raise_escapes" `Quick
      test_no_handleable_raise_escapes;
    Alcotest.test_case "unhandleable_allowlisted" `Quick
      test_unhandleable_allowlisted;
  ]
