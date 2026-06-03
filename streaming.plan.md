# gohttp — First-class streaming bodies — Plan

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

- **Goal:** Make HTTP message bodies **stream first-class** rather than buffering them fully in memory — both **reading** (server request bodies, client response bodies are consumed incrementally) and **writing** (server responses, client request bodies are emitted incrementally, chunked when length is unknown). Match Go's `io.ReadCloser` body model, including the body lifecycle (drain/close) that keep-alive reuse depends on. HTTP/1.1 and HTTP/2.
- **SCOPING PRINCIPLE — only stream where Go streams.** Go does NOT stream everything; faithfully mirror where it buffers vs. streams:
  - **Reads** (server req body, client resp body): Go streams (`Body io.ReadCloser`, read on demand). → we stream.
  - **Server response writes:** Go buffers into a `bufio.Writer` of `bufferBeforeChunkingSize = 2048` bytes (`server.go:342,1096`); the framing decision (`chunkWriter.writeHeader`, `server.go:1284`) fires on first flush = buffer > 2048 **or** handler returns **or** `Flush()`. If the handler finishes with ≤2048 buffered and set no `Content-Length`, Go sets an **exact Content-Length** and does NOT chunk (`server.go:1353`). It switches to **chunked** (HTTP/1.1) only when the body exceeds 2048 / `Flush` is called / the handler is still running; HTTP/1.0 unknown-length → close at EOF. → we replicate this 2048-buffer-then-chunk model exactly; small responses stay buffered with Content-Length.
  - **Request writes (client):** Content-Length from `Request.content_length` when known, else chunked for a streaming body (`transfer.go`). → as today.
- **Success Criteria (as tests):**
  - *Integration:* `Stream.server_streams_unbuffered` — a handler that writes N chunks with `Flush` between them produces a chunked HTTP/1.1 response the client receives incrementally (assert chunks arrive before the handler finishes / total body equals the concatenation), with **no full-body buffer** on the server.
  - *Integration:* `Stream.client_body_streamed` — `Client.get` against a large (e.g. multi-MB) response returns a `Body.Stream` the caller drains chunk-by-chunk; assert the body is not pre-materialized (e.g. first chunk is readable before EOF) and the connection is reused only after the body is drained/closed.
  - *Unit:* existing 434 tests stay green (bodies set as `String`/`Empty` still work; tests reading bodies use `Body.read_all`).
- **Non-Goals:** Changing the `Body` variant shape beyond what streaming needs; backpressure tuning; removing the `String`/`Empty` conveniences; HTTP/3.
- **Constraints:** OCaml ≥ 5.0. No new deps expected. **When a ported test fails, fix the implementation, not the test** (unless adapting to the new streaming API — those test changes ARE legitimate and must be called out). Every `lib/` module keeps a `.mli`. Mirror Go's `io.ReadCloser` lifecycle. Cross-reference `go/src/net/http` (`transfer.go`, `server.go`, `transport.go`, `internal/http2/*`).

## Discovery

- **Body already supports streaming:** `Body.t = Empty | String of string | Stream of (unit -> string option Lwt.t)` (`body.mli`), with `read_all`/`write`. The plumbing materializes it away.
- **Buffering points (the spec for this work):**
  - `io.ml:116` `materialize_body` — `Body.read_all` → `Body.String`; called by `read_response` (`:208`, `:291`) and `read_request` (`:393`). `Transfer.read_transfer` already yields a streaming reader (`transfer.mli:107` `result`, chunked via `new_chunked_reader`), so the source is already incremental — we stop collapsing it.
  - `server.ml:368–451` `serve_one` — buffers all `write`s into a `Buffer`, sets Content-Length post-hoc, writes once. `response_writer` (`server.ml:49`) has no `flush`.
  - `client.ml`/`transport.ml` — rely on `Io.read_response` materializing; conn reuse assumes a fully-read body (`client.ml:104,150`).
  - HTTP/2: `h2_server.ml` builds request body via `H2_pipe` (streaming) and frames DATA on `write`; `h2_transport.ml` response body via pipe — already close to streaming; needs alignment with the Body lifecycle, not a rewrite.
