# gohttp — Tier 1: httptest + fs (file serving) — Plan

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

- **Goal:** Port two Tier-1 subsystems of Go's `net/http`, faithful 1:1:
  1. **`net/http/httptest`** — `ResponseRecorder` (in-memory `ResponseWriter` for unit-testing handlers) and `Server` (an ephemeral-loopback test server with `.url`/`.client`/`.close`, plus a TLS variant). This is a **force multiplier**: Go's own server/fs tests are written against `httptest`, so it unlocks faithfully porting many more Go tests.
  2. **`fs.go`** — static file serving: `FileSystem`/`File`/`Dir`, `ServeContent`, `ServeFile`, `FileServer`, **byte-range requests** (RFC 7233, single + `multipart/byteranges`), **conditional requests** (`If-Modified-Since`/`If-None-Match`/`If-Match`/`If-Unmodified-Since`/`If-Range`, ETag), directory listings, `toHTTPError`/`localRedirect`. Streams content (composes with the streaming body work).
- **Success Criteria (as tests):**
  - *Unit:* `Httptest.recorder_basic` — a handler that sets headers + `write_header 201` + writes a body, run against a `ResponseRecorder`, yields `code=201`, the header, and the body via `result`. (Ported from `recorder_test.go`.)
  - *Integration:* `Fs.serve_file_range` — a `FileServer` over a temp dir, hit through a `Httptest.Server` with the gohttp `Client`: a plain GET returns 200 + full contents + correct `Content-Type`/`Last-Modified`/`Accept-Ranges`; a `Range: bytes=N-M` GET returns **206** + `Content-Range` + exactly those bytes; an `If-None-Match`/`If-Modified-Since` GET returns **304**. (Ported from `fs_test.go`.)
- **Non-Goals:** `FileServerFS`/`fs.FS` adapter beyond a thin wrapper (we target `Dir` on the real filesystem); `filetransport.go` (the `file:` scheme RoundTripper); a full `mime.TypeByExtension` database (a small extension table + `Sniff` fallback is enough — note the stand-in); embedded-FS; HTTP/3.
- **Constraints:** OCaml ≥ 5.0. No new opam deps expected (filesystem via `Lwt_unix`/`Unix`; HTTP-date via a small helper, see Discovery). Every `lib/` module gets a `.mli`. Mirror Go's data structures and the `fs.go`/`httptest` control flow. Cross-reference `go/src/net/http/fs.go` and `go/src/net/http/httptest/*.go`. **When a ported test fails, fix the implementation, not the test** (unless adapting to an OCaml-API difference, which must be called out).

## Discovery

- **Current surfaces this composes with:**
  - `Server` (`server.mli`): `type handler = { serve_http : response_writer -> Body.t Request.t -> unit Lwt.t }`; `response_writer = { header : unit -> Header.t; write_header : int -> unit; write : string -> unit Lwt.t; flush : unit -> unit Lwt.t }`; `serve_mux`/`handle`/`handle_func`; `listen_and_serve_started : addr:string -> port:int -> handler -> (t * int * unit Lwt.t) Lwt.t` and `listen_and_serve_tls_started` (ephemeral port when `port=0`); `redirect`, `not_found`, `Status` helpers.
  - `Net`: `test_server_certificate`, TLS listen/connect, `with_timeout`.
  - `Client`/`Transport`: `get`/`do_`/`?insecure` (the test server uses a self-signed cert → its `Client()` must trust it / use `~insecure`).
  - `Request.t` (`url : Uri.t`, `header`, `meth`, `body`), `Response.t`, `Header` (`(string,string list) Hashtbl.t`), `Body` (`Empty|String|Stream`, `read_all`/`drain`/`iter`), `Sniff.detect_content_type`, `Method`, `Status`.
