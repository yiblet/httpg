# gohttp — Exceptions → Result.t / Lwt_result Migration — Plan

## Operating Requirements

**CRITICAL: COPY THIS SECTION VERBATIM TO EVERY NEW PLAN FILE YOU CREATE.**

### PLANNING

1. **SURFACE QUESTIONS AFTER DRAFTING.** When you finish the draft, you MUST list questions/concerns and point reviewers to the exact places to look.
2. **CONFIRM INTENT BEFORE GOING TO IMPLEMENTATION.** When you finish the draft, you MUST confirm intent and confirm that the plan is ready for implementation.

### EXECUTION

1. **UPDATE TICKETS WITH PROGRESS CONTINUOUSLY.** As you begin or complete a ticket, you MUST update the plan with what changed and which tests were added.
2. **ALWAYS TEST AND VERIFY COMPLETION.** Always test and verify completion of a ticket before proceeding to the next one.
3. **CHECK TESTS AT TICKET START.** At the start of a new ticket, check tests to ensure everything is working.
4. **CREATE COMMIT PER TICKET.** Create a commit per ticket at completion. Use semantic commit message conventions for the message.

> **VCS NOTE (this project):** version control is **jj (Jujutsu)**, colocated with git. Per-ticket commit = `jj commit -m "<type>: <summary>"`. Inspect with `jj st` / `jj log`. Do **not** use `git commit`.

## Problem

- **Goal:** Adopt a single, explicit error-handling philosophy across `gohttp` — **`Result.t` (with typed error variants per module) for every *handleable* error; exceptions only for the *unhandleable*** (programming bugs / invariant violations). Pure code returns `('a, error) result`; Lwt/IO code returns `('a, error) result Lwt.t` (composed with `Lwt_result`). This is recorded in `CLAUDE.md` and must hold across the codebase. It also tightens fidelity to Go, which returns `(T, error)` for handleable cases and `panic`s for bugs.
- **Success Criteria (as tests):**
  - *Unit:* `Transfer.parse_content_length_result` — `Transfer.parse_content_length ["x"]` returns `Error (Bad_content_length "x")` (today it raises `Bad_string_error`); a valid `["42"]` returns `Ok 42L`. Plus `Hpack.decode_invalid_index` — decoding a header block with an out-of-range index returns `Error (Invalid_indexed _)` rather than raising.
  - *Integration:* `Io.read_request_malformed` — feeding a malformed request (`"GET\r\n\r\n"` / bad header line) to `Io.read_request` over an `Lwt_io` pipe yields `Error (Protocol _)` (an `('a, Io.error) result Lwt.t`), never an unhandled exception; a well-formed request yields `Ok req`. End-to-end, `Server`/`Client` round-trips in the existing suites still pass unchanged.
  - *Guard:* `Error_policy.no_handleable_raise_escapes` — a meta-test (grep-based, see Ticket 8) asserting the modules migrated in this plan expose `error` types and no longer `raise` handleable exceptions across their `.mli`.
- **Non-Goals:** Converting *unhandleable* sites to `Result` (programmer-bug `Invalid_argument`/`Failure`/`assert false` in `h2_flow`, `h2_writesched`, `net.bound_port`, `hpack_tables.evict_oldest`, and internal control-flow exceptions like `Hpack.Need_more`, `let exception Done/Stop` in `pattern`/`mapping` — these **stay** as exceptions, by design); rewriting the h2 per-connection event-loop's internal exception→GOAWAY/RST machinery (only its *public boundaries* surface `result`); changing Go-test fidelity rules; introducing a new opam dependency (`Lwt_result` ships with `lwt`).
- **Constraints:** OCaml ≥ 5.0, `dune build` is **warnings-as-errors** (exhaustive-match warnings are the safety net for this migration). Every `lib/` module keeps a hand-written `.mli` in sync. Mirror Go's structures. **When a ported test fails, fix the implementation, not the test**, unless it's a genuine OCaml-API porting artifact (call it out). Repo must build green and the full `dune test` suite must pass at the end of every ticket.

## Discovery

