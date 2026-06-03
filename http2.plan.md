# gohttp — HTTP/2 (with TLS/ALPN) — Plan

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

- **Goal:** Add **HTTP/2** (RFC 7540 + HPACK RFC 7541) to gohttp — server and client — negotiated over **TLS via ALPN** ("h2"), faithful 1:1 to Go's implementation, reusing the existing `Request`/`Response`/`Header`/`Body` types and wiring into the existing `Server`/`Client`/`Transport` so a caller transparently gets HTTP/2 when the peer supports it (with HTTP/1.x fallback).
- **Success Criteria (as tests):**
  - *Unit:* `Hpack.roundtrip` — encode a header list with the HPACK encoder, decode with the decoder, assert equality incl. dynamic-table behavior, against RFC 7541 appendix examples (ported from `hpack_test.go`). `Frame.roundtrip` — write each frame type with the `Framer` and read it back, asserting fields (ported from `frame_test.go`).
  - *Integration:* `H2.clientserver_roundtrip` — start a gohttp server with TLS+ALPN advertising `h2`, connect with the gohttp client forcing `h2`, perform a GET and a POST over a single multiplexed connection, assert `:status` 200 + body equality (mirrors `internal/http2` server/transport tests).
- **Non-Goals:** HTTP/3/QUIC; Server Push (`PUSH_PROMISE` send path — parse/ignore is fine); RFC 9218 priority scheduler (round-robin scheduler only); the legacy `Dial`/proxy/`OnProxyConnectResponse` paths; `h2c` cleartext upgrade is **optional/stretch** (TLS-ALPN is the required path). Continue to exclude HTTP/3.
- **Constraints:** OCaml ≥ 5.0, dune ≥ 3.0. Reuse existing deps (`lwt lwt.unix uri tls-lwt base64 multipart_form-lwt`) — `tls`/`tls-lwt` already support ALPN config and server certificates; `x509` can mint a self-signed cert for tests. Pure codec modules (hpack, frame) must not depend on Lwt. Cross-reference every module against its Go source under `go/src/net/http/internal/http2/*.go` and `go/src/vendor/golang.org/x/net/http2/hpack/*.go`. **When a ported test fails, fix the implementation, not the test** (unless a documented Go-specific porting artifact).
  - **Every `lib/` module MUST have a hand-written `.mli`.**
  - **Mirror Go's data structures** (map→`Hashtbl`, slices→lists/arrays, ring buffers/queues as Go has them).
  - **Layout:** HTTP/2 lives **in the `gohttp` library** (flat files, `h2_`/`hpack_` prefixes) because it shares the core `Request`/`Response`/`Header` types and is wired into `Server`/`Client` — exactly as Go bundles `internal/http2` into `net/http`. Avoid module cycles: the h2 server/transport take the handler / round-trip pieces they need as parameters or depend on lower modules; `Server`/`Client` depend on the `H2_*` modules, never the reverse.

## Discovery

- **Current state:** HTTP/1.0+1.1 is fully ported and green (262 tests) on this branch — see `work.plan.md` Tickets 1–12b. Relevant existing modules the h2 layer composes with: `Header` (`(string,string list) Hashtbl.t`), `Body` (`Empty | String | Stream`), `'body Request.t` / `'body Response.t` (records with `meth`/`url`/`header`/`body`/`proto*`/`ctx`…), `Server` (`handler`, `response_writer`, `listen_and_serve`), `Client`/`Transport` (`round_trip`, `?context`), `Net` (`listen`/`accept`/`connect ?tls`/`channels_of_fd`/`with_timeout`; TLS client uses a documented null authenticator; **no server-side TLS yet**), `Context`, private internal lib `gohttp_internal` (`Chunked`, `Ascii`).
- **Go source layout (the spec):**
  - HPACK: `go/src/vendor/golang.org/x/net/http2/hpack/` — `huffman.go`, `static_table.go`, `tables.go`, `encode.go`, `hpack.go` (decoder).
  - Core: `internal/http2/http2.go` (constants, settings, `Setting`, frame types/flags, client preface `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`), `errors.go` (`ErrCode`, `StreamError`, `ConnectionError`), `ascii.go`, `ciphers.go` (bad-cipher denylist for the TLS handshake check).
  - Framing: `frame.go` (1873 lines) — `Framer`, `FrameHeader`, all frame types + header-block (CONTINUATION) assembly.
  - IO/flow: `flow.go` (inflow/outflow), `databuffer.go`, `pipe.go`.
  - Write path: `write.go` (frame writers), `writesched.go` + `writesched_roundrobin.go` (scheduler).
  - Endpoints: `server.go` (3232), `transport.go` (3200), `client_conn_pool.go`, `config.go`, `api.go`.
- **Critical contracts:** the `Framer` read/write API; HPACK `Encoder`/`Decoder`; the stream state machine (idle→open→half-closed→closed); connection + stream flow-control windows (default 65535); SETTINGS exchange after preface. ALPN: TLS config advertises `["h2"; "http/1.1"]`; the negotiated protocol selects the serve/round-trip path.
- **Migration pressure points:** (1) HTTP/2 needs **server-side TLS** which `Net` doesn't have yet — must be added (cert + ALPN). (2) Avoiding OCaml module cycles between `Server`/`Client` and the `H2_*` modules. (3) Mapping Go's goroutine-per-conn + channels (serverConn `serve` loop, `writeFrameAsync`, per-stream goroutines) onto Lwt fibers + `Lwt_mvar`/`Lwt_stream`/`Lwt_condition`. (4) Flow-control backpressure expressed with Lwt promises.
- **Areas of uncertainty:** (1) How much of Go's scheduler/concurrency must be faithful vs. a simpler-but-correct Lwt model that passes the ported tests. (2) `tls-lwt` server-side ALPN selection API surface (must verify). (3) Trailer + 100-continue + flow-control edge cases. (4) Whether HPACK Huffman table is small enough to embed by hand vs. generate.

