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
Status: Done

**A) Scope** Port `internal/http2/flow.go` (inflow/outflow window accounting + `add`/`take`/`available`), `databuffer.go` (the chunked `dataBuffer`), and `pipe.go` (the `pipe` used to feed stream request/response bodies, with error/close propagation). Adapt the pipe's blocking read to an Lwt promise.

**B) Migration Strategy** Additive `h2_flow.ml`, `h2_databuffer.ml`, `h2_pipe.ml`.

**C) Exit State** Window math + pipe read/write/close semantics match Go.

**D) Detailed Design** `type outflow`/`inflow` with `available`/`take n`/`add n` (int32 overflow checks → errors). `H2_pipe`: `write : string -> unit`, `read : unit -> string Lwt.t` (blocks until data/close), `close_with_error`.

**E) Testing Plan** *Unit* (`test/test_h2_flow.ml`, ported from `flow_test.go`/`databuffer_test.go`/`pipe_test.go`): window add/take/overflow; databuffer read/write across chunks; pipe blocking read unblocked by write/close. Lwt via `Lwt_main.run`, bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Files created:**
  - `lib/h2_flow.ml` + `lib/h2_flow.mli` (module `Gohttp.H2_flow`) — port of `internal/http2/flow.go`. `inflow_min_refresh` (4<<10), `max_window` (2^31-1). `type inflow = { mutable avail : int32; mutable unsent : int32 }` with `create_inflow`/`inflow_init`/`inflow_add` (returns the WINDOW_UPDATE size, 0 when buffered below `inflow_min_refresh` and not doubling; uses `Int64` for the overflow math; raises `Invalid_argument "negative update"` / `"flow control update exceeds maximum window size"` where Go panics)/`inflow_take` (treats `n` as unsigned uint32 vs `avail`)/`take_inflows`. `type outflow = { mutable n : int32; mutable conn : outflow option }` (Go's `conn *outflow` linkage, `None` for the conn-level flow) with `create_outflow`/`set_conn_flow`/`available` (min of stream and conn windows)/`take` (raises `Invalid_argument "internal error: took too much"`)/`add` (faithful int32-wraparound overflow guard `(sum > n) = (f.n > 0)`, returns false on >2^31-1). All `int32` to match Go's int32 fields exactly.
  - `lib/h2_databuffer.ml` + `lib/h2_databuffer.mli` (module `Gohttp.H2_databuffer`) — port of `internal/http2/databuffer.go`. `exception Read_empty` (= Go `errReadEmpty`, text `read from empty dataBuffer` via `read_empty_msg`). `type t = { mutable chunks : bytes array; mutable r; mutable w; mutable size; mutable expected : int64 }` mirroring `dataBuffer`; faithful tiered size classes (1/2/4/8/16 KiB) via `chunk_size_for`/`get_data_buffer_chunk` (Go's `dataChunkPools` rendered as plain GC-managed allocations — no pool). `create ?expected`, `len`, `read` (raises `Read_empty` when empty; advances/shifts chunks exactly as Go's `Read`+`bytesFromFirstChunk`), `write` (Go's `lastChunkOrAlloc` with `want = max(expected, len p)` and `expected` decrement), plus `write_string`/`read_string` string helpers used by `H2_pipe` and tests. Pure (no Lwt).
  - `lib/h2_pipe.ml` + `lib/h2_pipe.mli` (module `Gohttp.H2_pipe`) — port of `internal/http2/pipe.go`. `exception Closed_pipe_write`/`Uninitialized_pipe_write` (= `errClosedPipeWrite`/`errUninitializedPipeWrite`, texts exposed). `type t` mirrors Go's `pipe` (`b : H2_databuffer.t option` (None when done), `unread`, `err`, `break_err`, `read_fn`, a `donec` promise pair) but Go's `sync.Cond` is an `Lwt_condition.t` broadcast by write/close/break. `create`/`set_buffer`/`len`; `read : t -> int -> string Lwt.t` (recursive: break→fail immediately; data→return; err→run `read_fn` once, drop buffer, fail; else await `Lwt_condition.wait` and retry — Go's `c.Wait()` loop); `write` (broadcasts via `Fun.protect ~finally`, fails on closed/uninitialized); `close_with_error`/`break_with_error`/`close_with_error_and_code` (shared `close_with_error_into`, first-writer-wins, break preserves `unread` and nulls the buffer); `err`; `done_` (resolves when closed/broken — Go's `Done()` channel). The single-threaded Lwt scheduler makes the check-then-wait sequence race-free (no bind boundary between the empty check and `Lwt_condition.wait`).
- **Files modified:**
  - `test/test_h2_flow.ml` (new) — 9 cases ported from `flow_test.go`: `TestInFlowTake`, `TestInflowAddSmall`, `TestInflowAdd`, `TestTakeInflows`, `TestOutFlow`, `TestOutFlowAdd`, `TestOutFlowAddOverflow`, plus two cases covering the inflow add panics (negative / >max-window → `Invalid_argument`, OCaml rendering of Go's `panic`).
  - `test/test_h2_databuffer.ml` (new) — 4 cases ported from `databuffer_test.go`: `TestDataBufferAllocation`, `TestDataBufferAllocationWithExpected`, `TestDataBufferWriteAfterPartialRead` (each via Go's `testDataBuffer` harness: drain at read sizes 1/2/1024/32768 and compare bytes — exercising chunk-boundary spanning), plus a `read_empty` case asserting `Read_empty` on an empty and on a fully-drained buffer.
  - `test/test_h2_pipe.ml` (new) — 9 cases ported from `pipe_test.go`: `TestPipeClose` (first-error-wins), `TestPipeDoneChan`/`_ErrFirst`/`_Break`/`_Break_ErrFirst` (done-promise resolution), `TestPipeCloseWithError` (drain-then-error, post-close Write/Read fail), `TestPipeBreakWithError` (immediate error, `unread`=3, buffer nulled), plus two cases proving a blocked `read` (asserted `Lwt.is_sleeping`) is unblocked by a later `write` and by `close_with_error`. Driven by `Lwt_main.run` bounded by `Net.with_timeout 10.` so a hang fails.
  - `test/test_gohttp.ml` — wired `("H2Flow", …)`, `("H2DataBuffer", …)`, `("H2Pipe", …)`.
- **Test evidence:** baseline `jj st` clean + `dune build`/`dune test` = **384** green. After: `dune build` clean, `dune test` = **406 tests run, Test Successful** (terminates in ~0.86s). New suites: **H2Flow** = 9, **H2DataBuffer** = 4, **H2Pipe** = 9 (384 + 22 = 406). All H2Pipe Lwt tests terminate under the 10s timeout (blocking-read-unblocked-by-write/close confirmed).
- **Go cases omitted / artifacts:** `databuffer_test.go`'s `reflect.DeepEqual(b.chunks, want)` internal chunk-layout assertions are not ported byte-for-byte — `H2_databuffer.t` keeps `chunks` abstract (project rule: hand-written `.mli`); the observable contract those tests guard (correct bytes read back across chunk boundaries at multiple read sizes, i.e. Go's `testDataBuffer` helper) is fully ported, and the size-class allocation logic is mirrored exactly in `chunk_size_for`/`last_chunk_or_alloc`. Go's `sync.Pool` chunk pooling and `putDataBufferChunk` are no-ops in OCaml (GC-managed) so there is no pool-return path to test. Go's `inflow` add overflow/negative paths `panic`; rendered as `Invalid_argument` and tested as such. The `read_fn`/`closeWithErrorAndCode` trailers hook is ported and exposed for the later server/transport tickets (not separately unit-tested here since `pipe_test.go` has no dedicated case).
- **Commit:** `feat(h2): port flow control, data buffer and stream pipe (H2 Ticket 5)` (single jj change; id reported below).

### Ticket 6 — Write path + scheduler
Status: Done

**A) Scope** Port `internal/http2/write.go` (the `writeFramer` frame-writer values: settings, headers, data, window-update, rst, goaway, ping) and `writesched.go` + `writesched_roundrobin.go` (the round-robin write scheduler queuing frames per stream). Skip the RFC 9218 priority scheduler.

**B) Migration Strategy** Additive `h2_write.ml`, `h2_writesched.ml`; composes `h2_frame`.

**C) Exit State** Scheduler ordering + frame writers match Go's round-robin behavior.