- **Critical contracts:** `Body.t`; `Io.read_request`/`read_response`/`write_request`/`write_response`; `Server.response_writer`/`handler`; `Transfer.read_transfer`/`write_body`/chunked writer; keep-alive reuse in `server.ml` serve loop and `transport.ml` pool.
- **Migration pressure points:** (1) **Keep-alive + streaming** — a connection can't be reused until the body is drained; need explicit drain on the server (before next request) and a close/drain on the client response. (2) **Chunked trailers** are read *after* the body stream hits EOF — must fire on stream end and populate the (mutable) trailer. (3) **Content sniffing** (`Sniff.detect_content_type`) needs the first ≤512 bytes — keep a *small* sniff buffer, not a whole-body buffer. (4) Tests/asserts that pattern-match `Body.String` must switch to `Body.read_all`.
- **Areas of uncertainty:** how much h2 already streams end-to-end vs. materializes at the pipe boundary; whether `?context` cancellation cleanly aborts a mid-stream read; trailer-on-EOF wiring through the returned body.

## Target Shape

- **Body lifecycle:** add a close/drain notion (e.g. `Body.drain : t -> unit Lwt.t` to consume-and-discard; optionally a `close` hook on streams for resource release). `Stream` readers obtained from a connection carry an on-EOF action (read trailer / mark connection drained).
- **Reading (server req / client resp):** `Io.read_request`/`read_response` return the body **as a `Stream`** wrapping `Transfer.read_transfer`'s reader — no materialization. On EOF the stream reads chunked trailers into the message's (mutable) `trailer` and marks the underlying connection drained/reusable. `Body.read_all` remains for callers who want it all.
- **Writing (server resp):** `serve_one`'s `response_writer` streams: first `write` triggers implicit `WriteHeader 200` + (small-buffer) content sniff + header flush deciding framing — **Content-Length** if set by the handler before the first write, else **chunked** (HTTP/1.1) / connection-close (HTTP/1.0); subsequent writes stream directly (chunked-encode or raw) and `flush` pushes bytes. Add `flush` to `response_writer`.
- **Client:** `Client`/`Transport` return a streaming `Response.body`; the connection returns to the pool only after the body is drained/closed (`Body.drain`/close). `?context` cancellation aborts an in-flight body read.
- **HTTP/2:** the h2 `response_writer` already frames DATA per write (flow-controlled) — confirm no hidden full buffer and expose `flush`; h2 client/server request+response bodies are `Stream`s over `H2_pipe`. Align types with the unified `Body` lifecycle.
- **End-state:** no code path reads an entire body into memory unless the caller asks (`read_all`) or the body was set as `String`. Server can emit an unbounded response; client can consume an unbounded response.

## Implementation Guide

- **Execution Model:** Orchestrator + sub-agents, tickets **serial**, lowest open first. Never parallelize tickets.
- **Per-Ticket Workflow:** ticket agent MUST (1) `jj st` + `dune test` green start; (2) implement against the Go source, keep every `.mli`; (3) port/adapt tests, driving Lwt via `Lwt_main.run` bounded by `Net.with_timeout`; (4) ALL plan edits (Execution Record) BEFORE committing; (5) one clean `jj commit`, no edits after.
- **Verification Gate:** Execution Record shows `dune build` clean + named tests passing + jj commit id before advancing. Networked/streaming tests MUST terminate (timeout-bounded).
- **Failure Handling:** ticket agent failure → feedback; retry ONCE with a fresh agent; two failures → stop, return to user.
- **Test-change rule:** adapting a test to the new streaming API (e.g. `Body.read_all` instead of matching `Body.String`) is legitimate and must be explicitly noted in the Execution Record; never weaken an assertion about status/headers/body-content to pass.

## Build Out

### Ticket 1 — Body lifecycle + streaming reads (HTTP/1.x)
Status: Done

**A) Scope** Stop materializing on read: `Io.read_request`/`read_response` return a `Body.Stream` wrapping `Transfer.read_transfer`'s reader. Add `Body.drain` (+ a close/on-EOF hook). Chunked trailers are read when the stream hits EOF and populate the message trailer. Server serve loop drains any unread request body before keep-alive reuse.

**B) Migration Strategy** Keep `Body.read_all`. Update tests/code that pattern-match `Body.String` from a read path to use `read_all` (note each). `String`/`Empty` set-bodies unchanged.