## Target Shape

- **Responsibilities / Ownership:** New modules in `gohttp`:
  - `hpack.ml` (+ maybe `hpack_huffman.ml`, `hpack_tables.ml`) — pure HPACK encoder/decoder.
  - `h2_error.ml` — error codes, `Stream_error`, `Connection_error`.
  - `h2.ml` — shared constants (frame types, flags, settings, preface, default windows).
  - `h2_frame.ml` — `Framer` + frame types (pure codec over byte buffers; reads/writes via `Lwt_io` at the edges, but framing logic pure).
  - `h2_flow.ml`, `h2_databuffer.ml`, `h2_pipe.ml` — flow control + stream IO buffers.
  - `h2_write.ml`, `h2_writesched.ml` — frame writers + round-robin write scheduler.
  - `h2_server.ml` — serverConn: preface/settings handshake, stream state machine, frame loop, builds a `Request.t`, invokes a supplied handler, writes the `Response.t` as frames.
  - `h2_transport.ml` (+ conn pool) — ClientConn: round trip over an h2 connection.
- **Public contracts (target):** `Server.listen_and_serve` gains TLS+ALPN and dispatches h2 connections to `H2_server`; `Client`/`Transport` gain an h2 path selected by ALPN (or forced). `Net` gains `listen_tls`/server-side ALPN and `connect ?alpn`. The same `handler`/`response_writer` and `Request.t`/`Response.t` types serve both protocols.
- **Execution flow (server):** `Net` TLS accept → ALPN = "h2" → `H2_server.serve conn ~handler`: read preface, exchange SETTINGS, loop reading frames; HEADERS → decode via `Hpack` → build `Request.t` (with a streaming `Body` fed by DATA frames through `H2_pipe`) → run `handler` → write `:status`+headers (HEADERS) + body (DATA) via the write scheduler, respecting flow control. Non-h2 → existing HTTP/1.x serve loop.
- **Execution flow (client):** `Transport.round_trip` → connect with ALPN → if "h2", `H2_transport` opens/reuses a `ClientConn`, allocates a stream, sends HEADERS(+DATA), reads HEADERS/DATA into a `Response.t`. Else HTTP/1.x path.
- **Migration shape:** Bottom-up so the tree stays green every ticket: codecs (hpack, frame) → IO/flow → write scheduler → server → transport → TLS/ALPN wiring + e2e. h2 modules take callbacks/lower deps to avoid cycles with `Server`/`Client`.
- **End-state properties:** Each Go http2 source file has a named OCaml counterpart with a ported test; a single TLS port serves both h2 and http/1.1 by ALPN; the public `Server`/`Client` API is unchanged for callers.

## Implementation Guide

- **Execution Model:** Orchestrator + sub-agents, tickets worked **serially**, lowest open ticket first. Never parallelize tickets.
- **Per-Ticket Workflow:** each ticket agent MUST: (1) `jj st` + `dune test` to confirm green start; (2) implement against the matching Go source, writing a `.mli` for every new module and mirroring Go data structures; (3) port the corresponding Go `*_test.go` cases into alcotest, driving Lwt with `Lwt_main.run` bounded by `Net.with_timeout`; (4) do ALL plan edits (Execution Record: changes, test evidence + counts) BEFORE committing; (5) one clean `jj commit -m "<semantic message>"`, no edits after.
- **Verification Gate:** before advancing, the Execution Record must show `dune build` clean + named tests passing + a jj commit id. Networked tests MUST terminate (timeout-bounded) — a hang is a failure.
- **Failure Handling:** ticket agent failure → return feedback; orchestrator adjusts the plan and retries ONCE with a fresh agent; two failures → stop and return to the user with context.
- **Scope Handling:** honor user scope (one ticket vs all). The big endpoint tickets (Server, Transport) may be internally split into sub-steps by the agent, but each must leave the build green and commit once.

## Build Out

### Ticket 1 — h2 scaffolding: constants, errors, preface
Status: Done

**A) Scope** Foundation for everything: `h2.ml` (frame types, flags, `SettingID`s + defaults, the client connection preface, default initial window sizes, max frame size bounds) and `h2_error.ml` (`ErrCode` enum + text, `Stream_error`, `Connection_error`, `ConnectionError`/`StreamError` constructors). Pure, no IO.

**B) Migration Strategy** Additive new modules in `gohttp`; nothing depends on them yet.

**C) Exit State** Constants/errors match Go; `dune test` green.

**D) Detailed Design** Port `internal/http2/http2.go` constant block + `errors.go`. `type err_code = ...` (NO_ERROR…HTTP_1_1_REQUIRED) with `err_code_string`; `exception Connection_error of err_code`; `type stream_error = { stream_id : int; code : err_code }`; `setting` type + `SettingHeaderTableSize` etc.; `client_preface : string`.