- **HTTP-date:** `cookie.ml` already contains a hand-written GMT formatter/parser for `Mon, 02 Jan 2006 15:04:05 GMT` (RFC1123) and the cookie expires layouts. `fs` needs `Last-Modified`/`If-Modified-Since` in the same RFC1123 GMT format, plus Go's `http.ParseTime` (which accepts RFC1123, RFC850, ANSI C asctime). **Decision:** extract the date logic into a small shared `Http_time` module (`format_gmt`, `parse_http_time` accepting the 3 layouts) and have both `cookie.ml` and `fs.ml` use it (Ticket 3 does the extraction).
- **File / ReadSeeker:** Go's `ServeContent` takes an `io.ReadSeeker`; `http.File` is `Read`/`Seek`/`Close`/`Readdir`/`Stat`. We model a `File`/`FileSystem` interface over `Lwt_unix` (open, fstat for size+modtime, `Lwt_unix.lseek`/pread for ranges, `Lwt_unix.readdir`/`Lwt_unix.opendir` for listings). Range reads seek + read a bounded window (streamed as a `Body.Stream`).
- **MIME by extension:** Go uses `mime.TypeByExtension` then sniffs. We use a small built-in extension→type table (`.html .css .js .json .png .jpg .gif .svg .txt .pdf …`) and fall back to `Sniff.detect_content_type` on the first bytes — noted as a stand-in (no `mime` package port).
- **Migration pressure points:** (1) `ServeContent` must stream + support seeking for ranges — don't read whole files into memory. (2) `httptest.Server.Client()` must trust the self-signed test cert (use `~insecure` / a custom authenticator) or TLS tests fail post-verification-work. (3) Path cleaning / directory-traversal safety (`Dir.Open` rejects `..`, mirrors `containsDotDot`/`http.ServeMux` cleanPath). (4) `multipart/byteranges` response generation needs a boundary + per-part headers.
- **Areas of uncertainty:** exact `If-Range` (ETag vs date) interaction with range serving; `Lwt_unix` seek/readdir ergonomics; how faithfully to reproduce Go's `dirList` HTML escaping; modtime resolution (seconds) vs Go.

## Target Shape

