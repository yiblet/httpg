# gohttp — OCaml port of Go `net/http` (HTTP/1.x: 1.0 + 1.1) — Plan

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

> **VCS NOTE (this project):** version control is **jj (Jujutsu)**, colocated with git. Per-ticket commit = finalize the working-copy change with a semantic message: `jj commit -m "<type>: <summary>"`. Inspect state with `jj st` / `jj log`. Do **not** use `git commit`.

## Problem

- **Goal:** A faithful 1:1 OCaml port of Go's `net/http` package supporting **all HTTP/1.x versions Go supports — i.e. HTTP/1.0 and HTTP/1.1** (no HTTP/2+) — both server (`Handler`, `ServeMux`, `ResponseWriter`, `Server.ListenAndServe`) and client (`Client`, `Transport`, `RoundTripper`) — mirroring Go's file layout, type names, and function names.
- **HTTP version scope:** Match Go's HTTP/1.x behavior exactly. Requests/responses carry `proto`/`proto_major`/`proto_minor`; framing and connection management are **version-sensitive** per Go: HTTP/1.0 defaults to `Connection: close` and has no chunked transfer-encoding (keep-alive only via `Connection: keep-alive`); HTTP/1.1 defaults to keep-alive and supports chunked. Go also tolerates the `HTTP/0.9`-style simple requests only insofar as its parser does — replicate exactly what `request.go`/`transfer.go` do, no more.
- **Success Criteria (as tests):**
  - *Unit:* `header.canonical_key` ⇒ alcotest case `Header.canonical` asserts `canonical_header_key "uSER-aGeNT" = "User-Agent"`; `Transfer.chunked_roundtrip` encodes then decodes a body and asserts byte-equality with Go's `transfer_test.go` fixtures.
  - *Integration:* `Clientserver.get_roundtrip` starts a `Gohttp.Server` on a loopback port via the Lwt backend, issues `Gohttp.Client.do` GET, and asserts status `200` and body equality — mirroring Go's `clientserver_test.go` happy path.
- **Non-Goals:** HTTP/2, HTTP/3, ALPN h2 (`http2.go`, `clientconn.go`, `socks_bundle.go`, h2 bundles) — but HTTP/1.0 **is in scope**; `net/url` reimplementation (use `uri`); CGI/FCGI/pprof/httputil subpackages; the monad/IO-functor abstraction (deferred — write directly against Lwt).
- **Constraints:** OCaml ≥ 5.0, dune ≥ 3.0. Deps: `uri`, `lwt`, `tls-lwt`, `alcotest` (already installed in the local switch, alongside `tls`/`x509`). Pure data modules must not depend on Lwt. Cross-reference every module against its `go/src/net/http/*.go` source. **When a ported test fails, fix the implementation, not the test** (unless the failure is a documented Go-specific porting artifact).

## Discovery

- **Key User Paths:** Today the repo is greenfield scaffolding — `lib/gohttp.{ml,mli}` exports a `greeting` stub and `test/test_gohttp.ml` asserts on it; `bin/main.ml` prints the greeting. No HTTP code exists yet. The reference implementation is vendored read-only at `go/src/net/http/*.go` (the `go/` git submodule).
- **Current Architecture:** `lib/dune` declares a single-module wrapped library `(public_name gohttp)`. `gohttp.opam` declares only `ocaml`/`dune` deps. VCS is jj colocated with git; `master` bookmark at the OCaml-setup commit, working copy empty.
- **Critical Contracts (from Go, the spec we port):**
  - `Header = map[string][]string`, canonicalized via `CanonicalHeaderKey` (`header.go`).
  - `Request` / `Response` structs (`request.go:` ~line 95, `response.go:` ~line 30) — `Body io.ReadCloser` is a struct field; we model it as a parametric `'body` field.
  - `Handler.ServeHTTP(ResponseWriter, *Request)`, `HandlerFunc`, `ServeMux` (`server.go:89,97,2337,2630`).
  - Wire framing in `transfer.go`: `chunked`, `fixLength`, `readTransfer`, `writeBody` (lines 338,491,609,661).
  - `readRequest(*bufio.Reader)` (`request.go:1084`) — Lwt analogue reads from an `Lwt_io.input_channel`.