**E) Testing Plan** *Unit* (`test/test_h2.ml`, ported from `errors_test.go`/`http2_test.go`): err-code stringers, preface bytes, settings id values.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Files created:**
  - `lib/h2_error.ml` + `lib/h2_error.mli` — port of `internal/http2/errors.go`: `err_code` variant (NoError…HTTP11Required plus `Unknown of int`), `err_code_to_int`/`err_code_of_int`/`err_code_string` (faithful to Go's `errCodeName` map; unknown → `"unknown error code 0xN"`), `exception Connection_error of err_code`, `stream_error` record + `exception Stream_error`, `stream_error`/`conn_error` constructors.
  - `lib/h2.ml` + `lib/h2.mli` — port of the constant block of `internal/http2/http2.go` + frame type/flag constants from `frame.go`: `client_preface` (`"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"`), `client_preface_len` (24), `next_proto_tls` (`"h2"`), `frame_type` (Data=0…Continuation=9) + int conversions + stringer, frame flags (END_STREAM=0x1, END_HEADERS=0x4, PADDED=0x8, PRIORITY=0x20, ACK=0x1), `setting_id` (HeaderTableSize=1…MaxHeaderListSize=6) + int conversions + stringer, defaults (`initial_window_size=65535`, `initial_max_frame_size=16384`, `initial_header_table_size=4096`, `default_max_read_frame_size=1 lsl 20`), `setting` record.
- **Files modified:**
  - `test/test_h2.ml` (new) — 59 cases ported from `errors_test.go` (`TestErrCodeString`, incl. unknown 0xf) + constant block: err-code int round-trips/values, preface bytes/length, frame-type values + round-trips, frame flags, setting-id values/round-trips/names, default constants.
  - `test/test_gohttp.ml` — wired `("H2", Test_h2.tests)`.
- **Test evidence:** baseline `dune test` = **262** tests green. After: `dune build` clean, `dune test` = **321 tests run, Test Successful**. New **H2** suite = **59** cases (262 + 59 = 321).
- **Go cases omitted:** none of `errors_test.go` (its sole `TestErrCodeString` is ported). `http2.go`/`frame.go` have no dedicated stringer test for settings/frames beyond the values asserted here. The `Unknown of int` constructor is an OCaml-specific representation of Go's open-ended `ErrCode`/`SettingID`/`FrameType` uint values (Go has no separate variant; unknown values flow through the same int type).
- **Commit:** `feat(h2): scaffold HTTP/2 constants, error codes and preface (H2 Ticket 1)` (single squashed jj change; id reported to orchestrator).

Status: Done

### Ticket 2 — HPACK: Huffman + static & dynamic tables
Status: Done

**A) Scope** Port `hpack/huffman.go` (Huffman code table, encode + decode with the decoding tree, `ErrInvalidHuffman`), `hpack/static_table.go` (the 61-entry static table), and the table machinery from `hpack/tables.go` (`HeaderField`, `headerFieldTable`, `dynamicTable` with size accounting + eviction). Pure.

**B) Migration Strategy** Additive (`hpack_huffman.ml`, `hpack_tables.ml` or folded into `hpack.ml`).

**C) Exit State** Huffman round-trips; static lookups + dynamic eviction match Go.

**D) Detailed Design** Faithful Huffman table (embed the code/length arrays from Go). `HeaderField = { name; value; sensitive }`; dynamic table as a ring/list with `evictOldest` and `setMaxSize`.

**E) Testing Plan** *Unit* (`test/test_hpack_tables.ml`, ported from `tables_test.go`/huffman cases): Huffman encode→decode round-trip incl. EOS padding; static table indices; dynamic table add/evict/size.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Files created:**
  - `lib/hpack_huffman.ml` + `lib/hpack_huffman.mli` — port of `hpack/huffman.go` plus the `huffmanCodes` (256 × uint32) and `huffmanCodeLen` (256 × uint8) arrays from `tables.go`, embedded verbatim. `exception Invalid_huffman` (= Go `ErrInvalidHuffman`); lazily-built decode tree (`type node` mirroring Go's `node`, via `build_root_huffman_node`/`buildRootHuffmanNode`); `decode : string -> string` (faithful `huffmanDecode` with `maxLen=0`, validating incomplete symbol / overlong padding / non-EOS-prefix trailing bits); `encode : string -> string` (port of `AppendHuffmanString` from an empty dst, EOS-padded to a byte boundary, using `Int64` for Go's uint64 bit buffer); `encoded_len : string -> int` (= `HuffmanEncodeLength`).
  - `lib/hpack_tables.ml` + `lib/hpack_tables.mli` — port of `hpack/static_table.go` + the table machinery of `tables.go` and the `HeaderField`/`dynamicTable` parts of `hpack.go`. `type header_field = { name; value; sensitive }` with `is_pseudo`/`size` (len name + len value + 32); `type header_field_table` (mirrors `headerFieldTable`: oldest-first `ents` + `evict_count` + `by_name`/`by_name_value` `Hashtbl`s keyed by stable 1-based unique ids) with `add_entry`/`evict_oldest`/`search` (returns `(index, name_value_match)`) and the static-vs-dynamic `id_to_index` split; the 61-entry `static_table` array + `static_table_len`/`static_table_entry`/`static_search` (over the global `static_field_table`); `type dynamic_table` (mirrors `dynamicTable`: `size`/`max_size`/`allowed_max_size`) with `create_dynamic_table`/`dynamic_add`/`set_max_size`/`set_allowed_max_size`/`dynamic_evict` and combined-index lookup `at` (static 1..61, dynamic after, newest lowest = Go `(*Decoder).at`).