- **Key user/runtime paths that raise today:** request/response read (`Io.read_request`/`read_response` → `Protocol_error`, `Missing_host`), body framing (`Transfer`/`internal/chunked` → `Bad_string_error`, `Chunk_error`, `Err_line_too_long`), HPACK decode (`Hpack`/`Hpack_huffman` → `Decoding_error`, `Invalid_indexed`, `String_too_long`, `Invalid_huffman`), HTTP/2 frame read (`H2_frame`/`H2_error` → `Connection_error`, `Stream_error`, `Frame_too_large`, …), endpoint glue (`Server.handle` → `Register_error`, `Client.do_` → `Failure` on redirect policy, `Fs` → `Invalid_unsafe_path`/`No_overlap`/`Invalid_range`, `Form` → `Form_error`/`Not_multipart`).
- **Current architecture (error style is already mixed):**
  - **Already `result`:** `Values.parse_query` (`(unit,string) result`), `Client.check_redirect` (`(unit,string) result`), `Form.parse_form` (`(unit,string) result Lwt.t`), `Pattern.parse` (`(t,string) result`), `Cookie.valid` (`(unit,string) result`), `Fs.parse_range`/`Fs.file_system.open_` (`(_,exn) result`), `Hpack.read_var_int` (`(int*int,exn) result`). These use **strings or `exn`** as the error — the migration normalizes them to **typed variants**.
  - **Exceptions across the `.mli` boundary (handleable):** `transfer`, `internal/chunked`, `io`, `hpack`, `hpack_huffman`, `h2_frame`, `h2_error`, `h2_pipe`, `h2_databuffer`, `server` (`Register_error`), `form`, `fs`.
  - **Exceptions caught internally (no boundary change needed beyond cleanup):** `pattern` (`Parse_error` caught in `parse`), `h2_transport` (`Client_conn_closed`/`Conn_got_goaway`/`Stream_aborted`/`Malformed_response` are internal to the conn loop).
  - **Unhandleable (KEEP as exceptions):** `h2_flow` (`Invalid_argument` on window-overflow invariant), `h2_writesched` (`Failure` on illegal stream-id/DATA invariant), `net.bound_port` (`Failure` precondition), `hpack_tables.evict_oldest` (`Invalid_argument`), `Hpack.Need_more` (decoder control-flow sentinel), `let exception Done/Stop` in `pattern`/`mapping`.
  - Raw counts (audit): ~36 `exception` decls; ~120 `raise`, 58 `Lwt.fail`, 16 `failwith`, 8 `invalid_arg`. Heaviest raise files: `h2_frame` (49), `io` (19), `h2_transport` (15), `internal/chunked` (14), `transfer` (13), `hpack` (12).
- **Critical contracts that constrain the change:**
  - `Io.read_request : Lwt_io.input_channel -> Body.t Request.t Lwt.t` and `read_response` are consumed by `Server` (`server.ml`), `Transport`, `Client`. Changing their return type ripples into the request-serving loop and the keep-alive client.
  - `Transfer.read_transfer : message -> Lwt_io.input_channel -> result Lwt.t` (note: `Transfer.result` is an existing record type — the migration must not collide with the new `error` naming; use `Transfer.error` for the variant and leave the `result` record as-is or rename — see Areas of Uncertainty).
  - `Body.t = Empty | String of string | Stream of (unit -> string option Lwt.t)` — the stream thunk currently *raises* on framing errors mid-stream. A streaming read can fail *after* headers are returned; that error surfaces inside the thunk, not at the `read_request` boundary. The migration must decide how mid-stream framing errors are represented (see Areas of Uncertainty).
  - `Server.handler.serve_http : response_writer -> Body.t Request.t -> unit Lwt.t` is the public handler contract — unchanged by this plan.
- **Migration pressure points:**
  - **Caller fan-out.** `Transfer` and `Io` have many callers. Converting a low-level module forces every caller to handle the new `result` *in the same ticket*, or the build breaks. Mitigation: each low-level ticket ships a temporary **`*_exn` shim** (raises the old exception) so not-yet-migrated callers keep compiling; later tickets delete the shim.
  - **`Lwt_result` ergonomics.** `('a, e) result Lwt.t` needs `let*`/`>>=` from `Lwt_result` to stay readable. Introduce a shared `let ( let* )`/`( let+ )` open convention (Ticket 1) so every migrated module uses the same idiom.
  - **h2 event loop.** `h2_server`/`h2_transport` translate internal exceptions into GOAWAY/RST/stream-abort. Only the *public* entrypoints (`read_frame`, `round_trip`, `serve`) need a `result` surface; the internal loop can keep exceptions. Don't over-convert.
- **Areas of Uncertainty (decide before/within the cited tickets):**
  1. **Mid-stream body errors.** When a chunked body is malformed *after* `read_request` returned `Ok`, where does the error go? Options: (a) the `Body.Stream` thunk returns a `result` (`(string option, error) result Lwt.t`) — viral, touches every body consumer; (b) keep the thunk raising for the *mid-stream* case and only convert the *header/initial-parse* boundary to `result`. **Recommendation:** (b) — Go itself surfaces mid-body errors as a later `Read` error, and OCaml's stream thunk raising is the faithful analogue; document it as a deliberate exception-stays case. Decide in **Ticket 4**.
  2. **`Transfer.result` name clash.** `transfer.mli` already exports `type result`. Introduce `type error` (no clash) and keep `result`; do **not** shadow `Stdlib.result`. Confirm in **Ticket 4**.
  3. **h2 error surface granularity.** Whether `H2_frame.read_frame` returns `(frame, H2_error.t) result Lwt.t` with a unified `H2_error.t` variant, vs. a frame-local `error`. **Recommendation:** unify under `H2_error.t` since `H2_error` already models connection/stream codes. Decide in **Ticket 7**.
  4. **`exn`-typed results already in the API** (`Fs`, `Hpack.read_var_int`, `Fs.file_system.open_`). These become typed variants; `Fs.file_system.open_` is a *public extension point* (callers implement filesystems) — changing `(file,exn) result` to `(file, Fs.error) result` is a breaking signature change for any external implementer. In-repo only today, so safe; note it. Decide in **Ticket 6**.

