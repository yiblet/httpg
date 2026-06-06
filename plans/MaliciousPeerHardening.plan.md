# Malicious-Peer Hardening (bad clients / bad servers) — Plan

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

---

## Problem

- **Goal:** Make gohttp defend against malicious or buggy peers the way Go's `net/http` does — abusive clients attacking the server, malicious servers attacking the client — across HTTP/1.x and HTTP/2. Each defense must mirror Go's mechanism, constant values, and error semantics (`go/src/net/http/` is the spec of record). This is a **fresh, never-shipped** stack: there are no external consumers and **no migration or backward-compatibility concern** — the only fidelity target is Go itself.
- **Success Criteria (as a test):** A new alcotest suite **`Abuse`** (aggregated into `test/test_gohttp.ml`) passes, where each enabled ticket contributes at least one ported/adapted test. Headline integration tests:
  - `TestServerSlowlorisHeaderTimeout` (T1): a client that opens a connection and never finishes the request headers is dropped within `read_header_timeout` instead of pinning a fiber forever.
  - `TestServerRequestHeaderTooLarge` (T2): a request whose header block exceeds `max_header_bytes` is answered `431` and the connection closed (Go: `errTooLarge` → 431, `server.go:2053`).
  - `TestServerRejectsTooManyEarlyResets` (T8): a rapid open+RST_STREAM loop trips an `ENHANCE_YOUR_CALM` connection error (Go: `server.go:2263`, CVE-2023-44487).
  - `TestTransportResponseHeaderTooLarge` (T6): a server streaming an unbounded response header block makes the client fail with a modeled "response header too large" error, not OOM (Go: `Transport.MaxResponseHeaderBytes`).
- **Non-Goals:**
  - The already-faithful cases require no code change and get no ticket: CL+TE conflict (Case 3), duplicate/invalid Content-Length (Case 4), CONTINUATION flood (Case 10).
  - The already-shipped bounded request-body drain (`Body.drain ~limit:max_post_handler_read_bytes`, `server.ml`) and the separately-tracked `Body`-as-`io.ReadCloser` gap (`TODO.md`) are out of scope here.
  - No new concurrency abstraction; stay on Lwt as the rest of the repo does.
  - HTTP/3, cookie jar, proxies (existing `TODO.md` non-goals) unchanged.
- **Constraints:**
  - **Fidelity over invention:** mirror Go's mechanism, constant values, and error semantics. Cite the matching `go/src/net/http/*.go:line` in every implementing change.
  - **Streaming preserved:** bounds enforced incrementally (byte budgets, deadlines) — never by buffering a whole message to measure it (`CLAUDE.md`).
  - **Error policy:** handleable protocol/limit violations are typed `Result`/typed-error variants per module; unhandleable bugs stay `raise` (`CLAUDE.md`).
  - **`.mli` discipline:** every new public function/field gets an `.mli` entry in the same change.
  - **Defaults match Go:** `DefaultMaxHeaderBytes = 1 lsl 20`, `MaxResponseHeaderBytes` default `10 lsl 20`, `maxQueuedControlFrames = 10000` (already present), `defaultMaxStreams = 250`, chunked `maxLineLength = 4096` (already present), rapid-reset backlog `4 * adv_max_streams`.

---

## Discovery

### Key User Paths

- **HTTP/1.x server:** `Net.accept` → `Server.serve_conn` / `serve_tls_conn` per-connection loop (`lib/server.ml:699`, `:824`) → `Io.read_request` (`lib/io.ml:543`, raising core `read_request_raising` `:259`) → handler dispatch → bounded body drain → loop. Request line + headers read by `read_line` (`lib/io.ml:67`) and `read_mime_header_raising` (`lib/io.ml:111`); framing by `lib/transfer.ml` + `lib/internal/chunked.ml`.
- **HTTP/1.x client:** `Client.do_` → redirect loop `do_one` (`lib/client.ml:97`) → `Transport.round_trip` → `Io.read_response` (`lib/io.ml:546`, core `read_response_raising` `:367`).
- **HTTP/2 server:** `Server.serve_tls_conn` ALPN "h2" → `H2_server.serve` (one event-loop fiber); frames decoded by `H2_frame`, headers by HPACK (`hpack.ml`), handlers scheduled by `schedule_handler` (`h2_server.ml:606`).
- **HTTP/2 client:** `Transport.round_trip` force-h2 → `H2_transport`.

### Current Architecture (where defenses do / don't live)

- **Read primitives are unbounded.** `read_line` (`lib/io.ml:67`) appends to an unbounded `Buffer` and takes **no** limit arg; `read_mime_header_raising` (`lib/io.ml:111`) gathers an unbounded number of lines. No `setReadLimit`/`hitReadLimit` analogue. `read_request`/`read_response` (`io.ml:543`,`:546`) take no budget. This single fact underlies Cases 2, 5 (trailer), and 14.
- **No socket deadlines.** Neither serve loop nor the read paths apply any timeout. `Net.with_timeout` (`lib/net.ml:225`) exists but is only used by tests. `Server.t` (`lib/server.ml:644`) has no timeout fields; `Server.create` (`:654`) is just `?addr ?port handler`. (Case 1.)
- **Framing is faithful.** `Transfer.parse_transfer_encoding`/`fix_length` (`lib/transfer.ml:267-270`) and `parse_content_length` (`:205-221`) match Go (Cases 3, 4). Chunked core (`lib/internal/chunked.ml`: `max_line_length=4096`, hex overflow, `excess` accounting) is faithful; only the post-body **trailer** read (`lib/io.ml:215` → unbounded `read_mime_header_raising`) is missing Go's `seeUpcomingDoubleCRLF` bound (Case 5).
- **Header validation is write-only.** `Header.write_subset` (`lib/header.ml:88-107`) neutralizes outbound CRLF and drops invalid names, but `valid_header_field_name` is **never** applied on the read path, and there is no `ValidHostHeader` / missing-Host-for-1.1 check (Cases 6, 8).
- **HTTP/2 has most defenses, with holes.** CONTINUATION flood (`h2_frame.ml`), `max_queued_control_frames=10000` (`h2_server.ml:23`, `:1102`), maxConcurrentStreams (`h2_server.ml:793`), and flow-control overflow detection (`h2_flow.ml`) are faithful. Gaps: rapid-reset backlog cap absent (`schedule_handler` `h2_server.ml:606-613` queues `sc.unstarted` unbounded via O(n) `@ [..]`; `EnhanceYourCalm` exists at `h2_error.ml:15` but is **unused**), `MAX_HEADER_LIST_SIZE` not advertised/derived and the per-string HPACK cap mis-wired to the 16 MiB list budget, duplicate-SETTINGS not rejected (`h2_server.ml:918` `process_settings`), flow-control overflow surfaces as `invalid_arg` rather than a modeled connection error.