**D) Detailed Design** `type write_scheduler` with `open_stream`/`close_stream`/`push`/`pop` (returns next frame to write honoring flow control + round-robin). Frame writers produce bytes via the Ticket-4 `Framer`.

**E) Testing Plan** *Unit* (`test/test_h2_writesched.ml`, ported from `writesched_test.go`/`writesched_roundrobin_test.go`): enqueue across streams, assert round-robin pop order; control frames prioritized; flow-control-blocked data deferred.

**F) End-of-Ticket Verification** `dune build && dune test` clean.

**G) Execution Record**

- **Files created:**
  - `lib/h2_write.ml` + `lib/h2_write.mli` (module `Gohttp.H2_write`) — port of `internal/http2/write.go`. Go's `writeFramer` interface (a set of distinct structs) is rendered as a single `write_framer` variant: `Write_settings` (`writeSettings`), `Write_settings_ack` (`writeSettingsAck`), `Write_goaway` (`writeGoAway`), `Write_data` (`writeData`), `Write_handler_panic_rst` (`handlerPanicRST`), `Write_rst_stream` (`StreamError`-as-writer, the `resetStream` path), `Write_ping`/`Write_ping_ack` (`writePing`/`writePingAck`), `Write_window_update` (`writeWindowUpdate`), `Write_res_headers` (`writeResHeaders`, record `write_res_headers`), `Write_push_promise` (`writePushPromise`, record `write_push_promise` with the promised id pre-resolved), `Write_100_continue` (`write100ContinueHeadersFrame`). Predicates `write_ends_stream` (`writeEndsStream`; false for RST_STREAM), `data_size` (the `len(wd.p)` used by `DataSize`/`Consume`). Helpers `httpcode_string` (`httpCodeString`), `encode_headers` (`encodeHeaders` — sorted keys via `String.compare` mirroring `sorterPool.Keys`, `LowerHeader` ASCII lower-casing + `validWireHeaderFieldName` + `ValidHeaderFieldValue` skips, `transfer-encoding: trailers`-only rule). `write_frame ~enc oc w` is the `writeFrame` method dispatch; header writers use `split_header_block` (Go's `splitHeaderBlock`, fixed `split_max_frame_size = 16384`) to emit a HEADERS/PUSH_PROMISE frame + 0+ CONTINUATION frames, encoding the block by capturing `Hpack.set_writer` output. The frame writers ultimately call the Ticket-4 `H2_frame.write_*` functions over an `Lwt_io.output_channel`. (`flushFrameWriter`/`writeContext`/`staysWithinBuffer`/`replyToWriter` are not modeled — see omissions.)
  - `lib/h2_writesched.ml` + `lib/h2_writesched.mli` (module `Gohttp.H2_writesched`) — port of `internal/http2/writesched.go` (`FrameWriteRequest`, the two-stage `writeQueue`, `writeQueuePool`) + `writesched_roundrobin.go` (`roundRobinWriteScheduler`). `type stream = { id; flow : H2_flow.outflow; mutable max_frame_size }` mirrors the `stream` fields the scheduler reads (`stream.id`, `stream.flow`, `stream.sc.maxFrameSize`); `make_stream`. `type frame_write_request = { write; stream : stream option }` (Go's `FrameWriteRequest`; `done` channel omitted — see omissions) with `stream_id` (`StreamID`, falling back to the RST writer's id), `is_control` (`isControl`), `data_size` (`DataSize`), `consume` (`Consume` — `min(n, flow.available())` capped by `maxFrameSize`, `H2_flow.take` on the split/whole path, returns `(consumed, rest, n)` with n ∈ {0,1,2}). Internal `write_queue` is the faithful two-stage `currQueue[currPos:]`+`nextQueue` queue with `prev`/`next` ring links and `wq_empty`/`wq_push`/`wq_shift`/`wq_peek`/`wq_consume`. `type t` = `roundRobinWriteScheduler` (`control` queue, `streams : (int, write_queue) Hashtbl.t`, `head` ring cursor). `create`/`open_stream` (ring insert before head = end of list; panic→`Failure` on dup/0)/`close_stream` (unlink + `Hashtbl.remove`, drops the queue = the `writeQueuePool` GC no-op)/`adjust_stream` (no-op)/`push` (control vs stream queue, closed-stream→control with the `add DATA on non-open stream` panic→`Failure`)/`pop` (control/RST first, then round-robin `consume math.MaxInt32` advancing `head` past the chosen stream, skipping flow-blocked DATA).
- **Files modified:**
  - `test/test_h2_writesched.ml` (new) — 7 cases ported from `writesched_test.go` + `writesched_roundrobin_test.go`: `TestFrameWriteRequestNonData` (DataSize 0 + consumed-whole for SETTINGS-ack and RST), `TestFrameWriteRequest_StreamID` (StreamError writer id), `TestFrameWriteRequestWithData` (flow-blocked → n=0), `TestFrameWriteRequestData` (split by maxFrameSize then by 8 then remainder — asserts the consumed/rest sizes + endStream flags), `TestRoundRobinScheduler` (4 streams of 1..4 frames + 2 control frames; asserts control-first then exact round-robin order `[1;2;3;4;2;3;4;3;4;4]` with each DATA = maxFrameSize), plus two added cases: `flow_control_skip` (a window-blocked DATA stream is skipped while a sibling with window pops, then unblocks once given window — exercises the `Pop` flow-control skip + ring traversal) and `close_stream_drops` (queued DATA is discarded after `close_stream`).
  - `test/test_h2_write.ml` (new) — 10 cases for the write framers: SETTINGS / SETTINGS-ack / WINDOW_UPDATE / DATA / RST_STREAM / GOAWAY / PING-ack round-trip through `H2_frame.read_frame`; `writeResHeaders` (`:status` 200 + lower-cased custom header + content-type/length) and `write100ContinueHeadersFrame` (`:status` 100) read back via `read_meta_headers`; and a `continuation_split` case (a 40000-byte header value forces HEADERS + CONTINUATION via `splitHeaderBlock`, reassembled by `read_meta_headers`). Driven by `Lwt_main.run` over `Lwt_io.pipe ()`, bounded by `Net.with_timeout 10.`.
  - `test/test_gohttp.ml` — wired `("H2Write", Test_h2_write.tests)` and `("H2Writesched", Test_h2_writesched.tests)`.