**C) Exit State** Reads stream; `read_all` still yields full bodies; chunked trailers still parsed (existing trailer tests pass); keep-alive still works (server drains before next request). Build + tests green.

**D) Detailed Design** `Body.drain : t -> unit Lwt.t`. `Io.read_*` build `Body.Stream next` where `next` pulls from `Transfer.read_transfer`'s reader and, on `None`, runs the trailer/cleanup action (mutating the message `trailer`). A connection-level "body fully read" flag gates reuse.

**E) Testing Plan** *Unit/Integration* (`test/test_stream_read.ml` + adapt existing): a chunked response read incrementally (first chunk before EOF), `read_all` equals the full body, trailer populated after drain; keep-alive: two requests on one connection where the first body is partially read then drained.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record**

*Baseline:* `jj st` clean; `dune build && dune test` green — **434 tests**.

*Files modified (with `.mli` updates):*
- `lib/body.ml` + `lib/body.mli` — added `Body.drain : t -> unit Lwt.t` (pulls a `Stream` to EOF discarding chunks; `Empty`/`String` are no-ops). `read_all`/`write`/the `Stream` variant unchanged.
- `lib/io.ml` — **removed `materialize_body`** (which did `Body.read_all` → `Body.String`, collapsing the streaming reader from `Transfer.read_transfer`, and eagerly read the chunked trailer). Replaced with a non-buffering `stream_body` helper + a `merge_trailer` helper (Go's `mergeSetHeader`). `read_request`/`read_response` now build the message record first (body = `Empty`, trailer = the *declared* trailer) then set `body` to a `Body.Stream` wrapping `read_transfer`'s reader. On the reader's first `None` (io.EOF), a chunked body reads the trailing trailer block via the existing `read_mime_header` (Go's `body.readTrailer`) and merges it into the record's mutable `trailer` (`set_trailer` closure mutating `r.trailer`/`resp.trailer`). An `eof` ref guards a second post-EOF call to keep returning `None`. If `read_transfer` yields `Empty`/`String` (no body / no-body-expected statuses), it is passed through unchanged.
- `lib/server.ml` — the plaintext serve loop and the HTTP/1.x-over-TLS serve loop now run `Body.drain r.body` (guarded by `Lwt.catch`) on a kept-alive connection **before** looping to read the next request (Go's `finishRequest` body consume/close), positioning the connection at the next message boundary and reading any chunked trailer. Stale "bodies are fully materialized" comment updated. No `.mli` change (internal serve loop).

*De-materialization:* the single buffering point named in the plan (`io.ml` `materialize_body`, called by `read_response` ×2 and `read_request`) is gone; reads now stream chunk-by-chunk and the trailer is read lazily on EOF instead of eagerly.

*Keep-alive draining + trailer-on-EOF mechanism:* the streaming body carries an `eof` flag set on the reader's first `None`; reaching it runs the trailer read (mutating the message trailer) — so the connection is only advanced past the body once it is fully consumed. The server serve loop calls `Body.drain` before the next `read_request`, which is what pulls a partially/never-read body to EOF (and through the trailer block) so the next message parse starts at the right offset. A second `next ()` after EOF returns `None` (no double trailer read).

*Tests adapted to `read_all`:* **none required.** The existing read-path tests (`test/test_readrequest.ml`, `test/test_response.ml`) already assert body content via `Body.read_all` (their `body_of` helpers), and trailer assertions run *after* `body_of`, so the lazy trailer-on-EOF read fires before the trailer is checked. Set-body tests (`test_requestwrite`/`test_responsewrite`/`test_request`/`test_h2_transport`) only *construct* `Body.Empty`/`Body.String`, which are unaffected. No assertion was weakened.

*New tests:* `test/test_stream_read.ml` (`val tests`, each bounded by `Net.with_timeout 5.0` over `Lwt_main.run`), wired into `test/test_gohttp.ml` as `("StreamRead", Test_stream_read.tests)` — **6 cases**:
  - `first_chunk_before_eof` — pulls one chunk (`"foo"`) from the `Body.Stream` and asserts it is obtainable while more chunks remain (proves no full buffering), then the second (`"bar"`).
  - `read_all_full_payload` — a fresh parse's `read_all` equals `"foobarbaz"`.
  - `trailer_after_drain` / `trailer_undeclared_after_drain` — chunked body with (declared and undeclared) trailer; after `drain`/`read_all` the response `trailer` carries the trailer header.
  - `keep_alive_two_responses` / `keep_alive_chunked_then_next` — two responses concatenated on one channel; read+drain the first (fixed-length and chunked-with-trailer respectively), then successfully read the second.

*Evidence / counts:* `dune build` clean (no warnings; dev profile treats them as errors). `dune exec test/test_gohttp.exe` → **440 tests run, 0 FAIL** (440 `[OK]`), `Test Successful in ~1.37s` (terminates). New total **440** = 434 baseline + 6 StreamRead.

Status: Done.

### Ticket 2 — Streaming server responses (HTTP/1.x)
Status: Done

**A) Scope** Rewrite `serve_one`'s `response_writer` to faithfully mirror Go's `chunkWriter`: buffer writes into a `bufferBeforeChunkingSize = 2048`-byte buffer; the framing decision fires at first flush = buffer exceeds 2048 **or** handler returns **or** `Flush()` called. If the handler finishes with ≤2048 buffered and set no `Content-Length` → emit exact **Content-Length**, write buffered body (NO chunking). Else → **chunked** (HTTP/1.1) / close-at-EOF (HTTP/1.0), streaming subsequent writes directly. Implicit `WriteHeader 200`; content sniff uses the first ≤512 bytes of the buffer. Add `flush`.