### Critical Contracts

- `Io.error` (`lib/io.ml:26`, variants `Protocol | Missing_host | Transfer | Unexpected_eof`; surfaced by `Server.write_read_error_response` `lib/server.ml:677-695`): new request-side limit/validation failures add typed variants here and map to the right status. Client-side response-limit failure adds a variant too. **There is no existing `Request_too_large`/`Response_header_too_large`.**
- `Server.create` (`lib/server.ml:654`) currently `?addr ?port handler`; `Server.t` (`:644`) has no policy fields.
- `Transport.create` (`lib/transport.ml:64`) currently `?insecure ?authenticator ()`; `Transport.t` (`:40`) has no header-size field.
- `Io.read_request` / `Io.read_response` (`lib/io.mli:54`,`:65`) take no budget parameter today.
- `H2_frame.read_meta_headers` (called `h2_server.ml:1078`) — confirm whether it already accepts a `~max_header_list_size`; the server call site must pass a config-derived value (T9 verifies this in code).
- `H2_error.err_code` (`lib/internal/http2/h2_error.ml:3`) already defines `ProtocolError` (0x1), `FlowControlError` (0x3), `EnhanceYourCalm` (0xb). The h2 serve loop already converts `Conn_error` codes to GOAWAY; new caps reuse that path.

### Migration Pressure Points

- **None in the backward-compatibility sense** — fresh code, no external callers. The only intra-repo pressure is keeping the build green per ticket. Since Go models these knobs as struct fields with zero-value = off/default, the faithful OCaml shape is **optional `create` args with Go-matching defaults**; existing test/demo call sites that omit them keep compiling for free. The one shared piece is the **bounded read layer** (T2): `read_line ?limit` + a head budget threaded through `read_mime_header_raising`, consumed by T2 (request), T3 (trailer), and T6 (response). Land T2 first.

### Areas of Uncertainty

- **Lwt deadline shape (T1).** Lwt has no `SetReadDeadline`; the faithful analogue is `Lwt.pick` / `Net.with_timeout` around each read promise. Confirm that wrapping `Io.read_request` whole cleanly separates the *header* deadline from the *whole-request* deadline given the body is a lazily-pulled `Body.Stream`: header-deadline around `read_request`, idle-deadline around the between-requests next-read, whole-request/read-deadline around body-stream pulls, write-deadline around response writes.
- **Byte-budget span (T2).** Confirm the budget covers request-line + all header lines cumulatively against one limit (Go counts the whole head against `initial_read_limit = max_header_bytes + 4096`, `server.go:929`).
- **HPACK per-string vs list cap (T9).** Go sets per-string = list size but its list default is 1 MiB; ours is 16 MiB. Decide the gohttp h2 default `max_header_bytes` (propose `1 lsl 20` to match Go) and whether to bound the Huffman decoder by length or keep a tightened post-decode check. Also confirm whether `read_meta_headers` already takes `~max_header_list_size`.
- **Flow-control modeling (T11).** Confirm whether the h2 serve loop already turns an `invalid_arg` from the inflow path into a GOAWAY rather than crashing the fiber: if it does, T11 is a low-priority fidelity rename; if not, it is a correctness fix.

### The 15-case matrix (research result)

| # | Case | Direction / proto | Go mechanism (ref) | gohttp today | Verdict | Ticket |
|---|------|-------------------|--------------------|--------------|---------|--------|
| 1 | Slowloris / idle & header read timeouts | client→server h1 | `ReadHeaderTimeout`/`IdleTimeout`, `SetReadDeadline` (`server.go:1017`,`:2145`) | no timeouts anywhere | **HIGH** | T1 |
| 2 | Oversized / too-many request headers | client→server h1 | `DefaultMaxHeaderBytes=1<<20`, `setReadLimit`/`hitReadLimit` (`server.go:920`,`:1024`,`:818`) → 431 | unbounded `read_line`/header gather | **HIGH** | T2 |
| 3 | CL + TE:chunked conflict (smuggling) | both h1 | `fixLength` strips CL, TE wins (`transfer.go:718`) | faithful (`transfer.ml:267-270`) | none | — |
| 4 | Duplicate / invalid Content-Length | both h1 | `fixLength`/`parseContentLength` (`transfer.go:666`,`:1050`) | faithful (`transfer.ml:233-256`,`:205-221`) | none | — |
| 5 | Malformed chunked (size/ext/trailer) | both h1 | core + `seeUpcomingDoubleCRLF` trailer cap (`transfer.go:894-951`) | core faithful; **trailer + line unbounded** (`io.ml:215`,`:67`) | **MEDIUM** | T3 |
| 6 | Header/CRLF/NUL injection & invalid bytes | both h1 | write neutralize + read validate loop (`header.go:190`,`server.go:1053`) | write faithful; **read name/value validation missing** | **MEDIUM** | T4 |
| 7 | `Expect: 100-continue` abuse | client→server h1 | lazy 100, 417 on unknown (`server.go:2090`,`:2236`) | **absent entirely** | **MEDIUM** | T5 |
| 8 | Request-line / Host / URI validation | client→server h1 | missing-Host-1.1 + `ValidHostHeader` (`server.go:1045-1052`) | partial; **no Host-required / Host-validity** | **MEDIUM** | T4 |
| 9 | Rapid Reset (CVE-2023-44487) | client→server h2 | backlog `>4*advMaxStreams` → `ENHANCE_YOUR_CALM` (`server.go:2263`) | **unbounded `sc.unstarted`** | **HIGH** | T8 |
| 10 | CONTINUATION flood (CVE-2024-27316) | client→server h2 | `2*remainSize` cap (`frame.go:1774`) | faithful (`h2_frame.ml`) | none | — |
| 11 | HPACK header-list-size bomb | both h2 | advertise `MAX_HEADER_LIST_SIZE`, `SetMaxStringLength` (`server.go:778`,`frame.go:1722`) | **not advertised; per-string cap mis-wired (16 MiB); Huffman unbounded** | **HIGH** | T9 |
| 12 | Control-frame floods (SETTINGS/PING) | client→server h2 | `maxQueuedControlFrames=10000` + dup-SETTINGS reject (`server.go:896`,`:1616`) | cap faithful; **dup-SETTINGS not rejected** | **LOW** | T10 |
| 13 | Flow-control & maxConcurrentStreams | client→server h2 | refused-stream + window overflow `ConnectionError` (`flow.go`) | faithful; overflow is `invalid_arg` not modeled | **LOW** | T11 |
| 14 | Oversized response headers / body | server→client h1 | `Transport.MaxResponseHeaderBytes` default `10<<20` (`transport.go:337`) | **no cap; unbounded status+header read** (body OK) | **HIGH** | T6 |
| 15 | Client redirect abuse (leak / loop / scheme) | server→client h1 | sticky subdomain-aware strip + Referer (`client.go:691`,`:1008-1048`,`:147`) | cap+lists faithful; **non-sticky exact-string strip (`client.ml:122`); no Referer** | **MEDIUM** | T7 |

