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
Status: Done

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

**What changed**
- `lib/server.ml`:
  - `Server.t` gains four duration fields `read_timeout`, `read_header_timeout`, `write_timeout`, `idle_timeout` (seconds; `0.` = no timeout, Go's zero-value). `create` gains the matching optional args (default `0.`).
  - New internal `timeouts` record + `timeouts_of_server`, applying Go's `readHeaderTimeout()`/`idleTimeout()` fallback to `read_timeout` (server.go:3717-3729). Note `write_timeout` does NOT fall back (matches Go — only header/idle fall back).
  - New `race_deadline conn_ctx ~secs op`: when `secs<=0.` runs the op unbounded; otherwise derives `Context.with_timeout conn_ctx secs` and `Lwt.pick`s the op against `Context.done_`, returning ``` `Done v ``` / ``` `Timeout ```, calling the returned `cancel` on the happy path to disarm the timer (mirrors client.ml:209).
  - New `wrap_read_timeout_body conn_ctx ~secs r`: wraps the request `Body.Stream` so each pull is raced against a whole-request read deadline (server.go:1015,:1074-1076); on EOF/failure it disarms via `cancel`; on deadline it surfaces EOF. Same shape as `Client.wrap_timer_body`.
  - Refactored the duplicated per-connection loop in `serve_conn` and the http1-over-TLS branch of `serve_tls_conn` into one shared `serve_loop ~timeouts ~ic ~oc ~remote handler`, which applies: header deadline (`read_header_timeout`) around `Io.read_request` on the first request; idle deadline (`idle_timeout`) around the between-requests next read; whole-request deadline (`read_timeout`) around body pulls via the wrapper; write deadline (`write_timeout`) around `serve_one`. On header/idle timeout it closes with no reply (Go hangs up). `serve`/`serve_tls` accept loops now compute `timeouts_of_server srv` per connection and thread it in.
  - `listen_and_serve_started` gains the four optional knobs (forwarded to `create`) so tests can configure them.
- `lib/server.mli`: documented the four new `create` knobs and the four new `listen_and_serve_started` knobs (kept in sync).
- `test/test_abuse.ml` (new) + wired `("Abuse", Test_abuse.tests)` into `test/test_gohttp.ml`: `slowloris_header_timeout` and `idle_timeout`, both raw-loopback-socket integration tests bounded by `Net.with_timeout`.

**Precedent followed**
- `Client.Timeout` (`client.ml:203-209`) — derive a deadline child via `Context.with_timeout`, `cancel`-disarm on the happy path. Mirrored exactly in `race_deadline`. **Verified against Go:** Go uses socket `SetReadDeadline`/`SetWriteDeadline` (server.go:1007-1022,:2145-2149), separate from the request context; Lwt_io has no settable socket deadline, so Context-as-timeout-vehicle is the deliberate, already-established Lwt adaptation. No correction to the precedent was needed.
- `Client.wrap_timer_body` (`client.ml:164-180`) — wrap a `Body.Stream` thunk with a one-shot side-effect/disarm. Mirrored in `wrap_read_timeout_body`.
- Connection context tree already owned by the server: `conn_ctx`/`req_ctx` (`server.ml:706`,`:720`). The deadline children are derived off `conn_ctx` and are **not** made the parent of `req_ctx` — Go's request context is not cancelled by ReadTimeout, so this preserves Go's separation.

**Fidelity note (the deliberate adaptation):** Go implements all four timeouts with socket `SetReadDeadline`/`SetWriteDeadline` (server.go:1007-1022,:2145-2149), independent of the request `context`. Lwt_io channels expose no settable socket deadline, so this port uses a child `Context` deadline derived off `conn_ctx` as the timeout vehicle — the same adaptation the client made for `Client.Timeout`. The deadline child is deliberately NOT the parent of `req_ctx`. One minor approximation: Go arms the idle deadline only over the `Peek(4)` wait for the next request's first bytes, then switches to the header deadline; here the idle deadline is raced over the whole next `read_request` (both are read-side deadlines, so for the idle drop this is equivalent in observable behavior).

**Alcotest tail**
```
  [OK]          Abuse                   0   slowloris_header_timeout.
  [OK]          Abuse                   1   idle_timeout.

Test Successful in 2.297s. 506 tests run.
```
`dune build` clean (warnings-as-errors), `dune fmt` applied, full `dune test` green (506 tests).

**Commit:** `yyykxtxy` (`feat(server): add read/header/idle/write timeouts (Slowloris hardening)`).

---

### Ticket 2 — `max_header_bytes` + bounded read layer (Case 2) — FOUNDATION
Status: Done

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

**What changed**
- `lib/io.ml`:
  - New internal sentinel `exception Request_too_large` + `request_too_large_sentinel` alias (Go's `errTooLarge`, server.go:998), declared before `type error` so the `Request_too_large` arm can shadow the name — mirrors the existing `Missing_host` sentinel idiom (io.ml:14-21).
  - New `Io.error` arm `Request_too_large` with `error_to_string` = `"http: request too large"`; mapped at the boundary in `error_of_exception` (`e == request_too_large_sentinel -> Request_too_large`), so it rides the existing `to_result` catch-at-boundary path verbatim.
  - **The reusable bounded-read primitive:** `read_line : ?limit:int ref -> Lwt_io.input_channel -> string Lwt.t`. `limit` is a **shared mutable byte budget** (`int ref`): each byte pulled off `ic` (including the terminating CRLF) decrements it, and the read raises `Request_too_large` as soon as the budget would go negative — *before* buffering an unbounded line. Omitting `limit` is unbounded as before. Modeled on `chunked.ml`'s incremental `Buffer.length > max_line_length` check, but as a shared decrementing ref so one budget spans multiple `read_line` calls.
  - `read_mime_header_raising : ?limit:int ref -> ...` threads the same `limit` ref through every header line, continuing from wherever the request/status line left it.
  - `read_request_raising : ?max_header_bytes:int -> ...` creates `Some (ref (n + 4096))` (Go's `initialReadLimitSize = maxHeaderBytes + 4096` bufio slop, server.go:929) and passes it to BOTH the request-line `read_line` and `read_mime_header_raising ?limit`, so the request line + all header lines are bounded cumulatively against one limit (server.go:1024).
  - Boundary wrapper `read_request : ?max_header_bytes:int -> ...` forwards to the raising core.
- `lib/io.mli`: documented the new `Request_too_large` error arm and `?max_header_bytes` on `read_request` (kept in sync). `read_line`/`read_mime_header_raising` are not in the `.mli` (internal); the public budget surface is `read_request`'s `?max_header_bytes`.
- `lib/server.ml`:
  - `Server.t` gains `max_header_bytes : int`; `create` gains `?max_header_bytes` defaulting to `default_max_header_bytes = 1 lsl 20` (Go's `DefaultMaxHeaderBytes`, server.go:922).
  - `write_read_error_response` maps `Io.Request_too_large` to `431 Request Header Fields Too Large` + the shared `error_headers` (which include `Connection: close`), then close (server.go:2053-2062). Placed before the `Protocol | Missing_host | Transfer` catch-all 400 arm.
  - `serve_loop` gains `~max_header_bytes`, passed to `Io.read_request ~max_header_bytes`. `serve_conn`/`serve_tls_conn` gain `?max_header_bytes` (default `default_max_header_bytes`); the `serve`/`serve_tls` accept loops pass `srv.max_header_bytes`. `listen_and_serve_started` forwards `?max_header_bytes` to `create`.
- `lib/server.mli`: documented `?max_header_bytes` on `create` and `listen_and_serve_started`.
- `test/test_abuse.ml`: added `request_header_too_large`, `request_line_too_long`, `headers_under_limit_ok` (raw-loopback integration, bounded by `Net.with_timeout`).

**Reusability for T3/T6 (the design ask)**
- `read_line ?limit:int ref` is **not server-specific**: the budget is a caller-owned `int ref`. T6 (client `MaxResponseHeaderBytes`) reuses it identically — `read_response_raising` will create `ref (max_response_header_bytes + 4096)` and pass `?limit` to its status-line `read_line` (io.ml:~388) and `read_mime_header_raising ?limit` (io.ml:~430). T3 (chunked trailer) reuses it by passing a `?limit` to the trailer's `read_mime_header_raising` call in `stream_body` (io.ml:~225). The sentinel→`error` boundary already in place means T3/T6 only need their own `error` arm + boundary mapping (T6) or reuse `Request_too_large`/a new `Transfer` arm (T3); no new mechanism.

**Precedent followed**
- (a) **Raise-a-sentinel / catch-at-boundary** (io.ml:14-21 `Missing_host`, `error_of_exception`/`to_result` io.ml:52-58,:~545): added `Request_too_large` the same way — raised deep in `read_line`, mapped once at the boundary. **Verified against Go:** Go's `errTooLarge` is a sentinel `error` value checked at `conn.serve` (server.go:998,:2053); the raise-and-map shape matches Go's error-value-comparison. No correction needed.
- (b) **`lib/internal/chunked.ml`'s incremental byte bound** (`max_line_length = 4096`, the per-byte `Buffer.length > max_line_length` check at chunked.ml:98): modeled `read_line ?limit`'s per-byte budget on it, generalizing the fixed per-line cap into a shared decrementing cross-line budget (Go bounds the whole head, not each line — server.go:929). **Verified against Go:** Go's `setReadLimit`/`hitReadLimit` (server.go:803-818,:1024) limits *total* bytes read off the socket for the head against `initialReadLimitSize`, which is exactly the shared-ref-across-lines behavior here, not chunked's per-line cap. No correction to chunked needed (it faithfully mirrors `internal/chunked.go`'s own per-line `ErrLineTooLong`, a different Go limit).

**Alcotest tail**
```
  [OK]          Abuse                   2   request_header_too_large.
  [OK]          Abuse                   3   request_line_too_long.
  [OK]          Abuse                   4   headers_under_limit_ok.

Test Successful in 2.264s. 509 tests run.
```
`dune build` clean (warnings-as-errors), `dune fmt` applied, full `dune test --force` green (509 tests: 506 prior + 3 new).

**Commit:** `mzmnkpzo` (`feat(io): bound request head with max_header_bytes (431 on overflow)`).

---

### Ticket 3 — Bounded chunked trailer + line cap (Case 5)
Status: Done

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

**What changed**
- `lib/io.ml`:
  - New internal sentinel `exception Trailer_too_large` + `trailer_too_large_sentinel` alias (Go's "http: suspiciously long trailer after chunked body", transfer.go:934), declared next to the T2 `Request_too_large` sentinel and aliased for the deep parse path — the same idiom.
  - New `Io.error` arm `Trailer_too_large` (`error_to_string` = the Go message); mapped at the boundary in `error_of_exception` (`e == trailer_too_large_sentinel -> Trailer_too_large`), riding the existing `to_result` catch-at-boundary path verbatim.
  - New `trailer_buffer_size = 4096` (Go's "underlying buffer size, typically 4kB", transfer.go:932) and `read_trailer ic`: reads the chunked trailer via `read_mime_header_raising` bounded by a fresh `?limit:(ref trailer_buffer_size)` (the T2 primitive). On budget exhaustion `read_line` raises the shared `Request_too_large` sentinel; `read_trailer` catches that and re-raises `Trailer_too_large` so the error type is correct (not 431). The empty-trailer common case (bare CRLF, transfer.go:913-917) is the `read_line`-returns-"" fast path already inside `read_mime_header_raising`, so no separate two-byte peek was needed.
  - `stream_body`'s chunked-body EOF action now calls `read_trailer ic` instead of the bare `read_mime_header_raising ic`.
- `lib/io.mli`: added the `Trailer_too_large` boundary-error arm AND the `exception Trailer_too_large` (mirroring how `Missing_host` is exposed both as an exception and an `error` arm) — because the trailer is read **mid-stream** inside the body `Stream` thunk, callers observe it as a raise from a body pull (`Body.read_all`/`Body.drain`), per the documented mid-stream policy, not as a boundary `Error`.
- `lib/server.ml`: added `Io.Trailer_too_large` to `write_read_error_response`'s catch-all 400 arm (defensive — it is normally a mid-stream raise and rarely reaches the boundary; 400 matches Go's plain-Read-error treatment of a malformed trailer). Needed to keep the match exhaustive under warnings-as-errors.
- `test/test_abuse.ml`: added `chunked_trailer_too_long`, `chunked_empty_trailer_ok`, `chunked_small_trailer_ok`, driven over an in-memory `Lwt_io` channel (`ic_of_string` + `Io.read_response`), bounded by `Net.with_timeout`. The too-long test asserts the `Io.Trailer_too_large` exception raises from `Body.drain` (mid-stream), not from `read_response`.

**Precedent followed**
- **T2's `read_line ?limit` + the `io.ml` sentinel→`error` boundary.** Reused the shared mutable byte-budget `int ref` to bound the trailer's `read_mime_header_raising`, and added `Trailer_too_large` via the identical raise-a-sentinel / map-at-boundary idiom (`error_of_exception`) rather than a parallel mechanism. **Verified against Go:** Go's defense (`seeUpcomingDoubleCRLF`, transfer.go:894-951) peeks up to the bufio buffer size (~4kB) for an upcoming double-CRLF before parsing, because it cannot slip a `LimitReader` in front of `textproto` (transfer.go:925-931). `Lwt_io` exposes no non-consuming `Peek`, so the faithful adaptation reproduces the **effect** — cap the trailer block to the same 4096-byte buffer budget — using the T2 budget directly. This is equivalent (both bound the trailer to the buffer size). No correction to the T2 precedent was needed; it was already faithful.
- **Deliberate adaptation (recorded):** Go uses peek-then-parse; we use bounded-read. Documented inline in `read_trailer`. The empty-trailer fast path (transfer.go:913-917) is subsumed by `read_mime_header_raising`'s existing blank-first-line handling, so it required no extra peek.

**Alcotest tail**
```
  [OK]          Abuse                   5   chunked_trailer_too_long.
  [OK]          Abuse                   6   chunked_empty_trailer_ok.
  [OK]          Abuse                   7   chunked_small_trailer_ok.

Test Successful in 2.281s. 512 tests run.
```
`dune build` clean (warnings-as-errors), `dune fmt`/`dune build @fmt` clean, full `dune test --force` green (512 tests: 509 prior + 3 new).

**Commit:** `zyqyworr` (`feat(io): bound chunked trailer with seeUpcomingDoubleCRLF analogue`).

---

### Ticket 4 — Server read-path header-name/value + Host validation (Cases 6 & 8)
Status: Done

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

**What changed**
- `lib/io.ml`:
  - New internal sentinel `exception Malformed_host` + `malformed_host_sentinel` alias (Go's `badRequestError("malformed Host header")`, server.go:1051), declared before `type error` so the `Malformed_host` arm can shadow the name — the same idiom as the existing `Missing_host`/`Request_too_large`/`Trailer_too_large` sentinels. New `Io.error` arm `Malformed_host` (`error_to_string` = `"malformed Host header"`), mapped at the boundary in `error_of_exception` (`e == malformed_host_sentinel -> Malformed_host`), riding the established `to_result` catch-at-boundary path.
  - New `valid_host_byte`/`valid_host_header` — a faithful port of httpguts `validHostByte`/`ValidHostHeader` (httplex.go:209-263): the lenient host byte table (alnum + sub-delims + unreserved + `% : [ ] ' _ ~` etc.), placed next to the existing `valid_header_value_byte`.
  - **The validation sweep** added to `read_request_raising` right after the `too many Host headers` check, before the Host is derived/deleted, mirroring Go's `conn.serve` ordering (server.go:1045-1062): (1) missing required Host on proto≥1.1, non-CONNECT, non-h2-upgrade → `Protocol_error "missing required Host header"`; (2) a single malformed Host value → `malformed_host_sentinel`; (3) the per-header name/value loop over the parsed `Header.t`: `Header.valid_header_field_name k` false → `Protocol_error "invalid header name"`, any value byte failing `valid_header_value_byte` → `Protocol_error "invalid header value"`. `is_h2_upgrade` ports request.go:529 (`PRI`, empty headers, path `*`, `HTTP/2.0`).
- `lib/io.mli`: added the `Malformed_host` boundary-error arm and documented the validation sweep on `read_request`.
- `lib/header.ml`/`lib/header.mli`: exposed the already-present `valid_header_field_name` in the `.mli` (no impl change) so the read path can reuse it — no second token table.
- `lib/server.ml`: added `Io.Malformed_host` to `write_read_error_response`'s 400 arm (alongside `Protocol`/`Missing_host`/`Transfer`/`Trailer_too_large`), matching Go's `badRequestError` → 400.
- `test/test_abuse.ml`: added `rejects_invalid_header_name`, `rejects_bad_host_header`, `rejects_missing_host_http11`, `accepts_valid_host_and_headers` (raw-loopback integration, bounded by `Net.with_timeout`).

**Error-variant decisions**
- **Added `Malformed_host`** (own variant) — Go gives malformed Host its own `badRequestError` message; a distinct arm keeps the boundary error faithful and reusable.
- **Reused `Protocol`** for invalid-header-name, invalid-header-value, and missing-Host. All map to 400; `Protocol` carries Go's exact message text (`"invalid header name"` / `"invalid header value"` / `"missing required Host header"`). The write-side `Missing_host` arm was **not** reused for the inbound missing-Host case: its `error_to_string` is the write-path message (`"http: Request.Write on Request with no Host or URL set"`), which would be wrong inbound. `Protocol "missing required Host header"` is the faithful inbound message and still maps to 400, so the dead inbound `Missing_host` arm stays for the write path only.

**Precedent followed**
- **Write-side `Header.valid_header_field_name`** (header.ml:65): reused verbatim on the read path — no second token table. **Verified against Go:** it is `String.length s > 0 && String.for_all Gohttp_base.Textproto.valid_header_field_byte s`, and `valid_header_field_byte` matches httpguts `isTokenTable` (httplex.go:15-93) byte-for-byte (tchar set). Faithful; no correction.
- **`valid_header_value_byte`** (io.ml): reused for the value-byte check. **Verified:** `b = 0x09 || (b >= 0x20 && b <> 0x7f)` is exactly `!(isCTL(b) && !isLWS(b))` from httpguts `ValidHeaderFieldValue` (httplex.go:303-310) — allows HTAB and any non-DEL byte ≥ 0x20 (incl. high bytes), rejects other CTLs. Faithful; no correction.
- **Sentinel→`error` boundary** (io.ml `error_of_exception`/`to_result`): `Malformed_host` added the same way as T2/T3's `Request_too_large`/`Trailer_too_large` — raised deep, mapped once at the boundary. Invalid-name/value/missing-Host reuse the existing `Protocol_error` sentinel directly.

**Fuzz harness:** the HTTP Garden harness directory (`fuzz/garden/`) is not present in this checkout, so it could not be consulted. The four alcotest tests cover the no-Host (`GET / HTTP/1.1\r\n\r\n` → 400) and malformed-target/Host (`Host: bad host` → 400) cases the harness flagged; both verified passing.

**Alcotest tail**
```
  [OK]          Abuse                   8   rejects_invalid_header_name.
  [OK]          Abuse                   9   rejects_bad_host_header.
  [OK]          Abuse                  10   rejects_missing_host_http11.
  [OK]          Abuse                  11   accepts_valid_host_and_headers.

Test Successful in 2.274s. 516 tests run.
```
`dune build` clean (warnings-as-errors), `dune fmt`/`dune build @fmt` clean, full `dune test --force` green (516 tests: 512 prior + 4 new).

**Commit:** `pnzmvtww` (`feat(io): validate inbound header names/values + Host (400 on violation)`).

---

### Ticket 5 — `Expect: 100-continue` handling + 417 (Case 7)
Status: Done

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

**What changed**
- `lib/request.ml` / `lib/request.mli`: new `expects_continue : 'a t -> bool` (port of `request.go:1518` `expectsContinue`), defined as `Transfer.has_token (Header.get r.header "Expect") "100-continue"`. Reuses the already-faithful `Transfer.has_token` (the port of `header.go:240` `hasToken`) rather than re-deriving token-boundary logic. `request.ml` does not depend on `Transfer` elsewhere, but the layering (transfer = layer 2, request = layer 3) makes request → transfer the correct, cycle-free direction (verified `transfer.ml` never names `Request`).
- `lib/server.ml`:
  - New `wrap_expect_continue_body oc r`: wraps the request `Body.Stream` so the FIRST pull writes `HTTP/1.1 100 Continue\r\n\r\n` to `oc` and flushes (once, guarded by a `wrote` ref), then calls the underlying `inner ()` to read the body. Empty/String bodies are left untouched (they never occur when `content_length<>0`). This is the OCaml analogue of Go's `expectContinueReader.Read` (server.go:964-983), in the same one-shot-side-effect-on-pull shape as `Client.wrap_timer_body` / the Ticket 1 `wrap_read_timeout_body`.
  - New `write_expectation_failed oc`: writes `HTTP/1.1 417 Expectation Failed` + the shared `error_headers` (which already include `Connection: close`) + a short body, then flush — Go's `response.sendExpectationFailed` (server.go:2236-2252) which sets `Connection: close`, writes 417, and does not run the handler.
  - `serve_loop` (the unified per-connection dispatch path from Ticket 1): after setting `req_ctx` and BEFORE the read-timeout body wrap / dispatch, port server.go:2089-2101 — if `Request.expects_continue r`: when `proto≥1.1 && content_length<>0L`, apply `wrap_expect_continue_body oc r` (and continue normally); else if the `Expect` header is non-empty (any other value), `write_expectation_failed oc`, cancel the request context, and return without dispatching (the connection then closes via `serve_loop`'s finalizer — `Connection: close`). Requests with no `Expect` header take the unchanged path.
  - **Wrapper composition (the design ask):** `wrap_expect_continue_body` is applied FIRST (it becomes `r.body`), then `wrap_read_timeout_body conn_ctx ~secs:to_read r` wraps THAT. So a body pull goes: read-timeout race → expect-continue thunk (writes 100 on first pull) → real body reader. This orders the 100-continue write to fire on the first *real* body pull, still bounded by the whole-request read deadline. When `read_timeout` is 0 (default) the read-timeout wrapper is a no-op and the expect-continue wrapper stands alone.
- `test/test_abuse.ml`: added `expect_100_continue` and `expect_unknown` (raw-loopback integration, bounded by `Net.with_timeout`), plus a `read_all_until_eof` helper. Wired both into the `tests` list. (No change to `test/test_gohttp.ml` — the `Abuse` suite was already aggregated by Ticket 1.)

**Precedent followed**
- `Client.wrap_timer_body` (`client.ml:164-180`) and the Ticket 1 `wrap_read_timeout_body` (`server.ml:797`) — wrap a `Body.Stream` thunk with a one-shot side-effect on pull. Mirrored exactly in `wrap_expect_continue_body`. **Verified against Go:** Go's `expectContinueReader.Read` (server.go:969-983) writes `"HTTP/1.1 100 Continue\r\n\r\n"` + `Flush` guarded by a `canWriteContinue` once-flag on the first body read; the OCaml `wrote` ref reproduces the once-semantics, and the wrap-before-dispatch + lazy-write-on-pull matches server.go:2091-2095. No correction to the precedent was needed.
- `Transfer.has_token` (`transfer.ml:169`) reused for `expects_continue`. **Verified against Go:** it is a faithful port of `header.go:240` `hasToken` (case-insensitive, token-boundary aware via `isTokenBoundary`). No correction needed.

**Test-determinism adaptation**
- The "lazy vs eager" assertion is made deterministic by the socket ordering itself: the client sends only the request headers (with `Expect: 100-continue` + `Content-Length: 5`), withholds the body, then blocks reading the status line. The interim `HTTP/1.1 100 Continue` line can only arrive once the handler pulls the body (the wrapper writes it on first pull), so receiving the 100 line at all proves it was emitted lazily after dispatch — and a non-lazy server that withheld 100 until something else would hang, failing the bound. The client then sends the body and reads exactly one Content-Length-framed response (via `read_one_response`, not EOF) because the echo response is keep-alive — the only adaptation vs. a naive read-to-EOF, since the connection is not closed after a successful 100-continue exchange. The `expect_unknown` test reads to EOF, which is correct there because the 417 carries `Connection: close`.

**Alcotest tail**
```
  [OK]          Abuse                  11   accepts_valid_host_and_headers.
  [OK]          Abuse                  12   expect_100_continue.
  [OK]          Abuse                  13   expect_unknown.

Test Successful in 2.265s. 518 tests run.
```
`dune build` clean (warnings-as-errors), `dune fmt` applied, full `dune test --force` green (518 tests: 516 prior + 2 new).

**Commit:** `xnuwpvmy` (`feat(server): honor Expect: 100-continue lazily, 417 on unknown Expect`).

---

### Ticket 6 — Client `MaxResponseHeaderBytes` (Case 14)
Status: Done

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

**What changed**
- `lib/io.ml`:
  - New internal sentinel `exception Response_header_too_large` + `response_header_too_large_sentinel` alias — the client-side mirror of T2's `Request_too_large`, declared before `type error` (whose `Response_header_too_large` arm shadows the name) so the deep parse path can raise it; caught at the boundary in `error_of_exception` and mapped to the `error` arm. Distinct sentinel from `Request_too_large` so the client surfaces its own typed error (not the server-side 431 path).
  - New `Io.error` arm `Response_header_too_large` with `error_to_string` = `"net/http: server response headers exceeded MaxResponseHeaderBytes; aborted"` (Go's `transport.go:2506` message, dropping only the `%d bytes` byte count which is not available at the boundary).
  - `read_response_raising` gains `?max_header_bytes`: allocates `Some (ref (n + 4096))` (the same `initialReadLimitSize`/bufio-slop shape as `read_request_raising`, Go's `pc.readLimit`) and passes the shared T2 `?limit` ref to BOTH the status-line `read_line` and the header-block `read_mime_header_raising`, so the status line + all header lines are bounded cumulatively against one budget. The shared `read_line` budget raises `Request_too_large`; `read_response_raising` catches that at both read points and re-raises `Response_header_too_large` so the error type is correct on the client side (this is the same remap idiom `read_trailer` uses to turn `Request_too_large` into `Trailer_too_large`).
  - Boundary wrapper `read_response : ?request -> ?max_header_bytes -> ...` forwards to the raising core.
- `lib/io.mli`: documented the new `Response_header_too_large` boundary-error arm and `?max_header_bytes` on `read_response` (kept in sync).
- `lib/transport.ml`:
  - `Transport.t` gains `max_response_header_bytes : int`; `create` gains `?max_response_header_bytes` defaulting to `default_max_response_header_bytes = 10 lsl 20` (Go's `DefaultMaxResponseHeaderBytes`, transport.go:337-340).
  - The response read site (`exchange` inside `round_trip`) passes `~max_header_bytes:t.max_response_header_bytes` into `Io.read_response`.
  - **Error surfacing:** no new boundary mapping was needed — the existing `or_raise` at the read site already maps ANY `Io.error` (now including `Response_header_too_large`) into `Lwt.fail (Io.Protocol_error (Io.error_to_string e))`, which rides the transport's established exception-based round-trip-failure flow (the retry/close-conn machinery). So an oversized response head fails the round trip with the modeled message text rather than hanging or OOMing.
- `lib/transport.mli`: documented `?max_response_header_bytes` on `create` (kept in sync).
- `lib/server.ml`: added `Io.Response_header_too_large` to `write_read_error_response`'s catch-all 400 arm purely to keep the match exhaustive under warnings-as-errors — it is a client-side error that can never arise on the server's `read_request` path (commented as such).
- `test/test_abuse.ml`: added `response_header_too_large` and `response_header_under_limit_ok`, both driving a RAW `Net.listen`/`Net.accept` loopback server (not a gohttp `Server`, so it can emit malicious bytes) against a `Client` backed by `Transport.create ~max_response_header_bytes:8192`, all bounded by `Net.with_timeout 5.`. Added a `with_raw_server` helper (single-shot accept + serve, listener/conn torn down in `finalize`). The too-large test asserts the round trip fails with an exception whose message contains `MaxResponseHeaderBytes` (not a hang/OOM); the ok test asserts 200 + intact body.

**Precedent followed**
- **Response-side mirror of T2.** Reused T2's `read_line ?limit` / `read_mime_header_raising ?limit` shared mutable byte budget (`int ref`) verbatim and the `io.ml` sentinel→`error` boundary (`error_of_exception`/`to_result`) — added `Response_header_too_large` exactly as T2 added `Request_too_large` (raised deep, mapped once at the boundary), and remapped `Request_too_large`→`Response_header_too_large` at the two read points the same way `read_trailer` remaps it to `Trailer_too_large`. **Verified against Go:** Go bounds the response head with `pc.readLimit = t.maxHeaderResponseSize()` set before `readResponse` and surfaces `errTooLarge`/the `MaxResponseHeaderBytes` message at `transport.go:2504-2507`; the default is `DefaultMaxResponseHeaderBytes = 10<<20` applied when the field is zero (`transport.go:337-340`). The shared-ref-across-status-line-and-headers budget reproduces `pc.readLimit` bounding the whole head. No correction to the T2 precedent was needed.
- **Transport `Io`-error mapping at the read site.** Followed the existing `or_raise` (`lib/transport.ml`) which already converts every `Io.error` into `Io.Protocol_error (Io.error_to_string e)` and lets it ride the transport's exception-based failure flow — no bespoke mapping added.

**Alcotest tail**
```
  [OK]          Abuse                  14   response_header_too_large.
  [OK]          Abuse                  15   response_header_under_limit_ok.

Test Successful in 2.237s. 520 tests run.
```
`dune build` clean (warnings-as-errors), `dune fmt` applied, full `dune test --force` green (520 tests: 518 prior + 2 new).

**Commit:** `yrolkqzz` (`feat(transport): bound response head with MaxResponseHeaderBytes`).

---

### Ticket 7 — Client sticky / subdomain-aware redirect header stripping + Referer (Case 15)
Status: Done

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

**What changed**
- `lib/client.ml`:
  - New pure helper `is_domain_or_subdomain ~sub ~parent` — a faithful port of Go's `isDomainOrSubdomain` (client.go:1026-1048): exact match → true; a `:` or `%` in `sub` (IPv6 literal/zone) → false; else `sub` must end in `"." ^ parent` (`String.length sub > String.length parent` + suffix-equal + the char before the suffix is `.`). Mirrors `strings.HasSuffix(sub, parent) && sub[len-len(parent)-1] == '.'` exactly (the `ls > lp` guard reproduces Go's behavior — `HasSuffix` is true for `sub == parent` but that is handled by the earlier exact-match branch, and the `[ls-lp-1]` index requires `ls > lp`).
  - New `should_copy_header_on_redirect ~initial ~dest` = `is_domain_or_subdomain ~sub:(url_host dest) ~parent:(url_host initial)` (client.go:1008-1024). **IDNA simplification (recorded):** Go runs both hosts through `idnaASCIIFromURL` (transport.go:3187 → request.go:786 `idnaASCII`), which for already-ASCII hosts returns them unchanged (the `ascii.Is(v)` fast path). This repo has no IDNA helper, so it uses the raw `Uri.host` (= Go's `url.Hostname()`, no port) directly — exactly Go's no-error fallback for ASCII hosts. The suffix/`.`/IPv6 logic is byte-for-byte. Non-ASCII IDN hosts would not be punycode-normalized, the one divergence, noted inline.
  - New `referer_for_url ~last ~next ~explicit` — port of `refererForURL` (client.go:147-170): `None` (omit) when `last` is https and `next` is http; else the user's `explicit` Referer if set on the original request; else `last` with userinfo stripped via `Uri.with_userinfo last None` (Go's `lastReq.String()` minus `user:pass@`).
  - `do_one` gains an optional `?round_trip` per-hop round-tripper (default: `Transport.round_trip c.transport`), exposed as a test seam so the redirect loop can be driven against a header-capturing stub without DNS.
  - **The fix:** replaced the per-hop, non-sticky, exact-string `let strip_sensitive = url_host loc_url <> initial_host` with a sticky `bool ref` (init `false`) carried across the loop, computed **initial-vs-dest** exactly as Go (client.go:691-694): `if (not !strip_sensitive) && url_host initial_req.url <> url_host loc_url && not (should_copy_header_on_redirect ~initial:initial_req.url ~dest:loc_url) then strip_sensitive := true`, where `initial_req = List.hd via` (Go's `reqs[0]`). Once latched it never resets (sticky across a bounce-back). `copy_headers` is called with `~strip_sensitive:!strip_sensitive` — unchanged otherwise. The now-unused `initial_host` binding was removed.
  - **Referer (independent, previous-hop):** after copying headers, sets `Referer` from `referer_for_url ~last:req.url ~next:loc_url ~explicit:explicit_referer` (client.go:698, using `reqs[len-1].URL` = the request just made = `req`), omitting it on https→http. `explicit_referer` captures any Referer the user set on the original request.
- `lib/client.mli`: documented the three new public helpers (`is_domain_or_subdomain`, `should_copy_header_on_redirect`, `referer_for_url`) and the `?round_trip` seam on `do_one` (kept in sync; all genuine Go ports, cited).
- `test/test_abuse.ml`: added `redirect_strip_sticky_on_bounce_back`, `redirect_keeps_header_on_subdomain`, `redirect_referer_https_to_http`, all driving `Client.do_one ~round_trip` against a stub that records per-hop headers and returns canned 302 redirects (a `stub_response` builder sets `resp.request <- Some req` so `Response.location` resolves; absolute Location URLs keep cross-host hosts). Bounded by `Net.with_timeout`.

**Precedent followed**
- **`copy_headers` / `sensitive_header`** (client.ml:71,:85) kept as-is — the header lists already match Go (client.go:817-821) verbatim; only the `strip_sensitive` flag computation changed. **Verified against Go:** the strip lists and the 10-redirect cap were confirmed faithful; no correction needed.
- The earlier draft's per-hop exact-string strip (`url_host loc_url <> initial_host`, non-sticky) was the **bug** this ticket corrects — confirmed against client.go:691-694 that Go compares the *initial* request host to the destination with a *sticky latch* and a *subdomain-aware* `shouldCopyHeaderOnRedirect`, not previous-vs-next exact-string. No existing test encoded the old behavior, so no test had to be weakened.

**No existing test adjusted** — there were no prior client redirect tests (grep of `test/` for redirect/Location/Authorization found only fs/response cases, none asserting the strip behavior).

**Alcotest tail**
```
  [OK]          Abuse                  16   redirect_strip_sticky_on_bounce_b...
  [OK]          Abuse                  17   redirect_keeps_header_on_subdomain.
  [OK]          Abuse                  18   redirect_referer_https_to_http.

Test Successful in 2.286s. 523 tests run.
```
`dune build` clean (warnings-as-errors), `dune fmt` applied, full `dune test --force` green (523 tests: 520 prior + 3 new).

**Commit:** `okuyxtor` (`feat(client): sticky subdomain-aware redirect header strip + Referer`).

---

### Ticket 8 — HTTP/2 rapid-reset backlog cap (Case 9, CVE-2023-44487)
Status: Done

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

**What changed**
- `lib/internal/http2/h2_server.ml`:
  - `serverConn.unstarted` changed from a `(int * (unit -> unit Lwt.t)) list` (appended with the O(n) `sc.unstarted @ [..]`) to a FIFO `(int * (unit -> unit Lwt.t)) Queue.t`. Under a rapid-reset flood this list churned hot; `Queue.add`/`Queue.pop` are O(1) and preserve the FIFO drain order. Initializer is now `Queue.create ()`.
  - `schedule_handler` now returns `(unit, H2_error.err_code) result` (was `unit`). It mirrors Go's `scheduleHandler` (server.go:2254-2273): if `cur_handlers < adv_max_streams` it starts the handler fiber and returns `Ok ()`; **else if `Queue.length sc.unstarted > 4 * sc.adv_max_streams`** it returns `Error H2_error.EnhanceYourCalm` (Go's `ConnectionError(ErrCodeEnhanceYourCalm)`, server.go:2263); otherwise it `Queue.add`s the entry and returns `Ok ()`. The comparison matches Go's `> int(4*sc.advMaxStreams)` exactly.
  - `handler_done_serve` rewritten to drain the `Queue` (was a recursive list rebuild): pop from the front, skip-and-drop streams that were reset before their fiber started (`not (Hashtbl.mem sc.streams sid)`), start handlers up to `adv_max_streams`, and stop (leaving the remainder queued) once at the limit. Same FIFO semantics and reset-skip as before and as Go's `handlerDone` (server.go:2275-2297).
  - The single call site in `process_headers` (the `Ok (req, _)` branch) now returns `schedule_handler sc st req rw rws` directly instead of discarding its result and returning `Ok ()`. The error therefore rides the existing `process_headers` → `outcome_of_result` → `Conn_error code` → `go_away sc code` path verbatim (no bespoke teardown).
- `lib/internal/http2/h2_server.mli`: no change needed — `schedule_handler`/`handler_done_serve`/`unstarted` are internal (not exposed in the `.mli`).
- `test/test_abuse.ml`: added `too_many_early_resets` (wired into the `Abuse` suite), driven over the same in-memory `Lwt_io.pipe` + raw `H2_frame`/`Hpack` framer harness as `test/test_h2_server.ml`, bounded by `Net.with_timeout 15.`.

**Precedent followed**
- The connection-error → GOAWAY path: handlers/processors return `Error H2_error.X`, `outcome_of_result` (h2_server.ml ~:1037) turns it into `Conn_error code`, and `go_away` (~:367) emits the GOAWAY. The refused-stream over-limit case (~:814, `RefusedStream`) and the `>100` SETTINGS count check are the concrete sibling models. `schedule_handler` was made to return the same `Error H2_error.X` so it flows through unchanged. **Verified against Go** (`go/src/net/http/internal/http2/server.go:2254-2297`): the cap (`len(sc.unstartedHandlers) > int(4*sc.advMaxStreams)` → `ConnectionError(ErrCodeEnhanceYourCalm)`), the FIFO drain, and the reset-stream skip all match. The `EnhanceYourCalm` variant (0xb) in `h2_error.ml` was previously defined-but-unused; it is now wired. No precedent correction was required.

**Data-structure change:** `sc.unstarted` is now a `Queue.t` (was a list with O(n) append). FIFO drain order preserved; the drain still drops reset streams and starts up to `adv_max_streams`.

**Test harness used:** `test/test_h2_server.ml`'s in-memory full-duplex `Lwt_io.pipe` pair driving `H2_server.serve` with a hand-built H2 client (preface + `H2_frame.write_settings`/`write_headers`/`write_rst_stream`, `Hpack` encoder). The new test reuses that idiom: `serve ~max_concurrent_streams:1`, a blocking handler (parked on a never-resolved `Lwt.wait ()`) on the first stream to pin `cur_handlers` at `adv_max_streams`, that first stream then reset (so `cur_client_streams` drops back, keeping later opens from being REFUSED), then a flood of 20 open+RST_STREAM pairs; the test reads frames until a GOAWAY and asserts its code is `ENHANCE_YOUR_CALM`. This adapts Go's `testServerMaxHandlerGoroutines` (server_test.go:4257-4356) to the Lwt harness (no synctest channels).

**Alcotest tail**
```
  [OK]          Abuse                  19   too_many_early_resets.

Full test results in `~/workspace/gohttp/_build/default/test/_build/_tests/gohttp'.
Test Successful in 2.272s. 524 tests run.
```
`dune build` clean (warnings-as-errors), `dune fmt` applied, full `dune test --force` green (524 tests: 523 prior + 1 new).

**Commit:** `pvmotnlq` (`feat(h2): cap rapid-reset handler backlog with ENHANCE_YOUR_CALM`).

---

### Ticket 9 — HTTP/2 MAX_HEADER_LIST_SIZE advertise/derive + HPACK per-string cap + Huffman bound (Case 11)
Status: Done

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

**What changed**
- `lib/internal/http2/h2.ml`/`.mli`: new constant `H2.default_max_header_bytes = 1 lsl 20` (Go's `DefaultMaxHeaderBytes`, server.go:497), used as the default advertised `SETTINGS_MAX_HEADER_LIST_SIZE` and the HPACK decode budget.
- `lib/internal/http2/h2_server.ml`/`.mli`: `serve` gains `?max_header_bytes` (default `H2.default_max_header_bytes`; a non-positive value falls back to the default — mirrors Go's `serverConn.maxHeaderListSize`, server.go:499-505). New `server_conn.adv_max_header_list_size` field. The initial SETTINGS frame now includes `{ id = Max_header_list_size; value = adv_max_header_list_size }` (placed after `Max_concurrent_streams`, matching server.go:774-779). The `read_meta_headers` call in `read_loop` now passes `~max_header_list_size:sc.adv_max_header_list_size` (was using the function's default).
- `lib/internal/http2/h2_frame.ml`/`.mli`: `read_meta_headers`/`read_meta_headers_raising` default for `?max_header_list_size` changed from `16 lsl 20` to `H2.default_max_header_bytes` (`1 lsl 20`) — the **divergence-from-Go correction** (Go's default is 1 MiB, not 16 MiB). The decoder per-string cap is still wired to `max_header_list_size` via `Hpack.set_max_string_length` — this is faithful: Go sets `SetMaxStringLength(maxHeaderStringLen())` where `maxHeaderStringLen() == maxHeaderListSize()` (frame.go:1697-1704,:1722). The `.mli` doc that wrongly claimed "16MB (Go's default)" was corrected.
- `lib/internal/http2/hpack_huffman.ml`/`.mli`: `decode` gains `?max_len`; `huffman_decode` now errors with the new `String_too_long` variant the moment the output buffer reaches `max_len` bytes (Go's `huffmanDecode(buf, maxLen, v)`, huffman.go:49,:67-68,:87-88), so an oversized compressed string is rejected **without** a large transient allocation. `error` gains `String_too_long` (Go's `ErrStringLength`).
- `lib/internal/http2/hpack.ml`: `decode_string` now passes `~max_len:d.max_str_len` to `Huff.decode` and maps `String_too_long` to the existing `String_too_long_sentinel` (→ `Hpack.String_too_long` at the boundary, faithful to Go hpack.go:516). Removed the stale comment flagging the unbounded Huffman path.
- `lib/server.ml`: the public `Server`'s `max_header_bytes` (the T2 field, default `1 lsl 20`) is now threaded into `Gohttp_http2.H2_server.serve ~max_header_bytes` at the ALPN "h2" boundary — so the same server knob derives both the h1 head budget and the h2 `MAX_HEADER_LIST_SIZE`, mirroring Go (`sc.maxHeaderListSize()` derives from `sc.hs.MaxHeaderBytes()`, server.go:499-505). Public wiring is NOT deferred.
- `test/test_hpack_tables.ml`: existing exhaustive matches on `Hpack_huffman.error` extended for the new `String_too_long` arm (both treat it as an unexpected failure for those invalid-Huffman cases).
- `test/test_abuse.ml`: three new tests (below).

**Open question resolution (recorded)**
- **Per-string vs list-size relationship:** kept per-string cap == list cap, which is exactly Go (`maxHeaderStringLen() == maxHeaderListSize()`, frame.go:1697-1704). The plan's "mis-wired to 16 MiB" was really a **wrong default** (16 MiB vs Go's 1 MiB), not a wrong *relationship*. Fixed the default to `1 lsl 20`. The cap is now derived from the configurable `max_header_bytes` (Go derives it from `MaxHeaderBytes()`), so the two remain a single source of truth, faithfully, rather than two unrelated constants.
- **Bound Huffman by length vs tightened post-decode check:** chose to **bound the Huffman decode by length** (`?max_len`), matching Go's `huffmanDecode(buf, maxLen, v)` exactly — it errors at the moment the output reaches `maxLen`, so the transient allocation is bounded by `maxLen` and never the full decompressed size. A post-decode check would have allowed an unbounded transient allocation first (the very OOM this ticket closes), so it was rejected.
- **Chosen values:** list size (and thus per-string cap) default = `1 lsl 20` (1 MiB), matching Go's `DefaultMaxHeaderBytes`. This is the safe, faithful gohttp default; it is configurable per-server via `Server.create ~max_header_bytes` / `H2_server.serve ~max_header_bytes`.

**Precedent followed**
- **Initial-SETTINGS construction + `Max_header_list_size` setting-id handling** (h2_server.ml `serve`, and the SETTINGS write path): added the advertised setting alongside the existing `Max_frame_size`/`Max_concurrent_streams`/... entries, not as a new subsystem. **Verified against Go** (server.go:774-779): Go advertises `SettingMaxHeaderListSize, sc.maxHeaderListSize()` in its initial `writeSettings`. Faithful.
- **CONTINUATION-flood `2*remainSize` bound** (h2_frame.ml `read_meta_headers_raising` loop): the incremental list-size enforcement was already present and faithful (`frag > 2 * !remain_size -> ProtocolError`, frame.go:1774); I only corrected its *default* budget. No logic correction needed there.
- **Sentinel→boundary error idiom in `hpack.ml`** (`String_too_long_sentinel` → `Hpack.String_too_long`): the new Huffman `String_too_long` rides the existing `error_of_exception` boundary exactly like `Invalid_huffman`. Faithful to Go's `ErrStringLength` propagation (hpack.go:516).
- **Correction made:** the `read_meta_headers` default of `16 lsl 20` (and its `.mli` doc claiming that was "Go's default") diverged from Go's actual 1 MiB default — corrected to `H2.default_max_header_bytes` and the doc fixed, per the workflow's "fix the precedent if it diverges" rule.

**Tests added** (`test/test_abuse.ml`)
- `advertises_max_header_list_size`: starts `H2_server.serve ~max_header_bytes:4096` over the in-memory pipe harness, reads the server's first SETTINGS frame, asserts a `Max_header_list_size` entry with value `4096`.
- `rejects_header_list_bomb`: `~max_header_bytes:256`; sends one HEADERS frame carrying a ~4 KiB header value; asserts the server GOAWAYs with `PROTOCOL_ERROR` (the assembled fragment exceeds `2 * remain_size`, frame.go:1774).
- `huffman_string_cap`: an HPACK unit test — hand-builds a literal-header-without-indexing wire block whose value is a Huffman-coded run that decodes to `cap+8` bytes while the *encoded* wire form stays `<= cap` (so the encoded-length check passes and the cap must be enforced during Huffman decode); feeds it to a decoder with `set_max_string_length cap`; asserts `Error Hpack.String_too_long`.

**Alcotest tail**
```
  [OK]          Abuse                  19   too_many_early_resets.
  [OK]          Abuse                  20   advertises_max_header_list_size.
  [OK]          Abuse                  21   rejects_header_list_bomb.
  [OK]          Abuse                  22   huffman_string_cap.

Test Successful in 2.249s. 527 tests run.
```
`dune build` clean (warnings-as-errors), `dune fmt` applied, full `dune test --force` green (527 tests: 524 prior + 3 new).

**Commit:** `qrttunxr` (`feat(h2): advertise/derive MAX_HEADER_LIST_SIZE + bound HPACK strings`).

---

### Ticket 10 — HTTP/2 duplicate-SETTINGS rejection (Case 12)
Status: Done

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

**What changed**
- `lib/internal/http2/h2_frame.ml`: new `settings_has_duplicates : settings_frame -> bool`, placed right after the `settings_frame` type. Mirrors Go's `SettingsFrame.HasDuplicates` (frame.go:832-850): scans the `settings` list for any repeated `s.id` (an O(n²) `List.exists` over the tail of each element — Go's small-frame n² path, fine here since the count is already capped at 100).
- `lib/internal/http2/h2_frame.mli`: added the `settings_has_duplicates` signature with a doc comment citing Go.
- `lib/internal/http2/h2_server.ml` `process_settings` (the non-ack branch, was the `> 100` guard): changed to `if List.length sf.settings > 100 || H2_frame.settings_has_duplicates sf then Error H2_error.ProtocolError`, with a comment citing server.go:1616-1620. This rides the existing `outcome_of_result`→`Conn_error`→`go_away` path unchanged, exactly like the sibling count check.
- `test/test_abuse.ml`: added `rejects_duplicate_settings` and `accepts_distinct_settings`, both using the existing in-memory `h2_duplex`/raw-framer harness, bounded by `Net.with_timeout`. Wired both into the `Abuse` `tests` list.

**Precedent followed**
- The `> 100` count check in `process_settings` (`h2_server.ml`, the sibling guard in the same non-ack branch). It already returns `Error H2_error.ProtocolError`; the duplicate check was added on the same `||` expression, in the same form, citing the same Go lines. **Verified against Go** (`go/src/net/http/internal/http2/server.go:1616-1620`): the guard is literally `if f.NumSettings() > 100 || f.HasDuplicates()`, so combining both into one `if ... then Error ProtocolError` is faithful. The `HasDuplicates` helper mirrors `frame.go:832-850` (n² scan over setting IDs). No precedent divergence found; no correction needed. `H2_error.ProtocolError` already maps to the GOAWAY `PROTOCOL_ERROR` wire code via the existing serve-loop conversion.

**Test note:** the harness's normal handshake sends an *empty* SETTINGS frame, and the server's own initial SETTINGS uses distinct IDs — neither trips the new check. The duplicate-rejection test deliberately puts both repeated entries in a *single* frame (two `Initial_window_size` entries); the accepts-distinct test sends three distinct IDs in one frame and then completes a GET (status 200, no GOAWAY) as the negative control.

**Alcotest tail**
```
  [OK]          Abuse                  23   rejects_duplicate_settings.
  [OK]          Abuse                  24   accepts_distinct_settings.

Test Successful in 2.296s. 529 tests run.
```
`dune build` clean (warnings-as-errors), `dune fmt` applied, full `dune test --force` green (529 tests: 527 prior + 2 new).

**Commit:** `olxqvkmy` (`feat(h2): reject duplicate-SETTINGS frames with PROTOCOL_ERROR`).

---

### Ticket 11 — HTTP/2 flow-control overflow modeled as connection error (Case 13)
Status: Done

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

**Step-2 finding (would it crash the fiber?): IT WOULD CRASH THE FIBER.**
- `inflow_add`'s overflow raised `invalid_arg` (h2_flow.ml:31). Its callers `send_window_update_conn`/`send_window_update_stream` (h2_server.ml:324,:339) are invoked **synchronously** from `process_data` (via `process_frame`, the `Read_frame` arm of `serve_loop`, h2_server.ml:1170) and directly from the `Body_read` arm (h2_server.ml:1193-1195). Neither path was wrapped in a `Lwt.catch`. `serve_loop` is wrapped only in `Lwt.finalize` (h2_server.ml:1309), which runs cleanup and **re-raises** — so an `inflow_add` overflow would reject the connection fiber's promise with `Invalid_argument` after running teardown, i.e. an unclean crash with **no GOAWAY emitted**. (The reader fiber's `Lwt.catch` at :1087 only covers wire reads, not the synchronous serve-loop frame processing.) So this was a correctness fix, not just a rename.

**Go-fidelity audit (the important correction to the plan's premise).**
- Verified against `go/src/net/http/internal/http2/flow.go`: `inflow.add`'s `panic("flow control update exceeds maximum window size")` (flow.go:42) is a genuine **panic / invariant**, NOT `ConnectionError(ErrCodeFlowControl)`. It returns flow control we previously *took* via `inflow.take` (itself capped), so a conformant peer can never trip it.
- The actual malicious-peer flow-control-overflow `ConnectionError(ErrCodeFlowControl)` lives on **two** paths, both of which gohttp **already** models correctly: (1) inbound DATA over the window — `inflow.take`/`takeInflows` false → `streamError`/`ConnectionError` (server.go:1444,:1732,:1749,:1762) ⇒ gohttp `process_data` already returns `Error H2_error.FlowControlError` (h2_server.ml:857-915); (2) a bogus peer **WINDOW_UPDATE** overflowing the *outbound* window — `flow.add` false → `ConnectionError(ErrCodeFlowControl)` (server.go:1525-1529,:1686-1693) ⇒ gohttp `process_window_update` already returns `Error H2_error.FlowControlError` (h2_server.ml:998-1007), riding `outcome_of_result`→`Conn_error`→`go_away`. Go's overflow test `TestServer_Send_GoAway_After_Bogus_WindowUpdate` (server_test.go:1354-1365) exercises exactly path (2) and already passed here.
- So the only remaining gap was the `inflow_add` invariant-overflow surfacing as an uncaught `invalid_arg`. Resolution honoring both Go and the repo's error policy: surface it as the modeled `H2_error.Connection_error H2_error.FlowControlError` (a typed connection error) and make the synchronous serve-loop paths route it to the **existing** `Conn_error`→`go_away` GOAWAY flow, so even this can't-happen invariant terminates the connection cleanly with `FLOW_CONTROL_ERROR` instead of crashing the fiber.

**What changed**
- `lib/internal/http2/h2_flow.ml`: `inflow_add`'s overflow now `raise (H2_error.Connection_error H2_error.FlowControlError)` instead of `invalid_arg`. The negative-update guard stays `invalid_arg` (Go's `panic("negative update")` — a real programming bug). Detection logic unchanged. (flow.go:42)
- `lib/internal/http2/h2_flow.mli`: documented the new raise behavior of `inflow_add` (negative → `Invalid_argument`; window overflow → `H2_error.Connection_error FlowControlError`).
- `lib/internal/http2/h2_server.ml`: the two synchronous serve-loop arms that can hit `inflow_add` (`Read_frame` → `process_frame`, and `Body_read` → `send_window_update_*`) now `try ... with H2_error.Connection_error code -> Conn_error code`, so a raised modeled connection error routes to the existing `go_away`/`finish_or_continue` path. No parallel teardown; reuses the `process_window_update` mechanism exactly. maxConcurrentStreams logic untouched.
- `test/test_h2_flow.ml`: `test_inflow_add_overflow` now expects `H2_error.Connection_error H2_error.FlowControlError` (was `Invalid_argument "..."`). This is a porting-artifact fix: Go's `inflow.add` panics (not a typed error), and Ticket 11 deliberately changes how the overflow is surfaced, so the unit test's expectation is updated to match the new modeled error.
- `test/test_abuse.ml`: added `h2_flow_control_overflow_goaway` and `h2_max_concurrent_streams_refused` to the `Abuse` suite (reusing the existing `h2_duplex`/`h2_request_block`/`h2_open`/`read_until_goaway` harness; added a `read_until_rst` helper).

**Tests added**
- `h2_flow_control_overflow_goaway` (mirrors Go's `TestServer_Send_GoAway_After_Bogus_WindowUpdate`, server_test.go:1354-1365): client sends `WINDOW_UPDATE(stream 0, 2^31-1)` after the handshake; asserts the server GOAWAYs with `FLOW_CONTROL_ERROR` **and** that the serve fiber terminates cleanly (the `serve` promise resolves within 1s, proving no crash).
- `h2_max_concurrent_streams_refused` (regression — **not** previously covered in `test_abuse.ml`; only enum/encoding unit tests existed in `test_h2.ml`): with `~max_concurrent_streams:1`, stream 1 kept open (blocking handler) and stream 3 opened over the limit; asserts an `RST_STREAM` for stream 3 with `REFUSED_STREAM`. Added to lock in the already-faithful behavior (logic unchanged).

**Precedent followed**
- `process_window_update`/`process_settings` → `outcome_of_result` → `Conn_error` → `go_away` (h2_server.ml:1046-1048,:1064-1066,:1174-1177,:354). The modeled overflow error rides this identical path. **Verified against Go (flow.go, server.go) — see the Go-fidelity audit above.** The plan's premise ("flow-control overflow surfaces as `invalid_arg`") was true only for the can't-happen `inflow_add` invariant; the genuine malicious-peer overflow GOAWAY was already faithful and required no change. No precedent needed correcting; the plan's framing was refined (recorded above).

**Alcotest tail**
```
  [OK]          Abuse                  25   h2_flow_control_overflow_goaway.
  [OK]          Abuse                  26   h2_max_concurrent_streams_refused.

Test Successful in 2.248s. 531 tests run.
```
Plus `H2Flow` suite green (incl. the updated `inflow_add_overflow`). `dune build` clean (warnings-as-errors), `dune fmt` applied, full `dune test --force` green (531 tests: 529 prior + 2 new).

**Commit:** `lzsmymzk` (`feat(h2): model flow-control overflow as FLOW_CONTROL_ERROR GOAWAY`).