- **Files modified:**
  - `test/test_hpack_tables.ml` (new) — 12 cases ported from `tables_test.go` (`TestHeaderFieldTable` add/search/idToIndex/evict, mapped to `dynamic_table_search`) + the Huffman cases of `hpack_test.go` (`TestHuffmanRoundtrip`/`TestHuffmanDecode`): Huffman encode→decode round-trip over representative strings incl. all 256 byte values + high-code symbols (varying EOS padding); RFC 7541 C.4.1 vector `"www.example.com"` → `f1e3c2e5f23a6ba0ab90f4ff` and C.4.2 `"no-cache"` → `a8eb10649cbf` (encode + decode); invalid-Huffman raises `Invalid_huffman`; `encoded_len`; static lookups by index + name/value `static_search` (incl. name-only → newest id, sensitive); dynamic add/evict/size accounting, `set_max_size` shrink-to-0, combined-index `at`, `is_pseudo`, `size`.
  - `test/test_gohttp.ml` — wired `("HpackTables", Test_hpack_tables.tests)`.
- **Test evidence:** baseline `dune st` clean + `dune build`/`dune test` = **321** green. After: `dune build` clean, `dune test` = **333 tests run, Test Successful**. New **HpackTables** suite = **12** cases (321 + 12 = 333). Confirmed passing: a Huffman round-trip (`huffman_roundtrip`, incl. all 256 byte values) and the RFC 7541 C.4.1/C.4.2 known vectors (`huffman_rfc_vector_C41`/`_C42`).
- **Go cases omitted:** `tables_test.go`'s `TestHeaderFieldTableLookupAll` and benchmark/fuzz helpers are not separately ported — their lookup coverage is subsumed by `dynamic_table_search`/`static_search`. `TestHuffmanMaxStrLen` / `ErrStringLength` is deferred to Ticket 3 (the `maxStrLen`/`Decoder` decode path lives there; `hpack_huffman.decode` ports the `maxLen=0` unlimited path only). The lazy `sync.Once` build of the decode tree is rendered as OCaml `lazy` (semantic equivalent; no behavioral difference).
- **Commit:** `feat(h2): port HPACK Huffman codec and static/dynamic tables (H2 Ticket 2)` (single jj change; id reported to orchestrator).

Status: Done

### Ticket 3 — HPACK: encoder + decoder
Status: Done

**A) Scope** Port `hpack/encode.go` (`Encoder`: indexed/literal representations, integer + string encoding, dynamic-table sizing) and `hpack/hpack.go` (`Decoder`: parse representations, emit `HeaderField`s, dynamic-table updates, `maxStrLen`). Pure.

**B) Migration Strategy** Additive `hpack.ml` composing Ticket 2 tables.

**C) Exit State** Encode/decode round-trip incl. RFC 7541 examples; **Success Criterion `Hpack.roundtrip` passes**.

**D) Detailed Design** `Encoder.write_field`, `Decoder.write`/`decode_full`, integer (`N`-bit prefix) + Huffman/raw string primitives. `type 'a result` for decode errors.

**E) Testing Plan** *Unit* (`test/test_hpack.ml`, ported from `hpack_test.go`/`encode_test.go`): RFC 7541 C.2–C.6 request/response example sequences (with + without Huffman), dynamic-table eviction across requests, decode error cases.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Files created:**
  - `lib/hpack.ml` + `lib/hpack.mli` (module `Gohttp.Hpack`) — port of `hpack/encode.go` (`Encoder`) + `hpack/hpack.go` (`Decoder`), composing the Ticket-2 `Hpack_huffman` and `Hpack_tables` modules (tables/Huffman are reused, not reimplemented).
    - **Primitives:** `append_var_int`/`read_var_int` (RFC 7541 §5.1 `N`-bit prefix; faithful to Go `appendVarInt`/`readVarInt`, incl. the `m >= 63` overflow check → `Decoding_error "varint integer overflow"` and the `Need_more` sentinel); `append_hpack_string` (§5.2 length + optional Huffman, only Huffman when strictly shorter via `Hpack_huffman.encoded_len`/`encode`); decoder `read_string`/`decode_string` enforcing `max_str_len` (→ `String_too_long`).
    - **Encoder** (`type encoder`): `dynamic_table` (initial max 4096) + `Buffer`, `min_size`/`max_size_limit`/`table_size_update` mirroring Go's fields; `write_field` choosing indexed / literal-incremental-indexing / literal-without-indexing / never-indexed via `search_table` (`static_search` first, dynamic offset by `static_table_len`) + `should_index` (`!sensitive && size <= maxSize`); emits a pending dynamic-table-size-update before the field (`appendTableSize`, incl. the `min_size` double-update case); `set_max_dynamic_table_size`/`set_max_dynamic_table_size_limit`/`max_dynamic_table_size`; `set_writer`/`encode_to_string` accumulators.
    - **Decoder** (`type decoder`): `dynamic_table` + emit callback, `emit_enabled`, `max_str_len`, owned `save_buf`, `first_field`; `write` parsing the four representations + dynamic-table-size-update (faithful `parseHeaderFieldRepr` bit tests), with `Need_more` saved to `save_buf` (and the `2*(maxStrLen+8)` paranoia check → `String_too_long`); `close` (truncated-headers error), `decode_full`; faithful errors `Invalid_indexed`, `Decoding_error "invalid encoding"`, size-update-too-large and size-update-not-at-start.
