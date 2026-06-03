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
Status: Planned

**A) Scope** Stop materializing on read: `Io.read_request`/`read_response` return a `Body.Stream` wrapping `Transfer.read_transfer`'s reader. Add `Body.drain` (+ a close/on-EOF hook). Chunked trailers are read when the stream hits EOF and populate the message trailer. Server serve loop drains any unread request body before keep-alive reuse.

**B) Migration Strategy** Keep `Body.read_all`. Update tests/code that pattern-match `Body.String` from a read path to use `read_all` (note each). `String`/`Empty` set-bodies unchanged.

**C) Exit State** Reads stream; `read_all` still yields full bodies; chunked trailers still parsed (existing trailer tests pass); keep-alive still works (server drains before next request). Build + tests green.

**D) Detailed Design** `Body.drain : t -> unit Lwt.t`. `Io.read_*` build `Body.Stream next` where `next` pulls from `Transfer.read_transfer`'s reader and, on `None`, runs the trailer/cleanup action (mutating the message `trailer`). A connection-level "body fully read" flag gates reuse.

**E) Testing Plan** *Unit/Integration* (`test/test_stream_read.ml` + adapt existing): a chunked response read incrementally (first chunk before EOF), `read_all` equals the full body, trailer populated after drain; keep-alive: two requests on one connection where the first body is partially read then drained.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record** _(tbd)_

### Ticket 2 — Streaming server responses (HTTP/1.x)
Status: Planned

**A) Scope** Rewrite `serve_one`'s `response_writer` to faithfully mirror Go's `chunkWriter`: buffer writes into a `bufferBeforeChunkingSize = 2048`-byte buffer; the framing decision fires at first flush = buffer exceeds 2048 **or** handler returns **or** `Flush()` called. If the handler finishes with ≤2048 buffered and set no `Content-Length` → emit exact **Content-Length**, write buffered body (NO chunking). Else → **chunked** (HTTP/1.1) / close-at-EOF (HTTP/1.0), streaming subsequent writes directly. Implicit `WriteHeader 200`; content sniff uses the first ≤512 bytes of the buffer. Add `flush`.

**B) Migration Strategy** Add `flush : unit -> unit Lwt.t` to `response_writer` (update `server.mli` + the h2 adapter). Existing single-write handlers are unchanged in behavior: ≤2048-byte responses still get an exact Content-Length (matching Go), so existing response tests stay green.

**C) Exit State** A handler that exceeds 2048 bytes or calls `flush` produces a chunked stream flushed as it writes; ≤2048-byte responses still get Content-Length (no chunk); `dune test` green.

**D) Detailed Design** Writer state machine mirroring `chunkWriter`: accumulate into a 2048-byte buffer; on `handler_done && size ≤ 2048 && no explicit CL` → headers with `Content-Length = size` + raw body; on overflow/`flush`/handler-running → headers with `Transfer-Encoding: chunked` then `Transfer.chunked_writer_*` per write (HTTP/1.0: `Connection: close`, raw, close at EOF). Sniff Content-Type from the first ≤512 buffered bytes. Date/Connection per existing logic. Constant named `buffer_before_chunking_size = 2048`.

**E) Testing Plan** *Integration* (`test/test_stream_write.ml`): `Stream.server_streams_unbuffered` (Success Criterion) — multi-chunk + `flush` handler ⇒ client reads a chunked body assembled correctly; a single small write ⇒ Content-Length response (no chunking). Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record** _(tbd)_

### Ticket 3 — Streaming client response bodies (HTTP/1.x)
Status: Planned

**A) Scope** `Client`/`Transport` return a streaming `Response.body`; the connection is returned to the idle pool only after the body is drained/closed. `?context` cancellation aborts a mid-stream body read.

**B) Migration Strategy** Add/confirm a response body close/drain path; `Client.get`/`do_` callers either `read_all` or `Body.drain`. Update client tests to drain. Note the lifecycle change (faithful to Go's `resp.Body.Close()`).

**C) Exit State** `Client.get` of a large response streams chunk-by-chunk; conn reused after drain; cancellation works. Build + tests green.

**D) Detailed Design** The pooled connection's reuse is gated on the response body's EOF/drain. A streaming `Response.body` whose EOF action releases the connection to the pool (or closes it if not reusable).

**E) Testing Plan** *Integration* (`test/test_stream_client.ml`): `Stream.client_body_streamed` (Success Criterion) — large response streamed incrementally, reuse-after-drain asserted via the transport dial counter; a cancellation case aborting mid-body. Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record** _(tbd)_

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