- **New modules (in the `gohttp` library, flat, each with `.mli`):**
  - `http_time.ml` — `format_gmt : float -> string` (RFC1123 GMT) and `parse_http_time : string -> float option` (RFC1123 / RFC850 / asctime), extracted from `cookie.ml` which is refactored to use it. (Go `net/http`'s `TimeFormat`/`ParseTime`.)
  - `httptest.ml` — `Response_recorder` (record/obj implementing `Server.response_writer` + captured `code`/`header_map`/`body buffer`/`flushed`; `result : unit -> Body.t Response.t`); `Server` test-server (`new_server`/`new_tls_server`/`new_unstarted` over `Server.listen_and_serve_started`; fields `url`, `listener`, `close`, `client : unit -> Client.t`).
  - `fs.ml` — `Dir`, `file_system`/`file` interfaces, `serve_content`, `serve_file`, `file_server` (`-> Server.handler`), `dir_list`, `to_http_error`, `local_redirect`, and the range/precondition internals (`parse_range`, `http_range`, `scan_etag`, `check_preconditions`).
- **Public contracts:** `Httptest.new_server : Server.handler -> server Lwt.t` (+ `_tls`), `server.url : string`, `Httptest.close`, `Httptest.client`; `Httptest.Response_recorder.create`/`.to_response_writer`/`.result`; `Fs.file_server : file_system -> Server.handler`, `Fs.serve_file`, `Fs.serve_content`, `Fs.dir : string -> file_system`.
- **Execution flow:** test handler ↔ `Response_recorder` (no socket) **or** ↔ `Httptest.Server` (real loopback). `FileServer`: request → clean path → `Dir.open` → if dir: `dir_list` (or index.html) ; if file: `serve_content` → `check_preconditions` (maybe 304/412) → `parse_range` (maybe 206 single / `multipart/byteranges`) → stream bytes via `Body.Stream` over a seek+read window.
- **Migration shape:** bottom-up — `http_time` → `httptest` (recorder, then server) → `fs` core → `fs` conditionals → `fs` ranges. `fs` tickets test through `httptest.Server`, exactly as Go does.
- **End-state:** handlers are unit-testable in-memory; a real static file server with ranges + conditional GETs works end-to-end; both have ported Go tests.

## Implementation Guide

- **Execution Model:** Orchestrator + sub-agents, tickets **serial**, lowest open first. Never parallelize tickets.
- **Per-Ticket Workflow:** ticket agent MUST (1) `jj st` + `dune test` green start; (2) implement against the Go source, `.mli` for every new module, mirror Go data structures; (3) port the corresponding Go `*_test.go` cases into alcotest (driving Lwt via `Lwt_main.run`, networked tests bounded by `Net.with_timeout`); (4) ALL plan edits (Execution Record) BEFORE committing; (5) one clean `jj commit`, no edits after.
- **Verification Gate:** Execution Record shows `dune build` clean + named tests passing + jj commit id before advancing. Networked/file tests MUST terminate (timeout-bounded; temp dirs cleaned up).
- **Failure Handling:** ticket agent failure → feedback; retry ONCE with a fresh agent; two failures → stop, return to user.
- **Test-change rule:** adapting a ported test to an OCaml API shape is legitimate and must be noted; never weaken an assertion about status/headers/body.

## Build Out

### Ticket 1 — Http_time (shared HTTP-date) + httptest.ResponseRecorder
Status: Done

**A) Scope** (1) Extract a shared `http_time.ml` (+ `.mli`): `format_gmt` (RFC1123 `Mon, 02 Jan 2006 15:04:05 GMT`) and `parse_http_time` (accept RFC1123, RFC850, asctime — Go's `http.ParseTime`); refactor `cookie.ml` to use it (behavior identical, cookie tests stay green). (2) `httptest.ml` `Response_recorder`: an in-memory `Server.response_writer` capturing status (default 200), header map, body buffer, and a `flushed` flag; `result : unit -> Body.t Response.t` mirroring `ResponseRecorder.Result` (snapshot headers, body as `Body.String`, status code/line, auto Content-Type sniff + Content-Length like Go).

**B) Migration Strategy** Additive `http_time.ml`, `httptest.ml`; `cookie.ml` internals swapped to `Http_time` with no API change. `Response_recorder` exposes `to_response_writer : t -> Server.response_writer` so handlers run unchanged.

**C) Exit State** Handlers can be run against a recorder and inspected; cookie tests still green. Build + tests green.

**D) Detailed Design** `type t = { mutable code:int; header:Header.t; body:Buffer.t; mutable flushed:bool; mutable wrote_header:bool }`; `to_response_writer` builds the `{header;write_header;write;flush}` record over `t`; `result` follows `recorder.go:Result` (default 200, sniff Content-Type from body if unset, set Content-Length unless flushed/chunked).