- **Test evidence:** baseline `jj st` clean + `dune build`/`dune test` = **406** green. After: `dune build` clean, `dune test` = **423 tests run, Test Successful** (terminates in ~0.86s). New suites: **H2Write** = 10, **H2Writesched** = 7 (406 + 17 = 423). Confirmed: round-robin pop order `[1;2;3;4;2;3;4;3;4;4]` (`round_robin_scheduler`), control-frame-first priority (`round_robin_scheduler` + `flow_control_skip`), flow-control-blocked DATA skipped until window available (`flow_control_skip`), and `close_stream` drops queued frames (`close_stream_drops`).
- **Go cases omitted / artifacts:** the RFC 9218 priority scheduler (`writesched_priority_rfc9218.go` + `writesched_priority_rfc9218_test.go`) is a plan non-goal and is not ported. `writeContext`/`flushFrameWriter`/`staysWithinBuffer`/`replyToWriter` and the `done chan error` reply channel are server-loop plumbing (the write context is implemented by `serverConn`); they belong to the Ticket-8 server and are deferred there — the write framers here serialize directly to an `Lwt_io.output_channel` instead of through a `writeContext`. `writeQueuePool.get`/`put` is rendered as plain GC-managed allocation (no pool); `close_stream` simply drops the queue. Go's `panic` on illegal `OpenStream`/`Push` (dup stream, 0, DATA-on-closed) is rendered as `Failure`. `writeData.String` (debug) is not ported. The `encodeHeaders` non-ASCII skip path uses the same `LowerHeader`/`validWireHeaderFieldName` predicates as `h2_frame.ml` (re-implemented locally since they are private there).
- **Commit:** `feat(h2): port write framers and round-robin write scheduler (H2 Ticket 6)` (single jj change; id reported to orchestrator).

### Ticket 7 — Server TLS + ALPN in Net
Status: Done

**A) Scope** Add server-side TLS with ALPN to `Net`: `listen_tls` accepting a certificate + advertised ALPN protocols (`["h2"; "http/1.1"]`), exposing the negotiated protocol per accepted connection; and extend client `connect` with `?alpn` advertising + negotiated-protocol readout. Provide a test self-signed cert helper (mint via `x509`, or vendor Go's `internal/testcert` PEM).

**B) Migration Strategy** Additive to `Net` (existing `listen`/`connect` unchanged; new `listen_tls`/`accept_tls` + `?alpn`). Verify `tls-lwt` server ALPN selection API first.

**C) Exit State** A TLS server advertises ALPN; a TLS client negotiates and both can read the selected protocol; HTTP/1.1-over-TLS still works.

**D) Detailed Design** `listen_tls : ?backlog:int -> certificates:Tls.Config.certchain -> alpn:string list -> string -> int -> server Lwt.t`; `accept_tls : server -> (ic * oc * string option (* negotiated alpn *) * sockaddr) Lwt.t`; `connect ~host ~port ?tls ?alpn () -> (ic * oc * string option)`. Document trust settings.

**E) Testing Plan** *Integration* (`test/test_h2_tls.ml`): loopback TLS handshake with ALPN advertising `["h2";"http/1.1"]`, assert negotiated protocol is `h2`; a second case advertising only `http/1.1` negotiates `http/1.1`. Bounded by `Net.with_timeout`.

**F) End-of-Ticket Verification** `dune build && dune test` clean; handshake tests terminate.

**G) Execution Record**

- **Verified `tls`/`tls-lwt` 2.1.0 ALPN API** (inspected `_opam/lib/tls/config.mli`, `_opam/lib/tls-lwt/tls_lwt.mli`, `_opam/lib/tls/core.ml`, `_opam/lib/x509/x509.mli`):
  - **Server config:** `Tls.Config.server ?alpn_protocols:string list ?certificates:Tls.Config.own_cert ... () : (Tls.Config.server, [> `Msg of string]) result`. ALPN list is in descending preference; the server selects the first advertised protocol the client also offers (documented in `config.mli`'s "Note on ALPN protocol selection"). Certificates passed as `` `Single (certchain) `` where `certchain = X509.Certificate.t list * X509.Private_key.t`.
  - **Server handshake:** `Tls_lwt.Unix.server_of_fd : Tls.Config.server -> Lwt_unix.file_descr -> Tls_lwt.Unix.t Lwt.t`. Channels via `Tls_lwt.of_t : ?close -> Tls_lwt.Unix.t -> ic * oc`.
  - **Negotiated protocol readout:** `Tls_lwt.Unix.epoch : t -> (Tls.Core.epoch_data, unit) result`; the field is `epoch_data.alpn_protocol : string option` (= Go's `tls.ConnectionState.NegotiatedProtocol`). Used identically on both client and server sessions.
  - **Client config:** `Tls.Config.client ~authenticator ?alpn_protocols ... ()`; client handshake `Tls_lwt.Unix.client_of_fd cfg ?host fd`, then the same `epoch`/`alpn_protocol` readout.
  - **Test cert:** minted at runtime via `X509.Private_key.generate ~bits:2048 \`RSA` + `X509.Signing_request.create` (CN=localhost) + `X509.Signing_request.sign` (self-signed, SAN DNS=localhost, BasicConstraints, ~10y validity) — no PEM files. The `mirage-crypto` RNG is seeded with `Mirage_crypto_rng_unix.use_default ()` (new `Net.ensure_rng`) before key-gen / handshake.
- **Files modified:**
  - `lib/net.ml` + `lib/net.mli` — added: `ensure_rng : unit -> unit` (idempotent RNG seed); `test_server_certificate : unit -> Tls.Config.certchain` (runtime self-signed cert); `type tls_server` (listening fd + `Tls.Config.server`); `listen_tls : ?backlog -> certificates:Tls.Config.certchain -> alpn:string list -> string -> int -> tls_server Lwt.t`; `tls_listen_fd : tls_server -> Lwt_unix.file_descr` (for `bound_port` on ephemeral listeners); `accept_tls : tls_server -> (ic * oc * string option * Unix.sockaddr) Lwt.t` (accept + server handshake + negotiated-ALPN readout); `connect_alpn : host:string -> port:int -> ?tls:bool -> ?alpn:string list -> unit -> (ic * oc * string option) Lwt.t` (negotiated protocol as 3rd element). Refactored the client TLS upgrade into `dial`/`client_config`/`negotiated_alpn`/`host_to_domain_name` helpers.
  - **`connect` arity UNCHANGED** (least-disruptive path): `connect` still returns the 2-tuple `(ic, oc)` — now implemented as a thin wrapper over `connect_alpn` discarding the protocol — so the 8 existing 2-tuple call sites (`lib/transport.ml`, `test/test_serve.ml` ×6, `test/test_net.ml`) and all HTTP/1.x tests stay green untouched. The new 3-tuple readout lives on the additive `connect_alpn`.
  - `lib/dune` — added `tls x509 ptime mirage-crypto-rng.unix fmt` to the `gohttp` library deps (alongside the existing `tls-lwt`).
  - `test/test_h2_tls.ml` (new) — 3 cases, all bounded by `Net.with_timeout 15.` over an ephemeral loopback TLS server: `alpn_negotiates_h2` (both peers `["h2";"http/1.1"]` ⇒ client and server both read `Some "h2"`), `alpn_negotiates_http11` (server `["h2";"http/1.1"]`, client `["http/1.1"]` ⇒ both read `Some "http/1.1"`), `tls_byte_roundtrip` (client writes a line over the TLS channels, server echoes, client reads it back — proves the buffered `Lwt_io` channels over the TLS session carry data).
  - `test/test_gohttp.ml` — wired `("H2Tls", Test_h2_tls.tests)`.
- **Test evidence:** baseline `jj st` clean + `dune build`/`dune test` = **423** green. After: `dune build` clean, `dune test` = **426 tests run, Test Successful** (terminates in ~0.97s — handshake tests bounded, no hang). New **H2Tls** suite = **3** cases (423 + 3 = 426). Confirmed: real loopback TLS handshake completes, **ALPN negotiates `h2`** when both advertise it, falls back to `http/1.1` when the client offers only that, and a byte round-trip over the TLS channels succeeds.
- **Go cases omitted / artifacts:** no direct Go source file (Go uses `crypto/tls`); behavior-fidelity instead of source-fidelity. The runtime self-signed cert replaces Go's vendored `internal/testcert` PEM (no files on disk; the client's `null_authenticator` skips verification). The SAN omits the IP entry (`General_name.IP` wants raw 4-byte octet strings and the client does not verify, so DNS=localhost suffices). `Net.ensure_rng` / `Mirage_crypto_rng_unix.use_default` is OCaml-stack RNG bookkeeping with no Go analogue (Go's `crypto/rand` is implicitly seeded).
- **Commit:** `feat(h2): add server-side TLS and ALPN negotiation to Net (H2 Ticket 7)` (single jj change; id reported to orchestrator).

### Ticket 8 — HTTP/2 server connection
Status: Done

**A) Scope** Port `internal/http2/server.go` (HTTP/2 subset): `H2_server.serve conn ~handler` — read+validate client preface, send/receive SETTINGS, run the frame-read loop, manage the stream state machine + flow control + write scheduler, decode HEADERS into a `Request.t` with a streaming `Body` fed by DATA via `H2_pipe`, invoke the supplied `handler` (the existing `Server` handler type, passed in to avoid a module cycle), and write the `Response.t` as HEADERS+DATA honoring flow control. Handle RST_STREAM/GOAWAY/PING/WINDOW_UPDATE. Server Push send path out of scope.