---

## Target Shape

- **Responsibilities / Ownership:**
  - **Bounded read layer (`lib/io.ml`)** owns byte budgets: `read_line ?limit` and a head-budget threaded through `read_mime_header_raising`, raising a typed `Io` error on exhaustion. Shared by server request reads, client response reads, and chunked trailer reads.
  - **`Server.t` (`lib/server.ml`)** owns server policy: `read_timeout`, `read_header_timeout`, `write_timeout`, `idle_timeout`, `max_header_bytes`, plus `Expect`/`100-continue` handling and the read-path validation sweep.
  - **`Transport.t` (`lib/transport.ml`)** owns client policy: `max_response_header_bytes`; **`Client` (`lib/client.ml`)** owns sticky redirect-header stripping and Referer.
  - **HTTP/2 (`lib/internal/http2/`)** owns h2 caps: rapid-reset backlog (`h2_server.ml`), `MAX_HEADER_LIST_SIZE` advertise/enforce + HPACK string cap (`h2_server.ml`/`h2_frame.ml`/`hpack.ml`), duplicate-SETTINGS rejection, modeled flow-control errors.
- **Public Contracts (end state):**
  - `Server.create` gains `?read_timeout ?read_header_timeout ?write_timeout ?idle_timeout ?max_header_bytes` (all optional seconds/bytes, Go-matching defaults; zero/None = off where Go's zero is off).
  - `Transport.create` gains `?max_response_header_bytes` (default `10 lsl 20`).
  - `Io.read_request` / `read_response` gain `?max_header_bytes` (budget); `read_line` gains `?limit`.
  - New `Io.error` variants: `Request_too_large`, `Malformed_host`, `Response_header_too_large`. New `Request.expects_continue`.
  - New h2: server initial SETTINGS includes `Max_header_list_size`; `schedule_handler` trips `EnhanceYourCalm` over the backlog; `process_settings` rejects duplicates; flow-control overflow surfaces as a modeled `H2_error` connection error.
- **Execution Flow (end state):** each read on a server connection is bounded by a deadline (header → whole-request → idle) and a header-byte budget; on violation the connection is answered with the Go-matching status (431/400/417) and closed. The h2 event loop trips `ENHANCE_YOUR_CALM`/`PROTOCOL_ERROR`/`FLOW_CONTROL_ERROR` GOAWAYs on the corresponding abuse. The client bounds response-header bytes and never re-leaks sensitive headers once stripped.
- **Migration Shape:** N/A in the backcompat sense (fresh stack). All new knobs are optional `create` args defaulting to Go's values, so existing test/demo callers keep compiling. T2's bounded read layer is introduced behind the same function names with an optional `?limit`, so non-bounded callers are unaffected.
- **End-State Properties:** no single connection can force unbounded memory or unbounded fiber lifetime; h2 abuse classes (rapid reset, header bomb, control-frame flood, dup settings) all terminate the connection as Go does; the client cannot be OOM'd by a hostile server's headers and cannot be tricked into re-leaking credentials across a redirect bounce.

---

## Implementation Guide

- **Execution Model:** orchestrator + sub-agents, **serial** tickets in the listed order. Dependencies: **T3 and T6 require T2** (the bounded read layer); T8–T11 are independent of T1–T7 and of each other. The orchestrator spawns one sub-agent per ticket whose sole job is that ticket.
- **Per-Ticket Workflow (each sub-agent):**
  1. `dune build && dune test` to confirm a green start.
  2. **Precedent survey (MANDATORY — do this before designing).** Find where this repo has *already solved an analogous problem* and follow that idiom, so the fix is consistent with **both** Go's behavior **and** the existing codebase. Each ticket lists a **Precedent to follow** pointer as your starting point; read it, then grep for sibling patterns (e.g. how typed boundary errors are raised-and-mapped, how `Context` deadlines are derived, how an h2 connection error becomes a GOAWAY, how a `Body.Stream` is wrapped). Prefer reusing an established pattern over inventing a new mechanism. **Before copying a precedent, verify it against the Go source it claims to mirror.** If the precedent itself diverges from Go (wrong constant, non-faithful logic), do **not** propagate the divergence: fix the precedent to match Go as part of this ticket, update the **Precedent to follow** pointer in the plan, and note the correction in the Execution Record. If you must diverge from either Go or the local idiom, justify it. Record which precedent you followed (and any precedent you had to correct) and why.
  3. Implement the ticket, keeping `.mli` in sync and citing the matching `go/src/net/http/*.go:line`.
  4. Add the named ported/adapted test(s) into the `Abuse` suite (or the existing suite the test belongs to) and wire into `test/test_gohttp.ml`.
  5. `dune build` (warnings are errors), `dune fmt`, `dune test`.
  6. Record what changed + the precedent followed + test evidence (paste the alcotest tail) + commit id in the ticket's Execution Record.
  7. Create one commit (semantic message). **VCS: this repo uses jj colocation — use `jj`, not `git`.**
- **Verification Gate:** the orchestrator may start the next ticket only when the current ticket's Execution Record shows: build clean, the named test(s) present and passing (alcotest tail pasted), a note of the precedent followed (per workflow step 2), and a commit id. If evidence is missing, spawn a verifier agent to run the checks and fill the record before proceeding.
- **Failure Handling:** if a sub-agent fails, it returns feedback describing what broke. The orchestrator adjusts the plan if needed and retries **once** with a fresh sub-agent. Two failures on the same ticket → stop and return control to the user with context.
- **Scope Handling:** follow the user's requested scope exactly — one ticket means only that ticket; "all" means in listed order. A reasonable shippable subset is the five HIGH tickets first (T1, T2, T8, T9, T6) if the user wants to triage by severity.
- **Test fidelity:** where Go has a matching test (`go/src/net/http/serve_test.go`, `internal/http2/server_test.go`, `transport_test.go`), port it and treat it as the spec. If a verbatim port can't pass due to an architectural difference (e.g. the too-big path can't inject `Connection: close` — see `TODO.md`), adapt the assertion and call out the divergence in the Execution Record.