- **Migration Pressure Points:** The greeting stub and its test must be removed in the first ticket without leaving a red build. `lib/` flips from single-module to multi-module wrapped (modules become `Gohttp.Method`, `Gohttp.Header`, …) — `bin/` and `test/` references update in lockstep. Go's `bufio.Reader` line/byte reads map onto `Lwt_io` channels; chunked/content-length framing is the riskiest fidelity surface.
- **Areas of Uncertainty:** (1) How closely `Uri.t` semantics match `url.URL` for `RequestURI`/`Host`/path handling — may need thin adapters. (2) Exact `ResponseWriter` buffering/implicit-`WriteHeader(200)` ordering vs Go. (3) Whether Lwt in-memory pipes (`Lwt_io.pipe`) faithfully drive `transfer_test.go` fixtures without real sockets. (4) Trailer handling edge cases.

## Target Shape

- **Responsibilities / Ownership:** A single `gohttp` library. **Pure modules** (`method`, `status`, `header`, `sniff`, `cookie`, `pattern`, `routing_tree`, `mapping`, plus the `request`/`response` *types* and pure helpers) carry no IO. **IO modules** (`body`, `transfer`, `io`, `net`, `server`, `client`, `transport`) use Lwt directly (`Lwt_io` channels ≈ `bufio`; `Lwt_unix` sockets; `tls-lwt` for HTTPS).
- **Public Contracts (target OCaml surface):**
  - `Gohttp.Method.t` (string), `Gohttp.Status` (codes + `status_text`).
  - `Gohttp.Header.t` with `get/set/add/del/write/canonical_header_key`.
  - `'body Gohttp.Request.t`, `'body Gohttp.Response.t` records (fields mirror Go; `body : 'body`).
  - `Gohttp.Server`: `Handler`/`handler_func`, `ResponseWriter`, `ServeMux`, `listen_and_serve`.
  - `Gohttp.Client.do_`, `Gohttp.Transport` (HTTP/1.1 keep-alive).
- **Execution Flow (end state):** Server: `listen_and_serve` → `Net` accept loop → per-conn Lwt fiber → `Io.read_request` → `ServeMux` dispatch → handler writes via `ResponseWriter` → `Io.write_response`. Client: `Client.do_` → `Transport.round_trip` → `Net` connect (+TLS) → `Io.write_request` → `Io.read_response`.
- **Migration Shape:** Built bottom-up so the tree compiles green after every ticket: pure leaves → framing → message read/write → net → server → client. A thin `Url` adapter module wraps `Uri.t` only if Discovery uncertainty (1) proves real.
- **End-State Properties:** Each Go source file has a named OCaml counterpart and a ported test, making the port auditable file-by-file against `go/src/net/http`.

## Implementation Guide

- **Execution Model:** Orchestrator + sub-agents. The orchestrator works tickets **serially**, lowest open ticket first; never parallelizes tickets.
- **Per-Ticket Workflow:** For each ticket the orchestrator spawns one dedicated ticket agent that MUST: (1) `jj st` + run existing `dune test` to confirm green start; (2) implement the ticket against the matching `go/src/net/http` file; (3) port the corresponding Go `*_test.go` cases into alcotest and run `dune build && dune test`; (4) update this ticket's **Execution Record** with what changed, test evidence (names + pass counts), and commit id; (5) `jj commit -m "<semantic message>"` before returning.
- **Verification Gate:** Before advancing, the orchestrator confirms the ticket's Execution Record shows `dune build` clean and the named tests passing, and that a jj commit exists (`jj log` shows it). If evidence is missing/incomplete, spawn a verification agent to run `dune build && dune test`, record evidence, and commit any fixup.
- **Failure Handling:** If a ticket agent fails, it returns feedback. The orchestrator adjusts the plan if needed and retries **once** with a fresh agent. Two failures → stop and return control to the user with failure context.
- **Scope Handling:** Honor user scope exactly — one named ticket ⇒ only that ticket; "all" ⇒ tickets in order. No ticket is complete until tests pass, the Execution Record is updated, and the jj commit exists.

## Build Out

### Ticket 1 — Project skeleton + Method + Status
Status: Done