- **Files modified:**
  - `test/test_hpack.ml` (new) — 22 cases ported from `hpack_test.go`/`encode_test.go` + RFC 7541 appendix C. Integer primitive (C.1.1/C.1.2 vectors, round-trips, `Need_more` on truncation); RFC **C.2** (C.2.1 literal-with-indexing, C.2.2 literal-without-indexing, C.2.3 never-indexed/sensitive, C.2.4 indexed); RFC **C.3** request sequence (no Huffman, 3 requests C.3.1–C.3.3); RFC **C.4** request sequence WITH Huffman (C.4.1–C.4.3); RFC **C.5** response sequence with eviction (256-byte table, C.5.1–C.5.3); RFC **C.6** response sequence with eviction WITH Huffman (C.6.1–C.6.3); encoder type-byte + round-trip; **Success Criterion `Hpack.roundtrip`** = `roundtrip_basic` + `roundtrip_dynamic_two_passes` (dynamic table across two encode/decode passes on one encoder/decoder pair, asserting the 2nd pass compresses) + `roundtrip_table_size_update`; decode error cases (`Invalid_indexed 0`, index-too-large, truncated headers, `String_too_long`, size-update-too-large, size-update-not-at-start).
  - `test/test_gohttp.ml` — wired `("Hpack", Test_hpack.tests)`.
- **Test evidence:** baseline `jj st` clean + `dune build`/`dune test` = **333** green. After: `dune build` clean, `dune test` = **355 tests run, Test Successful**. New **Hpack** suite = **22** cases (333 + 22 = 355). RFC 7541 examples **C.1.1, C.1.2, C.2.1–C.2.4, C.3.1–C.3.3, C.4.1–C.4.3, C.5.1–C.5.3, C.6.1–C.6.3 all decode to the spec fields and pass**. `Hpack.roundtrip` Success Criterion passes (incl. the cross-pass dynamic-table case).
- **Go cases omitted / artifacts:** `encode_test.go`'s byte-exact encoder vectors that assume the RFC's *non-Huffman* output are not asserted byte-for-byte — Go's encoder (faithfully ported) Huffman-encodes whenever strictly shorter (e.g. "custom-key" → 8 bytes), so its bytes differ from the raw-literal RFC C.2/C.3 examples; the encoder is instead validated by representation-type byte + decode round-trip. The RFC C.3/C.5 *decode* vectors fully exercise the non-Huffman decode path. Go's incremental `Write`/`saveBuf` chunk-boundary fuzz tests are covered structurally by the `Need_more`/truncated-headers cases. `bufPool`/`sync` machinery is an OCaml no-op (GC-managed). The `Need_more` exception is exposed (Go's internal `errNeedMore`) so the truncation primitive is testable.
- **Commit:** `feat(h2): port HPACK encoder and decoder with RFC 7541 examples (H2 Ticket 3)` (single jj change; id reported below).

### Ticket 4 — Frame layer (Framer)
Status: Done

**A) Scope** Port `internal/http2/frame.go`: `FrameHeader`, the `Framer` (`read_frame`/`write_*`), and all frame types — DATA, HEADERS (+ priority + padding), PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE (parse), PING, GOAWAY, WINDOW_UPDATE, CONTINUATION — including header-block fragment assembly (`ReadMetaHeaders` via HPACK from Ticket 3) and frame-size enforcement. Framing logic pure over byte buffers; the `Framer` reads/writes through `Lwt_io` channels at the edges.

**B) Migration Strategy** Additive `h2_frame.ml`; composes `h2`, `h2_error`, `hpack`.

**C) Exit State** Each frame type round-trips; **Success Criterion `Frame.roundtrip` passes**.

**D) Detailed Design** `read_frame : Lwt_io.input_channel -> frame Lwt.t`; `write_data`/`write_headers`/`write_settings`/… : `Lwt_io.output_channel -> … -> unit Lwt.t`. Frame variant type with per-type records. `read_meta_headers` assembles HEADERS+CONTINUATION and decodes via `Hpack.Decoder`.

