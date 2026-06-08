## What this is

`httpg` is a **faithful 1:1 OCaml port of Go's `net/http`** — HTTP/1.0, HTTP/1.1, and HTTP/2 (over TLS via ALPN), server and client. The Go source is vendored read-only at **`go/src/net/http/`** (a git submodule) and is the **spec of record**: every `lib/` module corresponds to a Go source file and is meant to match its types, function names, and behavior. HPACK lives at `go/src/vendor/golang.org/x/net/http2/hpack/`; HTTP/2 at `go/src/net/http/internal/http2/`.

## Non-negotiable conventions (read before editing)

- **Every `lib/` module has a hand-written `.mli`.** New modules must add one. Keep it in sync on every change.
- **Mirror Go's data structures, not just behavior.** Go `map[K]V` → OCaml `Hashtbl` by default (not assoc lists), Go slices → lists/arrays as fits. **Exception (deliberate deviation):** the public `Header.t` is a **persistent `Map`** with a functional API (`add`/`set`/`del : t -> … -> t`), so a value can be shared/forked freely — this is what lets `Response` be an immutable builder and handlers be `Request -> Response`. Code that mutated a header in place now threads the returned value (record fields do `r.header <- Header.set r.header …`; `Transfer.read_transfer` returns the post-framing header in its `result`). The HTTP/2 `Api.Header` stays a mutable `Hashtbl` (decoupled); the ALPN shims convert at the boundary.
- **Port Go's tests too, and treat them as the spec.** Each `test/test_<x>.ml` is ported from the matching `go/src/net/http/<x>_test.go`. **When a ported test fails, fix the implementation, not the test** — unless the failure is a genuine Go-specific porting artifact, which must be called out explicitly.
- **Stream where Go streams.** Bodies are not buffered whole; reads/writes happen in bounded windows. Don't reintroduce whole-body `read_all` on hot paths.
- **`Result.t` for everything handleable; exceptions only for the unhandleable.** A handleable error is anything a caller could reasonably recover from, branch on, or translate (parse failures, protocol violations, validation, not-found, IO errors) → return `('a, error) result` with **typed error variants per module**, not strings. The unhandleable — programming bugs and invariant violations (`invalid_arg`, `assert false`, "can't happen", writer-after-close) — stays `raise`. This lines up with Go's own split (`(T, error)` for handleable, `panic` for bugs). On IO paths, internals may still raise, but the **public boundary** catches modeled failures and converts them to `(_, error) result`, re-raising anything not modeled (bugs, `Eio.Cancel`). The dividing line is handleable-vs-unhandleable, not pure-vs-effectful.
- Cross-reference the matching `go/src/net/http/*.go` file (with line refs) when porting or fixing.

## Commands

```sh
dune build                                   # build (warnings are errors)
dune test                                    # run the suite, fast (skips `Slow tests; alias: dune runtest)
HTTPG_SLOW=1 dune test                       # include the slow stress/timeout tests too
dune exec test/test_httpg.exe -- test Header # run ONE suite (suite names below)
dune exec test/test_httpg.exe -- test Header 3 # run one case within a suite
dune exec httpg                             # run the demo (h1 + streaming + h2-over-TLS round trips)
opam install . --deps-only --with-test       # install deps into the switch
```

Tests are a single alcotest runner (`test/test_httpg.ml`) that aggregates one suite per module (`Header`, `Cookie`, `Transfer`, `Hpack`, `H2Frame`, `Fs`, `Httptest`, …). Eio-based tests run under `Eio_main.run` and are bounded by `Net.with_timeout` (an `Eio.Time` deadline) so a hang fails instead of blocking. A handful of slow stress/timeout tests are tagged `` `Slow `` (alcotest speed level) and skipped by default; `Test_harness.run_slow` (set by `HTTPG_SLOW=1`) feeds alcotest's `~quick_only` to include them. Tag new high-iteration or real-clock-wait tests `` `Slow `` rather than letting them bloat the default run.

## Architecture