**A) Scope** Replace the greeting stub with a multi-module `gohttp` library and land the two simplest pure modules: `Method` (`method.go`) and `Status` (`status.go`). Adds deps to `gohttp.opam`/dune.

**B) Migration Strategy** Delete `greeting` from `lib/gohttp.{ml,mli}` (or repurpose `gohttp.ml` as a re-export module), update `bin/main.ml` and `test/` in the same change so the build never goes red. Convert `lib/dune` to a wrapped multi-module lib depending on `uri lwt lwt.unix tls-lwt`; add a `test/dune` using `alcotest`.

**C) Exit State** `dune build` and `dune test` green. `Gohttp.Method.get = "GET"` etc.; `Gohttp.Status.status_text 200 = "OK"`.

**D) Detailed Design**
- `lib/method.ml`: `let get = "GET"`, `head`, `post`, `put`, `patch`, `delete`, `connect`, `options`, `trace`; `type t = string`.
- `lib/status.ml`: integer constants (`status_ok = 200`, …) and `val status_text : int -> string` mirroring Go's map.
- `lib/dune`: `(library (name gohttp) (public_name gohttp) (libraries uri lwt lwt.unix tls-lwt))`.

**E) Testing Plan** *Unit* (alcotest, `test/test_method.ml`, `test/test_status.ml`): `Method.constants` asserts the nine method strings; `Status.text` asserts representative `status_text` mappings (200→"OK", 404→"Not Found", 418→"I'm a teapot", unknown→"").

**F) End-of-Ticket Verification** `dune build && dune test` clean; greeting stub fully removed (no dangling refs).

**G) Execution Record**

- **Status:** Done.
- **Files changed:**
  - `lib/dune` — converted to wrapped multi-module lib: `(library (name gohttp) (public_name gohttp) (libraries uri lwt lwt.unix tls-lwt))`.
  - `lib/gohttp.ml`, `lib/gohttp.mli` — deleted (greeting stub removed). No wrapper module needed; dune wraps modules as `Gohttp.Method` / `Gohttp.Status`.
  - `lib/method.ml` — new; port of `go/src/net/http/method.go`. `type t = string` and the nine method constants (`get="GET"`, `head`, `post`, `put`, `patch`, `delete`, `connect`, `options`, `trace`).
  - `lib/status.ml` — new; port of `go/src/net/http/status.go`. All integer status-code constants plus `status_text : int -> string` mirroring Go's `StatusText` exactly (returns "" for unknown codes, including the unused 306).
  - `bin/main.ml` — placeholder now prints `Gohttp.Status.status_text Gohttp.Status.status_ok` ("OK"); no more `greeting` ref.
  - `test/dune` — `(test (name test_gohttp) (libraries gohttp alcotest))`.
  - `test/test_gohttp.ml` — alcotest runner aggregating the Method and Status suites.
  - `test/test_method.ml` — new; asserts the nine method strings.
  - `test/test_status.ml` — new; asserts `status_text` mappings (200→"OK", 404→"Not Found", 418→"I'm a teapot", 100→"Continue", 500→"Internal Server Error", 999→"", 306→"").
  - `gohttp.opam` — added `uri`, `lwt`, `tls-lwt`, and `alcotest {with-test}` to depends. (`gohttp.opam` is hand-written; `dune-project` has no `(generate_opam_files ...)`.)
- **Test evidence:** `dune build` clean; `dune test` → "Test Successful in 0.001s. 16 tests run." All `[OK]`. Suite `Method` (9 cases: get/head/post/put/patch/delete/connect/options/trace) and suite `Status` (7 cases: 200→OK, 404→Not Found, 418→I'm a teapot, 100→Continue, 500→Internal Server Error, 999→"", 306→"").
- **Commit id:** `38d183b1` (jj change `ktsztlxm`) — "feat: scaffold multi-module lib with Method and Status (Ticket 1)". This plan-file edit recording the commit id lands in a subsequent working-copy change.

### Ticket 2 — Header
Status: Done

**A) Scope** Port `header.go`: `Header.t` (canonical-key map to value lists) with `add/set/get/values/del/clone/write` and `canonical_header_key`.

**B) Migration Strategy** Purely additive new module `lib/header.ml`; no existing consumers yet.

**C) Exit State** Header ops + canonicalization match Go; `dune test` green.