## Target Shape

- **Responsibilities / Ownership:**
  - Each module **owns a `type error`** (closed, typed variant) declared in its `.mli`, covering exactly its *handleable* failures. Lower-level error types are *embedded* in higher-level ones (e.g. `Io.error` has an arm `Transfer of Transfer.error`; `H2_frame`/`H2_server` errors embed `H2_error.t`). No global mega-error type.
  - Unhandleable failures remain exceptions, owned where they are, and are **documented** in the `.mli` as "raises X on programmer error / invariant violation."
- **Public Contracts (target signatures):**
  - Pure: `Pattern.parse : string -> (t, error) result`; `Values.parse_query : string -> t * (unit, error) result`; `Cookie.valid : t -> (unit, error) result`; `Hpack.decode_full : decoder -> string -> (header_field list, error) result`; `Hpack_huffman.decode : string -> (string, error) result`.
  - Lwt: `Transfer.read_transfer : message -> Lwt_io.input_channel -> (result, error) Stdlib.result Lwt.t`; `Io.read_request : Lwt_io.input_channel -> (Body.t Request.t, error) result Lwt.t` (and `read_response`, `read_mime_header`, `write_request`); `H2_frame.read_frame : ?max_size:int -> Lwt_io.input_channel -> (frame, H2_error.t) result Lwt.t`.
  - Endpoints: `Server.handle : serve_mux -> string -> handler -> (unit, error) result` (registration); `Fs.parse_range : string -> int64 -> (http_range list, error) result`; `Form.parse_multipart_form : ... -> (unit, error) result Lwt.t`.
- **Execution Flow:** request serving becomes: `Io.read_request ic` → `match` on `result` → on `Error e`, the server writes the appropriate status (e.g. 400) and closes/keeps-alive per policy, instead of a `Lwt.catch` around the read. Internally, low-level reads compose with `Lwt_result`'s `let*` so the first `Error` short-circuits the chain.
- **Migration Shape:** strictly **bottom-up**, one module (+ its direct callers) per ticket. Each low-level ticket adds a `name_exn` shim (`val read_transfer_exn : ... -> result Lwt.t` raising the legacy exception) consumed by not-yet-migrated callers; the shim is deleted by the ticket that migrates the last caller. `Lwt_result` `let*`/`let+` opened locally per module via a shared `Result_syntax`/`Lwt_result.Syntax` convention established in Ticket 1.
- **End-State Properties:** every handleable failure is visible in the type; `dune build`'s exhaustiveness checking forces callers to handle each error arm; exceptions are a small, documented, unhandleable-only set; the codebase matches Go's `(T,error)`/`panic` split and the `CLAUDE.md` convention; the guard test prevents regressions.

## Implementation Guide

- **Execution Model:** Act as an **orchestrator**. Work tickets **serially, bottom-up, one at a time**. For each ticket, spawn a dedicated **ticket sub-agent** scoped to that ticket only. Do not parallelize tickets (each depends on the previous module's `error` type).
- **Per-Ticket Workflow (the sub-agent MUST):**
  1. Run `dune build && dune test` first to confirm a green baseline (Operating Requirement: check tests at start).
  2. Implement the ticket: define `type error` in the `.mli`, convert public functions to return `result`/`result Lwt.t`, update the `.ml`, update **all direct callers** (or add the `*_exn` shim so callers still compile), keep streaming behavior intact.
  3. Port/adjust the matching Go test assertions (expect `Error _` where they expected a raise); add the named tests from the ticket's Testing Plan to `test/test_<x>.ml` and register them in `test/test_gohttp.ml`.
  4. `dune build` (warnings-as-errors) **and** `dune test` must pass. Record the exact command output as evidence.
  5. Update this plan's ticket **Execution Record** (status, what changed, test evidence, commit id).
  6. `jj commit -m "<type>: <summary>"`.
- **Verification Gate:** the orchestrator may proceed only when the ticket's Execution Record shows (a) `dune build` clean, (b) `dune test` passing with the new named tests listed, and (c) a commit id. If evidence is missing, spawn a verification sub-agent to run `dune build && dune test`, record results, and confirm — before advancing.
- **Failure Handling:** if a ticket sub-agent fails, capture its feedback, adjust the plan if needed, and retry **once** with a fresh sub-agent. If it fails twice, **stop** and return control to the user with the failure context (do not advance).
- **Scope Handling:** if the user names a single ticket, execute only that one. If the user asks for the whole plan, execute Tickets 1→8 in order. Never skip ahead — a later module's `error` type embeds an earlier one.

## Build Out

### Ticket 1 — Audit artifact + `Lwt_result` conventions (no behavior change)
Status: Done

**A) Scope**
Land the durable **audit/decomposition** the migration is built on, plus the shared `Lwt_result` idiom every later ticket uses. Deliver `plans/error-handling-audit.md`: a table of every `exception`/`raise`/`failwith`/`invalid_arg` site classified **handleable vs unhandleable**, with the target per-module `error` variant and the ticket that converts it. No `lib/` behavior changes — purely additive infra + docs.