---

## Build Out

### Ticket 1 — Server read / header / idle / write timeouts (Case 1)
Status: Planned

**A) Scope**
Add Go's four server duration knobs so a slow/idle/incomplete client cannot pin a fiber forever (Slowloris). Closes the highest-value DoS gap. New optional `create` args, default off (zero = no timeout, like Go) — document that production should set them.

**B) Migration Strategy**
Additive `?read_timeout ?read_header_timeout ?write_timeout ?idle_timeout` on `Server.create`; `Server.t` gains the fields. The timeouts are implemented as **child `Context`s derived from the existing per-connection `conn_ctx`** (`server.ml:706`), not bare `Net.with_timeout` — reusing the established idiom (`Client.Timeout` already does `Context.with_timeout` at `client.ml:203`) and composing with the connection-close cancel that already exists. Existing callers/tests compile unchanged (defaults off). No backcompat surface to preserve beyond keeping the repo green.

**C) Exit State**
A connection that never completes the request headers is closed within `read_header_timeout`; an idle kept-alive connection is closed within `idle_timeout`. Build/tests green.

**D) Detailed Design**
- `Server.create : ?addr:string -> ?port:int -> ?read_timeout:float -> ?read_header_timeout:float -> ?write_timeout:float -> ?idle_timeout:float -> handler -> t` (seconds; mirror Go's `readHeaderTimeout()`/`idleTimeout()` fallback to `read_timeout`). Add fields to `Server.t` (`lib/server.ml:644`) and to `server.mli`.
- **Context-based deadlines.** `serve_conn` (`lib/server.ml:699`) / `serve_tls_conn` (`:824`) already hold `conn_ctx` (`:706`). For each bounded read/write, derive a child via `Context.with_timeout conn_ctx secs` and race the operation: `Lwt.pick [ op; (Context.done_ ctx >>= fun () -> match Context.err ctx with Some Context.Deadline_exceeded -> <close, no reply> | _ -> <connection gone>) ]`, calling the returned `cancel` on the happy path to disarm the timer (as `client.ml:209` does). Apply: header deadline (`read_header_timeout`) around `Io.read_request`; idle deadline (`idle_timeout`) around the between-requests next-read (Go's `Peek(4)`); whole-request deadline (`read_timeout`) around body-stream pulls; write deadline (`write_timeout`) around response writes. On header/idle timeout, close with no reply (Go hangs up).
- **Fidelity note (record in Execution Record):** Go implements these four timeouts with socket `SetReadDeadline`/`SetWriteDeadline` (`server.go:1017`, `:2145`), *separate* from its request `context`. Lwt_io channels expose no settable socket deadline, so we use `Context` as the timeout vehicle — the same adaptation the client already made. The deadline child is derived off `conn_ctx` and is *not* made the parent of `req_ctx` (Go's request context is not cancelled by ReadTimeout), preserving Go's separation.
- **Precedent to follow:** `Client.Timeout` already derives a deadline child and races the body against it — `Context.with_timeout req.Request.ctx secs` + `cancel` disarm (`lib/client.ml:203-209`); and the server already owns the connection context tree (`conn_ctx`/`req_ctx`, `lib/server.ml:706`,`:720`). Mirror that idiom; do **not** introduce a bare `Net.with_timeout` one-off.
- Reference: `go/src/net/http/server.go:1007-1022`, `:1074-1076`, `:2145-2149`, `:3717-3724`.

**E) Testing Plan (Integration)**
- `TestServerSlowlorisHeaderTimeout`: start a server with `~read_header_timeout:0.2`; open a raw loopback socket, send `"GET / HTTP/1.1\r\n"` and nothing more; assert the connection is closed (read returns EOF) within a bounded `Net.with_timeout`, and the serve fiber did not leak. Assertion: closure observed < ~1s.
- `TestServerIdleTimeout`: complete one request, then hold the kept-alive connection idle; assert it closes within `~idle_timeout`.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green incl. the two new tests; `dune fmt` applied.

**G) Execution Record**
_(to be filled during implementation: changes, alcotest tail, commit id, status)_

---

### Ticket 2 — `max_header_bytes` + bounded read layer (Case 2) — FOUNDATION
Status: Planned

**A) Scope**
Bound the request status line + header block so one connection cannot exhaust memory. Introduces the shared bounded-read primitive (`read_line ?limit` + head budget) that T3 and T6 reuse. Server answers `431 Request Header Fields Too Large` and closes, as Go does.

