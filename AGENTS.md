## What this is

`gohttp` is a **faithful 1:1 OCaml port of Go's `net/http`** — HTTP/1.0, HTTP/1.1, and HTTP/2 (over TLS via ALPN), server and client. The Go source is vendored read-only at **`go/src/net/http/`** (a git submodule) and is the **spec of record**: every `lib/` module corresponds to a Go source file and is meant to match its types, function names, and behavior. HPACK lives at `go/src/vendor/golang.org/x/net/http2/hpack/`; HTTP/2 at `go/src/net/http/internal/http2/`.

## Non-negotiable conventions (read before editing)

- **Every `lib/` module has a hand-written `.mli`.** New modules must add one. Keep it in sync on every change.
- **Mirror Go's data structures, not just behavior.** Go `map[K]V` → OCaml `Hashtbl` (e.g. `Header.t = (string, string list) Hashtbl.t`), not assoc lists or `Map.Make`. Go slices → lists/arrays as fits.
- **Port Go's tests too, and treat them as the spec.** Each `test/test_<x>.ml` is ported from the matching `go/src/net/http/<x>_test.go`. **When a ported test fails, fix the implementation, not the test** — unless the failure is a genuine Go-specific porting artifact, which must be called out explicitly.
- **Stream where Go streams.** Bodies are not buffered whole; reads/writes happen in bounded windows. Don't reintroduce whole-body `read_all` on hot paths.
- **`Result.t` for everything handleable; exceptions only for the unhandleable.** A handleable error is anything a caller could reasonably recover from, branch on, or translate (parse failures, protocol violations, validation, not-found, IO errors) → return `('a, error) result` with **typed error variants per module**, not strings. The unhandleable — programming bugs and invariant violations (`invalid_arg`, `assert false`, "can't happen", writer-after-close) — stays `raise`. This lines up with Go's own split (`(T, error)` for handleable, `panic` for bugs). On Lwt/IO paths, internals may still fail the promise, but the **public boundary** does one `Lwt.catch` and converts modeled failures to `(_, error) result Lwt.t`, re-raising anything not modeled (bugs, cancellation). The dividing line is handleable-vs-unhandleable, not pure-vs-Lwt.
- Cross-reference the matching `go/src/net/http/*.go` file (with line refs) when porting or fixing.

## Commands

```sh
dune build                                   # build (warnings are errors)
dune test                                    # run the full alcotest suite (alias: dune runtest)
dune exec test/test_gohttp.exe -- test Header # run ONE suite (suite names below)
dune exec test/test_gohttp.exe -- test Header 3 # run one case within a suite
dune exec gohttp                             # run the demo (h1 + streaming + h2-over-TLS round trips)
opam install . --deps-only --with-test       # install deps into the switch
```

Tests are a single alcotest runner (`test/test_gohttp.ml`) that aggregates one suite per module (`Header`, `Cookie`, `Transfer`, `Hpack`, `H2Frame`, `Fs`, `Httptest`, …). Lwt-based tests run via `Lwt_main.run` and are bounded by `Net.with_timeout` so a hang fails instead of blocking.

## Architecture

**Concurrency model:** written **directly against Lwt** (no monad/IO-functor abstraction). `Lwt_io` channels are the analogue of Go's `bufio.Reader`/`Writer`; `Lwt_unix` for sockets; `tls-lwt` for TLS. Go's goroutines + channels + `sync.Cond` map to Lwt fibers + `Lwt_condition`/`Lwt_mvar`/`Lwt_mutex` (most visible in `h2_server.ml`/`h2_transport.ml`, which use a single per-connection event-loop fiber).

**Two libraries:**
- `lib/` → the public `gohttp` library. Flat modules, accessed as `Gohttp.Header`, `Gohttp.Server`, etc.
- `lib/internal/` → the private `gohttp_internal` library (no `public_name`, access-restricted), mirroring Go's `net/http/internal`: `Chunked` (chunked codec) and `Ascii` (ASCII helpers).

**Layering (bottom-up; this order avoids OCaml module cycles):**
1. Pure data: `method`, `status`, `header`, `cookie`, `sniff`, `http_time`; URLs use the `uri` opam lib (`Uri.t`), not a `net/url` port; `values` ports `url.Values`.
2. Framing: `transfer` (content-length/chunked), `body`, `gohttp_internal/chunked`.
3. Message read/write: `request`, `response` (records with a **parametric `'body` field**), `io` (read/write over `Lwt_io`).
4. Net: `net` (TCP listen/accept/connect, server-side TLS + ALPN; client TLS verifies via `ca-certs` by default, with a `?insecure` opt-out).
5. Endpoints: `server` (Handler/ServeMux/ResponseWriter), `client`, `transport` (keep-alive pool).
6. HTTP/2: `hpack*`, `h2`, `h2_frame`, `h2_flow`, `h2_*`, `h2_server`, `h2_transport` live in the **same `gohttp` library** (as Go bundles `internal/http2` into `net/http`). To avoid cycles, the `H2_*` modules take the handler / round-trip pieces as parameters — `Server`/`Client` depend on `H2_*`, never the reverse. `Server.listen_and_serve_tls` / `Transport` pick HTTP/2 vs HTTP/1.x by the negotiated ALPN protocol, with h1 fallback.

**Bodies & lifecycle:** `Body.t = Empty | String of string | Stream of (unit -> string option Lwt.t)`. Read paths return a `Stream`; the connection is reused only after the body reaches EOF / `Body.drain`. `?context` (`Context.t`, an Lwt-backed port of Go's `context`, deadline/cancel only — no Values) threads through `Client`/`Transport` to bound/cancel requests.

**Testing helpers:** `Httptest.Response_recorder` (in-memory `ResponseWriter` for unit-testing handlers) and `Httptest.Server` (ephemeral loopback server, http + TLS, with a preconfigured client) — used by `fs` and server/client tests exactly as Go uses `net/http/httptest`.

## Working style in this repo

Substantial features are built via **ticketed plan files** in `plans/*.plan.md` (problem → discovery → target shape → tickets). Work proceeds **one ticket at a time, one `jj commit` per ticket**, each leaving the build green with ported tests and an updated execution record in the plan. Completed plans are removed (their records persist in git history); the active plan stays under `plans/`.

## Deliberate stand-ins (affect current behavior)

- Multipart parsing uses the `multipart_form-lwt` opam lib (Go hand-rolls `mime/multipart`); `max_memory` is accepted but not enforced.
- MIME-by-extension in `fs` is a small built-in table + `Sniff` fallback (no `mime` package port).
- TLS client verifies certs by default (`ca-certs`); use `~insecure` for self-signed (e.g. the test server).

Remaining gaps and explicit non-goals (HTTP/3, proxies, cookie jar, server push, …) are tracked in **`TODO.md`**.