**B) Migration Strategy**
Additive only. Introduce a tiny shared syntax convention for `('a,'e) result Lwt.t` (use stdlib `Lwt.Syntax`/`Lwt_result.Syntax` — `lwt` already provides `Lwt_result`). No public signatures change, so the build/tests are unaffected.

**C) Exit State**
`plans/error-handling-audit.md` exists and matches the current code; the `Lwt_result` usage pattern is documented (a short `README`-style note in the audit doc, or a `lib/result_syntax.ml` helper if a shared open is warranted). `dune build && dune test` green.

**D) Detailed Design**
- Audit doc columns: `module | site (file:line) | exception/raise | handleable? | target error arm | ticket`.
- Decide whether to add `lib/result_syntax.ml(i)` re-exporting `Lwt_result.Syntax`'s `let*`/`let+` plus `Result.Syntax` for pure code, or to just `open Lwt_result.Syntax` per module. **Recommendation:** no new module; `open Lwt_result.Syntax` locally — but if 3+ modules need the same pure+Lwt mix, add `Result_syntax`. Record the decision in the doc.

**E) Testing Plan**
- **Unit:** none required (no behavior change). Add a placeholder/no-op is unnecessary. Verification is `dune build && dune test` stays green. (The guard test itself lands in Ticket 8 once modules expose `error`.)

**F) End-of-Ticket Verification**
`dune build` (warnings-as-errors) clean; `dune test` full suite passes; audit doc committed.

**G) Execution Record**

**Status:** Done.

**What changed (additive only — no `lib/` behavior or signature changes):**
- Added `plans/error-handling-audit.md`, the durable audit/decomposition doc:
  - A **Conventions** section documenting the error philosophy and the
    **`Lwt_result` syntax decision**: *no new `lib/result_syntax.ml(i)` module* —
    each migrated module uses `open Lwt_result.Syntax` locally for
    `('a, error) result Lwt.t` and `open Result.Syntax` (stdlib, OCaml ≥ 5.4; this
    switch is 5.4.1) or explicit `match` for pure `('a, error) result`. Verified
    `Lwt_result` ships with the `lwt` opam package (`_opam/lib/lwt/lwt_result.mli`,
    lwt 6.1.2) and `lwt` is already a `lib/dune` dependency — **no new opam dep.**
    Includes a `let*` idiom code example.
  - A **migrated-module audit table** (columns `module | site (file:line) |
    exception/raise kind | handleable? | target error arm | ticket`) covering every
    handleable site in `transfer`, `internal/chunked`, `io`, `hpack`,
    `hpack_huffman`, `h2_frame`, `h2_error`, `h2_pipe`, `h2_databuffer`, `server`,
    `form`, `fs`, `pattern`, `values`, `cookie`, grouped by the converting ticket
    (2–7), each mapped to its target per-module `error` variant.
  - An **unhandleable allowlist** (`h2_flow`, `h2_writesched`, `net.bound_port` +
    other `net` setup `failwith`, `hpack_tables` incl. `evict_oldest`,
    `Hpack.Need_more`, `Hpack.read_var_int` precondition, `pattern`/`mapping`
    `let exception Done/Stop`, `cookie`/`hpack` internal `raise Exit`,
    `h2_frame:418` window-increment invariant, plus `context`, `httptest`,
    `routing_tree`, `h2_write` invariants) — these stay exceptions, to be documented
    in their `.mli`s.
  - **Raw counts** at the baseline.
- No source files under `lib/` were touched.

**Test evidence:**
```
$ dune build --root <worktree>     # warnings-as-errors
=== BUILD EXIT: 0 ===
$ dune test --root <worktree> --force
Test Successful in 1.847s. 487 tests run.
=== TEST EXIT: 0 ===
```
(Baseline before the change was identical: build exit 0, 487 tests run, all OK —
no behavior change, as expected.)

**Commit id:** `jj` change **`vwsywrln`** (canonical, stable id)
(`docs: error-handling audit + Lwt_result conventions (Result migration T1)`).
Resolve the current git commit hash with `jj log -r vwsywrln`.

### Ticket 2 — Pure parsers → typed `error` variants (pattern, values, cookie)
Status: Planned

**A) Scope**
Normalize the modules that *already* return `result` (but with `string`/`exn` payloads) to **typed variants**, establishing the idiom on the safest, purely-functional surface. Converts `Pattern.parse`, `Values.parse_query`/`parse_query_into`, `Cookie.valid`.