**D) Detailed Design**
- `type t` backed by an ordered/string map of canonical key → `string list`.
- `val canonical_header_key : string -> string` (per-token capitalization, ASCII only).
- `val write : t -> Buffer.t -> unit` producing CRLF-terminated `Key: value` lines in Go's ordering rules.

**E) Testing Plan** *Unit* (`test/test_header.ml`, ported from `header_test.go`): `Header.canonical` (case folding incl. the `uSER-aGeNT` case), `Header.write` (sorted output + multi-value), `Header.get_set_add_del` semantics.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Status:** Done.
- **Files changed:**
  - `lib/header.ml` — new; port of `go/src/net/http/header.go` plus the
    textproto canonicalization/`MIMEHeader` methods it delegates to
    (`go/src/net/textproto/reader.go` `CanonicalMIMEHeaderKey` /
    `validHeaderFieldByte`, `go/src/net/textproto/header.go` `MIMEHeader`).
    Exposes `type t = { mutable entries : (string * string list) list }` (Go's
    `map[string][]string` with canonical keys), `create`, `canonical_header_key`,
    `add`, `set`, `get` (first value or ""), `values`, `del`, `has`, `clone`,
    `write`, and `write_subset ~exclude`. `write`/`write_subset` mirror Go's
    `Header.Write`/`writeSubset`: keys sorted via `String.compare`, one
    `Key: value\r\n` line per value, keys with invalid field-name bytes dropped
    (`valid_header_field_name`), values run through `headerNewlineToSpace` +
    `textproto.TrimString`.
  - `test/test_header.ml` — new; alcotest suite exposing `val tests`. Ports
    `header_test.go`: the `headerWriteTests` table (all 11 representative rows
    incl. sort-over-threshold and the invalid-characters/header-smuggling row),
    canonicalization cases (incl. Success-Criteria `uSER-aGeNT -> User-Agent`,
    plus invalid-byte passthrough), and get/set/add/del/values/clone semantics.
  - `test/test_gohttp.ml` — added `("Header", Test_header.tests)` to the
    `Alcotest.run "gohttp"` list.
- **Test evidence:** `dune build` clean; `dune test` → "Test Successful in
  0.002s. 36 tests run." All `[OK]`. New suite `Header` = 20 cases (8
  canonicalization, 11 write/write_subset, 3 get/set/add/del + values + clone),
  alongside `Method` (9) and `Status` (7) for 36 total.
- **Porting notes:** Go's `headerWriteTests` rows assign keys *directly* to the
  map literal, bypassing canonicalization (e.g. `"k1"`, `"NewlineInKey\r\n"`).
  The test reproduces this with a raw-insert `make` helper (`{ Header.entries =
  pairs }`) rather than `add`, which would canonicalize the keys — a Go-specific
  test-data artifact, so the fixtures (not the implementation) carry the
  non-canonical keys. Go's nil-vs-empty value-slice distinction (`Clone`,
  `headerWriteTests` "Nil"/"Empty") is not modeled; both contribute zero output
  lines, matching observable `Write` behavior.
- **Commit:** `a06fd61c` (jj change `xzyvzpmw`) — "feat: port Header with canonical keys and Write (Ticket 2)". This commit-id annotation lands in a subsequent working-copy change.

### Ticket 3 — Sniff
Status: Planned

**A) Scope** Port `sniff.go` `DetectContentType` content sniffing.

**B) Migration Strategy** Additive `lib/sniff.ml`.

**C) Exit State** `detect_content_type` matches Go for the sniff_test fixtures.

**D) Detailed Design** `val detect_content_type : string -> string` (default `application/octet-stream`); port the signature table and the text/binary heuristic.

**E) Testing Plan** *Unit* (`test/test_sniff.ml`, ported from `sniff_test.go`): `Sniff.detect` over the Go fixture table (HTML, PNG, GIF, PDF, plain text, empty→octet-stream).

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record** _(tbd)_

### Ticket 4 — Cookie
Status: Planned

**A) Scope** Port `cookie.go`: `Cookie.t`, `read_cookies`, `read_set_cookies`, `set_cookie`/`String`, sanitization.

**B) Migration Strategy** Additive `lib/cookie.ml`; depends on `Header`.