**E) Testing Plan** *Unit* (`test/test_h2_frame.ml`, ported from `frame_test.go`): write/read each frame type and assert fields; padding + priority parsing; oversize-frame + bad-stream errors; CONTINUATION assembly. Drive Lwt via `Lwt_main.run` over in-memory channels (`Lwt_io.pipe`).

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Files created:**
  - `lib/h2_frame.ml` + `lib/h2_frame.mli` (module `Gohttp.H2_frame`) — port of `internal/http2/frame.go`, composing `H2` (frame types/flags/settings), `H2_error` (`Connection_error`/`Stream_error`), `Hpack` (decoder for meta-headers). Byte-level encode/decode is pure over strings; thin Lwt wrappers read/write through `Lwt_io` channels.
    - **Types:** `frame_header = { length; typ : H2.frame_type; flags; stream_id }` (high stream-id bit masked); `priority_param = { stream_dep; exclusive; weight }`; a `frame` variant `Data | Headers | Priority | RST_stream | Settings | Push_promise | Ping | GoAway | Window_update | Continuation | Unknown` each pairing a `frame_header` with a per-type record (`data_frame`/`headers_frame`/… mirroring Go's concrete `*Frame` structs). `header_of_frame` mirrors Go's `Frame.Header`. PRIORITY_UPDATE (0x10) and any other unmodeled type flow through `Unknown { raw_type; payload }` (`H2.frame_type` only models 0x0–0x9, matching Ticket 1).
    - **Header codec:** `encode_frame_header`/`decode_frame_header` (9-byte header; reserved stream-id high bit masked on read, per Go `readFrameHeader`). `decode_frame_header_raw` keeps the raw type byte so unknown types pass through.
    - **Parsers** (pure, faithful to Go `parse*`): DATA (strip pad, stream-0 → PROTOCOL_ERROR, pad>payload → PROTOCOL_ERROR), HEADERS (optional pad + PRIORITY prefix, strip pad, stream-0 → PROTOCOL_ERROR, pad-too-big → `Stream_error` PROTOCOL_ERROR), PRIORITY (len≠5 → FRAME_SIZE), RST_STREAM (len≠4 → FRAME_SIZE, stream-0 → PROTOCOL_ERROR), SETTINGS (ACK+len>0 → FRAME_SIZE, stream≠0 → PROTOCOL_ERROR, len%6 → FRAME_SIZE, INITIAL_WINDOW_SIZE > 2^31-1 → FLOW_CONTROL), PUSH_PROMISE (parse path), PING (len≠8 → FRAME_SIZE, stream≠0 → PROTOCOL_ERROR), GOAWAY (stream≠0 → PROTOCOL_ERROR, len<8 → FRAME_SIZE), WINDOW_UPDATE (len≠4 → FRAME_SIZE, zero-inc → conn PROTOCOL_ERROR on stream 0 else `Stream_error`), CONTINUATION (stream-0 → PROTOCOL_ERROR), UNKNOWN passthrough.
    - **Reader:** `read_frame ?max_size ic` reads the 9-byte header then payload, raising `Frame_too_large` if declared length > `max_size` (default `max_frame_size` = 2^24-1), then dispatches to the type parser.
    - **Writers** (one channel write each, mirroring Go `Write*` incl. `validStreamID`/`validStreamIDOrZero`/pad-length checks): `write_data` (`?pad`), `write_headers` (`?end_stream`/`?end_headers`/`?pad_length`/`?priority`, zero-priority elision via `priority_is_zero`, exclusive high bit), `write_priority`, `write_rst_stream`, `write_settings`, `write_settings_ack`, `write_ping`, `write_goaway`, `write_window_update` (1..2^31-1 guard), `write_continuation`, `write_push_promise`, `write_raw`. Exceptions `Frame_too_large`/`Invalid_stream_id`/`Invalid_dep_stream_id`/`Pad_length_too_large` mirror Go's `ErrFrameTooLarge`/`errStreamID`/`errDepStreamID`/`errPadLength`.
    - **`read_meta_headers`:** port of `Framer.readMetaFrame` — assembles a HEADERS + zero-or-more CONTINUATION frames (until END_HEADERS), enforces CONTINUATION continuity (same stream, no interleaving; otherwise PROTOCOL_ERROR — Go's `checkFrameOrder`), decodes the block via the supplied `Hpack.decoder` with an emit callback enforcing `MAX_HEADER_LIST_SIZE` (`truncated`), `validWireHeaderFieldName` (lowercase token), `ValidHeaderFieldValue` (CTL-not-LWS), pseudo-after-regular, and `checkPseudos` (unknown/duplicate/mixed request-response pseudo → `Stream_error` PROTOCOL_ERROR); HPACK errors → `Connection_error COMPRESSION_ERROR`; over-large fragment → PROTOCOL_ERROR. Returns `meta_headers_frame = { fh; fields; truncated }`.
- **Files modified:**
  - `test/test_h2_frame.ml` (new) — 29 cases ported from `frame_test.go`: `frame_type_string`; byte-exact-encode + round-trip for RST_STREAM (`TestWriteRST`), DATA (`TestWriteData`), DATA padded ×3 (`TestWriteDataPadded`), HEADERS basic/end-flags/padding/priority (`TestWriteHeaders`), CONTINUATION not-end/end (`TestWriteContinuation`), PRIORITY ×2 (`TestWritePriority`), invalid stream-dep (`TestWriteInvalidStreamDep`), SETTINGS + ACK (`TestWriteSettings`/`TestWriteSettingsAck`), WINDOW_UPDATE (`TestWriteWindowUpdate`), PING + ACK (`TestWritePing`/`Ack`), GOAWAY (`TestWriteGoAway`), PUSH_PROMISE (`TestWritePushPromise`), frame-header codec (`TestReadFrameHeader`/`TestReadWriteFrameHeader`); oversize → `Frame_too_large` (`TestReadFrameHeaderFrameTooLarge`); bad-stream-id DATA/SETTINGS/SETTINGS-size errors; CONTINUATION assembly via `read_meta_headers` (single / one / two CONTINUATIONs, truncation, pseudo-after-regular, unknown-pseudo, duplicate-pseudo, invalid-field-name) ported from `TestMetaFrameHeader`. Lwt driven via `Lwt_main.run` over `Lwt_io.pipe ()`, bounded by `Net.with_timeout 10.`; byte-exact encodes captured via a custom `Lwt_io` output sink.
  - `test/test_gohttp.ml` — wired `("H2Frame", Test_h2_frame.tests)`.
- **Test evidence:** baseline `jj st` clean + `dune build`/`dune test` = **355** green. After: `dune build` clean, `dune test` = **384 tests run, Test Successful** (terminates in ~0.85s). New **H2Frame** suite = **29** cases (355 + 29 = 384). **Success Criterion `Frame.roundtrip` passes for every frame type** (DATA, HEADERS incl. priority+padding, PRIORITY, RST_STREAM, SETTINGS incl. ACK, PUSH_PROMISE, PING incl. ACK, GOAWAY, WINDOW_UPDATE, CONTINUATION via `read_meta_headers`): each writer's output reads back with matching fields, and the byte-exact encodings match Go's `wantEnc` vectors.
- **Go cases omitted / artifacts:** `TestFrameSizes` (Go `unsafe.Sizeof` struct-layout guard — not meaningful for an OCaml variant). `TestParseRFC9218Priority`/`TestWritePriorityUpdate` (RFC 9218 priority is a non-goal per the plan; PRIORITY_UPDATE is parsed only as `Unknown` passthrough, and `httpsfv` structured-fields parsing is out of scope). `TestSetReuseFrames`/`MoreThanOnce`/`NoSetReuseFrames` (Go's `frameCache` frame-reuse optimization — an OCaml no-op; we allocate fresh records). `TestSettingsDuplicates`/`HasDuplicates`, `TestTypeFrameParser`/`HolePanic`, `summarizeFrame`, `AllowIllegalReads`/`AllowIllegalWrites` debug-framer plumbing, and `ErrorDetail` are framer-internal/diagnostic helpers not part of the read/write contract this ticket needs (deferred to the server/transport tickets if required). The `Unknown of int` settings-id values that Go retains in its raw `[]byte` are not surfaced in the typed `settings` list (only modeled IDs 1–6 appear), but length/window-size validation still runs over the raw payload — matching the Ticket-1 `H2.setting_id` model. `read_frame`'s `?max_size` replaces Go's stateful `SetMaxReadFrameSize`.
- **Commit:** `feat(h2): port HTTP/2 frame layer (Framer + all frame types) (H2 Ticket 4)` (single jj change; id reported to orchestrator).

### Ticket 5 — Flow control + stream IO buffers
Status: Planned

**A) Scope** Port `internal/http2/flow.go` (inflow/outflow window accounting + `add`/`take`/`available`), `databuffer.go` (the chunked `dataBuffer`), and `pipe.go` (the `pipe` used to feed stream request/response bodies, with error/close propagation). Adapt the pipe's blocking read to an Lwt promise.

**B) Migration Strategy** Additive `h2_flow.ml`, `h2_databuffer.ml`, `h2_pipe.ml`.

**C) Exit State** Window math + pipe read/write/close semantics match Go.