**B) Migration Strategy**
These are pure and already return `result`, so callers change only in the *payload* they match. Update in-repo callers (`Server`/`routing` for `Pattern`, request form helpers for `Values`). No shim needed (signature shape `(_, _) result` is preserved; only the error type param changes).

**C) Exit State**
`Pattern.error`, `Values.error`, `Cookie.error` declared in their `.mli`s; no `string`-typed error results remain in these three. Build + tests green.

**D) Detailed Design**
```ocaml
(* pattern.mli *)
type error =
  | Empty_pattern
  | Invalid_method of string
  | Missing_path            (* host present, path empty *)
  | Unclean_path of string
  | Bad_wildcard of string
  | Duplicate_wildcard of string
val parse : string -> (t, error) result   (* was (t, string) result *)

(* values.mli *)
type error = Invalid_semicolon_separator | Invalid_escape of string
val parse_query : string -> t * (unit, error) result
val parse_query_into : t -> string -> (unit, error) result

(* cookie.mli *)
type error = Invalid_name of string | Invalid_value of string | Invalid_domain of string | ...
val valid : t -> (unit, error) result
```
Exact arms refined against Go's error strings in `pattern.go`/`url.go`/`cookie.go`; keep a catch-all `Other of string` only if a Go message has no natural variant.

**E) Testing Plan**
- **Unit:** `Pattern.parse_errors_typed` — representative bad patterns map to the right arm (`""`→`Empty_pattern`, `"GE T /"`→`Invalid_method _`, `"/x{}"`→`Bad_wildcard _`); a valid pattern → `Ok`. `Values.parse_query_typed` — `"a;b=c"` → `Error Invalid_semicolon_separator`. Port the existing `pattern`/`values` Go test assertions to the typed arms.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` passes incl. new named tests.

**G) Execution Record**
_(fill on completion)_

### Ticket 3 — HPACK codec → `result` (hpack, hpack_huffman)
Status: Planned

**A) Scope**
Convert the pure HPACK decode path to `result` with a typed `error`, keeping `Need_more` as an internal control-flow exception (unhandleable). High value: every HTTP/2 header block decode flows through here.

**B) Migration Strategy**
`Hpack`/`Hpack_huffman` are pure and consumed by `H2_frame`/`h2` (migrated in Ticket 7). Add `Hpack.decode_full_exn`/`Hpack_huffman.decode_exn` shims raising the legacy exceptions so `H2_frame` keeps compiling until Ticket 7. `Hpack.read_var_int` already returns `(_, exn) result` → switch its payload to `Hpack.error`.

**C) Exit State**
`Hpack.error`, `Hpack_huffman.error` in `.mli`; decode entrypoints return `result`; `*_exn` shims present for h2 callers; `Need_more` documented as internal. Build + tests green.

**D) Detailed Design**
```ocaml
(* hpack.mli *)
type error =
  | Decoding of string
  | Invalid_indexed of int
  | String_too_long
  | Invalid_huffman           (* propagated from Hpack_huffman *)
  | Var_int_overflow
val decode_full : decoder -> string -> (header_field list, error) result
val read_var_int : int -> string -> int -> ((int * int), error) result
val decode_full_exn : decoder -> string -> header_field list   (* shim, deleted in T7 *)
(* exception Need_more stays — internal sentinel, documented *)

(* hpack_huffman.mli *)
type error = Invalid_huffman
val decode : string -> (string, error) result
val decode_exn : string -> string   (* shim, deleted in T7 *)
```

**E) Testing Plan**
- **Unit:** `Hpack.decode_invalid_index` — block with out-of-range index → `Error (Invalid_indexed _)`. `Hpack.decode_string_too_long` → `Error String_too_long`. `Hpack_huffman.decode_invalid` → `Error Invalid_huffman`; valid round-trip → `Ok`. Port the `hpack` Go decode-error tests to assert arms.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` (incl. `Hpack` suite) passes.

**G) Execution Record**
_(fill on completion)_

### Ticket 4 — Transfer framing → `Lwt_result` (transfer, internal/chunked)
Status: Planned

**A) Scope**
First Lwt/IO conversion: `Transfer` + `Gohttp_internal.Chunked` parse/frame functions return `result`/`result Lwt.t` with `Transfer.error`. Resolve the **mid-stream body error** decision (Areas of Uncertainty #1) and the **`Transfer.result` name** (#2).

**B) Migration Strategy**
`Transfer` is consumed by `Io`, `Body`, `H2_server`/`H2_transport`. Provide `Transfer.read_transfer_exn`, `Transfer.parse_content_length_exn`, etc. shims raising the legacy exceptions; `Io` (Ticket 5) and h2 (Ticket 7) migrate off the shims later. **Decision (recommended):** header/initial-framing errors → `result`; *mid-stream* `Body.Stream` thunk errors **stay as raises** (faithful to Go's later-`Read`-error model), documented in `body.mli`/`transfer.mli`.

**C) Exit State**
`Transfer.error` declared; `read_transfer`, `parse_content_length`, `parse_transfer_encoding`, chunked reader/writer entrypoints return `result`; `result` record type preserved (no clash); shims in place; mid-stream policy documented. Build + tests green.