**C) Exit State** Cookie parse/format match Go; `dune test` green.

**D) Detailed Design** `type t = { name; value; path; domain; expires; max_age; secure; http_only; same_site; raw; ... }`; `val read_cookies : Header.t -> string option -> t list`; `val cookie_string : t -> string`.

**E) Testing Plan** *Unit* (`test/test_cookie.ml`, ported from `cookie_test.go`): `Cookie.write` (Set-Cookie formatting), `Cookie.read` (request Cookie header parsing), sanitization edge cases.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record** _(tbd)_

### Ticket 5 — Body + Transfer (framing)
Status: Planned

**A) Scope** Port the wire framing from `transfer.go`: chunked encode/decode, content-length framing, trailers, plus a concrete `Body.t` over Lwt.

**B) Migration Strategy** New `lib/body.ml` + `lib/transfer.ml` using Lwt directly. Drive tests with in-memory `Lwt_io.pipe` channels — no sockets yet.

**C) Exit State** Encoding a body then decoding it round-trips byte-for-byte; chunked + content-length paths both covered. **Version-sensitive:** `fix_length`/`fix_trailer` must respect proto version — chunked TE is HTTP/1.1-only; HTTP/1.0 bodies are content-length- or close-delimited (mirror `transfer.go` exactly).

**D) Detailed Design**
- `lib/body.ml`: `type t = Empty | String of string | Stream of (unit -> string option Lwt.t)`.
- `lib/transfer.ml`: `val write_body : Lwt_io.output_channel -> transfer_writer -> unit Lwt.t`; `val read_transfer : [request|response] -> Lwt_io.input_channel -> unit Lwt.t`; helpers `chunked`, `fix_length`, `fix_trailer` mirroring Go line-for-line.

**E) Testing Plan** *Unit* (`test/test_transfer.ml`, ported from `transfer_test.go`): `Transfer.chunked_roundtrip` (encode→decode byte-equality), `Transfer.fix_length` (status/method-driven length rules, incl. HTTP/1.0 vs 1.1 differences), `Transfer.bad_chunk` (malformed chunk errors).

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record** _(tbd)_

### Ticket 6 — Request/Response types + read/write
Status: Planned

**A) Scope** Port the `Request`/`Response` types and their read/write halves: `request.go` (`readRequest`, `Write`), `response.go` (`ReadResponse`, `Write`).

**B) Migration Strategy** `lib/request.ml`, `lib/response.ml` (pure types + pure helpers), `lib/io.ml` (Lwt read/write). Compose `Header`, `Transfer`, `Body`, `Uri`. Tests driven by `Lwt_io.pipe`.

**C) Exit State** Round-trip: parse a raw HTTP/1.0 **and** HTTP/1.1 request/response then re-serialize to the canonical bytes. `proto`/`proto_major`/`proto_minor` parsed and preserved per Go's `ParseHTTPVersion`.

**D) Detailed Design**
- `'body Request.t` / `'body Response.t` records as in the approved plan (fields mirror Go).
- `lib/io.ml`: `read_request`, `write_request`, `read_response`, `write_response` over `Lwt_io` channels.

**E) Testing Plan** *Unit* (`test/test_readrequest.ml`, `test/test_requestwrite.ml`, `test/test_response.ml`, `test/test_responsewrite.ml`, ported from the matching Go files): parse representative requests/responses and assert field values; re-serialize and assert exact bytes; pure parts of `request_test.go` (e.g. `basic_auth`).

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record** _(tbd)_

### Ticket 7 — Net (sockets + TLS) + socket smoke test
Status: Planned

**A) Scope** `lib/net.ml`: Lwt_unix listen/accept/connect, `Lwt_io` channel creation, optional `tls-lwt` wrap.

**B) Migration Strategy** Additive; bridges `Io` to real sockets. Provides the substrate Tickets 9–10 build on.

**C) Exit State** A test opens a loopback listener, writes a line through `Io`, reads it back.

**D) Detailed Design** `val listen : addr -> Lwt_unix.file_descr Lwt.t`; `val accept : ... -> (Lwt_io.input_channel * Lwt_io.output_channel) Lwt.t`; `val connect : host:string -> port:int -> ?tls:bool -> unit -> (ic * oc) Lwt.t`.