**B) Migration Strategy** Additive `h2_server.ml`; `Server` (HTTP/1.x) will call it in Ticket 10. Map Go's goroutines/channels to Lwt fibers + `Lwt_condition`/`Lwt_mvar`.

**C) Exit State** An `H2_server.serve` over a duplex channel pair serves a handler for a GET and a POST; flow control + multiple concurrent streams work.

**D) Detailed Design** `serve : Lwt_io.input_channel -> Lwt_io.output_channel -> handler:(...) -> unit Lwt.t` (handler signature matches `Server`'s). Internal `serverConn`/`stream` records mirroring Go; `response_writer` impl that frames output.

**E) Testing Plan** *Integration* (`test/test_h2_server.ml`, ported subset of `server_test.go`): drive a raw client (Framer from Ticket 4) over an `Lwt_io.pipe` pair against `H2_server.serve` — send preface+SETTINGS+HEADERS, assert response HEADERS `:status:200` + DATA body; POST with DATA echoed; two concurrent streams. Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record**

- **Files created:**
  - `lib/h2_server.ml` + `lib/h2_server.mli` (module `Gohttp.H2_server`) — port of the HTTP/2 subset of `internal/http2/server.go`. To avoid a module cycle with the HTTP/1.x `Server` (which will call this in Ticket 10), `H2_server` defines its **own** `response_writer` record (`header`/`write_header`/`write`/`flush`, structurally identical to `Server.response_writer` plus a `flush`) and `handler = response_writer -> Body.t Request.t -> unit Lwt.t`, rather than depending on `Server`. Composes `H2`, `H2_error`, `H2_frame` (`read_frame`/`read_meta_headers`/`write_*`), `Hpack` (response encoder, request decoder), `H2_flow` (conn + per-stream in/outflow), `H2_pipe`/`H2_databuffer` (streaming request body), `H2_write`/`H2_writesched` (writer values + round-robin scheduler), `Header`, `Request`, `Body`, `Uri`, `Context`.
    - **Records mirroring Go:** `server_conn` (mirrors `serverConn`: `flow`/`conn_inflow`, `write_sched`, `streams : (int,stream) Hashtbl.t`, `saw_first_settings`/`need_to_send_settings_ack`/`unacked_settings`/`queued_control_frames`/`cur_client_streams`/`cur_handlers`/`max_client_stream_id`/`initial_stream_send_window`/`initial_stream_recv_window`/`max_frame_size`/GOAWAY bookkeeping/`unstarted` handler queue). `stream` (mirrors `stream`: `sched` = the `H2_writesched.stream` carrying id+outflow+max_frame_size shared by reference with the scheduler, `body : H2_pipe.t option`, `inflow`, `body_bytes`/`decl_body_bytes`, `state : stream_state` = idle/open/half-closed-local/half-closed-remote/closed, `reset_queued`/`got_trailer_header`/`wrote_headers`/`close_err`, a `cw` `Lwt_condition` for the closed transition, `trailer`/`req_trailer`).
    - **Handshake:** `serve` sends the server's initial SETTINGS (`MaxFrameSize`/`MaxConcurrentStreams`/`InitialWindowSize`/`HeaderTableSize`), reads+validates the client preface (`read_preface` via `Lwt_io.read_into_exactly`), then runs the serve loop; the first client frame must be SETTINGS (else PROTOCOL_ERROR), and the client's SETTINGS are ACKed (`need_to_send_settings_ack` → `scheduleFrameWrite`).
    - **Frame loop / state machine:** `process_frame` dispatch porting `processFrame` → `process_settings` (incl. `processSettingInitialWindowSize` window re-base over all streams, HEADER_TABLE_SIZE → `Hpack.set_max_dynamic_table_size`, MAX_FRAME_SIZE re-base), `process_headers` (odd-id rule, MAX_CONCURRENT_STREAMS → RST_STREAM REFUSED_STREAM, build `Request.t`, trailers on an existing stream), `process_data` (conn+stream flow control via `take_inflows`, declared-Content-Length overflow, padding flow-control refund, `end_stream` closing the body pipe), `process_window_update`, `process_ping` (→ PING ACK), `process_reset_stream` (→ `close_stream`), `process_goaway`. Connection errors → `go_away` + GOAWAY then end; stream errors → `reset_stream` (queue RST_STREAM).
    - **Request construction:** `build_request` ports `newWriterAndRequest`/`newWriterAndRequestNoBody`: `:method`/`:path`/`:scheme`/`:authority` pseudo-headers → `Request.t` fields (PROTOCOL_ERROR on malformed/missing, CONNECT special-case), regular fields → canonicalized `Header.t`, authority falls back to `Host`, Content-Length → `content_length`, and a streaming `Body.Stream` fed by a per-stream `H2_pipe` (DATA frames `H2_pipe.write` into it; the handler's `Body` reader awaits it and posts `Body_read` to refund flow control via WINDOW_UPDATE — `noteBodyRead`).
    - **Response path:** `new_response_writer` builds the `response_writer`; body bytes buffer until `flush`/handler completion. `write_chunk` ports `responseWriterState.writeChunk`: implicit `WriteHeader(200)`, Content-Length/Content-Type defaulting + body-allowed-for-status, then frames HEADERS (`Write_res_headers` via the Hpack encoder, split into CONTINUATION by `H2_write`) and DATA (`Write_data`), setting END_STREAM on the final frame. `run_handler` runs the handler in its own fiber, flushes the tail, and posts `Handler_done`; a handler exception → `Write_handler_panic_rst`.
    - **Concurrency mapping (Go goroutines/channels → Lwt):** Go's `serve` goroutine and its `select` over `readFrameCh`/`wantWriteFrameCh`/`wroteFrameCh`/`bodyReadCh`/`serveMsgCh` become **one serve fiber** (`serve_loop`) draining a single `Lwt_stream` of an `event` variant (`Read_frame`/`Read_meta`/`Read_error`/`Want_write_frame`/`Body_read`/`Handler_done`); that fiber exclusively owns every `server_conn`/`stream` mutable field and is the **sole writer** of the output channel (Go's "the serve goroutine never blocks; only handlers do"). Go's `readFrames` goroutine → a **reader fiber** (`read_loop`) that reads frames, assembles HEADERS+CONTINUATION via `read_meta_headers`, and posts `Read_frame`/`Read_meta`/`Read_error`. Each handler runs via `Lwt.async`; it posts `Want_write_frame` (Go's `wantWriteFrameCh`/`writeFrameFromHandler`) and `Body_read` (Go's `bodyReadCh`/`noteBodyReadFromHandler`) and blocks on an `Lwt_condition` for the frame-write result (Go's `wr.done` channel in `writeDataFromHandler`), raced against a `done_serving` condition (Go's `doneServing` close) so a dead connection unblocks handlers. Go's `writeFrameAsync` + `wroteFrame` are **fused** into `start_frame_write`: since `Lwt_io` writes are awaited inline on the single-writer serve fiber, the frame is written then the `wroteFrame` stream-state bookkeeping (END_STREAM → half-closed-local + RST_STREAM NO_ERROR, RST close, panic close) runs immediately. Go's per-stream request `pipe` is the existing `H2_pipe` (its `Lwt_condition` replaces Go's `sync.Cond`).