**D) Detailed Design**
```ocaml
(* transfer.mli *)
type error =
  | Line_too_long
  | Chunk of string                 (* from Chunked.Chunk_error *)
  | Bad_content_length of string
  | Unsupported_transfer_encoding of string
  | Bad_header of string * string   (* was Bad_string_error (what, value) *)
  | Unexpected_eof
val parse_content_length : string list -> (int64, error) result
val read_transfer : message -> Lwt_io.input_channel -> (result, error) Stdlib.result Lwt.t
val read_transfer_exn : message -> Lwt_io.input_channel -> result Lwt.t   (* shim *)

(* internal/chunked.mli *)
type error = Line_too_long | Chunk of string
val parse_hex_uint : string -> (int64, error) result
(* new_chunked_reader: header parse via result; mid-stream thunk may still raise Chunk *)
```
Internally compose with `open Lwt_result.Syntax` (`let*`) so the first framing error short-circuits.

**E) Testing Plan**
- **Unit:** `Transfer.parse_content_length_result` (success criterion) — `["x"]`→`Error (Bad_content_length "x")`, `["42"]`→`Ok 42L`, conflicting lengths → `Error`. `Transfer.read_transfer_bad_chunk` — feed a bad chunk size over an `Lwt_io` pipe → `Error (Chunk _)`. Port `transfer_test.go` error cases.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` (incl. `Transfer` suite) passes; mid-stream policy noted in plan + `.mli` comments.

**G) Execution Record**
_(fill on completion)_

### Ticket 5 — Message read/write → `Lwt_result` (io)
Status: Planned

**A) Scope**
Convert the request/response boundary: `Io.read_mime_header`, `read_request`, `read_response`, `write_request` return `result`/`result Lwt.t` with `Io.error` (embedding `Transfer.error`). Migrate `Io` off `Transfer`'s `*_exn` shims.

**B) Migration Strategy**
`Io.read_request`/`read_response` are consumed by `Server`, `Transport`, `Client`. To keep those green before their own conversion (Ticket 6), update them to `match` on the new `result` and re-raise internally as a stopgap, **or** add `Io.read_request_exn` shims. **Recommendation:** add `Io.*_exn` shims; Server/Transport/Client switch to the `result` API in Ticket 6 and the shims are deleted there.

**C) Exit State**
`Io.error` declared (arms: `Protocol of string`, `Missing_host`, `Transfer of Transfer.error`, `Unexpected_eof`); read/write entrypoints return `result`; `Io` no longer calls `Transfer.*_exn`; shims for Server/Transport/Client present. Build + tests green.

**D) Detailed Design**
```ocaml
(* io.mli *)
type error =
  | Protocol of string        (* malformed MIME header / request line *)
  | Missing_host
  | Transfer of Transfer.error
  | Unexpected_eof
val read_mime_header : Lwt_io.input_channel -> (Header.t, error) result Lwt.t
val read_request    : Lwt_io.input_channel -> (Body.t Request.t, error) result Lwt.t
val read_response   : ?request:Body.t Request.t -> Lwt_io.input_channel -> (Body.t Response.t, error) result Lwt.t
val write_request   : Lwt_io.output_channel -> Body.t Request.t -> (unit, error) result Lwt.t
val read_request_exn : Lwt_io.input_channel -> Body.t Request.t Lwt.t   (* shim, deleted in T6 *)
```

**E) Testing Plan**
- **Integration:** `Io.read_request_malformed` (success criterion) — over an `Lwt_io` pipe, `"GET\r\n\r\n"` and a bad header line → `Error (Protocol _)`; a well-formed request → `Ok req`; missing Host on write → `Error Missing_host`. Bounded by `Net.with_timeout`.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` (incl. existing `Io`/request tests) passes.

**G) Execution Record**
_(fill on completion)_

### Ticket 6 — HTTP/1.x endpoints → `result` (server, client, transport, fs, form)
Status: Planned

**A) Scope**
Migrate the h1 endpoint layer: `Server.handle`/`handle_func` (`Register_error`→`result`), `Client.do_` redirect-policy abort (`Failure`→`result` or typed error), `Transport`/`Server` request loop to consume `Io`'s `result` API, `Fs` (`Invalid_unsafe_path`/`No_overlap`/`Invalid_range` + `parse_range`/`file_system.open_` to typed variants), `Form` (`Form_error`/`Not_multipart`). Delete `Io.*_exn` and `Transfer.*_exn` shims once their last caller is migrated.

**B) Migration Strategy**
Largest fan-out ticket; if it gets unwieldy, split into 6a (server+transport+client request loop) and 6b (fs+form). The serving loop converts `Lwt.catch (read_request)` into `match%lwt read_request with Ok r -> ... | Error e -> write 400/close`. `Fs.file_system.open_` signature change (`exn`→`Fs.error`) is a public extension point — in-repo only, note it.