**D) Detailed Design** `type outflow`/`inflow` with `available`/`take n`/`add n` (int32 overflow checks → errors). `H2_pipe`: `write : string -> unit`, `read : unit -> string Lwt.t` (blocks until data/close), `close_with_error`.

**E) Testing Plan** *Unit* (`test/test_h2_flow.ml`, ported from `flow_test.go`/`databuffer_test.go`/`pipe_test.go`): window add/take/overflow; databuffer read/write across chunks; pipe blocking read unblocked by write/close. Lwt via `Lwt_main.run`, bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record** _(tbd)_

### Ticket 6 — Write path + scheduler
Status: Planned

**A) Scope** Port `internal/http2/write.go` (the `writeFramer` frame-writer values: settings, headers, data, window-update, rst, goaway, ping) and `writesched.go` + `writesched_roundrobin.go` (the round-robin write scheduler queuing frames per stream). Skip the RFC 9218 priority scheduler.

**B) Migration Strategy** Additive `h2_write.ml`, `h2_writesched.ml`; composes `h2_frame`.

**C) Exit State** Scheduler ordering + frame writers match Go's round-robin behavior.

**D) Detailed Design** `type write_scheduler` with `open_stream`/`close_stream`/`push`/`pop` (returns next frame to write honoring flow control + round-robin). Frame writers produce bytes via the Ticket-4 `Framer`.

**E) Testing Plan** *Unit* (`test/test_h2_writesched.ml`, ported from `writesched_test.go`/`writesched_roundrobin_test.go`): enqueue across streams, assert round-robin pop order; control frames prioritized; flow-control-blocked data deferred.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record** _(tbd)_

### Ticket 7 — Server TLS + ALPN in Net
Status: Planned

**A) Scope** Add server-side TLS with ALPN to `Net`: `listen_tls` accepting a certificate + advertised ALPN protocols (`["h2"; "http/1.1"]`), exposing the negotiated protocol per accepted connection; and extend client `connect` with `?alpn` advertising + negotiated-protocol readout. Provide a test self-signed cert helper (mint via `x509`, or vendor Go's `internal/testcert` PEM).

**B) Migration Strategy** Additive to `Net` (existing `listen`/`connect` unchanged; new `listen_tls`/`accept_tls` + `?alpn`). Verify `tls-lwt` server ALPN selection API first.

**C) Exit State** A TLS server advertises ALPN; a TLS client negotiates and both can read the selected protocol; HTTP/1.1-over-TLS still works.

**D) Detailed Design** `listen_tls : ?backlog:int -> certificates:Tls.Config.certchain -> alpn:string list -> string -> int -> server Lwt.t`; `accept_tls : server -> (ic * oc * string option (* negotiated alpn *) * sockaddr) Lwt.t`; `connect ~host ~port ?tls ?alpn () -> (ic * oc * string option)`. Document trust settings.