**B) Migration Strategy** Add `flush : unit -> unit Lwt.t` to `response_writer` (update `server.mli` + the h2 adapter). Existing single-write handlers are unchanged in behavior: ≤2048-byte responses still get an exact Content-Length (matching Go), so existing response tests stay green.

**C) Exit State** A handler that exceeds 2048 bytes or calls `flush` produces a chunked stream flushed as it writes; ≤2048-byte responses still get Content-Length (no chunk); `dune test` green.

**D) Detailed Design** Writer state machine mirroring `chunkWriter`: accumulate into a 2048-byte buffer; on `handler_done && size ≤ 2048 && no explicit CL` → headers with `Content-Length = size` + raw body; on overflow/`flush`/handler-running → headers with `Transfer-Encoding: chunked` then `Transfer.chunked_writer_*` per write (HTTP/1.0: `Connection: close`, raw, close at EOF). Sniff Content-Type from the first ≤512 buffered bytes. Date/Connection per existing logic. Constant named `buffer_before_chunking_size = 2048`.

**E) Testing Plan** *Integration* (`test/test_stream_write.ml`): `Stream.server_streams_unbuffered` (Success Criterion) — multi-chunk + `flush` handler ⇒ client reads a chunked body assembled correctly; a single small write ⇒ Content-Length response (no chunking). Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record**

*Baseline:* `jj st` clean (working copy empty, parent = Ticket 1 commit); `dune build && dune test` green — **440 tests**.

*Files modified (with `.mli` updates):*
- `lib/server.ml` + `lib/server.mli` — added `flush : unit -> unit Lwt.t` to `response_writer` (both the type and the `.mli` doc comment, which now describes the 2048 buffer-then-chunk + Flush model). Rewrote `serve_one` to mirror Go's `response`/`chunkWriter` (server.go:1096,1284,1353). Added the constant `buffer_before_chunking_size = 2048`. Updated the h2 adapter `h2_handler_of_handler` to project the H2 writer's existing `flush` into the new field (H2 already had `flush`).
- `test/test_gohttp.ml` — wired `("StreamWrite", Test_stream_write.tests)` into the runner.
- `test/test_stream_write.ml` — new integration suite (3 cases).