**C) Exit State**
No handleable exception is raised across `server`/`client`/`transport`/`fs`/`form` `.mli`s; `Io`/`Transfer` `*_exn` shims removed; serving loop maps read errors to HTTP responses. Build + tests green.

**D) Detailed Design**
```ocaml
(* server.mli *)
type error = Register of string   (* pattern conflict, was Register_error *)
val handle      : serve_mux -> string -> handler -> (unit, error) result
val handle_func : serve_mux -> string -> (response_writer -> Body.t Request.t -> unit Lwt.t) -> (unit, error) result

(* fs.mli *)
type error = Invalid_unsafe_path | No_overlap | Invalid_range of string
val parse_range : string -> int64 -> (http_range list, error) result
type file_system = { open_ : string -> (file, error) result Lwt.t }   (* was exn *)

(* form.mli *)
type error = Form of string | Not_multipart
val parse_form          : Body.t Request.t -> (unit, error) result Lwt.t
val parse_multipart_form : Body.t Request.t -> max_memory:int64 -> (unit, error) result Lwt.t
```
`Client.do_` redirect abort: return `(Body.t Response.t, Client.error) result Lwt.t` with `error = Redirect of string | Io of Io.error | ...` — confirm exact shape against `Client.check_redirect`'s existing `(unit,string) result`.

**E) Testing Plan**
- **Integration:** `Server.handle_conflict_result` — registering two conflicting patterns → `Error (Register _)`. `Fs.parse_range_typed` — bad `Range` header → `Error (Invalid_range _)`, unsatisfiable → `Error No_overlap`. End-to-end `Fs.serve_file_range` (existing) and the full Server/Client round-trip suites still pass. `Form.parse_non_multipart` → `Error Not_multipart`.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` full suite passes; confirm `grep -rn "_exn" lib/{io,transfer}.mli` returns nothing.

**G) Execution Record**
_(fill on completion)_

### Ticket 7 — HTTP/2 framing + endpoints boundaries → `result` (h2_frame, h2_error, h2_pipe, h2_databuffer, h2_server, h2_transport)
Status: Planned

**A) Scope**
Surface `result` at the HTTP/2 *public boundaries*: `H2_frame.read_frame` (and meta-headers read), `H2_pipe`/`H2_databuffer` read entrypoints, and `H2_server.serve`/`H2_transport.round_trip` error returns. Decide the unified error type (Areas of Uncertainty #3). Migrate off `Hpack`/`Transfer` `*_exn` shims and delete them. The **internal** event-loop exception→GOAWAY/RST machinery may stay (it's the faithful design); only entrypoints change.

**B) Migration Strategy**
Embed `H2_error.t` as the frame/connection error. `read_frame` returns `(frame, H2_error.t) result Lwt.t`. Internal callers in the conn loop convert `result` back to the existing internal `Connection_error`/`Stream_error` raise where the loop already expects to `Lwt.catch` them — minimizing churn. `H2_databuffer.Read_empty` / `H2_pipe.Closed_pipe_write` become `result` arms where consumed by streaming; if a site is a pure invariant (read past asserted length), keep it a raise and document.

**C) Exit State**
`H2_error.t` is the unified h2 error; `read_frame`/meta-headers/round-trip expose `result`; all `Hpack`/`Transfer`/`Hpack_huffman` `*_exn` shims deleted; internal GOAWAY/RST behavior unchanged and tests green.

**D) Detailed Design**
```ocaml
(* h2_error.mli — unify *)
type t =
  | Connection of err_code
  | Stream of stream_error
  | Frame_too_large
  | Invalid_stream_id
  | Invalid_dep_stream_id
  | Pad_length_too_large
  | Compression of Hpack.error
(* keep exception Connection_error/Stream_error ONLY if the internal loop still raises them;
   prefer raising via [to_exn t] at the few internal catch points. *)

(* h2_frame.mli *)
val read_frame : ?max_size:int -> Lwt_io.input_channel -> (frame, H2_error.t) result Lwt.t
```
`H2_server.serve`/`H2_transport.round_trip` keep their `unit Lwt.t`/`Response.t Lwt.t` shapes where failures are connection-fatal (handled internally), but expose `result` where a caller can distinguish (e.g. `round_trip` → `(Body.t Response.t, H2_error.t) result Lwt.t` if a clean per-request error is meaningful — confirm against Go's `RoundTrip` error contract).

**E) Testing Plan**
- **Unit/Integration:** `H2_frame.read_oversize_frame` — a frame exceeding `max_size` → `Error Frame_too_large`. `H2_frame.read_bad_stream_id` → `Error Invalid_stream_id`. Existing `H2Frame` suite + the h2-over-TLS round-trip demo/tests still pass (GOAWAY/RST behavior unchanged). Port the relevant `frame`/`http2` Go error tests.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` (incl. `H2Frame`, `Hpack`) passes; `grep -rn "decode_full_exn\|decode_exn\|read_transfer_exn" lib/` returns nothing.

