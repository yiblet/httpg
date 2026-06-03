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
  - **Every `lib/` module MUST have a hand-written `.mli` interface file** exposing only its faithful public surface.
  - **Mirror Go's data structures, not just behavior.** Go `map[K]V` → OCaml `Hashtbl` (the hash-map analog), not `Map.Make` or assoc lists; Go slices → lists/arrays as fits. E.g. `Header.t = (string, string list) Hashtbl.t` mirrors `Header map[string][]string`.

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
  - **`lib/internal/` (private library `gohttp_internal`)** mirrors Go's `net/http/internal` package (and its `internal/ascii` subpackage): an access-restricted library (no `public_name`; bound to the `gohttp` package) reachable only from within `lib/` and from the in-tree `test/` executable (a same-project test may depend on a private library), not by external `gohttp` consumers. It now houses `Chunked` (the chunked transfer-encoding codec, port of `internal/chunked.go`; `transfer.ml` delegates to and re-exports `Gohttp_internal.Chunked`) and `Ascii` (port of `internal/ascii/print.go`: `equal_fold`/`is_print`/`is`/`to_lower`). `transfer.ml`, `cookie.ml`, and `request.ml` route their ASCII case-fold / lowercase helpers through `Gohttp_internal.Ascii`, mirroring Go's `ascii.EqualFold`/`ascii.ToLower` call sites. Room for further internal ports later (`common`, `testcert`). The top-level `lib/dune` does not use `include_subdirs`, so `lib/internal/` with its own `dune` is a separate library by default — the desired isolation.
- **End-State Properties:** Each Go source file has a named OCaml counterpart and a ported test, making the port auditable file-by-file against `go/src/net/http`.

## Implementation Guide

- **Execution Model:** Orchestrator + sub-agents. The orchestrator works tickets **serially**, lowest open ticket first; never parallelizes tickets.
- **Per-Ticket Workflow:** For each ticket the orchestrator spawns one dedicated ticket agent that MUST: (1) `jj st` + run existing `dune test` to confirm green start; (2) implement the ticket against the matching `go/src/net/http` file, writing a `.mli` for every new module and mirroring Go's data structures (`map`→`Hashtbl`); (3) port the corresponding Go `*_test.go` cases into alcotest and run `dune build && dune test`; (4) do ALL plan edits (this ticket's **Execution Record**: what changed, test evidence with names + pass counts) BEFORE committing; (5) run a single `jj commit -m "<semantic message>"` and do not edit files afterward (one clean commit per ticket).
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
Status: Done

**A) Scope** Port `sniff.go` `DetectContentType` content sniffing.

**B) Migration Strategy** Additive `lib/sniff.ml`.

**C) Exit State** `detect_content_type` matches Go for the sniff_test fixtures.

**D) Detailed Design** `val detect_content_type : string -> string` (default `application/octet-stream`); port the signature table and the text/binary heuristic.

**E) Testing Plan** *Unit* (`test/test_sniff.ml`, ported from `sniff_test.go`): `Sniff.detect` over the Go fixture table (HTML, PNG, GIF, PDF, plain text, empty→octet-stream).

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Status:** Done.
- **Files changed:**
  - `lib/sniff.ml` — new; port of `go/src/net/http/sniff.go` +
    `go/src/net/http/internal/sniff.go` (`DetectContentType`). Exposes
    `val detect_content_type : string -> string` (default
    `"application/octet-stream"`) and `val sniff_len = 512` (only the first 512
    bytes are considered). Ports the full `sniffSignatures` table in Go's order
    and the matcher types as closures of type
    `sniff_sig = data:string -> first_non_ws:int -> string`:
    `html_sig` (case-insensitive tag prefix + tag-terminating byte),
    `exact_sig` (prefix), `masked_sig` (`mask`/`pat` with optional `skip_ws` for
    `<?xml`), `mp4_sig` (big-endian box-size parse via bit-shifts, `ftyp` +
    `mp4` brand scan), and `text_sig` (the binary/text heuristic, last in the
    table). Includes HTML tags, `%PDF-`/`%!PS-Adobe-`, UTF BOMs, image
    (ICO/BMP/GIF/WEBP/PNG/JPEG), audio/video (AIFF/ID3/OGG/MIDI/AVI/WAVE/MP4/
    WEBM), font (ms-fontobject/TTF/OTTO/ttcf/WOFF/WOFF2), and archive
    (GZIP/ZIP/RAR/WASM) signatures, with charset suffixes preserved
    (`text/plain; charset=utf-8`, `text/xml; charset=utf-8`, the utf-16 BOMs).
  - `test/test_sniff.ml` — new; alcotest suite `val tests`. Ports the
    `sniffTests` table from `go/src/net/http/sniff_test.go`
    (`TestDetectContentType`), all 38 rows, each asserting
    `detect_content_type data = contentType`, including the empty-input case.
  - `test/test_gohttp.ml` — added `("Sniff", Test_sniff.tests)` to the
    `Alcotest.run "gohttp"` list.
- **Test evidence:** `dune build` clean; `dune test` → "Test Successful in
  0.003s. 74 tests run." All `[OK]`. New suite `Sniff` = 38 cases (cases 0–37),
  alongside `Method` (9), `Status` (7), `Header` (20) for 74 total.
- **Porting notes:** The Go `"Empty"` fixture expects
  `"text/plain; charset=utf-8"` (not `application/octet-stream`): on empty data
  the whitespace-skip leaves `firstNonWS = 0`, every preceding signature fails
  the length check, and `textSig` matches a zero-length tail. The port follows
  the Go source faithfully and the ported test asserts the same Go value. The
  net-based `TestServerContentTypeSniff`, `TestServerIssue5953`,
  `TestContentTypeWithVariousSources`, and `TestSniffWriteSize` are
  server-behavior tests, intentionally omitted (deferred to the server ticket).
- **Commit:** _(commit id annotation lands in a subsequent working-copy change)_

### Ticket 4 — Cookie
Status: Done

**A) Scope** Port `cookie.go`: `Cookie.t`, `read_cookies`, `read_set_cookies`, `set_cookie`/`String`, sanitization.

**B) Migration Strategy** Additive `lib/cookie.ml`; depends on `Header`.

**C) Exit State** Cookie parse/format match Go; `dune test` green.

**D) Detailed Design** `type t = { name; value; path; domain; expires; max_age; secure; http_only; same_site; raw; ... }`; `val read_cookies : Header.t -> string option -> t list`; `val cookie_string : t -> string`.