**E) Testing Plan** *Unit* (`test/test_httptest.ml`, from `recorder_test.go`): `recorder_basic` (Success Criterion — code/header/body via result), default-200, implicit-WriteHeader-on-first-write, WriteString, Flush sets flushed; plus a `test/test_http_time.ml` round-trip (format→parse, the 3 parse layouts).

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Baseline:** `jj st` clean; `dune build && dune test` green at **452** tests.
- **Files created:**
  - `lib/http_time.ml` + `lib/http_time.mli` — shared HTTP-date module. `format_gmt : float -> string` (Go `http.TimeFormat` `"Mon, 02 Jan 2006 15:04:05 GMT"`); `parse_http_time : string -> float option` (Go `http.ParseTime`: tries RFC1123 GMT, then RFC850 `"Monday, 02-Jan-06 15:04:05 GMT"` with 2-digit-year pivot at 69 like Go's `time`, then ANSIC asctime `"Mon Jan _2 15:04:05 2006"` with space-collapsed day). Also re-exports the civil-date primitives (`days_in_month`, `is_leap`, `days_from_civil`, `unix_of_utc`, `utc_of_unix`, `month_of_name`, name tables) that were moved out of `cookie.ml`.
  - `lib/httptest.ml` + `lib/httptest.mli` — `Response_recorder` (Go `httptest.ResponseRecorder`). Record `{ mutable code; header; body:Buffer; mutable flushed; mutable wrote_header; mutable snap_header; mutable default_remote_addr }`; `create` (code=200), `to_response_writer`, `result : t -> Body.t Response.t`, getters `code`/`body_string`/`header`. Faithful port of `recorder.go`: first `write_header` wins; first `write` implicitly commits 200 + sniffs Content-Type (≤512 bytes, only when unset and no Transfer-Encoding) via `Sniff.detect_content_type`; `flush` commits 200 (no sniff) and sets `flushed`; header snapshot (`Header.clone`) taken at first commit (or at `result` time if never committed); `result` defaults code 0→200, status line `"%03d %s"`, body `Body.String`, content_length via a port of `parseContentLength` (trim, ""→-1, reject `+`/`-`/overflow).
  - `test/test_http_time.ml` (`val tests`, 6 cases): `format_gmt` of a known epoch (2006-01-02 15:04:05 UTC, Monday) == expected RFC1123; RFC1123 round-trip; RFC850 + asctime samples parse to the same epoch; garbage and empty → `None`.
  - `test/test_httptest.ml` (`val tests`, 10 cases ported from `recorder_test.go`): `recorder_basic` (Success Criterion: header + `write_header 201` + body → code 201 / "201 Created" / header / body), default 200, first-code-only, implicit-WriteHeader-on-first-write (flushed false), write-string (+CT sniff), flush-sets-flushed (result content_length −1), Content-Type html detection, Content-Type explicit not overridden, header snapshot at first commit, Content-Length header parsed (=9).
- **Files modified:**
  - `lib/cookie.ml` — removed the duplicated civil-date math/formatter (`days_from_civil`/`unix_of_utc`/`utc_of_unix`/`format_time`/name tables); now delegates to `Http_time` (`days_in_month`, `is_leap`, `unix_of_utc`, `month_of_name`, `format_time = Http_time.format_gmt`, `year_of` via `Http_time.utc_of_unix`). The cookie-specific `parse_expires` (accepts `DD-Mon-YYYY HH:MM:SS MST` with 4-digit year + arbitrary zone, unlike Go's `ParseTime`) was kept in `cookie.ml` to preserve byte-identical cookie behavior. `cookie.mli` unchanged.
  - `test/test_gohttp.ml` — wired `("HttpTime", Test_http_time.tests)` and `("Httptest", Test_httptest.tests)`.
- **Evidence:** `dune build` clean; `dune test` green — **468** tests (452 baseline + 6 HttpTime + 10 Httptest). All 91 Cookie cases stay green (refactor behavior-preserving). New suites: HttpTime 0–5 OK, Httptest 0–9 OK.
- **API adaptation noted:** Go's `ResponseRecorder.WriteHeader` panics on a non-3-digit code (`checkWriteHeaderCode`); the OCaml `write_header` raises `Invalid_argument` instead (closest idiomatic analogue). Trailer-header handling in `Result` (the `Trailer`/`Trailer:`-prefix machinery) was not ported — the existing `Response.t` has `trailer = None` and no ticket consumer needs it yet; noted as a deliberate omission. `default_remote_addr` field is present (Go `DefaultRemoteAddr`) but only consumed by the loopback Server (Ticket 2).

**Status: Done.** Commit: see below.

### Ticket 2 — httptest.Server (loopback test server + Client + TLS)
Status: Done

**A) Scope** Port `httptest/server.go` (subset): `new_server handler` binds an ephemeral `127.0.0.1` port via `Server.listen_and_serve_started`, exposing `url` (`http://127.0.0.1:PORT`), a `close` that stops the server, and `client ()` returning a `Client.t` configured to talk to it. `new_tls_server` uses `listen_and_serve_tls_started` + `Net.test_server_certificate`; its `client ()` trusts the self-signed cert (via `~insecure` / custom authenticator). `new_unstarted` + `start`/`start_tls` if cheap.

**B) Migration Strategy** Thin wrapper over existing started-server helpers; additive. TLS client trust handled with the existing insecure opt-out.