- **Files modified:**
  - `test/test_h2_server.ml` (new) — 3 integration cases ported from `server_test.go`, each bounded by `Net.with_timeout 15.` over a **full-duplex pair of `Lwt_io.pipe ()`** (client→server + server→client) driving a raw HTTP/2 client (the Ticket-4 `H2_frame` writers + Ticket-3 `Hpack` encoder/decoder) against `H2_server.serve`, with a connection-wide HPACK decoder (HPACK is stateful across streams): `get` (preface+SETTINGS+HEADERS GET `/`, END_STREAM+END_HEADERS; handler replies 200 + "hello"; asserts response `:status`=200 and a DATA frame carries "hello"), `post_echo` (HEADERS POST + DATA("ping") END_STREAM; handler echoes `Body.read_all`; asserts DATA "ping" back), `two_streams` (concurrent ids 1 and 3, distinct `/a`/`/b` paths echoed; asserts both get `:status`=200 and the right body). Helpers do the SETTINGS handshake and `collect_frames … ~until:(saw_end_stream id)` (collects until the server sets END_STREAM/RST on the stream).
  - `test/test_gohttp.ml` — wired `("H2Server", Test_h2_server.tests)`.
- **Test evidence:** baseline `jj st` clean + `dune build`/`dune test` = **426** green. After: `dune build` clean, `dune test` = **429 tests run, Test Successful** (terminates in ~1.0s — all bounded by `Net.with_timeout`, no hang/deadlock). New **H2Server** suite = **3** cases (426 + 3 = 429). Confirmed: GET 200 + "hello", POST body echo, and two concurrent streams each get a 200 response + correct body.
- **Go cases/features omitted / artifacts:** **Server push** (`startPush`/PUSH_PROMISE send path) — plan non-goal (parse-only). **RFC 9218 / RFC 7540 priority** (`priorityWriteScheduler`, `processPriority`/`processPriorityUpdate`, `AdjustStream`) — plan non-goal; the round-robin scheduler is used and PRIORITY/PRIORITY_UPDATE frames are accepted-and-ignored. **100-continue auto-send** (`requestBody.needsContinue`/`write100ContinueHeaders`) — the `Write_100_continue` writer and its suppression logic exist in `write_frame`, but `serve` does not auto-emit it (handlers don't request it in this subset). **Timers** (`firstSettingsTimeout`/`idleTimeout`/`SendPingTimeout`/read+write deadlines, `time.AfterFunc`) — omitted; the test harness bounds liveness with `Net.with_timeout`, and EOF on the client→server pipe ends `serve` (Go's `readFrames` EOF path). **Graceful-shutdown machinery** (`startGracefulShutdown`/`shutdownTimer`/`goAwayTimeout`) — reduced to: a connection-error GOAWAY is sent then the loop ends; a received GOAWAY sets `in_goaway`. **`ConnState` hooks**, **`canonicalHeader` cache**, **`bufferedWriter`/`sync.Pool`/`writeQueuePool`/`writeDataPool`** (GC-managed in OCaml, no pools), **`closeNotifier`/`SetReadDeadline`/`EnableFullDuplex`/`Hijack`** are not modeled. **Mid-stream/undeclared trailers** (`TrailerPrefix`/`promoteUndeclaredTrailers`) and **HEAD-response** content-length nuances are simplified (predeclared `Trailer` accumulation on a trailing HEADERS frame is accepted but not re-emitted to the handler request). **Content sniffing** (`DetectContentType`) is reduced to a `text/plain; charset=utf-8` default when no Content-Type is set and a body exists. Go's `writeFrameAsync`/`wroteFrame` split (a separate goroutine + `wroteFrameCh`) is collapsed to a synchronous inline write on the single-writer serve fiber (faithful behavior, not faithful goroutine count — `Lwt_io` writes are non-blocking from the loop's view). The handler-reply association (Go's `wr.done` channel) is a `(write_framer * Lwt_condition) list` keyed by physical identity (`==`) of the freshly-allocated writer value, removed on reply.
- **Commit:** `feat(h2): port HTTP/2 server connection (serverConn, streams, dispatch) (H2 Ticket 8)` (single jj change; id reported to orchestrator).

### Ticket 9 — HTTP/2 transport (client)
Status: Done

**A) Scope** Port `internal/http2/transport.go` + `client_conn_pool.go` (subset): `H2_transport` — establish a `ClientConn` over a duplex channel (preface + SETTINGS), allocate stream IDs, send a `Request.t` as HEADERS(+DATA), read HEADERS/DATA into a `Response.t` (streaming body via `H2_pipe`), multiplex concurrent streams, basic conn pool keyed by authority. Flow control + WINDOW_UPDATE + GOAWAY handling.