**B) Migration Strategy**
`read_line` gains `?limit:int`; `read_mime_header_raising` and `read_request_raising` thread a cumulative remaining-byte budget. New `Io.Request_too_large` variant. `Server.t`/`create` gain `?max_header_bytes` (default `1 lsl 20`). Non-bounded callers omit `?limit` and are unaffected.

**C) Exit State**
A request with a header block (or single huge line, or unterminated header stream) exceeding `max_header_bytes` yields 431 + close; normal requests unchanged. Build/tests green.

**D) Detailed Design**
- `lib/io.ml`: `read_line : ?limit:int -> Lwt_io.input_channel -> string Lwt.t` raising `Request_too_large` when the line would exceed the remaining budget; a mutable budget (`int ref`) decremented per byte across the request line + every header line in `read_mime_header_raising`. `read_request ?max_header_bytes`.
- New variant in `Io.error` (`lib/io.ml:26`): `Request_too_large` (+ `.mli`). Map it in `Server.write_read_error_response` (`lib/server.ml:677`) to `431` with `Connection: close` (Go `server.go:2053-2062`, `errTooLarge` at `:998`).
- `initial_read_limit = max_header_bytes + 4096` (Go `server.go:929`).
- **Precedent to follow:** (a) the raise-a-sentinel / catch-at-boundary error model already in `lib/io.ml` — internal exception → `error_of_exception` → typed `error` via `to_result` (`io.ml:520-546`; e.g. the `Missing_host` sentinel at `:13-21`); add `Request_too_large` the same way rather than returning results from deep in the parser. (b) `lib/internal/chunked.ml` already enforces an incremental byte bound (`max_line_length = 4096`, hex overflow) without buffering — model `read_line ?limit`'s per-byte budget decrement on it.
- Reference: `go/src/net/http/server.go:920-929`, `:1024`, `:803-818`.

**E) Testing Plan (Integration)**
- `TestServerRequestHeaderTooLarge`: server with `~max_header_bytes:8192`; send a request with a header block > 8 KiB; assert status `431` and the connection closes.
- `TestServerRequestLineTooLong`: a single request line > limit → 431.
- `TestServerHeadersUnderLimitOk`: a request just under the limit is served `200` (no false positive).

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green incl. new tests; `dune fmt`.

**G) Execution Record**
_(to be filled)_

---

### Ticket 3 — Bounded chunked trailer + line cap (Case 5)
Status: Planned — depends on Ticket 2

**A) Scope**
Bound the trailer block read after a chunked body (and any single line) so a malicious chunked message can't OOM the peer via an endless/gigantic trailer. Applies to both server (request) and client (response) since the trailer read is shared.

**B) Migration Strategy**
Reuse T2's `read_line ?limit`; add a trailer-size guard mirroring Go's `seeUpcomingDoubleCRLF` (bounded peek before parsing) and a bare-`\r\n` fast path. New handleable `Transfer`/`Io` error "suspiciously long trailer after chunked body".

**C) Exit State**
A chunked body followed by an oversized/unterminated trailer fails with a typed error instead of unbounded buffering; well-formed (incl. empty) trailers still parse. Build/tests green.

**D) Detailed Design**
- In the chunked-body EOF action (`lib/io.ml:215`), replace the bare `read_mime_header_raising` with a bounded `read_trailer`: fast-path empty trailer when the next two bytes are `\r\n` (Go `transfer.go:913-917`); otherwise require an upcoming double-CRLF within a bounded peek (~buffer size) before reading, else error (Go `transfer.go:894-951`, `:934`).
- Give every trailer/header line the T2 `?limit` cap.
- **Precedent to follow:** T2's `read_line ?limit` + the `io.ml` sentinel→`error` boundary (reuse it for the trailer error, don't invent a parallel mechanism); and `lib/internal/chunked.ml`'s existing bounded reads as the model for the bounded peek. The trailer is parsed by the same `read_mime_header_raising` you bounded in T2.
- Reference: `go/src/net/http/transfer.go:894-951`; `internal/chunked.go` (core already faithful in `lib/internal/chunked.ml`).

**E) Testing Plan (Unit)**
- `TestChunkedTrailerTooLong`: chunked body + an oversized trailer block → typed error; `TestChunkedEmptyTrailerOk`: chunked body + bare `\r\n` → success; `TestChunkedSmallTrailerOk`: one small trailer header parses and is surfaced. Exercise via `Io.read_request`/`read_response` over an in-memory channel.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green incl. new tests; `dune fmt`.

**G) Execution Record**
_(to be filled)_

---

### Ticket 4 — Server read-path header-name/value + Host validation (Cases 6 & 8)
Status: Planned

**A) Scope**
Add Go's post-parse validation sweep on inbound requests: reject non-token header **names** and CTL-bearing values (Case 6 read-side), reject a missing `Host` on HTTP/1.1 and a malformed `Host` value (Case 8). Outbound CRLF neutralization is already faithful (`header.ml`) — no change there.

**B) Migration Strategy**
Add the sweep in `read_request_raising` after the header block is parsed. New `Io` variants (`Malformed_host`; reuse `Protocol`/`Missing_host` for the rest) for "invalid header name", "invalid header value", "malformed Host header". Map to `400` in `write_read_error_response`.

**C) Exit State**
Requests with invalid header names/values or missing/malformed Host get `400`; valid requests unchanged. Build/tests green.