**C) Exit State** A `Httptest.Server` serves a handler and the gohttp client round-trips against `.url` (http and https). Build + tests green.

**D) Detailed Design** `type server = { url:string; port:int; close:unit -> unit Lwt.t; ... }`; `new_server : Server.handler -> server Lwt.t`; `client : server -> Client.t`. TLS variant returns `https://…` and an insecure-trusting client.

**E) Testing Plan** *Integration* (`test/test_httptest_server.ml`, from `httptest_test.go`/`server_test.go`): `server_get` (handler echoes path → client GET asserts body/status), `server_tls` (https round trip via the server's client), `server_close` (after close, a connect fails/times out). Bounded by `Net.with_timeout`.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate; no leaked listeners.

**G) Execution Record**

- **Baseline:** `jj st` clean (`@` empty, parent `7c450943`); `dune build && dune test` green at **468** tests.
- **Files modified:**
  - `lib/httptest.ml` — added the `Server` submodule (Go `httptest.Server`, loopback path). `type server = { url; port; tls; srv : Server.t; serve : unit Lwt.t; close : unit -> unit Lwt.t }`. `new_server` (Go `NewServer`): binds `127.0.0.1:0` via `Server.listen_and_serve_started`, drives the serve loop in the background with `Lwt.async` (Go's `goServe`), `url = "http://127.0.0.1:PORT"`. `new_tls_server` (Go `NewTLSServer`): same over `Server.listen_and_serve_tls_started` with `Net.test_server_certificate` (Go `testcert.LocalhostCert`), `url = "https://127.0.0.1:PORT"`. `client` (Go `Server.Client`): TLS server → `Client.create ~insecure:true ()` (the faithful analogue of Go pre-loading the self-signed cert into the client's `RootCAs`), HTTP server → `Client.create ()`. `close` (Go `Server.Close`) → `Server.close srv`. Accessors `url`/`port`.
  - `lib/httptest.mli` — **updated**: documented the new `Server : sig … end` submodule (`type server`, `url`, `port`, `new_server`, `new_tls_server`, `client`, `close`) and broadened the module-header comment to cover both halves.
  - `test/test_gohttp.ml` — wired `("HttptestServer", Test_httptest_server.tests)`.
- **Files created:**
  - `test/test_httptest_server.ml` (`val tests`, 3 cases ported from `server_test.go`/`httptest_test.go`, each `Lwt_main.run` bounded by `Net.with_timeout`, server closed via `Lwt.finalize`/explicit `close`):
    - `server_get` (Go `TestServer`): handler writes `Uri.path req.url`; `Httptest.Server.client` GET `<url>/foo` → 200 + body `"/foo"`.
    - `server_tls` (Go `testServerClient`): `new_tls_server` + its `client` → https round trip, asserts URL is `https://`, status 200, body `"hello"`.
    - `server_close` (Go `Server.Close` semantics): serve a 200 first (sanity), `close`, then a fresh `Net.connect` to the captured port must raise (connection refused), bounded by the timeout.
- **Evidence:** `dune build` clean; `dune test` green — **471** tests (468 baseline + 3 HttptestServer). `dune exec test/test_gohttp.exe -- test HttptestServer` → 3/3 OK in 0.111s (terminates; no leaked listeners — each server `close`d). Full run 1.849s.
- **API adaptation / omissions noted:** `new_unstarted` + `Start`/`StartTLS` **omitted** — gohttp's `Server.listen_and_serve_started` binds and serves in one step, so the unstarted/started split is not useful here (noted in the `.mli`). Go's in-memory "fakenet" network (`NewTestServer`) is out of scope; only the loopback path is ported. `Server.Client` trust is modeled as `~insecure:true` rather than a pinned `RootCAs` cert pool, because `Net`'s TLS surface exposes the documented insecure opt-out (`null_authenticator`) as the analogue of Go's per-cert trust for the self-signed test certificate.