**Concurrency model:** written **directly against Eio** in direct style (no monad/IO-functor abstraction). `Eio.Buf_read.t`/`Eio.Buf_write.t` are the analogue of Go's `bufio.Reader`/`Writer`; `Eio.Net` for sockets; TLS is hand-driven over the sans-io `Tls.Engine` state machine (no `tls-eio`). Capabilities (`net`, `clock`, optional `domain_mgr`) are captured at construction and threaded via `Eio.Switch`; cancellation rides switch teardown (`Eio.Cancel`) rather than a context value. Go's goroutines + channels + `sync.Cond` map to Eio fibers + `Eio.Condition`/`Eio.Stream`/`Eio.Mutex` (most visible in `h2_server.ml`/`h2_transport.ml`, which use a single per-connection event-loop fiber). The accept loop can fan out across OS cores via an `Eio.Domain_manager` (one accept loop per domain on the shared listening socket).

**Four libraries** (mirroring Go's package layout below/within `net/http`):
- `lib/base/` → `httpg_base`, the **foundation layer** below net/http: ports of the Go stdlib packages `net/http` and `internal/http2` both depend on — currently `Textproto` (`textproto.CanonicalMIMEHeaderKey`). Re-exported publicly. Not "internal" — it sits beneath net/http. (Go's `context` is not ported: under Eio, deadlines/cancellation ride `Eio.Switch`/`Eio.Time` instead.)
- `lib/internal/` → the private `httpg_internal` library: **the home for everything that is not part of `httpg`'s public API.** That is (a) ports of the *loose files* of Go's `net/http/internal` — `Chunked`, `Ascii`, `Common` (sentinel errors), `Sniff` (`internal/sniff.go`; the public `Httpg.Sniff` is a wrapper), `Httpcommon` (`internal/httpcommon`; the h1/h2-shared request/header encoding) — and (b) modules that live in Go's `net/http` package but are kept **unexported** there, so they shouldn't be exported here either: the routing internals `Pattern` (`pattern.go`), `Routing_tree` (`routingNode`), `Mapping` (`mapping.go`). Consumers in `lib/` reach them via `Httpg_internal.Pattern` (etc.), usually behind a local module alias; they never appear under `Httpg.*`. The rule is **"hidden from the public API," not "Go package == `net/http/internal`."** A module that Go *exports* (e.g. `http.TimeFormat`/`ParseTime` → `Http_time`, `url.Values` → `Values`, `http.DetectContentType` → `Sniff` wrapper) stays public in `lib/`.
- `lib/internal/http2/` → the private `httpg_http2` library, mirroring Go's `net/http/internal/http2` subdirectory: the whole HTTP/2 stack (`Hpack*`, `H2`, `H2_frame`, `H2_flow`, `H2_pipe`, `H2_databuffer`, `H2_error`, `H2_writesched`, `H2_write`, `H2_server`, `H2_transport`) plus `Api` (Go's `api.go` decoupled types). It depends on `httpg_base`/`httpg_internal` but **never names** the public `Request`/`Response`/`Body`/`Header`/`Status` types.
- `lib/` → the public `httpg` library. Flat modules, accessed as `Httpg.Header`, `Httpg.Server`, etc. It contains the **h1/h2 translation shims** (Go's `http2.go`): `Transport`/`Server` convert `Request.t`/`Response.t` ⇄ the `Httpg_http2.Api` types at the ALPN boundary.

**Layering (bottom-up; this order avoids OCaml module cycles):**
1. Pure data: `method`, `status`, `header`, `cookie`, `sniff`, `http_time`; URLs use the `uri` opam lib (`Uri.t`), not a `net/url` port; `values` ports `url.Values`.
2. Framing: `transfer` (content-length/chunked), `body`, `httpg_internal/chunked`.
3. Message read/write: `request`, `response` (records with a **parametric `'body` field**), `io` (read/write over `Eio.Buf_read`/`Eio.Buf_write`).
4. Net: `net` (TCP listen/accept/connect, server-side TLS + ALPN; client TLS verifies via `ca-certs` by default, with a `?insecure` opt-out).
5. Endpoints: `server` (Handler/ServeMux), `client`, `transport` (keep-alive pool). **Handlers are axum-style** (deliberate deviation from Go's `ServeHTTP(ResponseWriter, *Request)`): `handler = sw:Eio.Switch.t -> Body.t Request.t -> Body.t Response.t` — build an immutable `Response` (the `Response.create () |> with_status … |> with_body …` builder) and return it; the serve loop flushes it. Streaming is a `Body.Stream` body the loop pulls and flushes per chunk (so incremental delivery is preserved); the framing is chosen from the body shape, honoring a declared `content_length` for known-length streams (file ranges). `~sw` is the request switch — a handler streaming from an opened resource (the file server's fd) opens it under `~sw`, released once the response is sent.
6. HTTP/2: the whole stack lives in the private **`httpg_http2`** library (`lib/internal/http2/`), mirroring Go's `net/http/internal/http2`. Like Go's package it is **decoupled** from net/http: it works in `Httpg_http2.Api` types (`api.go` — `client_request`/`server_request`/`client_response`/`response_writer`, `Header = Hashtbl`, an `io.ReadCloser`-shaped `Body`) and never names `Request`/`Response`/`Body`/`Header`/`Status`. The public `Server`/`Transport` hold the **translation shims** (Go's `http2.go`: `http2RoundTrip` / `http2Handler.ServeHTTP`) that convert `Request.t`/`Response.t` ⇄ `Api` at the ALPN boundary, with h1 fallback. (`Status.status_text` for a response is applied by the client shim, as in Go.)

**Bodies & lifecycle:** `Body.t = Empty | String of string | Stream of (unit -> string option)`. Read paths return a `Stream`; the connection is reused only after the body reaches EOF / `Body.drain`. There is no `?context` parameter (Go's `context` is dropped in this port): per-request cancellation is expressed via the caller's `~sw`, and `Client`'s overall `?timeout` is enforced as an `Eio.Time` deadline (`Net.with_timeout`) when a `clock` was captured.

**Testing helpers:** `Httptest.Server` (ephemeral loopback server, http + TLS, with a preconfigured client) — used by `fs` and server/client tests as Go uses `net/http/httptest`. (Go's `ResponseRecorder` is dropped: with `Request -> Response` handlers a handler is tested by calling it directly and inspecting the returned `Response.t`.)

## Working style in this repo

Substantial features are built via **ticketed plan files** in `plans/*.plan.md` (problem → discovery → target shape → tickets). Work proceeds **one ticket at a time, one `jj commit` per ticket**, each leaving the build green with ported tests and an updated execution record in the plan. Completed plans are removed (their records persist in git history); the active plan stays under `plans/`.

## Deliberate stand-ins (affect current behavior)

- Multipart parsing uses the sans-io `multipart_form` opam lib (Go hand-rolls `mime/multipart`); `max_memory` is accepted but not enforced.
- MIME-by-extension in `fs` is a small built-in table + `Sniff` fallback (no `mime` package port).
- TLS client verifies certs by default (`ca-certs`); use `~insecure` for self-signed (e.g. the test server).
- **h2c (HTTP/2 cleartext) is a deliberate deviation, not a port:** Go's `net/http` has no h2c (it lives in `golang.org/x/net/http2/h2c`, outside the vendored spec). We support only the **prior-knowledge** form (RFC 9113 §3.3), not the HTTP/1.1 `Upgrade: h2c` dance. Server: `Server.create`/`listen_and_serve`/`_started ?force_h2:true` makes a *plaintext* listener hand each connection straight to `H2_server.serve` (which reads/validates the client preface itself) — no ALPN, no `Upgrade:`. Client: `Client.get`/`head`/`post`/`do_`/`do_one ?force_h2:true` (and `Transport.round_trip ?force_h2`) speak h2c over an `http://` URL. The flag is a no-op over TLS, where ALPN selects the protocol.

Remaining gaps and explicit non-goals (HTTP/3, proxies, cookie jar, server push, …) are tracked in **`TODO.md`**.

## VCS

IMPORTANT: this repo may use either only git or git w/ jj colocation. If the root repo has a .jj file please use jj. otherwise assume it's a git repo.