**D) Detailed Design**
- `lib/io.ml read_request_raising` (~`:286`): iterate parsed headers — reject when `Header.valid_header_field_name k` is false (`lib/header.ml`) and when any value byte fails `valid_header_value_byte` (`lib/io.ml`). Add missing-Host-for-1.1 guard (proto≥1.1 && no Host && method≠CONNECT && not h2-upgrade → bad request) mirroring `server.go:1045-1047`; port a `valid_host_header` byte-table check (`golang.org/x/net/http/httpguts` `httplex.go:209-263`) for the single Host value → `Malformed_host` (`server.go:1050`). Note: the existing server-side `Io.Missing_host` arm (`server.ml:692`) is currently dead for inbound — this wires it (or a new variant) to a real path.
- **Precedent to follow:** the **write-side** validation already in `lib/header.ml` — `valid_header_field_name` (`:65`) and the `write_subset` drop-invalid-keys loop (`:88-107`). Reuse `valid_header_field_name` (don't write a second token table) and mirror its style for the read-side value-byte check; surface failures through the same `io.ml` sentinel→`error` boundary as T2.
- Reference: `go/src/net/http/server.go:1045-1063`, `request.go:1143-1157`.

**E) Testing Plan (Unit/Integration)**
- `TestServerRejectsInvalidHeaderName` (e.g. `"Foo Bar: x"`) → 400; `TestServerRejectsBadHostHeader` → 400; `TestServerRejectsMissingHostHTTP11` → 400; `TestServerAcceptsValidHostAndHeaders` → 200. Drive via raw socket or `Io.read_request` over in-memory channels.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green; `dune fmt`.

**G) Execution Record**
_(to be filled)_

---

### Ticket 5 — `Expect: 100-continue` handling + 417 (Case 7)
Status: Planned

**A) Scope**
Honor `Expect: 100-continue` (lazily emit the interim `100 Continue` on first body read) and reject unknown `Expect` values with `417 Expectation Failed` + `Connection: close`. Fixes an interop break (spec-compliant clients withholding the body hang today) and a minor self-inflicted resource issue.

**B) Migration Strategy**
Add `Request.expects_continue` (port `request.go:1518`). In the serve loop, wrap the request `Body.Stream` so the first pull writes `HTTP/1.1 100 Continue\r\n\r\n` once (analogue of `expectContinueReader`); reject unknown `Expect` before dispatch. No change to requests without `Expect`.

**C) Exit State**
A client sending `Expect: 100-continue` receives the interim 100 when the handler first reads the body; an unknown `Expect` gets 417 + close. Build/tests green.

**D) Detailed Design**
- `Request.expects_continue : _ t -> bool` = has token `100-continue` in `Expect` (`request.go:1518`).
- `lib/server.ml` serve loop (`serve_conn` dispatch, ~`:710`): if `expects_continue && proto≥1.1 && content_length<>0`, wrap `r.body` (a `Body.Stream` thunk) so the first invocation writes the 100 line to `oc` then flushes, then proceeds; else if `Header.get r.header "Expect" <> ""`, write 417 with `Connection: close` and stop. Mirror `server.go:2090-2101`, `:2236-2252`, `:964-983`.
- **Precedent to follow:** `Client.wrap_timer_body` (`lib/client.ml:164-180`) already wraps a `Body.Stream` thunk to run a side-effect on pull (it disarms the timeout on first read/EOF). The 100-continue reader is the same shape — wrap the stream so the first pull has a one-shot side-effect (write `100 Continue`). Follow that wrapper's structure.

**E) Testing Plan (Integration)**
- `TestServerExpect100Continue`: client sends headers with `Expect: 100-continue`, waits; assert it receives `100 Continue` only after/when the handler reads the body, then the final response. `TestServerExpectUnknown`: `Expect: bogus` → `417` + `Connection: close`. (Port from `serve_test.go` Expect tests.)

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green; `dune fmt`.

**G) Execution Record**
_(to be filled)_

---

### Ticket 6 — Client `MaxResponseHeaderBytes` (Case 14)
Status: Planned — depends on Ticket 2

**A) Scope**
Bound the response status line + header block the client reads, so a hostile/buggy server cannot OOM the client before any handler runs. Body is already correctly bounded (streaming `Transfer`), so no body change.

**B) Migration Strategy**
`Transport.t`/`create` gain `?max_response_header_bytes` (default `10 lsl 20`, Go's default). Thread the budget (reusing T2's bounded read) through `Io.read_response`. New `Io.Response_header_too_large` variant surfaced as a `Transport`/`Client` error.

**C) Exit State**
A server streaming an unbounded header block makes the client fail with a modeled error within the budget; normal responses unchanged. Build/tests green.

**D) Detailed Design**
- `Transport.create : ?insecure:bool -> ?authenticator:... -> ?max_response_header_bytes:int -> unit -> t`; field on `Transport.t` (`lib/transport.ml:40`). Pass into `Io.read_response ?max_header_bytes` at the read site (`lib/transport.ml:331`).
- `Io.read_response` budgets the status line (`read_line`, `io.ml:370`) + header block (`read_mime_header_raising`, `io.ml:401`) using T2's `?limit`. New `Io.error` variant `Response_header_too_large` (+ `.mli`); map at the transport public boundary to a typed transport error.
- **Precedent to follow:** this is the response-side mirror of T2 — reuse T2's `read_line ?limit` and sentinel→`error` boundary verbatim. For surfacing the error at the client boundary, follow how the transport already maps `Io` errors at the read site (`or_raise`, `lib/transport.ml:331`).
- Reference: `go/src/net/http/transport.go:275-280`, `:337-340`, `:364`.

**E) Testing Plan (Integration)**
- `TestTransportResponseHeaderTooLarge`: a raw loopback server that writes a status line then an endless header stream; client transport with `~max_response_header_bytes:8192`; assert the round trip fails with the modeled error (not a hang/OOM) within a bounded timeout. `TestTransportResponseHeaderUnderLimitOk`: normal response under the limit succeeds.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green; `dune fmt`.

**G) Execution Record**
_(to be filled)_

---

### Ticket 7 — Client sticky / subdomain-aware redirect header stripping + Referer (Case 15)
Status: Planned