*Buffer-then-chunk + Flush implementation:* `serve_one`'s writer keeps a `Buffer` (`body_buf`), and flags `wrote_header`/`headers_emitted`/`chunking`/`handler_done`. `write data`: implicit `WriteHeader 200`, append to `body_buf`; if headers not yet emitted and the buffer exceeds 2048 → `emit_headers` (chunked decision, handler not done) then stream the buffer chunk-encoded; if already streaming → write directly (chunked or raw). `flush ()`: implicit 200, force `emit_headers` if not yet (length unknown → chunked HTTP/1.1 / close HTTP/1.0), push buffered bytes, `Lwt_io.flush`. After the handler returns, `handler_done := true`; if headers were never emitted (everything fit in ≤2048 and no flush) → `emit_headers` decides the **exact-Content-Length common case** (`auto_cl`: handler done, ≤2048 buffered i.e. not chunking, no explicit CL, body allowed, not a zero-byte HEAD, no explicit TE — server.go:1353) and writes the buffered body raw with NO chunking; if streaming already started → flush residual bytes then `chunked_writer_close` for the terminating 0-chunk. `emit_headers` writes the status line (request proto), sniffs Content-Type from the first ≤512 buffered bytes (when unset, body allowed, not nosniff), sets Date if absent, picks the framing header (Content-Length / `Transfer-Encoding: chunked`), and the Connection header. HTTP/1.0 keep-alive (Go's `wants10KeepAlive`, server.go:1369): an HTTP/1.0 request asking for keep-alive answered with a known length (Content-Length / HEAD / no-body) advertises `Connection: keep-alive` and stays reusable; otherwise HTTP/1.0 closes. `close_after_reply` drives the keep-alive return value, consistent with the framing (chunked/CL keep-alive per the existing rules; HTTP/1.0 unknown-length close-delimited → not reusable).

*Tests touched + why:* only `test/test_gohttp.ml` (wiring). No existing test needed adaptation: existing small-response server tests still see an exact Content-Length (≤2048 buffered, handler done → `auto_cl`), and the HTTP/1.0 keep-alive `Serve.http10_close` test still gets `Connection: keep-alive` because the `wants10KeepAlive` branch was reproduced faithfully. No assertion was weakened. No `response_writer` record-literal in tests required a `flush` field (none construct the record).

*New tests (`test/test_stream_write.ml`, each bounded by `Net.with_timeout 10.0` over `Lwt_main.run`, real loopback server via `Server.listen_and_serve_started` + raw `Net.connect` client) — 3 cases:*
  - `server_streams_unbuffered` (**Success Criterion**) — handler writes "alpha"/"beta"/"gamma" with `flush` between, suspended after the first flush on a promise the test resolves only after it has read the early bytes. Asserts the early bytes announce `Transfer-Encoding: chunked` and that the dechunked early body is exactly `"alpha"` **while the handler is still suspended** (chunk observable on the client before completion = unbuffered streaming). After release, the full dechunked body equals `"alphabetagamma"`.
  - `small_response` — one ≤2048-byte write ⇒ exact `Content-Length: 16`, NO `Transfer-Encoding: chunked`, body intact.
  - `large_response` — a 5000-byte write without flush ⇒ `Transfer-Encoding: chunked`, no Content-Length, dechunked body intact.

*Evidence / counts:* `dune build` clean (dev profile, warnings-as-errors). `dune exec test/test_gohttp.exe` → **443 tests run, Test Successful in ~1.3s** (terminates) — 440 prior all green + 3 new StreamWrite (`server_streams_unbuffered`, `small_response`, `large_response` all `[OK]`). New total **443** = 440 + 3. Confirmed small ≤2048 responses still get Content-Length; large/flushed responses chunk.

Status: Done.

### Ticket 3 — Streaming client response bodies (HTTP/1.x)
Status: Done

**A) Scope** `Client`/`Transport` return a streaming `Response.body`; the connection is returned to the idle pool only after the body is drained/closed. `?context` cancellation aborts a mid-stream body read.

**B) Migration Strategy** Add/confirm a response body close/drain path; `Client.get`/`do_` callers either `read_all` or `Body.drain`. Update client tests to drain. Note the lifecycle change (faithful to Go's `resp.Body.Close()`).

**C) Exit State** `Client.get` of a large response streams chunk-by-chunk; conn reused after drain; cancellation works. Build + tests green.

**D) Detailed Design** The pooled connection's reuse is gated on the response body's EOF/drain. A streaming `Response.body` whose EOF action releases the connection to the pool (or closes it if not reusable).

**E) Testing Plan** *Integration* (`test/test_stream_client.ml`): `Stream.client_body_streamed` (Success Criterion) — large response streamed incrementally, reuse-after-drain asserted via the transport dial counter; a cancellation case aborting mid-body. Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record**