**E) Testing Plan** *Integration* (`test/test_net.ml`): `Net.loopback_roundtrip` binds an ephemeral port, accepts one connection, echoes a request line, asserts equality.

**F) End-of-Ticket Verification** `dune build && dune test` clean (test must not hang — bounded with `Lwt_unix.with_timeout`).

**G) Execution Record** _(tbd)_

### Ticket 8 — ServeMux internals (pattern, routing_tree, mapping)
Status: Planned

**A) Scope** Port `pattern.go`, `routing_tree.go`, `mapping.go` — pattern parsing and the routing tree used by `ServeMux`.

**B) Migration Strategy** Additive pure modules; no server wiring yet.

**C) Exit State** Pattern parse + route matching match Go's test expectations.

**D) Detailed Design** `Pattern.parse : string -> pattern`; `Routing_tree` add/match with wildcards/`{name}`/`{name...}` and method matching as in Go 1.22+ mux.

**E) Testing Plan** *Unit* (`test/test_pattern.ml`, `test/test_routing_tree.ml`, ported from `pattern_test.go`/`routing_tree_test.go`): pattern parse cases, conflict detection, longest-match precedence, wildcard capture.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record** _(tbd)_

### Ticket 9 — Server + ServeMux dispatch
Status: Planned

**A) Scope** Port `server.go` (HTTP/1.x subset): `Handler`, `handler_func`, `ResponseWriter`, the per-conn serve loop, `Server`, `listen_and_serve`, `ServeMux` dispatch.

**B) Migration Strategy** New `lib/server.ml` composing `Io`, `Net`, `Routing_tree`. Keep-alive + implicit `WriteHeader(200)` semantics per Go. **Version-sensitive:** honor Go's connection-reuse rules — HTTP/1.0 closes by default unless `Connection: keep-alive`, HTTP/1.1 keeps alive unless `Connection: close`; emit responses with the request's protocol.

**C) Exit State** A server started on loopback serves a registered handler and returns the expected response for both HTTP/1.0 and HTTP/1.1 requests.

**D) Detailed Design** `ResponseWriter` interface (`header`, `write`, `write_header`); `Server.listen_and_serve : addr -> handler -> unit Lwt.t`; `ServeMux.handle`/`handle_func`.

**E) Testing Plan** *Integration* (`test/test_serve.ml`, ported subset of `serve_test.go`): `Serve.hello_handler` (200 + body), `Serve.not_found` (unregistered path → 404), `Serve.mux_routing` (path/method dispatch), `Serve.http10_close` (HTTP/1.0 request closes connection by default; keep-alive honored when requested).

**F) End-of-Ticket Verification** `dune build && dune test` clean; serve tests bounded by timeout.

**G) Execution Record** _(tbd)_

### Ticket 10 — Client + Transport
Status: Planned

**A) Scope** Port `client.go` + `transport.go` (HTTP/1.x): `RoundTripper`, `Transport`, `Client`, `Client.do`.

**B) Migration Strategy** New `lib/client.ml` + `lib/transport.ml` composing `Io`, `Net`. Connection reuse keyed by scheme/host/port. **Version-sensitive:** keep-alive reuse follows Go's rules (HTTP/1.1 default reuse; HTTP/1.0 only with `Connection: keep-alive`); requests default to HTTP/1.1 as Go does.

**C) Exit State** End-to-end: client GETs the Ticket-9 server and reads status+body. Satisfies the integration success criterion.

**D) Detailed Design** `Transport.round_trip : 'b Request.t -> Body.t Response.t Lwt.t`; `Client.do_ : ?client:Client.t -> 'b Request.t -> Body.t Response.t Lwt.t`; `Client.get`/`post` helpers. `bin/main.ml` becomes an example server+client round-trip.

**E) Testing Plan** *Integration* (`test/test_clientserver.ml`, ported subset of `clientserver_test.go`/`client_test.go`): `Clientserver.get_roundtrip` (200 + body equality), `Clientserver.post_body` (request body echo), `Transport.keepalive_reuse` (two requests reuse one connection).

**F) End-of-Ticket Verification** `dune build && dune test` clean; round-trip tests bounded by timeout.

**G) Execution Record** _(tbd)_