**B) Migration Strategy** Additive `h2_transport.ml`; `Transport`/`Client` call it in Ticket 10. Lwt fibers for the read loop.

**C) Exit State** `H2_transport` round-trips a request against the Ticket-8 server over an in-process channel pair (GET + POST), reads status + body.

**D) Detailed Design** `new_client_conn : Lwt_io.input_channel -> Lwt_io.output_channel -> client_conn Lwt.t`; `round_trip : client_conn -> Body.t Request.t -> Body.t Response.t Lwt.t`. Stream table (`Hashtbl` id→stream), shared read loop dispatching frames to per-stream Lwt wakers.

**E) Testing Plan** *Integration* (`test/test_h2_transport.ml`, ported subset of `transport_test.go`): connect a `ClientConn` to `H2_server.serve` over a connected `Lwt_io` socket pair (loopback), GET → 200 + body; POST body echoed; two concurrent round trips multiplexed on one conn. Bounded.

**F) End-of-Ticket Verification** `dune build && dune test` clean; tests terminate.

**G) Execution Record**

- **Files created:**
  - `lib/h2_transport.ml` + `lib/h2_transport.mli` (module `Gohttp.H2_transport`) — port of the client subset of `internal/http2/transport.go` + `client_conn_pool.go`. Works only over given `Lwt_io` channels (does not dial / depend on the HTTP/1.x `Transport`/`Client`, to avoid a module cycle — Ticket 10 wires those to call this). Composes `H2`, `H2_error`, `H2_frame` (`read_frame`/`read_meta_headers`/`write_*`), `Hpack` (request encoder reused across requests + a shared response decoder), `H2_flow` (conn + per-stream in/outflow), `H2_pipe`/`H2_databuffer` (streaming response body), `Header`, `Request`, `Response`, `Body`, `Status`, `Uri`.
    - **Records mirroring Go:** `client_conn` (mirrors `ClientConn`: `wmu` write mutex, `henc`, shared `hdec`, conn `conn_flow`/`conn_inflow`, `cond` broadcast on flow/closed changes, `streams : (int,client_stream) Hashtbl.t`, `next_stream_id`, peer settings `max_frame_size`/`max_concurrent_streams`/`initial_window_size`, our `initial_stream_recv_window`, `closed`/`closing`/`goaway`/`want_settings_ack`/`seen_settings` + `seen_settings_cond`, `reader_err`/`reader_done` + `req_header_mu`). `client_stream` (mirrors `clientStream`: `id`, `buf_pipe` response payload pipe, per-stream `flow`/`inflow`, `bytes_remain`, `res` + `resp_recv`, `peer_closed`, `abort_err`/`abort`, `past_headers`/`read_closed`/`read_aborted`/`is_head`).
    - **`new_client_conn ic oc`** ports `newClientConn`: writes the client preface + initial SETTINGS (`ENABLE_PUSH=0`, `INITIAL_WINDOW_SIZE`, `MAX_FRAME_SIZE`) + a conn-level WINDOW_UPDATE, inits the conn inflow, starts the shared read-loop fiber, and resolves once the server's first SETTINGS frame has been seen (Go's `seenSettingsChan`).
    - **`round_trip cc req`** ports `ClientConn.roundTrip`/`clientStream.writeRequest` + `encodeAndWriteHeaders`: under `req_header_mu` (Go `reqHeaderMu`) it allocates the next odd stream id, registers the stream, encodes pseudo-headers (`:authority`/`:method`/`:path`/`:scheme`) + headers via HPACK (port of `httpcommon.EncodeHeaders`' `enumerateHeaders` order + connection-specific-header skipping + lower-casing + content-length/user-agent defaulting) and writes the HEADERS frame (split into CONTINUATION by `max_frame_size`, END_STREAM when no body). The request body is written in a separate fiber (Go's `doRequest` goroutine) via `write_request_body`/`await_flow_control` (port of `writeRequestBody`/`awaitFlowControl`: respects per-stream + conn outflow windows, waits on `cond`, sends a trailing empty END_STREAM DATA for streamed bodies). It then awaits the response HEADERS and returns a `Response.t` whose body is a `Body.Stream` fed by DATA frames through the per-stream `H2_pipe` (END_STREAM closes the pipe with `End_of_file`, surfaced as stream end).
    - **Read loop** (`read_loop`, Go's `clientConnReadLoop.run`): reads frames, requires the first to be SETTINGS (else PROTOCOL_ERROR), and dispatches — `process_headers` (port of `processHeaders`/`handleResponse`: build `Response.t`, `:status`→`status_code`, 1xx ignored-and-retried, trailers end the stream, truncated→stream error), `process_data` (conn+stream flow control via `take_inflows`, padding refund, write into `buf_pipe`, WINDOW_UPDATE refunds, unsolicited-DATA→conn error), `process_settings` (ACK bookkeeping + `INITIAL_WINDOW_SIZE` re-base over open streams + `HEADER_TABLE_SIZE`→encoder + ACK write; first SETTINGS resolves `seen_settings`), `process_window_update` (unblock outflow + broadcast `cond`; per-stream overflow→stream reset, conn overflow→conn error), `process_reset_stream` (abort + close pipe), `process_ping` (PING ACK), `process_goaway` (abort streams above LastStreamID), PUSH_PROMISE→PROTOCOL_ERROR. Frame-level `Stream_error`s reset just that stream and keep the loop alive; EOF / connection errors end the loop and abort pending streams.
    - **Minimal conn pool** (`type t` + `create`/`round_trip_pooled`): `Hashtbl` authority(`host[:port]`)→`client_conn list`; `round_trip_pooled t ~connect req` reuses a usable conn or dials a new one via the supplied `connect authority` (returning a duplex `(ic,oc)`), then `round_trip`s. `close cc` marks closed + aborts.
- **Concurrency mapping (Go goroutines/channels → Lwt):** Go's `ClientConn.readLoop` goroutine → a single read-loop fiber (started by `new_client_conn` via `Lwt.async`, exception-guarded) that exclusively owns the connection's mutable state and dispatches frames. Go's `cc.cond` (`sync.Cond` broadcast on flow/closed changes) → an `Lwt_condition.t`; a flow-blocked request-body write awaits it (`await_flow_control` = Go's `awaitFlowControl` `cc.cond.Wait()` loop). Each per-stream channel maps to a condition or a once-set flag: `respHeaderRecv`→`resp_recv`+`res`, `peerClosed`→`peer_closed`, `abort`→`abort`+`abort_err`, `readerDone`→`reader_done`+`reader_err`. Go's per-stream response `bufPipe` is the existing `H2_pipe` (its internal `Lwt_condition` replaces Go's `sync.Cond`). Go's `wmu` write mutex → an `Lwt_mutex.t` serializing every channel write (HEADERS, DATA, WINDOW_UPDATE, PING ACK, SETTINGS ACK). Go's `reqHeaderMu` 1-element semaphore (stream-id alloc + HEADERS write) → an `Lwt_mutex.t`. Go's `doRequest` goroutine (write request, then read response concurrently) → an `Lwt.async` body-writer fiber while `round_trip` awaits the response on the calling fiber.
- **Files modified:**
  - `test/test_h2_transport.ml` (new) — 3 integration cases ported from `transport_test.go` (`TestTransport` GET / POST / concurrent), each bounded by `Net.with_timeout 15.` over a **real loopback TCP socket pair** (`Net.listen`/`accept`/`connect`) connecting an `H2_transport` `client_conn` to `H2_server.serve` (Ticket 8) running in a separate fiber with a test handler: `get` (handler 200+"hello"; `round_trip` of a GET ⇒ `status_code` 200, body "hello"), `post_echo` (handler echoes `Body.read_all`; client POSTs "ping" ⇒ body "ping"), `concurrent` (`Lwt.both` of two GETs `/a`/`/b` multiplexed on ONE `client_conn` ⇒ both 200 with the right body).
  - `test/test_gohttp.ml` — wired `("H2Transport", Test_h2_transport.tests)`.