**G) Execution Record**
_(fill on completion)_

### Ticket 8 — Final sweep, unhandleable documentation, regression guard
Status: Planned

**A) Scope**
Lock the philosophy in: document the surviving unhandleable exceptions, add the regression **guard test**, and update `CLAUDE.md`/`TODO.md`. Confirm `Lwt_result` syntax usage is consistent.

**B) Migration Strategy**
Documentation + test only; no signature changes. Audit that every remaining `raise`/`failwith`/`invalid_arg` in `lib/` is either (a) an unhandleable invariant (keep, with an `.mli` comment), or (b) an internal control-flow exception (`Need_more`, `let exception`). Anything else is a missed conversion → file/fix.

**C) Exit State**
`CLAUDE.md` convention reflects final reality; `plans/error-handling-audit.md` updated to "done" with the unhandleable allowlist; guard test passing. Build + tests green. Plan complete.

**D) Detailed Design**
- Guard: a test (or a small `dune` rule) that greps the migrated `.mli`s for `exception` declarations of handleable errors and fails if any reappear, and asserts each migrated module exports `type error`. Maintain an explicit **unhandleable allowlist** (`h2_flow`, `h2_writesched`, `net.bound_port`, `hpack_tables`, `Hpack.Need_more`, `pattern`/`mapping` `let exception`).

**E) Testing Plan**
- **Unit/meta:** `Error_policy.no_handleable_raise_escapes` (success criterion guard) — fails if a migrated module reintroduces a handleable `exception` in its `.mli` or drops its `type error`. `Error_policy.unhandleable_allowlisted` — the allowlisted modules are explicitly enumerated.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` full suite + guard passes; docs updated.

**G) Execution Record**
_(fill on completion)_

---

## Resolutions (confirmed 2026-06-03, "proceed on the plan")

1. **Mid-stream body errors:** ACCEPTED recommendation — `Body.Stream` thunk keeps *raising* mid-body; only header/initial-parse boundary returns `result`.
2. **h2 scope:** ACCEPTED — boundary-only conversion; internal event-loop exception→GOAWAY/RST machinery stays.
3. **`Fs.file_system.open_`:** APPROVED to break `(file,exn) result` → `(file, Fs.error) result` (in-repo only).
4. **Typed-variant granularity:** fine-grained variants, `string` payload only where Go's message has no structure.
5. **Shim strategy:** temporary `*_exn` shims as written (deleted by Tickets 6 & 7).
6. **Ticket 6 size:** keep as one ticket; split into 6a/6b only if it becomes unwieldy during execution.

## Open Questions / Concerns (review before implementation)

1. **Mid-stream body errors (Ticket 4, Uncertainty #1).** I recommend keeping the `Body.Stream` thunk *raising* for errors discovered mid-body (only the header/initial-parse boundary returns `result`), because that mirrors Go's "later `Read` returns an error" model and avoids making `(string option, error) result Lwt.t` viral through every body consumer. **Do you accept this, or do you want bodies fully `result`-ified?** Look at `lib/body.mli` (`Stream of (unit -> string option Lwt.t)`) and `lib/transfer.ml` chunked reader.
2. **h2 scope (Ticket 7).** I scoped h2 to *boundary-only* conversion, leaving the internal exception→GOAWAY/RST loop intact. Full conversion of the h2 event loop would be a much larger, riskier change for little fidelity gain. **OK to leave the h2 internals exception-based?** Look at `lib/h2_server.ml` / `lib/h2_transport.ml` (the per-connection fiber).
3. **`*_exn` shim strategy.** Each low-level ticket adds temporary `*_exn` shims so the build stays green between tickets, deleted by the ticket that migrates the last caller (Tickets 6 & 7 do the deletions). **Acceptable, or do you prefer fewer/larger tickets that convert a module + all callers atomically (fewer shims, bigger diffs)?**
4. **Typed-variant granularity.** I proposed fine-grained arms (e.g. `Bad_content_length of string`) with a `string` payload only where Go's message has no natural structure. **Confirm you want fine-grained variants, not a single `Other of string` per module.** (Your earlier choice was typed variants — this honors it.)
5. **`Fs.file_system.open_` signature change (Ticket 6, Uncertainty #4).** Changing `(file, exn) result` → `(file, Fs.error) result` is breaking for any *external* filesystem implementer. In-repo only today. **OK to break it?**
6. **Ticket 6 size.** It's the biggest fan-out (server/client/transport/fs/form). I can pre-split it into 6a (request loop) + 6b (fs/form) now if you'd rather not decide mid-flight.

## Confirmation

This plan is drafted and ready for your review. **It is not yet approved for implementation.** Please confirm intent (and answer the questions above, especially #1, #2, #5) before I begin executing tickets. On approval, I'll execute serially from Ticket 1, one commit per ticket, updating each Execution Record as I go.