**Status: Done.** Commit: see below.

### Ticket 3 — fs core: FileSystem/Dir/File, ServeContent (no ranges), ServeFile, FileServer, dir listing
Status: Done

**A) Scope** Port the `fs.go` core: `file_system`/`file` interfaces; `Dir` (a root dir, with dot-dot/traversal rejection); `serve_content` WITHOUT range handling yet (full-body stream + Content-Type (ext table → `Sniff` fallback) + `Last-Modified` via `Http_time` + `Accept-Ranges: bytes`); `serve_file`/`serve_file_fs`; `file_server : file_system -> Server.handler` (clean path, dir → `index.html` or `dir_list`, file → `serve_content`); `dir_list` (HTML listing, escaped); `to_http_error`; `local_redirect`.

**B) Migration Strategy** Additive `fs.ml`. Files read/streamed via `Lwt_unix` in bounded windows (compose with `Body.Stream`). Conditional/range logic stubbed to "serve full 200" until Tickets 4–5 (so this ticket ships a working FileServer).

**C) Exit State** A `FileServer` over a temp dir serves files (200 + content + Content-Type + Last-Modified + Accept-Ranges), lists directories, redirects `dir`→`dir/`, 404s missing/`..` paths. Build + tests green.

**D) Detailed Design** `type file_system = { open_ : string -> file Lwt.t }`; `type file = { read_window : off:int64 -> len:int -> string Lwt.t; size:int64; modtime:float; is_dir:bool; readdir:unit -> dirent list Lwt.t; close:unit -> unit Lwt.t }` (shape may vary; mirror `http.File`). `serve_content` streams the whole file as `Body.Stream`. `file_server` returns a `Server.handler`.

**E) Testing Plan** *Integration* (`test/test_fs.ml`, via `Httptest.Server` + `Client`, from `fs_test.go`): serve a known file (200 + bytes + Content-Type), directory listing contains entries, `..` traversal → 404, missing → 404, `dir`→`dir/` redirect (301). Bounded; temp dir created + removed.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate; temp dirs cleaned.

**G) Execution Record**