*Baseline:* `jj st` clean (working copy empty, parent = Ticket 2 commit `e0227a99`); `dune build && dune test` green — **443 tests**.

*Files modified (with `.mli` review):*
- `lib/transport.ml` — `round_trip`'s `exchange` no longer assumes a materialized body. After `Io.read_response` it computes reusability up front (`reusable t req resp` = keep-alives enabled ∧ neither request nor response asked to close — Go's `persistConn.alive`) and wraps the streaming `resp.body` with a one-shot **connection-release** action (`wrap_body_lifecycle`): when the body reaches EOF (inner reader returns `None`, after the chunked-trailer read), the connection is **returned to the idle pool** if reusable, else **closed** (Go's `bodyEOFSignal.fn` / `tryPutIdleConn` after `waitForBodyRead`). A no-body-on-wire body (`Empty`/`String`, e.g. HEAD / no-body status) releases the connection immediately (`Lwt.async`). The wrapped `next` **races each inner read against `Context.done_ req.ctx`** (Go aborting an in-flight body read on `<-ctx.Done()`): on the context firing it closes the connection (never pools a cancelled body) and re-raises the cause. The `released` flag makes the release run at most once (no double pool/close). The header-phase `exchange_with_ctx` race is unchanged (still closes on a headers-phase cancellation). The `dials`/`h2_round_trips` counters are untouched, so reuse-after-drain stays observable. Header comment updated to describe the streaming/`bodyEOFSignal` lifecycle. **No `.mli` change** — `round_trip`'s signature is unchanged; the lifecycle is internal.
- `lib/client.ml` — `do_one` redirect loop now **`Body.drain resp.Response.body` before following a redirect** (Go reads up to `maxBodySlurpSize` then closes; closing releases the connection). Because the body now streams, this drain is what advances the previous hop's connection to EOF and fires its pool-return action — without it the next hop would dial fresh. `do_` (timeout path) reworked: the `Client.Timeout` deadline must now cover the **streaming body read** (Go's `cancelTimerBody`). It no longer cancels the timer when `do_one` returns the response (the body is still in flight); instead it **wraps the response body** (`wrap_timer_body`) so reaching EOF / a read failure disarms the timer (Go's `cancelTimerBody.Read`/`Close` stopping the timer), and the transport's per-read context race already enforces the deadline mid-body. On any error during the round trip the timer is cancelled and the error re-raised. **No `.mli` change** — `do_`/`get`/`post`/`head` signatures are unchanged.
- `lib/server.ml` — **bug fix surfaced by the new client path:** the Ticket-2 streaming response path terminated a chunked stream with only `chunked_writer_close oc` (= `"0\r\n"`), omitting the trailing CRLF that ends the (empty) trailer block. A kept-alive client that reads the chunked trailer (`Io.stream_body` → `read_mime_header`) then blocks forever waiting for the blank line. Fixed to write `"0\r\n"` **then `"\r\n"`** (mirroring Go's `chunkWriter.close` and `Transfer.write_body`/`after_body`). This was previously unexercised: existing chunked server tests read to EOF on connection close, and clientserver tests used Content-Length responses, so no client ever read a chunked-keep-alive trailer. **No `.mli` change** (internal serve loop).

*How reuse is gated on body drain:* `round_trip` decides reusability before handing back the body and installs a one-shot release on the streaming body's EOF. The connection returns to the idle pool only when the caller pulls the body to `None` (via `Body.read_all` or `Body.drain`) — exactly Go's "connection returns to the pool after the body is fully read + closed". If the caller never drains, the connection is simply not reused.

*How cancellation aborts mid-body:* the wrapped body's `next` does `Lwt.choose [ inner (); Context.done_ req.ctx >>= raise cause ]` on every read. When the request context (an explicit `?context`, or the client `timeout` deadline composed onto it) fires while a body read is outstanding, the choose rejects with the context cause, the connection is **closed** (not pooled), and the cause propagates to the caller. The `cancel_mid_body` test exercises this; the existing `Context.deadline_aborts`/`cancel_aborts` tests (which fire during the headers read) still pass via the unchanged `exchange_with_ctx` race.

*Tests adapted + why:* **none required.** The existing client/transport/context/h2 tests already consume the response body with `Body.read_all` before inspecting reuse/state (`test_clientserver.ml`'s `keepalive_reuse` reads `resp1.body` then checks `dial_count`; `test_context.ml`/`test_h2_clientserver.ml` likewise), and the cancellation tests abort during the headers phase. All 443 prior tests stayed green with no assertion weakened. (The legitimate `read_all`/`drain` adaptation noted in the migration strategy turned out to be already in place from Ticket 1.)

*New tests:* `test/test_stream_client.ml` (`val tests`, real loopback `Server.listen_and_serve_started` + gohttp `Client`, each bounded by `Net.with_timeout` over `Lwt_main.run`), wired into `test/test_gohttp.ml` as `("StreamClient", Test_stream_client.tests)` — **3 cases:**
  - `client_body_streamed` (**Success Criterion**): handler writes `"FIRST"`, flushes, then **blocks on a promise the test resolves only after it has read that first chunk** from the response body, then streams 200×1024 bytes. The test asserts the first chunk (`"FIRST"`) is readable **while the handler is still suspended** (`Lwt.state released = Sleep`) — proving no pre-materialization — and that the full drained body (`first ^ read_all`) equals the exact concatenation (`"FIRST"` + 200·1KiB).
  - `reuse_after_drain`: two sequential `Client.get`s on one client/transport; after `Body.drain resp1.body` the test asserts `idle_count = 1` (connection pooled) and `dial_count = 1`, then the second `Client.get` reuses it (`dial_count` still `1`).
  - `cancel_mid_body`: handler writes one chunk, flushes, then sleeps 5s; client uses a `~context` with a 0.3s timeout — the first chunk reads fine but the next body read races the expired context and aborts with `Context.Deadline_exceeded` (not a full body).

*Evidence / counts:* `dune build` clean (dev profile, warnings-as-errors). `dune exec test/test_gohttp.exe` → **446 tests run, Test Successful in ~1.66s** (terminates) — 443 prior all green + 3 new StreamClient (`client_body_streamed`, `reuse_after_drain`, `cancel_mid_body` all `[OK]`). New total **446** = 443 + 3. First-chunk-before-EOF asserted (`client_body_streamed`); reuse-after-drain asserted via `dial_count`/`idle_count` (`reuse_after_drain`); mid-body cancellation asserted (`cancel_mid_body`).

Status: Done.

### Ticket 4 — HTTP/2 streaming alignment
Status: Planned

**A) Scope** Ensure the h2 `response_writer` frames DATA per `write` (flow-controlled) with a `flush`, no hidden whole-body buffer; h2 client/server request+response bodies are `Stream`s over `H2_pipe` aligned with the Body lifecycle (drain/close). Confirm large bodies stream over h2 without full materialization.

**B) Migration Strategy** Mostly confirmation + small fixes; reuse `H2_pipe`. Add `flush` to the h2 writer to match the unified `response_writer`.

**C) Exit State** h2 GET/POST still pass; a large h2 response streams incrementally; build + tests green.

**D) Detailed Design** Align `h2_server`/`h2_transport` body construction with `Body.Stream` + drain; ensure DATA is emitted on `write`/`flush` honoring stream/connection windows.

**E) Testing Plan** *Integration* (`test/test_stream_h2.ml` or extend existing): an h2 handler streaming multiple DATA frames ⇒ client assembles the full body; large-body round trip. Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record** _(tbd)_

### Ticket 5 — End-to-end streaming demo + docs
Status: Planned

**A) Scope** A `bin/main.ml` (or example) demonstrating a streaming server handler and a streaming client consumer over both h1 and h2; update module docs/`.mli` comments to describe the streaming/lifecycle model. Final sweep that no read/write path buffers unintentionally.

**B) Migration Strategy** Additive/demo + doc only.

**C) Exit State** Demo runs showing incremental streaming; docs updated; all tests green.

**D) Detailed Design** Demo: server handler writes a sequence with `flush`; client drains and prints chunks as they arrive.

**E) Testing Plan** Covered by Tickets 1–4 integration tests; the demo is a manual/runtime check (`dune exec gohttp`).

**F) End-of-Ticket Verification** `dune build && dune test` clean; `dune exec gohttp` shows streaming.

**G) Execution Record** _(tbd)_