**A) Scope**
Fix the sensitive-header leak where a redirect chain that returns to the original host re-attaches `Authorization`/`Cookie` (today's strip decision at `client.ml:122` is recomputed per hop against `initial_host`, non-sticky). Make stripping sticky and subdomain-aware like Go, and add Referer handling (omit on https→http).

**B) Migration Strategy**
Thread a `strip_sensitive` accumulator through `do_one`'s loop (init false, latches true and never resets). Port `should_copy_header_on_redirect`/`is_domain_or_subdomain` (`client.go:1008-1048`). Add `referer_for_url` (`client.go:147-152`). Header lists and the 10-redirect cap are already faithful.

**C) Exit State**
Once sensitive headers are stripped on a cross-host hop they stay stripped for the rest of the chain (incl. a bounce back to the original host); `sub.foo.com` from the *initial* `foo.com` keeps them (Go parity); Referer omitted on https→http. Build/tests green.

**D) Detailed Design**
- **Match Go's exact comparison (this corrects the earlier draft).** Go computes the strip flag against the **initial** request URL, not the previous hop, with a sticky latch (`client.go:691-694`): `if not strip_sensitive && initial_host <> dest_host && not (should_copy_header_on_redirect ~initial ~dest) then strip_sensitive := true`. `should_copy_header_on_redirect ~initial ~dest = is_domain_or_subdomain ~sub:dest_host ~parent:initial_host` (`:1008-1048`; keep on a subdomain-or-equal of the **initial** host). Referer is independent and uses the **previous** hop: `referer_for_url ~last:prev_url ~next:dest_url` (`:698`, `:147-152`; omit on https→http).
- `lib/client.ml do_one` (`:97`): replace the per-hop `strip_sensitive = url_host loc_url <> initial_host` (`:122`) with the sticky `bool ref` carried through the loop, set per the rule above (note: it compares `initial_host`, which `do_one` already binds at `:99`, against each hop's `dest_host` — not `prev_host`). Set/omit `Referer` from the previous hop's URL.
- **Precedent to follow:** the strip plumbing already exists and is faithful — `sensitive_header` (`lib/client.ml:71`) and `copy_headers ~strip_sensitive` (`:85`, called `:124`) match Go's header lists (`client.go:817-821`) verbatim; keep using `copy_headers` as-is. This ticket only changes *how* `strip_sensitive` is computed (sticky, against the **initial** host, subdomain-aware) and adds Referer.
- Reference: `go/src/net/http/client.go:691-698`, `:763-834`, `:1008-1048`, `:147-152`.

**E) Testing Plan (Integration/Unit)**
- `TestRedirectStripStickyOnBounceBack`: chain `a.com (Authorization) → b.com → a.com`; assert `Authorization` is absent on the final hop to `a.com`. `TestRedirectKeepsHeaderOnSubdomain`: `foo.com → sub.foo.com` keeps `Authorization`. `TestRedirectRefererHttpsToHttp`: Referer omitted. Use multi-host `Httptest` servers or a `round_trip` stub capturing per-hop headers.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green; `dune fmt`.

**G) Execution Record**
_(to be filled)_

---

### Ticket 8 — HTTP/2 rapid-reset backlog cap (Case 9, CVE-2023-44487)
Status: Planned

**A) Scope**
Bound the unstarted-handler backlog so an open+RST_STREAM flood can't cheaply force unbounded handler scheduling. Trip an `ENHANCE_YOUR_CALM` connection error when the backlog exceeds `4*adv_max_streams`, matching Go's CVE fix.

**B) Migration Strategy**
In `schedule_handler` (`h2_server.ml:606-613`), before appending to `sc.unstarted`, check `List.length sc.unstarted > 4 * sc.adv_max_streams` → connection error `H2_error.EnhanceYourCalm` propagated via the existing GOAWAY path (the variant exists at `h2_error.ml:15`, currently unused). Also switch the O(n) `sc.unstarted @ [..]` append (`:613`) to a non-quadratic structure (prepend+reverse-on-drain or a queue) since under attack the list churns hot.

**C) Exit State**
A rapid open+reset loop terminates the connection with `ENHANCE_YOUR_CALM`; normal over-limit queuing still drains correctly. Build/tests green.

**D) Detailed Design**
- `schedule_handler` returns/raises a `Conn_error EnhanceYourCalm` when over `4*adv_max_streams`; the drain (`h2_server.ml:621-628`) already skips reset streams. Reference: `go/src/net/http/internal/http2/server.go:2255-2273` (`scheduleHandler`), `:2275-2297` (`handlerDone`), `:277` (`advMaxStreams`).
- **Precedent to follow:** the connection-error→GOAWAY path is established — handlers return `Error H2_error.X`, `outcome_of_result` turns it into `Conn_error code` (`h2_server.ml:1017-1021`), and `go_away` (`:349`) emits it; the refused-stream over-limit case (`:796`) and the `>100` SETTINGS count check (`:924`) are concrete models. Make the backlog cap return the same `Error H2_error.EnhanceYourCalm` so it rides the existing path — don't add a bespoke teardown.

**E) Testing Plan (Integration)**
- `TestServerRejectsTooManyEarlyResets`: drive an h2 server connection (over the in-memory/loopback h2 test harness) opening streams and immediately sending RST_STREAM in a loop; assert the server emits a GOAWAY with `ENHANCE_YOUR_CALM` after the backlog cap. Port `TestServer_Rejects_TooManyEarlyResets` from `internal/http2/server_test.go`.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green; `dune fmt`.

**G) Execution Record**
_(to be filled)_

---

### Ticket 9 — HTTP/2 MAX_HEADER_LIST_SIZE advertise/derive + HPACK per-string cap + Huffman bound (Case 11)
Status: Planned

**A) Scope**
Advertise and enforce a config-derived `MAX_HEADER_LIST_SIZE` (default `1 lsl 20` to match Go, vs today's hardcoded 16 MiB), wire the HPACK per-string cap to a sane value (not the full list budget), and bound the Huffman decode so a compressed string can't force a multi-MB allocation before the post-decode check.

**B) Migration Strategy**
Add a server `max_header_bytes` (h2) option (default `1 lsl 20`); include `Max_header_list_size` in the server's initial SETTINGS; pass `~max_header_list_size` into the `read_meta_headers` call (`h2_server.ml:1078`); set the HPACK per-string cap separately from the list cap; bound `Huff.decode` by length or tighten the post-decode check.