- **Test evidence:** baseline `jj st` clean + `dune build`/`dune test` = **429** green. After: `dune build` clean, `dune test --force` = **432 tests run, Test Successful** (terminates in ~1.1s — all bounded by `Net.with_timeout`, no hang/deadlock). New **H2Transport** suite = **3** cases (429 + 3 = 432). Confirmed: GET 200 + "hello", POST body echo "ping", and two concurrent round trips on one `client_conn` each get 200 + the correct body — all against the real Ticket-8 `H2_server` over a loopback socket.
- **Go cases/features omitted / artifacts:** **Request body trailers** (`encodeTrailers`/`writeRequestBody` trailer path) — sent as an empty END_STREAM DATA instead; response trailers (`processTrailers`/`copyTrailers`) end the stream but are not re-surfaced on `Response.trailer`. **gzip auto-decompression** (`requestedGzip`/`gzipReader`/Accept-Encoding) — not added (the HTTP/1.x layer doesn't auto-gzip either). **`Ping`** (client-initiated PING + ack-waiter map), **healthCheck / read+write idle timeouts**, **`responseHeaderTimeout`**, **100-continue** (`on100`/expectContinue), **extended CONNECT** (`:protocol`/`SETTINGS_ENABLE_CONNECT_PROTOCOL`), **HEAD-specific content-length** nuances, and **`bytesRemain` over-Content-Length truncation enforcement** in the body reader are simplified/omitted (the streaming body relies on END_STREAM). **GOAWAY retry semantics** (`errClientConnGotGoAway` retry-on-new-conn, `pendingResets`/RST+PING gRPC workaround, `MarkDead`) — reduced to aborting streams above LastStreamID. **The conn pool** is the minimal authority→conn-list reuse (`canTakeNewRequest`/`maxConcurrentStreams` admission control, `awaitOpenSlotForStreamLocked`, idle-timeout eviction, `singleUse`/`doNotReuse`, `Shutdown`/`closeIfIdle`) is not modeled — Ticket 10 wires the real `Transport`. `bufPools`/`frameScratchBufferLen` chunk pooling is GC-managed (no pool). `sync.Cond`/channels are `Lwt_condition`/once-set flags as described above.
- **Commit:** `feat(h2): port HTTP/2 client transport (ClientConn, multiplexed round trips) (H2 Ticket 9)` (single jj change; id reported to orchestrator).

### Ticket 10 — ALPN wiring + end-to-end integration
Status: Done

**A) Scope** Wire it together: `Server.listen_and_serve` (and a new TLS variant) uses `Net.listen_tls` with ALPN `["h2";"http/1.1"]` and dispatches each accepted connection to `H2_server.serve` or the HTTP/1.x serve loop by negotiated protocol; `Transport`/`Client` connect with ALPN and use `H2_transport` when "h2" is negotiated (or when forced), falling back to HTTP/1.x. Optional `h2c` stretch only if cheap.

**B) Migration Strategy** Modify `Server`/`Client`/`Transport` to branch on ALPN; existing HTTP/1.x call sites and tests stay green. New public entry: `Server.listen_and_serve_tls`.

**C) Exit State** **Success Criterion `H2.clientserver_roundtrip` passes**: real TLS+ALPN gohttp server ↔ gohttp client over `h2`, GET + POST on one multiplexed connection, `:status` 200 + body equality; and an HTTP/1.1 client against the same TLS port still works (fallback).

**D) Detailed Design** `Server.listen_and_serve_tls : certificates:… -> string -> int -> handler -> unit Lwt.t`. `Transport` gains `?force_h2`/ALPN-driven selection. Dispatch by the negotiated-protocol string from Ticket 7.

**E) Testing Plan** *Integration* (`test/test_h2_clientserver.ml`): the Success-Criterion e2e over loopback TLS (GET+POST, multiplexed); plus a fallback case where the client advertises only `http/1.1` and gets served by the HTTP/1.x path. Bounded by `Net.with_timeout`.

**F) End-of-Ticket Verification** `dune build && dune test` clean; e2e tests terminate.

**G) Execution Record**