**E) Testing Plan** *Integration* (`test/test_h2_tls.ml`): loopback TLS handshake with ALPN advertising `["h2";"http/1.1"]`, assert negotiated protocol is `h2`; a second case advertising only `http/1.1` negotiates `http/1.1`. Bounded by `Net.with_timeout`.

**F) End-of-Ticket Verification** `dune build && dune test` clean; handshake tests terminate.

**G) Execution Record** _(tbd)_

### Ticket 8 — HTTP/2 server connection
Status: Planned

**A) Scope** Port `internal/http2/server.go` (HTTP/2 subset): `H2_server.serve conn ~handler` — read+validate client preface, send/receive SETTINGS, run the frame-read loop, manage the stream state machine + flow control + write scheduler, decode HEADERS into a `Request.t` with a streaming `Body` fed by DATA via `H2_pipe`, invoke the supplied `handler` (the existing `Server` handler type, passed in to avoid a module cycle), and write the `Response.t` as HEADERS+DATA honoring flow control. Handle RST_STREAM/GOAWAY/PING/WINDOW_UPDATE. Server Push send path out of scope.

**B) Migration Strategy** Additive `h2_server.ml`; `Server` (HTTP/1.x) will call it in Ticket 10. Map Go's goroutines/channels to Lwt fibers + `Lwt_condition`/`Lwt_mvar`.

**C) Exit State** An `H2_server.serve` over a duplex channel pair serves a handler for a GET and a POST; flow control + multiple concurrent streams work.

**D) Detailed Design** `serve : Lwt_io.input_channel -> Lwt_io.output_channel -> handler:(...) -> unit Lwt.t` (handler signature matches `Server`'s). Internal `serverConn`/`stream` records mirroring Go; `response_writer` impl that frames output.

**E) Testing Plan** *Integration* (`test/test_h2_server.ml`, ported subset of `server_test.go`): drive a raw client (Framer from Ticket 4) over an `Lwt_io.pipe` pair against `H2_server.serve` — send preface+SETTINGS+HEADERS, assert response HEADERS `:status:200` + DATA body; POST with DATA echoed; two concurrent streams. Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record** _(tbd)_

### Ticket 9 — HTTP/2 transport (client)
Status: Planned

**A) Scope** Port `internal/http2/transport.go` + `client_conn_pool.go` (subset): `H2_transport` — establish a `ClientConn` over a duplex channel (preface + SETTINGS), allocate stream IDs, send a `Request.t` as HEADERS(+DATA), read HEADERS/DATA into a `Response.t` (streaming body via `H2_pipe`), multiplex concurrent streams, basic conn pool keyed by authority. Flow control + WINDOW_UPDATE + GOAWAY handling.

**B) Migration Strategy** Additive `h2_transport.ml`; `Transport`/`Client` call it in Ticket 10. Lwt fibers for the read loop.

**C) Exit State** `H2_transport` round-trips a request against the Ticket-8 server over an in-process channel pair (GET + POST), reads status + body.

**D) Detailed Design** `new_client_conn : Lwt_io.input_channel -> Lwt_io.output_channel -> client_conn Lwt.t`; `round_trip : client_conn -> Body.t Request.t -> Body.t Response.t Lwt.t`. Stream table (`Hashtbl` id→stream), shared read loop dispatching frames to per-stream Lwt wakers.

**E) Testing Plan** *Integration* (`test/test_h2_transport.ml`, ported subset of `transport_test.go`): connect a `ClientConn` to `H2_server.serve` over a connected `Lwt_io` socket pair (loopback), GET → 200 + body; POST body echoed; two concurrent round trips multiplexed on one conn. Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record** _(tbd)_

### Ticket 10 — ALPN wiring + end-to-end integration
Status: Planned

**A) Scope** Wire it together: `Server.listen_and_serve` (and a new TLS variant) uses `Net.listen_tls` with ALPN `["h2";"http/1.1"]` and dispatches each accepted connection to `H2_server.serve` or the HTTP/1.x serve loop by negotiated protocol; `Transport`/`Client` connect with ALPN and use `H2_transport` when "h2" is negotiated (or when forced), falling back to HTTP/1.x. Optional `h2c` stretch only if cheap.

**B) Migration Strategy** Modify `Server`/`Client`/`Transport` to branch on ALPN; existing HTTP/1.x call sites and tests stay green. New public entry: `Server.listen_and_serve_tls`.

**C) Exit State** **Success Criterion `H2.clientserver_roundtrip` passes**: real TLS+ALPN gohttp server ↔ gohttp client over `h2`, GET + POST on one multiplexed connection, `:status` 200 + body equality; and an HTTP/1.1 client against the same TLS port still works (fallback).

**D) Detailed Design** `Server.listen_and_serve_tls : certificates:… -> string -> int -> handler -> unit Lwt.t`. `Transport` gains `?force_h2`/ALPN-driven selection. Dispatch by the negotiated-protocol string from Ticket 7.

**E) Testing Plan** *Integration* (`test/test_h2_clientserver.ml`): the Success-Criterion e2e over loopback TLS (GET+POST, multiplexed); plus a fallback case where the client advertises only `http/1.1` and gets served by the HTTP/1.x path. Bounded by `Net.with_timeout`.

**F) End-of-Ticket Verification** `dune build && dune test` clean; e2e tests terminate.

**G) Execution Record** _(tbd)_