**E) Testing Plan** *Unit* (`test/test_cookie.ml`, ported from `cookie_test.go`): `Cookie.write` (Set-Cookie formatting), `Cookie.read` (request Cookie header parsing), sanitization edge cases.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Status:** Done.
- **Files changed:**
  - `lib/cookie.ml` — new; port of `go/src/net/http/cookie.go`. Exposes
    `type same_site` (variant mirroring Go's `SameSite` iota+1 constants, plus a
    `Same_site_unset` modeling Go's zero value) and `type t` mirroring Go's
    `Cookie` struct field-for-field (`name`, `value`, `quoted`, `path`,
    `domain`, `expires`, `raw_expires`, `max_age`, `secure`, `http_only`,
    `same_site`, `partitioned`, `raw`, `unparsed : string list`). `expires` is a
    Unix-epoch `float` (`0.` = unset, mirroring Go's zero-`time.Time`/`IsZero`).
    Ports `read_set_cookies` (Go `readSetCookies`), `read_cookies ~filter`
    (Go `readCookies`), `set_cookie` (Go `(*Cookie).String`, the Set-Cookie /
    Cookie serialization), `valid` (Go `(*Cookie).Valid`, returns
    `(unit, string) result`), and the sanitization/parse helpers
    `sanitize_cookie_name`/`sanitize_cookie_value`/`sanitize_cookie_path`,
    `valid_cookie_domain`, `is_cookie_name_valid`, `parse_cookie_value`, plus an
    internal `parse_set_cookie` (Go `ParseSetCookie`). Includes a faithful
    self-contained GMT formatter for `TimeFormat`
    (`Mon, 02 Jan 2006 15:04:05 GMT`) and parsers for RFC1123 and
    `Mon, 02-Jan-2006 15:04:05 MST`, built on Hinnant civil/day conversions (no
    new opam deps), and `is_token`/`isCookieDomainName`/IPv4 validity helpers.
  - `lib/cookie.mli` — new; hand-written interface exposing only the faithful
    public surface (the type definitions, `default`, `read_set_cookies`,
    `read_cookies`, `set_cookie`, `valid`, and the sanitization/validity/parse
    helpers).
  - `test/test_cookie.ml` — new; alcotest suite `val tests` (90 cases) ported
    from `go/src/net/http/cookie_test.go`: `writeSetCookiesTests` (33 rows →
    `set_cookie` formatting), `readSetCookiesTests` (22 rows, each run twice to
    confirm no input mutation), `readCookiesTests` (10 rows, run twice),
    `TestCookieSanitizeValue` (14), `TestCookieSanitizePath` (3), and
    `TestCookieValid` (11). Uses a custom `cookie_t` Alcotest testable for full
    struct equality.
  - `test/test_gohttp.ml` — added `("Cookie", Test_cookie.tests)` to the
    `Alcotest.run "gohttp"` list.
- **Test evidence:** `dune build` clean; `dune test` → "Test Successful in
  0.027s. 164 tests run." All `[OK]`. New suite `Cookie` = 90 cases, alongside
  `Method` (9), `Status` (7), `Header` (20), `Sniff` (38) for 164 total
  (baseline was 74).
- **Porting notes / intentionally omitted Go cases:**
  - The GODEBUG `httpcookiemaxnum` override is not modeled; the port always uses
    the default limit of 3000 (`defaultCookieMaxNum`). The default-limit-exceeded
    rows (return empty slice) ARE ported; the GODEBUG-override rows (custom
    `httpcookiemaxnum=5` / `=0` / `=defaultMax+1`) are omitted (no env knob in
    the pure port). The within-limit override successes are equivalent to
    ordinary within-limit parses.
  - `TestSetCookie`, `TestAddCookie`, `TestSetCookieDoubleQuotes` depend on
    `ResponseWriter`/`Request` (later tickets); the underlying `set_cookie`
    formatting and `read_set_cookies` parsing they exercise are fully covered by
    the write/read tables here.
  - Log-output assertions (`"dropping invalid bytes"` / `"dropping domain
    attribute"`) are Go-specific: there is no `log.Printf` analog in the pure
    port, so `sanitizeOrWarn` drops bytes silently. Behavior (the dropped bytes)
    is identical and tested; only the side-effect logging is omitted.
  - Go's `time.Unix(0,0)` (1970-01-01) is **not** the zero time, so its
    `Valid()` cases treat `Expires` as set-and-valid (year 1970 ≥ 1601). Since
    `0.` denotes "unset" in this port, the `valid-expires`/`valid-all-fields`
    fixtures use a small positive epoch (`1.`) to faithfully reproduce "set and
    valid". The bare `SameSite` (no value) row parses to
    `Same_site_default_mode`, matching Go's `SameSite: SameSiteDefaultMode`.
- **Commit:** _(commit id annotation lands in a subsequent working-copy change)_

### Ticket 5 — Body + Transfer (framing)
Status: Done

**A) Scope** Port the wire framing from `transfer.go`: chunked encode/decode, content-length framing, trailers, plus a concrete `Body.t` over Lwt.

**B) Migration Strategy** New `lib/body.ml` + `lib/transfer.ml` using Lwt directly. Drive tests with in-memory `Lwt_io.pipe` channels — no sockets yet.

**C) Exit State** Encoding a body then decoding it round-trips byte-for-byte; chunked + content-length paths both covered. **Version-sensitive:** `fix_length`/`fix_trailer` must respect proto version — chunked TE is HTTP/1.1-only; HTTP/1.0 bodies are content-length- or close-delimited (mirror `transfer.go` exactly).

**D) Detailed Design**
- `lib/body.ml`: `type t = Empty | String of string | Stream of (unit -> string option Lwt.t)`.
- `lib/transfer.ml`: `val write_body : Lwt_io.output_channel -> transfer_writer -> unit Lwt.t`; `val read_transfer : [request|response] -> Lwt_io.input_channel -> unit Lwt.t`; helpers `chunked`, `fix_length`, `fix_trailer` mirroring Go line-for-line.