- **Baseline:** `jj st` clean (`@` empty `7f5238a4`, parent `5f3245bb` Ticket 2); `dune build && dune test` green at **471** tests.
- **Files created:**
  - `lib/fs.ml` + `lib/fs.mli` — port of the `fs.go` core.
    - `type file_info = { fi_name; fi_size:int64; fi_mod_time:float; fi_is_dir }` (Go `fs.FileInfo` subset). `type file = { stat; read_window:(off:int64 -> len:int -> string Lwt.t); readdir; close }` (Go `http.File` — `read_window` models seek+read; for THIS ticket only `off:0L` windows are used since no ranges). `type file_system = { open_ : string -> (file, exn) result Lwt.t }` (Go `FileSystem.Open`).
    - `dir : string -> file_system` (Go `Dir`): `path.Clean("/"+name)[1:]` via `Pattern.path_clean`, empty→".", rejects residual ".." via `contains_dot_dot` → `Invalid_unsafe_path` (Go `filepath.Localize`/`errInvalidUnsafePath`), `Filename.concat root path`, then `Lwt_unix.stat` + (dir) `opendir/readdir/closedir` per-entry-stat listing or (file) `openfile O_RDONLY` with a seek+read `read_window`. OS errors mapped: `ENOENT`/`ENOTDIR` → `Not_found`, `EACCES`/`EPERM` → the raw Unix error (→403), else 500.
    - `serve_content` (Go `serveContent`, full-200 path): `set_last_modified` (`Http_time.format_gmt`, skipped for zero/epoch modtime), `check_preconditions` (stub), Content-Type via the extension table → `Sniff.detect_content_type` on a ≤512-byte probe when unset (handler-set CT respected), `Accept-Ranges: bytes`, Content-Length (unless Content-Encoding set), `write_header 200`, then streams the whole file in 32 KiB windows (skipped for HEAD).
    - `serve_file` (Go `serveFile`): `.../index.html`→`./` redirect; with `redirect:true` dir-without-slash→`base/`, file-with-slash→`../base` (or 500 "traverse a non-directory" for `/`/`.`); directory serves `index.html` if present else `dir_list` (with `Last-Modified`); regular file → `serve_content`. Open/stat errors via `to_http_error`. Files closed via `Lwt.finalize`.
    - `file_server : file_system -> Server.handler` (Go `FileServer`/`fileHandler.ServeHTTP`): slash-prefixes + (via `Uri.with_path`) updates `r.url`, `path.Clean`s, dispatches `serve_file ~redirect:true`.
    - `dir_list` (Go `dirList`): sorts entries by name, `Content-Type: text/html; charset=utf-8`, `<!doctype html>` + viewport `<meta>` + `<pre>` with one `<a href="...">name</a>` per entry; href percent-escaped via `Uri.pct_encode ~component:`Path`, link text via a local `html_escape` (Go `htmlReplacer`); 500 "Error reading directory" on readdir failure.
    - `to_http_error` (Go `toHTTPError`): `Not_found`/`Invalid_unsafe_path` → 404 "404 page not found"; permission → 403 "403 Forbidden"; else 500.
    - `local_redirect` (Go `localRedirect`): 301 + `Location` with the raw query (`Uri.verbatim_query`) preserved, no absolutization.
    - `contains_dot_dot` (Go `containsDotDot`/`isSlashRune`), `check_preconditions` (Ticket-3 stub).
- **Files modified:**
  - `test/test_gohttp.ml` — wired `("Fs", Test_fs.tests)`.
  - `test/test_fs.ml` (created; `val tests`, 5 cases ported from `fs_test.go`, each `Lwt_main.run` bounded by `Net.with_timeout 10.`, served via `Httptest.Server` over a unique temp dir under `Filename.get_temp_dir_name ()`, removed in `Lwt.finalize` via `rm_rf`): `serve_known_file` (GET → 200 + exact bytes + `Content-Type: text/plain; charset=utf-8` + `Last-Modified` present + `Accept-Ranges: bytes`); `dir_listing` (GET `/` → 200, `text/html; charset=utf-8`, body lists `alpha.txt`/`beta.txt`); `traversal_blocked` (`/../../../../etc/passwd` → 404, never escapes the root); `missing_file` (→ 404); `dir_redirect` (`/sub` via `Transport.round_trip` to observe the raw 301 → 301 + `Location: sub/`).
- **What is stubbed for Tickets 4/5 (with hooks):**
  - **Ticket 4 (preconditions):** `check_preconditions w r ~modtime` returns `(false, <raw Range header>)` — never short-circuits to 304/412. Hook comments mark the `check_preconditions` body and the `if done_` branch in `serve_content`. `serve_file` does NOT yet apply the directory `If-Modified-Since`→304 (Go's `checkIfModifiedSince` on `d.ModTime()`); it always lists. Ticket 4 fills in `checkIfMatch`/`checkIfUnmodifiedSince`/`checkIfNoneMatch`/`checkIfModifiedSince`/`scanETag` + `writeNotModified`.
  - **Ticket 5 (ranges):** `serve_content` always sends a full 200; the parsed `_range_req` is unused. A `TICKET 5 HOOK` comment marks where to parse it and switch to 206 (single / `multipart/byteranges`) / 416 with `Content-Range`. `read_window` already supports seeking (`off`) so the range window slots in without an interface change.
- **Evidence:** `dune build` clean; `dune test` green — **476** tests (471 baseline + 5 Fs). `dune exec test/test_gohttp.exe -- test Fs` → 5/5 OK in 0.005s (terminates). No leaked temp dirs (`/tmp/gohttp_fs_*` empty after the run). Full run 1.809s.
- **Omissions / stand-ins noted:** `mime_by_ext` is a small built-in extension→MIME table (`.html .htm .css .js .mjs .json .png .jpg .jpeg .gif .svg .txt .xml .pdf .wasm .ico .woff .woff2`) — a deliberate stand-in for Go's `mime.TypeByExtension` (the `mime` package is not ported); everything else falls back to `Sniff.detect_content_type`. `ServeFile`/`ServeFileFS`/`FileServerFS`/`FS(fs.FS)` (the `io/fs` adapter and the top-level free functions over `Dir(dir)`) are out of scope here — the ticket targets `Dir` + `FileServer`; `serve_file` is exposed directly. `mapOpenError`'s non-directory-parent walk is reduced to the direct `ENOTDIR`→`Not_found` mapping (same observable 404). The `httpservecontentkeepheaders` GODEBUG / `serveError` header-stripping is reduced to `Server.error` (the headers it would strip are not set on this ticket's success path before an error). Directory `Last-Modified` is set before `dir_list` (Go does too) but the directory `If-Modified-Since` check is deferred to Ticket 4.

**Status: Done.** Commit: see below.

### Ticket 4 — fs conditional requests (preconditions + ETag + time headers)
Status: Planned

**A) Scope** Port `checkPreconditions`, `scanETag`, and the precondition headers: `If-Match`, `If-Unmodified-Since`, `If-None-Match`, `If-Modified-Since`, returning **304 Not Modified** / **412 Precondition Failed** per RFC 7232 + Go's exact precedence. Wire into `serve_content`. Emit `ETag` if the handler set one (Go doesn't auto-generate ETags; honor a handler-set ETag).

**B) Migration Strategy** Extends `serve_content` from Ticket 3; the stubbed "serve full 200" becomes precondition-aware. Uses `Http_time.parse_http_time`.

**C) Exit State** Conditional GETs behave per Go: `If-None-Match`/`If-Modified-Since` matching → 304 (no body); `If-Match`/`If-Unmodified-Since` failing → 412. Build + tests green.

**D) Detailed Design** Port `checkPreconditions` returning `(done, range_header)`; `scanETag`/`etagStrongMatch`/`etagWeakMatch`. 304 responses omit body + Content-Length per Go (`writeNotModified`).

**E) Testing Plan** *Integration* (`test/test_fs_conditional.ml`, from `fs_test.go`): `If-Modified-Since` ≥ modtime → 304; `If-None-Match: <etag>` match → 304; `If-Match` mismatch → 412; `If-Unmodified-Since` older → 412. Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record** _(tbd)_

### Ticket 5 — fs range requests (single + multipart/byteranges + If-Range)
Status: Planned

**A) Scope** Port `parseRange`, `httpRange` (`contentRange`/`mimeHeader`), `If-Range`, and range serving in `serve_content`: a single satisfiable range → **206** + `Content-Range` + that window (streamed); multiple ranges → **206** `multipart/byteranges` with a boundary and per-part `Content-Range`/`Content-Type`; unsatisfiable → **416** + `Content-Range: bytes */size`; `If-Range` (ETag or date) gates whether the range applies (else full 200). `Accept-Ranges: bytes` already set.

**B) Migration Strategy** Final extension of `serve_content`. Range windows read via the `file` seek+read window as a `Body.Stream`; multipart parts generated incrementally.

**C) Exit State** Range GETs return 206 + exact bytes (`Fs.serve_file_range` Success Criterion); multi-range returns multipart/byteranges; bad range → 416; `If-Range` honored. Build + tests green.

**D) Detailed Design** Port `parseRange` (RFC 7233 grammar incl. suffix ranges `-N`), `errNoOverlap`/416, `httpRange.contentRange`, the `multipart/byteranges` writer (boundary + part headers + bodies + closing boundary), `sumRangesSize`/`rangesMIMESize` for Content-Length when computable.

**E) Testing Plan** *Integration* (`test/test_fs_range.ml`, from `fs_test.go` range table): single `bytes=N-M` → 206 + `Content-Range` + bytes; suffix `bytes=-N`; multi `bytes=a-b,c-d` → multipart/byteranges (assert parts); unsatisfiable → 416; `If-Range` mismatch → full 200. Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record** _(tbd)_