- **Files modified:**
  - `lib/server.ml` + `lib/server.mli` — added the HTTP/2-over-TLS dispatch. New public entry points: `default_alpn_protocols = ["h2"; "http/1.1"]`; `listen_and_serve_tls : certificates:Tls.Config.certchain -> ?alpn:string list -> addr:string -> port:int -> handler -> unit Lwt.t` (Go's `ListenAndServeTLS`); and `listen_and_serve_tls_started` (the bind-first/return-port variant for tests, mirroring `listen_and_serve_started`). Internals: `serve_tls srv tls_srv` is the accept loop over a `Net.tls_server` (`Net.accept_tls` does the handshake + ALPN readout per connection), racing `Net.accept_tls` against the server's `stop` promise exactly like the plaintext `serve`; each accepted connection is dispatched in its own `Lwt.async` fiber by `serve_tls_conn`. **Plaintext `listen_and_serve`/`serve` are unchanged.**
  - `lib/transport.ml` + `lib/transport.mli` — ALPN-driven client protocol selection. `round_trip` gained `?force_h2:bool` (default false). For `scheme = "https"` (or `force_h2`) the dial now uses `Net.connect_alpn ~alpn:["h2"; "http/1.1"]` (`force_h2` advertises only `["h2"]`) via a new `dial_alpn` helper that returns the negotiated protocol; the legacy `dial` is `dial_alpn … ~force_h2:false` discarding it. A new h2 connection pool `h2_conns : (string, H2_transport.client_conn) Hashtbl.t` keyed by authority `"host:port"` (parallel to the existing h1 `idle_conn` pool) reuses live `client_conn`s (evicting via `H2_transport.is_closed`). Plaintext `http` keeps the unchanged HTTP/1.x `attempt` path. New test hook `h2_round_trip_count : t -> int`.
  - `lib/h2_transport.ml` + `lib/h2_transport.mli` — added `is_closed : client_conn -> bool` (`closed || closing`) so the transport pool can evict dead h2 conns.
  - `bin/main.ml` — extended the demo to also do a TLS+ALPN h2 round trip (`Server.listen_and_serve_tls_started` advertising `["h2"; "http/1.1"]` + `Client.get` over `https://…`, printing the h2 round-trip count). Both demos run and print 200 + body (verified: plaintext h1 and `h2 round trips: 1`).
- **How the dispatch / adapter works:**
  - **Server dispatch:** `serve_tls_conn` branches on the negotiated ALPN string from `Net.accept_tls`: `Some "h2"` → `H2_server.serve ic oc ~handler:(h2_handler_of_handler handler)`; anything else (incl. no ALPN) → the existing HTTP/1.x keep-alive serve loop (`Io.read_request`/`serve_one`) over the same TLS channels, with per-conn/per-request `Context` cancellation matching the plaintext path. Channels are closed in the finalizer either way.
  - **Server adapter (`Server.handler` ↔ `H2_server`):** the two `response_writer` types are structurally identical except `H2_server.response_writer` adds a `flush`. `h2_handler_of_handler` builds the `H2_server.response_writer`, projects it to a `Server.response_writer` (the three shared fields `header`/`write_header`/`write`, dropping `flush`), runs the user's `serve_http w r`, then calls `h2w.flush ()` to push the buffered headers/body onto the wire. No shared-signature refactor was needed — a straight field projection bridges them, keeping the single existing `Server.handler` type serving both protocols.
  - **Client routing:** `Transport.round_trip` for https first tries a pooled h2 `client_conn` for the authority; otherwise dials with ALPN. Negotiated `"h2"` → `H2_transport.new_client_conn` (pooled by authority) + `H2_transport.round_trip`; negotiated `http/1.1`/none → the HTTP/1.x exchange over the freshly-dialed channels. The client accepts the self-signed test cert via the existing `Net.connect_alpn` → `null_authenticator` path. `Client.get`/`post`/`head` signatures are unchanged; they gain the h2 behavior transparently because `Client.do_` composes `Transport.round_trip`.
- **Files created:**
  - `test/test_h2_clientserver.ml` (new) — 2 e2e cases over **real loopback TLS** (`Server.listen_and_serve_tls_started` on an ephemeral port with `Net.test_server_certificate`), bounded by `Net.with_timeout 30.`:
    - **`clientserver_roundtrip` (THE SUCCESS CRITERION):** server advertises `["h2"; "http/1.1"]`; the gohttp `Client` (https) does a GET (`/hello` ⇒ 200 + `"hello, h2"`) then a POST (`/echo` ⇒ echoed `"ping-pong"`), both on the **same pooled, multiplexed h2 connection**; asserts `Transport.h2_round_trip_count = 2` (proving h2 was used for both).
    - **`http11_fallback`:** server advertises only `["http/1.1"]`; the same gohttp Client over TLS is served by the HTTP/1.x path ⇒ 200 + body, with `h2_round_trip_count = 0`.
  - `test/test_gohttp.ml` — wired `("H2ClientServer", Test_h2_clientserver.tests)`.
- **Test evidence:** baseline `jj st` clean + `dune build`/`dune test` = **432** green. After: `dune build` clean, `dune test --force` = **434 tests run, Test Successful** (terminates in ~1.33s — all e2e bounded by `Net.with_timeout`, no hang). New **H2ClientServer** suite = **2** cases (432 + 2 = 434). **Success Criterion `H2.clientserver_roundtrip` passes** (GET 200 + body, POST echoed body, both over h2 on one multiplexed connection — `h2_round_trip_count = 2`), **and the http/1.1 fallback works** (200 + body, `h2_round_trip_count = 0`). All prior 432 tests stay green.
- **Go behaviors omitted / artifacts:** **h2c cleartext upgrade** — left unimplemented (plan optional/stretch; TLS-ALPN is the required path). **Client `?force_h2`** is exposed on `Transport.round_trip` but not threaded through `Client.get`/`post`/`head` (their signatures are kept per the ticket; the Success Criterion exercises natural ALPN negotiation over https rather than forcing). The h2 conn pool is a minimal authority→single-conn reuse (no `maxConcurrentStreams` admission control / idle-timeout eviction beyond `is_closed`) — matching the Ticket-9 pool scope. `h2_round_trip_count` is an OCaml test hook with no Go analogue (used to assert the path taken).
- **Commit:** `feat(h2): wire ALPN h2 into Server/Client with TLS and h1 fallback (H2 Ticket 10)` (single jj change; id reported to orchestrator).

Status: Done

---

## Follow-up — TLS server-certificate verification (security fix)

The HTTP/2 work shipped the TLS client substrate with a **null authenticator**
(`Net.null_authenticator`, accept-any), which is MITM-vulnerable and does NOT
match Go's `http.Client` (which verifies against the system trust store unless
`InsecureSkipVerify` is set). Fixed:

- **`Net`** — added `default_authenticator : unit -> X509.Authenticator.t`
  (built from the OS trust store via `Ca_certs.authenticator ()`; raises with a
  clear message if the store can't be loaded). `connect`/`connect_alpn`/
  `client_config` now take `?authenticator` / `?insecure` and **verify by
  default** (chain via system trust + hostname via the `?host` already passed to
  `Tls_lwt.Unix.client_of_fd` for SNI). `null_authenticator` is kept as the
  documented insecure opt-out (`?insecure:true`); an explicit `?authenticator`
  overrides. `ca-certs` added to `lib/dune` + `gohttp.opam`.
- **`Transport`** — `create ?insecure ?authenticator ()` stores the policy on
  `t` and threads it into the https `connect_alpn` dial; secure by default.
- **`Client`** — `create ?insecure ?authenticator ()`; with no explicit
  `?transport` an override builds a fresh transport carrying it, else reuses the
  secure `default_transport`.
- **Tests/demo** — `test/test_h2_tls.ml`, `test/test_h2_clientserver.ml` and
  `bin/main.ml`'s h2 demo hit a **self-signed cert over a `127.0.0.1` literal**,
  which legitimately fails verification (untrusted chain + IP, no hostname), so
  they now pass `~insecure:true`. No status/body assertion was weakened; the
  production default stays secure.
- **Evidence:** `dune build` clean; `dune test` = **434 tests, Test Successful**
  (terminates ~1.4s). Verified the default path actually verifies: a secure
  (no-`?insecure`) client connecting to the self-signed loopback server is
  **rejected** at the handshake (X509 validation error) rather than connecting.

Commit: `feat(tls): verify server certificates by default via system trust, with insecure opt-out`.

---

## HTTP/2 plan complete

All 10 tickets are **Done**. gohttp now ports Go's `net/http` HTTP/2 stack end-to-end: HPACK (Huffman + static/dynamic tables + encoder/decoder), the frame layer (Framer + all frame types), flow control / data buffer / stream pipe, the write framers + round-robin scheduler, the `H2_server` connection (serverConn + stream state machine), the `H2_transport` client (multiplexed `ClientConn` + pool), server-side TLS + ALPN in `Net`, and — this ticket — the public `Server`/`Client` transparently selecting HTTP/2 over TLS via ALPN with HTTP/1.1 fallback. Final suite: **434 tests green**. The two RFC Success Criteria (`Hpack.roundtrip`, `Frame.roundtrip`) and the integration Success Criterion (`H2.clientserver_roundtrip`: real TLS+ALPN gohttp server ↔ client over `h2`, GET + POST on one multiplexed connection) all pass.