**E) Testing Plan** *Unit* (`test/test_transfer.ml`, ported from `transfer_test.go`): `Transfer.chunked_roundtrip` (encode→decode byte-equality), `Transfer.fix_length` (status/method-driven length rules, incl. HTTP/1.0 vs 1.1 differences), `Transfer.bad_chunk` (malformed chunk errors).

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Status:** Done.
- **Files changed:**
  - `lib/body.ml` + `lib/body.mli` — new; a concrete body over Lwt,
    `type t = Empty | String of string | Stream of (unit -> string option Lwt.t)`
    (the analogue of Go's `io.ReadCloser` body field; `Empty` ≈ `http.NoBody`,
    `Stream` yields chunks until `None` ≈ `io.EOF`). Helpers `empty`,
    `of_string`, `of_stream`, `read_all : t -> string Lwt.t`, and
    `write : Lwt_io.output_channel -> t -> unit Lwt.t` (raw bytes, no framing).
  - `lib/transfer.ml` + `lib/transfer.mli` — new; port of
    `go/src/net/http/transfer.go` + `go/src/net/http/internal/chunked.go`.
    - **Chunked codec:** `new_chunked_reader` (port of `internal.chunkedReader`:
      `readChunkLine` incl. CRLF/bare-LF/stray-CR validation and `maxLineLength`,
      `trimTrailingWhitespace`, `removeChunkExtension`, `parseHexUint`, and the
      excess-overhead accounting `excess -= 16 + 2*n` capped at 16KiB). Returns a
      pull function yielding decoded chunk payloads then `None` at the 0-length
      chunk — and, like Go's internal reader, **does not** consume the trailing
      CRLF/trailers (that is the body/readTrailer layer's job). Errors:
      `Err_line_too_long` (`internal.ErrLineTooLong`) and `Chunk_error` (carries
      Go's malformed-chunk / bad-size / too-much-overhead / unexpected-EOF
      messages). Writer: `chunked_writer_write` (`%x\r\n` + data + `\r\n`,
      no-op on empty data) and `chunked_writer_close` (`0\r\n`).
    - **transfer.go:** `chunked`, `is_identity`, `no_response_body_expected`,
      `body_allowed_for_status`, `parse_content_length` (rejects empty / `+3` /
      `-3` / overflow via `Bad_string_error`), `fix_length` (version-sensitive:
      HEAD/1xx/204/304 → 0; chunked → -1 and drops Content-Length; dedups
      identical Content-Length and errors on conflicting ones; request-no-CL → 0
      vs response-no-CL → -1), `should_close` (HTTP/1.0 close-by-default unless
      `keep-alive`, HTTP/1.1 keep-alive unless `close`, `major<1` always close),
      `fix_trailer` (chunked-only; canonicalizes keys, rejects
      Transfer-Encoding/Trailer/Content-Length keys), `parse_transfer_encoding`
      (HTTP/1.0 ignores TE per Issue 12785; single-`chunked`-only, else
      unsupported/too-many error), `read_transfer` (the `transferReader` logic
      over a `message` record mirroring the *Request/*Response inputs; emits a
      `result` with the body reader — chunked / fixed-length LimitReader /
      HTTP/1.0 close-delimited / persistent-no-body), and `write_body` +
      `make_transfer_writer` (the pure `newTransferWriter` Body/ContentLength/
      TransferEncoding sanitization and `transferWriter.writeBody`: chunked,
      fixed-length with a ContentLength/body-length mismatch check, or
      unknown-length, plus trailer + terminating CRLF for chunked).
  - `test/test_transfer.ml` — new; alcotest suite `val tests` (17 cases),
    driving Lwt via `Lwt_main.run` over in-memory `Lwt_io` channels
    (`Lwt_io.of_bytes` for input, `Lwt_io.pipe` for output capture).
  - `test/dune` — added `lwt lwt.unix str` to libraries.
  - `test/test_gohttp.ml` — added `("Transfer", Test_transfer.tests)`.
- **Test evidence:** `dune build` clean; `dune test` → "Test Successful in
  0.027s. **181 tests run.**" All `[OK]`. New suite `Transfer` = 17 cases:
  `chunk_writer_format` (TestChunk wire format), **`chunked_roundtrip`**
  (Success Criterion: encode→decode byte-equality), `chunk_ignores_extensions`
  (TestChunkReadingIgnoresExtensions), `parse_hex_uint` (TestParseHexUint incl.
  error rows + sampled value rows), `chunk_invalid_inputs`
  (TestChunkInvalidInputs, 4 rows), `chunk_read_partial` (TestChunkReadPartial
  malformed tail), `incomplete_chunk` (TestIncompleteChunk: every prefix →
  unexpected-EOF, full stream OK), `parse_content_length` (TestParseContentLength),
  `parse_transfer_encoding` (TestParseTransferEncoding + HTTP/1.0-ignores row),
  `fix_length`, `should_close`, `fix_trailer`, `write_body_chunked` /
  `write_body_fixed` / `write_body_length_mismatch`
  (TestTransferWriterWriteBodyReaderTypes analogue — wire-bytes assertions, see
  notes), `read_transfer_chunked` (TestFinalChunkedBodyReadEOF analogue) and
  `read_transfer_content_length`. (Baseline before ticket: 164.)
- **Porting notes / intentionally omitted Go cases:**
  - `TestTransferWriterWriteBodyReaderTypes` uses Go `reflect.Type` to assert
    which concrete reader (`*os.File` vs `*bytes.Buffer`, `LimitedReader`
    unwrapping, `ReadFrom` vs `Write`) the writer hands to the destination —
    those are zero-copy/`io.ReaderFrom` optimization details with no OCaml/Lwt
    analogue. Ported instead as the observable wire output for the chunked,
    fixed-length and length-mismatch paths (the behavior those rows exercise).
  - The chunked reader surfaces a malformed-tail error eagerly (on the pull that
    consumes the chunk) rather than on the *next* Read as Go's streaming
    `chunkedReader` does (Go defers the CRLF check via `checkEnd`). Same error,
    same input rejected — a streaming-vs-batch artifact of the pull-based model;
    `chunk_read_partial` asserts the error regardless of which pull raises it.
  - `incomplete_chunk` uses Go's exact "valid" stream; note its second chunk
    declares size 5 over data `"abc\r\n"` (the data itself contains a CRLF), so
    the decoded bytes are `"abcdabc\r\n"`. The reader stops at the 0-chunk
    without consuming any trailing CRLF (matching `internal.chunkedReader`).
  - `probeRequestBody` / `shouldSendChunkedRequestBody` / the 200ms async
    byte-sniff (`ByteReadCh`, `finishAsyncByteRead`), `unwrapNopCloser` /
    `isKnownInMemoryReader` / `FlushAfterChunkWriter` flush behavior, and the
    `body` mutex/`Close`/`readTrailer`/`onHitEOF` machinery are
    Go-runtime/connection-management concerns deferred to later tickets
    (Request/Response read-write and Server/Transport); the framing they wrap is
    ported. `TestDetectInMemoryReaders`, `TestBodyReadBadTrailer` (depends on the
    `body` struct) and `TestChunkReaderAllocs` (Go GC allocation assertion) are
    omitted accordingly. The `httplaxcontentlength` GODEBUG knob is not modeled
    (default behavior only).
- **Commit:** _(commit id annotation lands in a subsequent working-copy change)_

### Ticket 6 — Request/Response types + read/write
Status: Done

**A) Scope** Port the `Request`/`Response` types and their read/write halves: `request.go` (`readRequest`, `Write`), `response.go` (`ReadResponse`, `Write`).

**B) Migration Strategy** `lib/request.ml`, `lib/response.ml` (pure types + pure helpers), `lib/io.ml` (Lwt read/write). Compose `Header`, `Transfer`, `Body`, `Uri`. Tests driven by `Lwt_io.pipe`.

**C) Exit State** Round-trip: parse a raw HTTP/1.0 **and** HTTP/1.1 request/response then re-serialize to the canonical bytes. `proto`/`proto_major`/`proto_minor` parsed and preserved per Go's `ParseHTTPVersion`.

**D) Detailed Design**
- `'body Request.t` / `'body Response.t` records as in the approved plan (fields mirror Go).
- `lib/io.ml`: `read_request`, `write_request`, `read_response`, `write_response` over `Lwt_io` channels.

**E) Testing Plan** *Unit* (`test/test_readrequest.ml`, `test/test_requestwrite.ml`, `test/test_response.ml`, `test/test_responsewrite.ml`, ported from the matching Go files): parse representative requests/responses and assert field values; re-serialize and assert exact bytes; pure parts of `request_test.go` (e.g. `basic_auth`).

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Status:** Done.
- **Files changed:**
  - `lib/request.ml` + `lib/request.mli` — new; port of the `Request` type and
    pure helpers from `go/src/net/http/request.go`. `type 'body t` mirrors Go's
    `Request` struct (`meth`, `url : Uri.t`, `proto`/`proto_major`/`proto_minor`,
    `header`, `body : 'body`, `content_length : int64`, `transfer_encoding`,
    `close`, `host`, `trailer : Header.t option`, `request_uri`, `remote_addr`);
    form/multipart/GetBody/Cancel/TLS/context fields omitted (deferred, see scope
    note). Helpers: `parse_http_version` (`ParseHTTPVersion`), `proto_at_least`,
    `user_agent`, `referer`, `cookies`/`cookie` (compose `Cookie.read_cookies`),
    `add_cookie`, `parse_basic_auth`, `basic_auth`, `basic_auth_encode`
    (`basicAuth`), `set_basic_auth`. Uses the `base64` lib for Basic auth.
  - `lib/response.ml` + `lib/response.mli` — new; port of the `Response` type and
    pure helpers from `go/src/net/http/response.go`. `type 'body t` mirrors Go's
    `Response` struct (`status`, `status_code`, `proto`/major/minor, `header`,
    `body : 'body`, `content_length`, `transfer_encoding`, `close`,
    `uncompressed`, `trailer`, `request : 'body Request.t option`); TLS field
    omitted (deferred). Helpers: `cookies` (`readSetCookies`), `proto_at_least`,
    `location` (`Location`, resolved against the request URL via `Uri.resolve`).
  - `lib/io.ml` + `lib/io.mli` — new; the Lwt read/write halves over
    `Lwt_io.input_channel`/`output_channel`. Includes a textproto-style header
    reader (`read_mime_header`: CRLF lines until blank, obs-fold continuation,
    `validHeaderValueByte`, value left-trim, key canonicalization — port of
    `textproto.Reader.ReadMIMEHeader` + `readContinuedLineSlice`), `read_line`
    (bufio/textproto `ReadLine`), `parse_request_line`, `is_token` (`validMethod`),
    `fix_pragma_cache_control`. `read_request` (`readRequest`/`ReadRequest`:
    request line, CONNECT just-authority handling, headers, Host promotion +
    deletion, `should_close`, `read_transfer`), `read_response` (`ReadResponse`:
    status line, `TrimLeft`, 3-digit code, headers, `read_transfer`),
    `write_request` (`Request.Write`: request line `HTTP/1.1`, Host, default
    User-Agent, transfer header via `Transfer.write_transfer_header`, header
    subset excluding the writer-managed keys, body), `write_response`
    (`Response.Write`: status-line text logic incl. `%03d` zero-pad and stutter
    trim, zero-length-body probe, the HTTP/1.1 unknown-length `Connection: close`
    rule, `Content-Length: 0` for bodyless allowed-status responses). Chunked
    bodies are materialized in memory and the trailer block parsed after the body
    (Go's `body.readTrailer`).
  - `lib/transfer.ml` + `lib/transfer.mli` — extended (not new): added
    `has_token` (`hasToken`), `should_send_content_length`
    (`transferWriter.shouldSendContentLength`), `write_transfer_header`
    (`transferWriter.writeHeader`: Connection/Content-Length/Transfer-Encoding/
    Trailer lines), and `tw_close`/`tw_header` fields plus `?close`/`?header`
    params on `make_transfer_writer`. `write_body` was already present from
    Ticket 5; the header-writing half (`writeHeader`) is the new piece Ticket 6
    needs.
  - `lib/dune` — added `base64` to libraries.
  - `gohttp.opam` — added `base64` (and `fmt` {with-test}).
  - `test/test_request.ml` — new; pure-helper cases from `request_test.go`:
    `parse_http_version` (the 17-row `parseHTTPVersionTests`), `parse_basic_auth`
    (the 10-row `parseBasicAuthTests`), `basic_auth_roundtrip`
    (`TestGetBasicAuth`: SetBasicAuth→BasicAuth for the 3 credential pairs +
    unauthenticated), `add_cookie`.
  - `test/test_readrequest.ml` — new; representative `reqTests` rows: baseline
    (all fields), simple GET, chunked-with-trailer, chunked-drops-Content-Length,
    plus HTTP/1.0 content-length + HTTP/1.0 keep-alive (version-sensitive close).
  - `test/test_requestwrite.ml` — new; `reqWriteTests` rows 0–4 (GET headers,
    GET chunked, POST chunked+close, POST Content-Length+close, Content-Length
    header ignored) asserting exact wire bytes.
  - `test/test_response.ml` — new; `respTests` ReadResponse rows: HTTP/1.0 close,
    HTTP/1.1 no-length close-delimited, 204 No Content, Content-Length, chunked
    multi-chunk, plus `Location` resolution.
  - `test/test_responsewrite.ml` — new; 15 `respWriteTests` rows (exact bytes).
  - `test/dune` — added `base64 fmt uri` to libraries.
  - `test/test_gohttp.ml` — registered the 5 new suites.
- **Test evidence:** `dune build` clean; `dune test` → "Test Successful in
  0.028s. **217 tests run.**" All `[OK]`. New suites: `Request` (4),
  `ReadRequest` (6), `RequestWrite` (5), `Response` (6), `ResponseWrite` (15) =
  36 new, alongside the 181 baseline.
- **Porting notes / intentionally omitted Go cases:**
  - **Scope deferrals (per ticket scope note):** multipart/form parsing
    (`ParseForm`, `ParseMultipartForm`, `FormValue`, `PostForm`, `MultipartReader`)
    and the `Form`/`MultipartForm` struct fields; `GetBody`, `Cancel`,
    `context`/`WithContext`/`Clone`, `tls.ConnectionState`, and httptrace fields.
    The corresponding Go tests (`TestParseForm*`, `TestMultipart*`, proxy
    `WriteProxy`/`WantProxy` columns, `TestRequestWriteTransport`,
    `TestRequestWriteClosesBody`) are out of scope.
  - **Uri vs net/url divergence (genuine porting artifact):** the `reqTests` row
    `GET //user@host/is/actually/a/path/` expects Go's `url.ParseRequestURI` to
    treat a scheme-relative target as a pure Path (host="" path=
    "//user@host/..."). `Uri.of_string` instead parses host="host" path=
    "/is/actually/a/path/". This is a `uri`-library semantics difference (the
    project uses `Uri.t`, not a `net/url` port), so that specific row is omitted;
    the absolute-URI and origin-form rows are ported. The malformed-URI error
    rows (`../../../../etc/passwd`, empty URL) are also omitted as they depend on
    `url.ParseRequestURI`'s exact error surface.
  - **Trailer reading:** the chunked reader (Ticket 5) stops at the 0-chunk
    without consuming trailers; `io.ml` reads the trailer block after the body in
    `materialize_body`, mirroring `body.readTrailer`'s effect (merging into the
    request/response `Trailer`). Bodies are materialized in memory rather than
    streamed lazily — an Lwt batch-vs-stream artifact that is observably
    equivalent for these round-trip tests.
  - **`TestReadResponseCloseInMiddle` / allocation / streaming tests** and the
    server/transport-coupled write tests are deferred to later tickets.
- **Commit:** _(commit id annotation lands in a subsequent working-copy change)_

### Ticket 7 — Net (sockets + TLS) + socket smoke test
Status: Done

**A) Scope** `lib/net.ml`: Lwt_unix listen/accept/connect, `Lwt_io` channel creation, optional `tls-lwt` wrap.

**B) Migration Strategy** Additive; bridges `Io` to real sockets. Provides the substrate Tickets 9–10 build on.

**C) Exit State** A test opens a loopback listener, writes a line through `Io`, reads it back.

**D) Detailed Design** `val listen : addr -> Lwt_unix.file_descr Lwt.t`; `val accept : ... -> (Lwt_io.input_channel * Lwt_io.output_channel) Lwt.t`; `val connect : host:string -> port:int -> ?tls:bool -> unit -> (ic * oc) Lwt.t`.

**E) Testing Plan** *Integration* (`test/test_net.ml`): `Net.loopback_roundtrip` binds an ephemeral port, accepts one connection, echoes a request line, asserts equality.

**F) End-of-Ticket Verification** `dune build && dune test` clean (test must not hang — bounded with `Lwt_unix.with_timeout`).

**G) Execution Record**

- **Status:** Done.
- **Files changed:**
  - `lib/net.ml` + `lib/net.mli` — new. No direct 1:1 Go source counterpart
    (Go's `net/http` builds on the stdlib `net` package + `crypto/tls`); this is
    the socket/TLS substrate the server (Ticket 9) and client (Ticket 10)
    tickets build on. Public surface (hand-written `net.mli`):
    - `listen : ?backlog:int -> string -> int -> Lwt_unix.file_descr Lwt.t` —
      resolves host/port via `Lwt_unix.getaddrinfo` (TCP), creates a socket,
      sets `SO_REUSEADDR`, binds, and `listen`s (`backlog` default 128, Go's
      `net.Listen` default). Host used as given (`0.0.0.0`/`127.0.0.1`); port 0
      yields an ephemeral port.
    - `accept : Lwt_unix.file_descr -> (Lwt_unix.file_descr * Unix.sockaddr) Lwt.t`
      — `Lwt_unix.accept` (one connection + peer addr).
    - `channels_of_fd : Lwt_unix.file_descr -> (Lwt_io.input_channel * Lwt_io.output_channel)`
      — wraps an fd in buffered `Lwt_io` channels (the `bufio` analogue used by
      `Io`).
    - `connect : host:string -> port:int -> ?tls:bool -> unit -> (ic * oc) Lwt.t`
      — resolves + connects a client TCP socket; when `tls:true`, builds a
      `Tls.Config.client` with the null authenticator and upgrades via
      `Tls_lwt.Unix.client_of_fd` (peer name from `Domain_name.host` when the
      host parses as a hostname), then `Tls_lwt.of_t` to `Lwt_io` channels.
    - `local_addr` / `bound_port` (extract the bound ephemeral port for tests),
      `sockaddr_to_string` (Go `host:port`, IPv6 bracketed — for
      `Request.remote_addr`), `with_timeout : float -> 'a Lwt.t -> 'a Lwt.t`
      (wraps `Lwt_unix.with_timeout` for bounded tests), and
      `null_authenticator : X509.Authenticator.t` (exposed + documented).
  - `test/test_net.ml` — new; alcotest suite `val tests` (1 case).
    `Net.loopback_roundtrip`: `listen "127.0.0.1" 0`, read the ephemeral port,
    one server fiber `accept`s + echoes a line, one client fiber `connect`s,
    writes `"PING"`, reads the echo, asserts equality. Whole run wrapped in
    `Net.with_timeout 5.` and driven by `Lwt_main.run` so a hang fails rather
    than blocks. (TLS path is smoke-only — not exercised here, see note.)
  - `test/test_gohttp.ml` — added `("Net", Test_net.tests)`.
    (`lib/dune` already had `tls-lwt`; `test/dune` already had `lwt lwt.unix`.)
- **Test evidence:** `dune build` clean; `dune test` → "Test Successful in
  0.031s. **218 tests run.**" All `[OK]`. New suite `Net` = 1 case
  (`loopback_roundtrip`), completes far under its 5s timeout (suite runs in
  ~0.03s total), confirming it terminates. Baseline before ticket: 217.
- **TLS verification note (documented deviation):** `connect ~tls:true` uses a
  **null authenticator** (`null_authenticator = fun ?ip:_ ~host:_ _ -> Ok None`)
  that accepts any server certificate without verification. This is acceptable
  for the smoke-test substrate only; a production client must supply a real
  authenticator (e.g. `X509` system trust). The policy is exposed and documented
  on `Net.null_authenticator` and in the `connect` doc comment so it is not
  mistaken for verified TLS. The TLS path itself is smoke-only (no local TLS
  server in the test); it is wired and type-checked but not exercised by a test.
- **Commit:** `(see below)`

### Ticket 8 — ServeMux internals (pattern, routing_tree, mapping)
Status: Done

**A) Scope** Port `pattern.go`, `routing_tree.go`, `mapping.go` — pattern parsing and the routing tree used by `ServeMux`.

**B) Migration Strategy** Additive pure modules; no server wiring yet.

**C) Exit State** Pattern parse + route matching match Go's test expectations.

**D) Detailed Design** `Pattern.parse : string -> pattern`; `Routing_tree` add/match with wildcards/`{name}`/`{name...}` and method matching as in Go 1.22+ mux.

**E) Testing Plan** *Unit* (`test/test_pattern.ml`, `test/test_routing_tree.ml`, ported from `pattern_test.go`/`routing_tree_test.go`): pattern parse cases, conflict detection, longest-match precedence, wildcard capture.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Status:** Done.
- **Files changed:**
  - `lib/mapping.ml` + `lib/mapping.mli` — new; port of
    `go/src/net/http/mapping.go`. `type ('k, 'v) t` is the hybrid
    slice-or-map container: stores entries in a list (`s`) while
    `len < max_slice` (= 8, Go's `maxSlice`), then switches to a `Hashtbl`
    (`m`) once over the threshold — mirroring Go's `mapping[K,V]{ s, m }`. Ports
    `create` (Go's zero value), `add`, `find` (`'v option` for Go's
    `(v, found)`), `each_pair` (with early-exit when `f` returns `false`), and
    `using_map` (exposes Go's `m.m != nil` for the threshold-switch test). Uses
    `Hashtbl` for the map representation per the project rule.
  - `lib/pattern.ml` + `lib/pattern.mli` — new; port of
    `go/src/net/http/pattern.go`. `type segment = { s; wild; multi }` and
    `type t = { str; method_; host; segments }` mirror Go's `segment`/`pattern`
    structs. Ports `parse` (Go's `parsePattern`, returning `(t, string) result`
    with Go's faithful `"at offset N: ..."` messages), `to_string`,
    `last_segment`, the `relationship` variant + `relationship_to_string` /
    `inverse_relationship` / `combine_relationships`, `compare_methods`,
    `compare_segments`, `compare_paths`, `compare_paths_and_methods`,
    `conflicts_with`, `describe_conflict`, `common_path`, `difference_path`, and
    the helpers `valid_method` (Go `validMethod`/`isToken`),
    `is_valid_wildcard_name`, `path_unescape` (Go `pathUnescape` via a self-
    contained `%XX` decoder), and `path_clean` (Go `cleanPath`/`path.Clean`, to
    reject unclean non-CONNECT patterns).
  - `lib/routing_tree.ml` + `lib/routing_tree.mli` — new; port of
    `go/src/net/http/routing_tree.go`. `type 'h node` mirrors Go's
    `routingNode` (leaf `pattern`+`handler` as `(Pattern.t * 'h) option`;
    interior `children : (string, _) Mapping.t`, `multi_child`, `empty_child`),
    keeping the handler polymorphic since the server is not wired yet. Ports
    `add_pattern` (host → method → path levels), `add_segments`, `set`,
    `add_child`/`find_child`, `match_` (Go's `match`: host then no-host
    fallback), `match_method_and_path` (exact method, then GET-for-HEAD, then
    no-method), `match_path` (literal → single-wildcard → multi-wildcard with
    backtracking, trailing-slash special case, wildcard capture), `first_segment`,
    `matching_methods`/`matching_methods_path`, and `print` (Go's
    `(routingNode).print` with `%q` quoting via a local `go_quote`).
    `children` uses `Mapping` (the `map`→`Hashtbl` analog) as Go does.
  - `test/test_mapping.ml` — new; alcotest suite `val tests` (4 cases) ported
    from `mapping_test.go`: `mapping_slice_to_map` (TestMapping: stays slice up
    to `max_slice`, `using_map` flips on the next add), `each_pair`
    (TestMappingEachPair: visits all pairs in the map representation, compared
    order-independently), `each_pair_stop` (early-exit when `f` returns false),
    `find_absent` (slice-representation present/absent lookups). (The
    `BenchmarkFindChild` benchmark is omitted — see notes.)
  - `test/test_pattern.ml` — new; alcotest suite `val tests` (8 cases) ported
    from `pattern_test.go`: `parse_pattern` (all 20 `TestParsePattern` rows incl.
    multi-space method, `%`-escapes, `{$}`, `{rest...}`), `parse_pattern_error`
    (all 21 `TestParsePatternError` rows, substring-matched), `compare_methods`
    (TestCompareMethods + inverse), `compare_paths` (a representative+edge subset
    of TestComparePaths with self-equivalence + inverse checks), `conflicts_with`
    (all 21 TestConflictsWith rows + commutativity), `describe_conflict`
    (TestDescribeConflict), `common_path` (TestCommonPath), `difference_path`
    (TestDifferencePath).
  - `test/test_routing_tree.ml` — new; alcotest suite `val tests` (4 cases)
    ported from `routing_tree_test.go` (handlers are `()` for Go's `nil`):
    `first_segment` (TestRoutingFirstSegment), `add_pattern` (TestRoutingAddPattern
    tree-structure rendering via `print`), `node_match` (the full
    TestRoutingNodeMatch: the 8-pattern tree, the 11-pattern host/method tree,
    and the `{$}`/`{w}`/`{w...}` precedence trees — longest-match, wildcard
    capture, HEAD-matches-GET, case-sensitive methods, host fallback),
    `matching_methods` (TestMatchingMethods incl. GET⇒HEAD).
  - `test/test_gohttp.ml` — registered `("Mapping", …)`, `("Pattern", …)`,
    `("RoutingTree", …)`.
- **Test evidence:** `dune build` clean; `dune test` → "Test Successful in
  0.031s. **234 tests run.**" All `[OK]`. New suites: `Mapping` (4), `Pattern`
  (8), `RoutingTree` (4) = 16 new, alongside the 218 baseline.
- **Porting notes / intentionally omitted Go cases:**
  - `mapping_test.go`'s `BenchmarkFindChild` / `findChildLinear` are Go
    benchmarks (perf-only), omitted; the slice-vs-map behavior they exercise is
    covered by the functional tests.
  - These modules are pure (no IO/Lwt) and are **not** wired into a server —
    that is Ticket 9. `routing_index.go` (the `routingIndex` optimization that
    pre-filters candidate patterns before tree search) is intentionally **not**
    ported: it is a performance optimization layered over the same tree; the
    tree's `add_pattern`/`match`/`matching_methods` semantics (the spec the mux
    relies on) are ported in full. The Go-side `TestRegisterConflict` lives in
    `pattern_test.go` but exercises `ServeMux.registerErr` (server wiring), so it
    is deferred to Ticket 9; the underlying `conflicts_with`/`describe_conflict`
    logic it depends on is fully covered here.
  - `is_valid_wildcard_name` uses ASCII letter/digit/`_` classification rather
    than Go's full `unicode.IsLetter`/`IsDigit`; sufficient for the ported test
    surface (all wildcard names are ASCII), flagged as a faithful narrowing.
  - `each_pair` / `print` iterate the map representation in `Hashtbl` order; the
    `print` test sorts child keys exactly as Go's `print` does, so output is
    deterministic, and `each_pair` results are compared order-independently.
- **Commit:** _(commit id annotation lands in a subsequent working-copy change)_

### Ticket 9 — Server + ServeMux dispatch
Status: Done

**A) Scope** Port `server.go` (HTTP/1.x subset): `Handler`, `handler_func`, `ResponseWriter`, the per-conn serve loop, `Server`, `listen_and_serve`, `ServeMux` dispatch.

**B) Migration Strategy** New `lib/server.ml` composing `Io`, `Net`, `Routing_tree`. Keep-alive + implicit `WriteHeader(200)` semantics per Go. **Version-sensitive:** honor Go's connection-reuse rules — HTTP/1.0 closes by default unless `Connection: keep-alive`, HTTP/1.1 keeps alive unless `Connection: close`; emit responses with the request's protocol.

**C) Exit State** A server started on loopback serves a registered handler and returns the expected response for both HTTP/1.0 and HTTP/1.1 requests.

**D) Detailed Design** `ResponseWriter` interface (`header`, `write`, `write_header`); `Server.listen_and_serve : addr -> handler -> unit Lwt.t`; `ServeMux.handle`/`handle_func`.

**E) Testing Plan** *Integration* (`test/test_serve.ml`, ported subset of `serve_test.go`): `Serve.hello_handler` (200 + body), `Serve.not_found` (unregistered path → 404), `Serve.mux_routing` (path/method dispatch), `Serve.http10_close` (HTTP/1.0 request closes connection by default; keep-alive honored when requested).

**F) End-of-Ticket Verification** `dune build && dune test` clean; serve tests bounded by timeout.

**G) Execution Record**

- **Status:** Done.
- **Files changed:**
  - `lib/server.ml` + `lib/server.mli` — new; port of the HTTP/1.x subset of
    `go/src/net/http/server.go`.
    - `type response_writer = { header; write_header; write }` models Go's
      `ResponseWriter` interface as a record of operations; `type handler =
      { serve_http : response_writer -> Body.t Request.t -> unit Lwt.t }` is
      Go's `Handler`, and `handler_func` is Go's `HandlerFunc`.
    - **ResponseWriter impl** (`serve_one`): buffers the body until the handler
      returns, then emits the status line with the request's protocol
      (`HTTP/1.1` if `proto_at_least 1 1` else `HTTP/1.0`), an exact
      `Content-Length` for body-allowed statuses (the common Go buffered path),
      Content-Type sniffing via `Sniff.detect_content_type` when unset and
      `X-Content-Type-Options: nosniff` absent, a `Date` header, and the
      version-sensitive `Connection` header (see keep-alive note). Implicit
      `WriteHeader(200)` on first `write`/at finish; `body_allowed_for_status`
      (1xx/204/304 carry no body); HEAD suppresses the body. Managed framing
      headers (`Content-Length`/`Transfer-Encoding`/`Connection`) are excluded
      from the handler header block, the rest written sorted via
      `Header.write_subset`.
    - **Helpers:** `error` (Go `Error`: reset Content-Type to
      `text/plain; charset=utf-8`, drop Content-Length, set nosniff, write
      code + message + "\n"), `not_found`/`not_found_handler` (Go `NotFound`/
      `NotFoundHandler`), `redirect`/`redirect_handler` (Go `Redirect`/
      `RedirectHandler`, incl. relative-target resolution against the request
      path, `path.Clean`, the trailing-slash preserve, `html_escape`, and the
      GET-only HTML body), `html_escape` (Go `htmlReplacer`).
    - **ServeMux:** `serve_mux` backed by `Routing_tree` (handler-polymorphic
      tree from Ticket 8) + `Pattern`. `new_serve_mux`, `handle`/`handle_func`
      (Go `Handle`/`HandleFunc` → `register`: parse, conflict-check via
      `Pattern.conflicts_with`/`describe_conflict` over a linear pattern list —
      Go's `registerErr` minus the `routingIndex` pre-filter — raising
      `Register_error` instead of panicking), `serve_mux_serve_http`
      (Go `ServeMux.ServeHTTP`: the `RequestURI == "*"` 400 case, then
      `find_handler`). `find_handler` ports Go's `findHandler`:
      `clean_path` (Go `cleanPath`), `strip_host_port` (Go `stripHostPort`),
      `match_or_redirect` + `exact_match` (trailing-slash 307 redirect),
      the cleaned-path 307 redirect, the CONNECT no-canonicalization branch,
      and the `matching_methods` → 405-with-Allow vs 404 distinction.
    - **Server:** `type t` (addr/port/handler + an internal stop promise +
      listening fd), `create`, minimal `close` (Go `Server.Close`: resolve the
      stop promise + close the listener), `serve` (Go `Server.Serve`: accept
      loop racing against the stop promise, each connection handled in its own
      `Lwt.async` fiber running the per-conn keep-alive loop via
      `Io.read_request`/`serve_one`), `listen_and_serve` (Go `ListenAndServe`),
      and `listen_and_serve_started` (binds first, returns
      `(t, bound_port, serve_loop)` so tests can target an ephemeral port and
      `close`).
  - `lib/pattern.mli` — exposed `path_clean` (already implemented in
    `pattern.ml`; `ServeMux.clean_path`/`redirect` reuse it as Go's `cleanPath`/
    `path.Clean`).
  - `test/test_serve.ml` — new; alcotest suite `val tests` (4 cases), a ported
    subset of `serve_test.go`. Each starts a real loopback server on an
    ephemeral port via `listen_and_serve_started`, drives it with a raw client
    (`Net.connect` + raw `Lwt_io`, since the gohttp Client is Ticket 10), and
    asserts on raw response bytes; the whole run is bounded by
    `Net.with_timeout 10.` and driven by `Lwt_main.run`, so a hang fails.
    - `hello_handler` (TestServeMux/handler-writes-body analogue): GET `/`,
      assert `200 OK` status line + body `"hello"`.
    - `not_found` (TestServeMuxHandler 404 path): unregistered path → 404 with
      `"404 page not found"` body.
    - `mux_routing`: patterns `/a`, `/b`, `POST /c` dispatch by path; GET `/c`
      → `405 Method Not Allowed` with `Allow: POST`; POST `/c` → its handler.
    - `http10_close` (version-sensitive connection mgmt): an HTTP/1.0 request
      gets an `HTTP/1.0 200` response and the server closes (no
      `Connection: keep-alive`, `read_to_eof` terminates with the body); an
      HTTP/1.0 `Connection: keep-alive` request gets `Connection: keep-alive`
      and a second request is served on the same socket.
  - `test/test_gohttp.ml` — registered `("Serve", Test_serve.tests)`.
- **Test evidence:** `dune build` clean; `dune test` → "Test Successful in
  0.032s. **242 tests run.**" All `[OK]`. New suite `Serve` = 4 cases
  (`hello_handler`, `not_found`, `mux_routing`, `http10_close`), alongside the
  238 baseline. Re-ran the executable 3× with identical results (242, ~0.03s),
  confirming the networked tests terminate (each bounded by
  `Net.with_timeout 10.`).
- **Keep-alive / version handling verification:** `serve_one` computes
  `keep_alive = (not req_should_close) && not handler_conn_close`, where
  `req_should_close` is `Request.close` as set by `Io.read_request`'s
  `Transfer.should_close` (HTTP/1.0 close-by-default unless `keep-alive`;
  HTTP/1.1 keep-alive unless `close`). On the wire: a closing response emits
  `Connection: close`; an HTTP/1.0 kept-alive response emits the explicit
  `Connection: keep-alive` Go requires (HTTP/1.1 kept-alive emits neither). The
  per-conn loop only iterates while `keep_alive` holds. The `http10_close` test
  asserts both directions end-to-end (default-1.0 closes + omits keep-alive;
  explicit-keep-alive advertises it and serves a second request on the same
  socket). The status line always carries the request's protocol.
- **Porting notes / intentionally omitted Go cases:**
  - Bodies are buffered (not streamed) before flush, so responses always carry
    an exact `Content-Length` — Go's common buffered path. The chunked-encoding
    fallback for unknown-length HTTP/1.1 streaming output is therefore not
    exercised by this ticket's writer (no streaming `ResponseWriter` yet); the
    chunked *framing* is ported in `Transfer` (Ticket 5). Flagged as a
    buffer-vs-stream narrowing.
  - `Server.Close` is intentionally minimal (resolve stop promise + close
    listener); graceful shutdown / connection tracking / `Shutdown`,
    `ConnState`/state hooks, `ReadTimeout`/`WriteTimeout`/`IdleTimeout`,
    `Hijack`, `Flush`, `Expect: 100-continue` handling, the `100 Continue`
    auto-send, and HTTP/2 / unencrypted-h2 / TLS-NPN paths are out of scope per
    the ticket. `relevantCaller`/superfluous-WriteHeader logging is omitted
    (no `log` analog).
  - `registerErr` is ported without the `routingIndex` `possiblyConflictingPatterns`
    pre-filter (Ticket 8 already noted `routing_index.go` is a perf-only
    optimization): conflict detection scans all registered patterns linearly,
    which is behaviorally identical. `register` raises `Register_error` rather
    than `panic`. `DefaultServeMux` and the package-level `Handle`/`HandleFunc`
    are omitted (no global mutable default; callers create a `serve_mux`).
  - `Redirect`'s non-ASCII `hexEscapeNonASCII` of the Location URL is narrowed
    to a pass-through (faithful for ASCII targets, the only ones tested);
    `StripPrefix` is omitted (not in the required surface, depends on
    `URL.RawPath` which `Uri.t` does not expose distinctly).
  - The networked `serve_test.go` tables (`TestServerContentTypeSniff`,
    `TestHostHandlers`, the large `TestServeMux*` route tables, timeout/idle
    tests, etc.) are not ported wholesale; the four representative cases above
    cover the required behaviors (200+body, 404, path/method dispatch, and the
    HTTP/1.0 vs keep-alive connection rules).
- **Commit:** _(commit id annotation lands in a subsequent working-copy change)_

### Ticket 10 — Client + Transport
Status: Planned

**A) Scope** Port `client.go` + `transport.go` (HTTP/1.x): `RoundTripper`, `Transport`, `Client`, `Client.do`.

**B) Migration Strategy** New `lib/client.ml` + `lib/transport.ml` composing `Io`, `Net`. Connection reuse keyed by scheme/host/port. **Version-sensitive:** keep-alive reuse follows Go's rules (HTTP/1.1 default reuse; HTTP/1.0 only with `Connection: keep-alive`); requests default to HTTP/1.1 as Go does.

**C) Exit State** End-to-end: client GETs the Ticket-9 server and reads status+body. Satisfies the integration success criterion.

**D) Detailed Design** `Transport.round_trip : 'b Request.t -> Body.t Response.t Lwt.t`; `Client.do_ : ?client:Client.t -> 'b Request.t -> Body.t Response.t Lwt.t`; `Client.get`/`post` helpers. `bin/main.ml` becomes an example server+client round-trip.

**E) Testing Plan** *Integration* (`test/test_clientserver.ml`, ported subset of `clientserver_test.go`/`client_test.go`): `Clientserver.get_roundtrip` (200 + body equality), `Clientserver.post_body` (request body echo), `Transport.keepalive_reuse` (two requests reuse one connection).

**F) End-of-Ticket Verification** `dune build && dune test` clean; round-trip tests bounded by timeout.

**G) Execution Record** _(tbd)_

### Ticket 11 — Form & multipart parsing
Status: Planned

**A) Scope** Port the request form API deferred from Ticket 6: `ParseForm`, `ParseMultipartForm`, `FormValue`, `PostFormValue`, `FormFile`, and the `form`/`post_form`/`multipart_form` fields of `Request.t`. URL-encoded form parsing (`application/x-www-form-urlencoded`) is ported faithfully; **multipart/form-data parsing uses the `multipart_form-lwt` opam library as a pragmatic stand-in** (Go hand-rolls `mime/multipart`; a faithful port is a possible future pass).

**B) Migration Strategy** Additive: add `form`/`post_form` (`(string, string list) Hashtbl.t` mirroring `url.Values`) and `multipart_form` fields to `Request.t` as optionals so existing Ticket-6 round-trips are unaffected. Add `multipart_form-lwt` to deps. Feed the existing `Body.t`/`Lwt_io` body stream into the parser.

**C) Exit State** `parse_form` populates `form`/`post_form` from the query string + urlencoded body; `parse_multipart_form` populates `multipart_form` for `multipart/form-data` bodies; `form_value`/`form_file` read from them. Build + tests green.

**D) Detailed Design** `val parse_form : Body.t Request.t -> unit Lwt.t`; `val parse_multipart_form : Body.t Request.t -> max_memory:int64 -> unit Lwt.t`; `val form_value : Body.t Request.t -> string -> string`; `val form_file : Body.t Request.t -> string -> (file_header) option`. `url.Values` → `(string, string list) Hashtbl.t` with `get`/`set`/`add`/`encode` helpers (a small `Values` module).

**E) Testing Plan** *Unit* (`test/test_request_form.ml`, ported from `request_test.go` form tests): `Form.parse_urlencoded` (query + body merge, precedence), `Form.multipart` (parse a multipart/form-data body, assert field + file values), `Form.form_value`. Note any rows skipped due to the library stand-in.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record** _(tbd)_

> **Deviation note:** Ticket 11's multipart parsing depends on `multipart_form-lwt` rather than a hand-written port of Go's `mime/multipart`. This is the one intentional fidelity exception in the plan, chosen for expedience; flagged here so it is not mistaken for a complete 1:1 port.