**C) Exit State**
The server advertises `MAX_HEADER_LIST_SIZE`; a header bomb is rejected at the configured size (not 16 MiB); a Huffman-compressed oversized string is rejected without a large transient allocation. Build/tests green.

**D) Detailed Design**
- `h2_server.ml`: initial SETTINGS gains `Max_header_list_size = max_header_bytes` (the SETTINGS write path already handles the `H2.Max_header_list_size` id, `:951`); decoder string cap set via `Hpack.set_max_string_length` to the per-string bound (not `max_header_list_size`); `read_meta_headers ~max_header_list_size:max_header_bytes` at `:1078` (confirm the function already accepts this param; if not, add it).
- `hpack.ml`: bound `decode_string`/`Huff.decode` by the per-string cap. Reference: `go/src/net/http/internal/http2/server.go:497-505`, `:778`; `frame.go:1716`, `:1722`, `:1774`; `hpack/hpack.go:84`, `:122`, `:488`, `:516`.
- **Precedent to follow:** the server already constructs and writes its initial SETTINGS and handles the `H2.Max_header_list_size` id in the SETTINGS path (`h2_server.ml:951`); the existing CONTINUATION-flood bound in `h2_frame.ml` is the model for an incremental decode cap. Add the advertised setting and the per-string cap alongside those, not as a new subsystem.

**E) Testing Plan (Unit/Integration)**
- `TestH2RejectsHeaderListBomb`: feed a HEADERS+CONTINUATION sequence whose decoded list exceeds the configured size → connection `PROTOCOL_ERROR`. `TestH2HuffmanStringCap`: a Huffman-coded string exceeding the per-string cap → `ErrStringLength`-equivalent. `TestH2AdvertisesMaxHeaderListSize`: initial SETTINGS contains `MAX_HEADER_LIST_SIZE`.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green; `dune fmt`.

**G) Execution Record**
_(to be filled)_

---

### Ticket 10 — HTTP/2 duplicate-SETTINGS rejection (Case 12)
Status: Planned

**A) Scope**
Reject a SETTINGS frame containing duplicate setting IDs with `PROTOCOL_ERROR`, matching Go's `f.HasDuplicates()` check (the `>100` count check is already present). Low severity (frame already bounded), fidelity item.

**B) Migration Strategy**
Add a `has_duplicates` helper (ideally on `H2_frame.settings_frame` to mirror `SettingsFrame.HasDuplicates`); call it in `process_settings` (`h2_server.ml:918`) alongside the existing count check.

**C) Exit State**
A SETTINGS frame with repeated IDs is a connection `PROTOCOL_ERROR`; valid frames unchanged. Build/tests green.

**D) Detailed Design**
- `H2_frame.settings_has_duplicates : settings_frame -> bool` (scan for repeated `s.id`). In `process_settings` (`h2_server.ml:918`): `if List.length sf.settings > 100 || settings_has_duplicates sf then Error ProtocolError`. Reference: `go/src/net/http/internal/http2/server.go:1616-1620`.
- **Precedent to follow:** the `>100` count check at `h2_server.ml:924` is the exact sibling — it already returns `Error H2_error.ProtocolError` from `process_settings`, which flows through `outcome_of_result`→`go_away`. Add the duplicate check on the same line, in the same form.

**E) Testing Plan (Unit)**
- `TestH2RejectsDuplicateSettings`: a SETTINGS frame with two entries for the same ID → `ProtocolError`; `TestH2AcceptsDistinctSettings`: distinct IDs accepted.

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green; `dune fmt`.

**G) Execution Record**
_(to be filled)_

---

### Ticket 11 — HTTP/2 flow-control overflow modeled as connection error (Case 13)
Status: Planned

**A) Scope**
Ensure a flow-control window overflow surfaces as a modeled `H2_error` connection error (GOAWAY `FLOW_CONTROL_ERROR`) rather than an `invalid_arg` raise that could crash the connection fiber. Detection logic itself is already correct. Low severity / fidelity — first confirm whether the serve loop already converts the raise.

**B) Migration Strategy**
If the event loop already catches the raise and GOAWAYs, this is a rename/typing cleanup; if not, convert the inflow-add overflow (`h2_flow.ml`) and related paths to return a `Result`/typed error consumed by the serve loop. maxConcurrentStreams enforcement is already faithful — no change.

**C) Exit State**
A peer that overflows its flow-control window triggers a clean `FLOW_CONTROL_ERROR` GOAWAY; the connection fiber does not crash. Build/tests green.

**D) Detailed Design**
- Audit `h2_flow.ml` and the h2 serve loop's error handling. Make window-overflow a modeled `H2_error.FlowControlError` connection error. Reference: `go/src/net/http/internal/http2/flow.go` (`inflow.add`/`take`, `ConnectionError(ErrCodeFlowControl)`).
- **Precedent to follow:** `process_window_update`/`process_settings` already return `Result` consumed by `outcome_of_result`→`Conn_error`→`go_away` (`h2_server.ml:1019-1039`,`:349`). Convert the overflow path to return `Error H2_error.FlowControlError` into that same flow instead of raising `invalid_arg`. **First confirm** (workflow step 2) whether the serve loop already catches the raise and GOAWAYs — if so this is a typing/rename cleanup, if not a correctness fix; record which in the Execution Record.

**E) Testing Plan (Unit/Integration)**
- `TestH2FlowControlOverflowGoaway`: send a WINDOW_UPDATE / data pattern that overflows the window; assert a `FLOW_CONTROL_ERROR` GOAWAY and no fiber crash. `TestH2MaxConcurrentStreamsRefused` (regression): exceeding `adv_max_streams` is `REFUSED_STREAM` (already works).

**F) End-of-Ticket Verification**
`dune build` clean; `dune test` green; `dune fmt`.

**G) Execution Record**
_(to be filled)_
