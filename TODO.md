# TODO

1. Create a README
---

## Malicious-peer hardening (bad clients / bad servers)

Close the gaps vs Go's `net/http` in defending against malicious or buggy peers — abusive
clients attacking the server, malicious servers attacking the client — across HTTP/1.x and
HTTP/2. Scoped from a 15-case attack matrix against the vendored Go source (`go/src/net/http/`,
the spec of record). Tickets are serial in the listed order; **T3/T6 depend on T2** (the bounded
read layer); **T8–T11 are independent**. A shippable severity-first subset is the five HIGH
tickets: **T1, T2, T8, T9, T6**.

**Constraints (per `CLAUDE.md`):** mirror Go's mechanism, constant values, and error semantics;
cite `go/src/net/http/*.go:line`. Enforce bounds *incrementally* (byte budgets, deadlines) — never
buffer a whole message to measure it. Handleable limit/protocol violations are typed `Result`/error
variants per module; unhandleable bugs stay `raise`. Every new public fn/field gets an `.mli` entry.
**Defaults must match Go:** `DefaultMaxHeaderBytes = 1<<20`, `MaxResponseHeaderBytes` default
`10<<20`, `maxQueuedControlFrames = 10000`, `defaultMaxStreams = 250`, chunked `maxLineLength = 4096`,
rapid-reset backlog `4*advMaxStreams`.

**Done / no ticket (already faithful):** CL+TE:chunked conflict — TE wins, CL stripped
(`transfer.ml:267-270`); duplicate/invalid Content-Length (`transfer.ml:233-256`, `:205-221`);
CONTINUATION flood / CVE-2024-27316 — `2*remainSize` cap (`h2_frame.ml:620`).
Out of scope: the bounded post-handler body drain (`Body.drain ~limit:max_post_handler_read_bytes`,
already shipped) and the separately-tracked `Body`-as-`io.ReadCloser` gap (see "Smaller / cleanup").

**Attack matrix (severity / ticket):**

| # | Case | Dir/proto | Go mechanism (ref) | httpg today | Verdict / ticket |
|---|------|-----------|--------------------|--------------|------------------|
| 1 | Slowloris / idle & header read timeouts | client→server h1 | `ReadHeaderTimeout`/`IdleTimeout`, `SetReadDeadline` (`server.go:1017`,`:2145`) | no timeouts anywhere | HIGH · T1 |
| 2 | Oversized / too-many request headers | client→server h1 | `DefaultMaxHeaderBytes=1<<20`, `setReadLimit`/`hitReadLimit` (`server.go:920`,`:1024`,`:818`) → 431 | unbounded `read_line`/header gather | HIGH · T2 |
| 3 | CL+TE:chunked conflict (smuggling) | both h1 | `fixLength` strips CL, TE wins (`transfer.go:718`) | faithful (`transfer.ml:267-270`) | — |
| 4 | Duplicate / invalid Content-Length | both h1 | `fixLength`/`parseContentLength` (`transfer.go:666`,`:1050`) | faithful (`transfer.ml:233-256`,`:205-221`) | — |
| 5 | Malformed chunked (size/ext/trailer) | both h1 | core + `seeUpcomingDoubleCRLF` trailer cap (`transfer.go:894-951`) | core faithful; trailer + line unbounded (`io.ml:214-217`,`:67-87`) | MEDIUM · T3 |
| 6 | Header/CRLF/NUL injection & invalid bytes | both h1 | write neutralize + read validate (`header.go:190`,`server.go:1053`) | write faithful; read name/value validation missing | MEDIUM · T4 |
| 7 | `Expect: 100-continue` abuse | client→server h1 | lazy 100, 417 on unknown (`server.go:2090`,`:2236`) | absent entirely | MEDIUM · T5 |
| 8 | Request-line / Host / URI validation | client→server h1 | missing-Host-1.1 + `ValidHostHeader` (`server.go:1045-1052`) | partial; no Host-required / Host-validity | MEDIUM · T4 |
| 9 | Rapid Reset (CVE-2023-44487) | client→server h2 | backlog `>4*advMaxStreams` → `ENHANCE_YOUR_CALM` (`server.go:2263`) | unbounded `sc.unstarted` | HIGH · T8 |
| 10 | CONTINUATION flood (CVE-2024-27316) | client→server h2 | `2*remainSize` cap (`frame.go:1774`) | faithful (`h2_frame.ml:620`) | — |
| 11 | HPACK header-list-size bomb | both h2 | advertise `MAX_HEADER_LIST_SIZE`, `SetMaxStringLength` (`server.go:778`,`frame.go:1722`) | not advertised; per-string cap mis-wired (16 MiB); Huffman unbounded | HIGH · T9 |
| 12 | Control-frame floods (SETTINGS/PING) | client→server h2 | `maxQueuedControlFrames=10000` + dup-SETTINGS reject (`server.go:896`,`:1616`) | cap faithful; dup-SETTINGS not rejected | LOW · T10 |
| 13 | Flow-control & maxConcurrentStreams | client→server h2 | refused-stream + window overflow `ConnectionError` (`flow.go`) | faithful; overflow is `invalid_arg` not modeled | LOW · T11 |
| 14 | Oversized response headers / body | server→client h1 | `Transport.MaxResponseHeaderBytes` default `10<<20` (`transport.go:337`) | no cap; unbounded status+header read (body OK) | HIGH · T6 |
| 15 | Client redirect abuse (leak / loop / scheme) | server→client h1 | sticky subdomain-aware strip + Referer (`client.go:691`,`:1008-1048`,`:147`) | cap+lists faithful; non-sticky exact-string strip; no Referer | MEDIUM · T7 |

**Where defenses do / don't live today (key facts):**
- Read primitives are **unbounded**: `read_line` (`io.ml:67-87`) appends to an unbounded `Buffer`;
  `read_mime_header_raising` (`io.ml:111-161`) gathers unbounded lines. No `setReadLimit`/`hitReadLimit`
  analogue. Underlies T2, T3 (trailer), T6.
- **No socket deadlines** anywhere. `Net.with_timeout` (`net.ml:225`) exists but is test-only; `Server.t`
  (`server.ml:644-652`) has no timeout fields. (T1.)
- Header validation is **write-only**: `Header.write_subset` (`header.ml:88-107`) neutralizes outbound
  CRLF and drops invalid names, but `valid_header_field_name` is never applied on the read path, and
  there's no `ValidHostHeader`/missing-Host-1.1 check. (T4.)
- HTTP/2 has most defenses with holes: rapid-reset backlog cap absent (`schedule_handler`
  `h2_server.ml:606-613` queues `sc.unstarted` unbounded; `EnhanceYourCalm` exists at `h2_error.ml:15`,
  unused); `MAX_HEADER_LIST_SIZE` not advertised and per-string HPACK cap mis-wired to the 16 MiB list
  budget (`h2_frame.ml:592`, `h2_server.ml:1243-1261`); dup-SETTINGS not rejected (`h2_server.ml:924`);
  flow-control overflow is `invalid_arg` not a modeled connection error.

**Key contracts (additive, Go-matching defaults — no break to existing callers):**
- `Io.error` (`io.ml:26-36`, surfaced by `Server.write_read_error_response` `server.ml:677-695`): add
  `Request_too_large` (→431), `Malformed_host` (→400), client `Response_header_too_large`.
- `Server.create` gains `?read_timeout ?read_header_timeout ?write_timeout ?idle_timeout ?max_header_bytes`;
  `Server.t` (`server.ml:644-652`) gains the fields. `Transport.create` gains `?max_response_header_bytes`;
  field on `Transport.t` (`transport.ml:54-70`). `Io.read_request`/`read_response` gain `?max_header_bytes`.
  `Request.expects_continue`.

### T1 — Server read / header / idle / write timeouts (Case 1) · HIGH
Add Go's four duration knobs so a slow/idle/incomplete client can't pin a fiber forever. New optional
`create` args; default off (zero = no timeout, like Go); document that production should set them.
- `Server.create : … -> ?read_timeout:float -> ?read_header_timeout:float -> ?write_timeout:float -> ?idle_timeout:float -> …` (seconds; `read_header_timeout`/`idle_timeout` fall back to `read_timeout` as in Go). Fields on `Server.t` (`server.ml:644`) + `.mli`.
- In `serve_conn`/`serve_tls_conn` (`server.ml:699`,`:841`): wrap `Io.read_request` with the header deadline; the between-requests next-read (Go's `Peek(4)`) with the idle deadline; body-stream pulls with the whole-request deadline; response writes with the write deadline. Use `Net.with_timeout` (an `Eio.Time` deadline). On header timeout, close with no reply (Go hangs up). The body is a lazily-pulled `Body.Stream`, so the header deadline cleanly separates from the whole-request deadline.
- Ref: `server.go:1007-1022`, `:1074-1076`, `:2145-2149`, `:3717-3724`.
- Tests: `TestServerSlowlorisHeaderTimeout` (send `"GET / HTTP/1.1\r\n"` and nothing more with `~read_header_timeout:0.2`; assert close <~1s, no fiber leak); `TestServerIdleTimeout` (complete one request, hold kept-alive idle, assert close within `~idle_timeout`).

### T2 — `max_header_bytes` + bounded read layer (Case 2) · HIGH · FOUNDATION (T3/T6 depend)
Bound request-line + header block; answer `431 Request Header Fields Too Large` + close. Introduces the
shared bounded-read primitive T3/T6 reuse. Budget spans request-line + all header lines cumulatively
(Go counts the whole head against one limit).
- `io.ml`: `read_line : ?limit:int -> Eio.Buf_read.t -> string` raising `Request_too_large` when the line would exceed the remaining budget; a mutable budget (`int ref`) decremented per byte across the request line + every header line in `read_mime_header_raising`. `read_request ?max_header_bytes`.
- New `Io.error` variant `Request_too_large` (+ `.mli`); map in `Server.write_read_error_response` (`server.ml:677`) to `431` + `Connection: close` (Go `server.go:2053-2062`, `errTooLarge` `:998`). `initial_read_limit = max_header_bytes + 4096` (Go `server.go:929`). `Server.t`/`create` gain `?max_header_bytes` (default `1 lsl 20`).
- Ref: `server.go:920-929`, `:1024`, `:803-818`.
- Tests: `TestServerRequestHeaderTooLarge` (`~max_header_bytes:8192`, header block >8 KiB → 431 + close); `TestServerRequestLineTooLong` (single line > limit → 431); `TestServerHeadersUnderLimitOk` (just under → 200, no false positive).

### T3 — Bounded chunked trailer + line cap (Case 5) · MEDIUM · depends on T2
Bound the trailer block read after a chunked body (and any single line) so a chunked message can't OOM
via an endless/gigantic trailer. Shared trailer read covers both server (request) and client (response).
- In the chunked-body EOF action (`io.ml:214-217`), replace bare `read_mime_header_raising` with a bounded `read_trailer`: fast-path empty trailer when the next two bytes are `\r\n` (Go `transfer.go:913-917`); else require an upcoming double-CRLF within a bounded peek (~buffer size) before reading, else error (Go `transfer.go:894-951`, `:934`). Give every trailer/header line the T2 `?limit` cap. New handleable "suspiciously long trailer" error.
- Ref: `transfer.go:894-951`; `internal/chunked.go` (core already faithful in `chunked.ml`).
- Tests (via `Io.read_request`/`read_response` over in-memory channels): `TestChunkedTrailerTooLong` (oversized trailer → typed error); `TestChunkedEmptyTrailerOk` (bare `\r\n` → success); `TestChunkedSmallTrailerOk` (one small trailer header parses & is surfaced).

### T4 — Server read-path header name/value + Host validation (Cases 6 & 8) · MEDIUM
Post-parse validation sweep on inbound requests → `400`. (Outbound CRLF neutralization already faithful.)
- `io.ml read_request_raising` (~`:286`): reject when `Header.valid_header_field_name k` is false (`header.ml:65`) or any value byte fails `valid_header_value_byte` (`io.ml:103`). Add missing-Host-for-1.1 guard (proto≥1.1 && no Host && method≠CONNECT && not h2-upgrade → bad request, `server.go:1045-1047`); port a `valid_host_header` byte-table check (x/net `httpguts` `httplex.go:209-263`) for the single Host value → "malformed Host header" (`server.go:1050`). Wire the currently-dead inbound `Io.Missing_host` arm (`server.ml:692`) or add a new variant.
- Ref: `server.go:1045-1063`, `request.go:1143-1157`.
- Tests: `TestServerRejectsInvalidHeaderName` (`"Foo Bar: x"` → 400); `TestServerRejectsBadHostHeader` → 400; `TestServerRejectsMissingHostHTTP11` → 400; `TestServerAcceptsValidHostAndHeaders` → 200.

### T5 — `Expect: 100-continue` handling + 417 (Case 7) · MEDIUM
Lazily emit interim `100 Continue` on first body read; reject unknown `Expect` with `417 Expectation
Failed` + `Connection: close`. (Spec-compliant clients withholding the body hang today.)
- `Request.expects_continue : _ t -> bool` = has token `100-continue` in `Expect` (`request.go:1518`).
- `server.ml` serve loop (`serve_one`/~`:722`): if `expects_continue && proto≥1.1 && content_length<>0`, wrap `r.body` (`Body.Stream` thunk) so the first pull writes `HTTP/1.1 100 Continue\r\n\r\n` to `oc` and flushes, then proceeds; else if `Header.get r.header "Expect" <> ""`, write 417 + `Connection: close` and stop. Mirror `server.go:2090-2101`, `:2236-2252`, `:964-983`.
- Tests: `TestServerExpect100Continue` (client sends `Expect: 100-continue`, receives 100 only when handler reads body, then final response); `TestServerExpectUnknown` (`Expect: bogus` → 417 + `Connection: close`).

### T6 — Client `MaxResponseHeaderBytes` (Case 14) · HIGH · depends on T2
Bound the response status line + header block so a hostile server can't OOM the client. (Body already
bounded by streaming `Transfer`.)
- `Transport.create : … -> ?max_response_header_bytes:int -> unit -> t` (default `10 lsl 20`); field on `Transport.t` (`transport.ml:54`). Pass into `Io.read_response ?max_header_bytes` at `transport.ml:331`. `Io.read_response` budgets status line (`read_line`, `io.ml:370`) + header block (`read_mime_header_raising`, `io.ml:401`) via T2's `?limit`. New `Io.error` `Response_header_too_large` (+`.mli`); map at the transport public boundary to a typed transport error.
- Ref: `transport.go:275-280`, `:337-340`, `:364`.
- Tests: `TestTransportResponseHeaderTooLarge` (raw loopback server writes status line + endless header stream; `~max_response_header_bytes:8192` → modeled error within a bounded timeout, no hang/OOM); `TestTransportResponseHeaderUnderLimitOk`.

### T7 — Client sticky / subdomain-aware redirect header stripping + Referer (Case 15) · MEDIUM
Fix the leak where a redirect chain bouncing back to the original host re-attaches `Authorization`/`Cookie`
(today's strip decision is recomputed per hop vs `initial_host`, non-sticky).
- `client.ml do_one` (`:97-156`): replace per-hop `strip_sensitive = url_host loc_url <> initial_host` (`:122`) with a sticky accumulator threaded through `loop` (init false, latches true, never resets); set true via `should_copy_header_on_redirect prev_host new_host` returning false (port `is_domain_or_subdomain` so `sub.foo.com` from `foo.com` keeps headers). Add `referer_for_url ~last ~next` and set/omit `Referer` (omit on https→http). Header lists + 10-redirect cap already faithful.
- Ref: `client.go:691-695`, `:763-834`, `:1008-1048`, `:147-152`.
- Tests: `TestRedirectStripStickyOnBounceBack` (`a.com (Authorization) → b.com → a.com`; `Authorization` absent on final hop); `TestRedirectKeepsHeaderOnSubdomain` (`foo.com → sub.foo.com` keeps it); `TestRedirectRefererHttpsToHttp`.

### T8 — HTTP/2 rapid-reset backlog cap (Case 9, CVE-2023-44487) · HIGH
Trip `ENHANCE_YOUR_CALM` when the unstarted-handler backlog exceeds `4*adv_max_streams`.
- `schedule_handler` (`h2_server.ml:606-613`): before appending to `sc.unstarted`, if `List.length sc.unstarted > 4 * sc.adv_max_streams` → connection error `H2_error.EnhanceYourCalm` (variant exists at `h2_error.ml:15`, currently unused) propagated via the existing GOAWAY path. Also replace the O(n) `sc.unstarted @ [..]` append (`:613`) with a non-quadratic structure (prepend+reverse-on-drain or a queue) — under attack the list churns hot. `handler_done_serve` (`:615`) already skips reset streams.
- Ref: `internal/http2/server.go:2255-2273`, `:2275-2297`, `:277`.
- Test: `TestServerRejectsTooManyEarlyResets` (open+RST_STREAM loop → GOAWAY `ENHANCE_YOUR_CALM` after the cap; port from `internal/http2/server_test.go`).

### T9 — HTTP/2 MAX_HEADER_LIST_SIZE advertise/derive + HPACK per-string cap + Huffman bound (Case 11) · HIGH
Advertise/enforce a config-derived `MAX_HEADER_LIST_SIZE` (default `1<<20` to match Go, vs today's
hardcoded 16 MiB), wire the HPACK per-string cap separately from the list budget, and bound Huffman decode.
- `h2_server.ml`: add a server h2 `max_header_bytes` option (default `1 lsl 20`); include `Max_header_list_size = max_header_bytes` in initial SETTINGS (`:1243-1261`); pass `~max_header_list_size:max_header_bytes` into `read_meta_headers` (`:1078`, already takes the param); set the decoder per-string cap via `Hpack.set_max_string_length` to the per-string bound (not the list cap).
- `hpack.ml`: bound `decode_string`/`Huff.decode` (`:303-310`) by the per-string cap (the unbounded path is flagged at `:306-307`).
- Ref: `internal/http2/server.go:497-505`,`:778`; `frame.go:1716`,`:1722`,`:1774`; `hpack/hpack.go:84`,`:122`,`:488`,`:516`.
- Tests: `TestH2RejectsHeaderListBomb` (HEADERS+CONTINUATION decoded list > configured size → conn `PROTOCOL_ERROR`); `TestH2HuffmanStringCap` (Huffman string > per-string cap → `ErrStringLength`-equiv); `TestH2AdvertisesMaxHeaderListSize` (initial SETTINGS contains it).
- Open question: confirm the per-string vs list relationship and whether to bound Huffman by length or keep a tightened post-decode check.

### T10 — HTTP/2 duplicate-SETTINGS rejection (Case 12) · LOW
Reject a SETTINGS frame with duplicate IDs → `PROTOCOL_ERROR` (the `>100` count check already exists).
- `H2_frame.settings_has_duplicates : settings_frame -> bool` (mirror `SettingsFrame.HasDuplicates`). In `process_settings` (`h2_server.ml:924`): `if List.length sf.settings > 100 || settings_has_duplicates sf then Error ProtocolError`.
- Ref: `internal/http2/server.go:1616-1620`.
- Tests: `TestH2RejectsDuplicateSettings`; `TestH2AcceptsDistinctSettings`.

### T11 — HTTP/2 flow-control overflow modeled as connection error (Case 13) · LOW
Make a flow-control window overflow surface as a modeled `FLOW_CONTROL_ERROR` GOAWAY rather than an
`invalid_arg` that could crash the connection fiber. First confirm whether the event loop already
converts the raise — if so this is a rename/typing cleanup, else a correctness fix.
- Audit `h2_flow.ml` (`:9`,`:30-31`,`:46-66`,`:93-99`) and the h2 serve loop's error handling; make window-overflow a modeled `H2_error.FlowControlError` connection error. maxConcurrentStreams enforcement already faithful.
- Ref: `internal/http2/flow.go` (`inflow.add`/`take`, `ConnectionError(ErrCodeFlowControl)`).
- Tests: `TestH2FlowControlOverflowGoaway`; `TestH2MaxConcurrentStreamsRefused` (regression — already works).

**Test harness:** new alcotest suite `Abuse`, aggregated into `test/test_httpg.ml`; each ticket
contributes ≥1 ported/adapted test (or adds to the existing suite the test belongs to). Where Go has a
matching test (`serve_test.go`, `internal/http2/server_test.go`, `transport_test.go`), port it verbatim
and treat it as the spec; if an architectural difference blocks a verbatim port (e.g. the too-big path
can't inject `Connection: close` — see "Smaller / cleanup"), adapt the assertion and call out the
divergence.

## Production-readiness (server)
- Graceful `Shutdown` / `Close`, `SetKeepAlivesEnabled`.
- Timeouts: Read / Write / Idle / ReadHeader; `MaxHeaderBytes`. _(planned in detail above — T1/T2)_
- `ResponseController`, `Hijacker`, `CloseNotifier`.
- `Expect: 100-continue` handling. _(planned in detail above — T5)_
- `DefaultServeMux` + package-level `Handle`/`HandleFunc`/`ListenAndServe`.

## Client / transport
- Cookie jar (`net/http/cookiejar`).
- Proxies: `ProxyFromEnvironment`, HTTP `CONNECT` tunneling, SOCKS5 (`socks_bundle.go`).
- Connection-pool limits: `MaxIdleConns`, `MaxConnsPerHost`, `IdleConnTimeout`; custom `DialContext`.
- `RegisterProtocol` + alternate-scheme RoundTrippers.
- Transparent gzip / `DisableCompression`; `GetBody` re-send on redirect; `ErrUseLastResponse`.

## HTTP/2 extras
- Server Push send (`PUSH_PROMISE`) — currently parse-only.
- RFC 9218 priority scheduler (round-robin only today). h2c prior-knowledge (RFC 9113 §3.3) is supported via `?force_h2` on `Server`/`Client` (a deliberate deviation — no Go-stdlib analogue); the HTTP/1.1 `Upgrade: h2c` form is not.
- Trailers re-surfaced on `Response`; `maxConcurrentStreams` await; GOAWAY-retry-on-new-conn; extended CONNECT.
- HTTP/2 response content sniffing (reduced to a `text/plain` default).

## Subpackages not yet ported
- `net/http/httputil` — `ReverseProxy`, `DumpRequest`/`DumpResponse` (ReverseProxy is now very feasible).
- `net/http/httptrace`, `net/http/cgi`, `net/http/fcgi`, `net/http/pprof`, `csrf.go`.
- `net/http/internal/httpsfv` (RFC 8941 Structured Field Values parser): its only consumer is `internal/http2/frame.go`'s `parseRFC9218Priority` (the PRIORITY_UPDATE frame), which is unported — bring `httpsfv` in alongside that frame, in the RFC 9218 priority work above.

## Smaller / cleanup
- `Body` is `io.Reader`, not `io.ReadCloser` — there is no `Body.Close`. `Body.t`
  models only the read side; connection-reuse cleanup is deferred to the serve
  loop's post-handler `Body.drain ~limit:maxPostHandlerReadBytes` (256 KB) and to
  the client's redirect drain. The net keep-alive decision matches Go (reuse iff
  the body reached EOF within the bound), but the missing closer means:
  - a handler cannot proactively `req.Body.Close()` to release/abort the body
    mid-handler (Go's `doEarlyClose` bounded drain in `body.Close`, transfer.go);
  - no "closed with non-EOF error forces close" signal (Go's `closed && !sawEOF`
    in `finishRequest`), and no `closed` flag / `ErrBodyReadAfterClose`;
  - the client redirect drain is unbounded instead of Go's `maxBodySlurpSize`
    (2 KB, client.go) — bounding it safely needs a closer so a stopped-short body
    still releases its connection (today the transport releases only at EOF);
  - the server's too-big path closes the socket but cannot inject `Connection:
    close` into the already-written response (Go drains in `finishRequest`
    *before* flushing). A verbatim `TestServerUnreadRequestBodyLarge` would fail
    on the header assertion until this is addressed.
  Fix: give `Body.Stream` a closer (the faithful `io.ReadCloser` shape); covers
  the handler-close, client-2 KB-bound, and (with drain-before-flush) the
  `Connection: close` cases.
- Missing **pre-response body drain** (deadlock, Go Issue 15527). Go drains the
  unconsumed request body in *two* places: `finishRequest` (`server.go:1690-1711`,
  always closes the body) **and** the `WriteHeader` path *before* the response is
  flushed (`server.go:1404-1463`: when `ContentLength != 0 && !closeAfterReply &&
  !fullDuplex`, `io.CopyN(io.Discard, reqBody, maxPostHandlerReadBytes+1)`). The
  port only does the former — the post-handler `drain_request_body` in the serve
  loop (`server.ml:967-969`, `:634-640`). The pre-response discard exists to avoid
  a TCP deadlock: a client that writes its whole request body and *then* reads the
  response can deadlock against a server that starts writing a (large) response
  while the request body is still unconsumed and both send buffers fill. Eio's
  buffering shifts the exact window vs Go's blocking sockets, but the
  deadlock is still reachable for a handler that emits a large response without
  reading a large request body. There is also no `fullDuplex` opt-out
  (`ResponseController.EnableFullDuplex`) to *disable* the pre-drain when a handler
  intentionally streams both directions.
  Fix: before flushing response headers in `serve_one` (`server.ml`), if
  `content_length <> 0 && keep_alive && not full_duplex`, run a bounded
  `Body.drain ~limit:max_post_handler_read_bytes` on the request body (set
  `close_after_reply` on too-big / read-error, as Go's `requestTooLarge` /
  `closeAfterReply` do); add a per-request `full_duplex` flag to opt out. Couples
  with the `Body` closer item above (drain-before-flush is what also unblocks the
  `Connection: close` injection on the too-big path). Ref: `server.go:1404-1463`,
  `:1690-1711`; Go Issue 15527.
- `Request.Clone` (`clone.go`); `Header.clone` already exists.
- Multipart: `Multipart.of_body` settles each part incrementally (memory, or temp-file spill past `max_memory`) and yields a `(part, error) result Seq.t`, but it is not a true *wire*-streaming reader (consume-once part bodies) and drops unstructured custom part headers; both deferred. Backed by the `multipart_form` stand-in.
- `Form`: drop the dead `Invalid_escape` error variant — it is declared (type + `error_to_string`) to mirror Go's `QueryUnescape` error but is **never constructed** (the `uri`-backed `query_unescape` is lenient), so it is an unreachable arm callers needlessly match. Either remove it or actually detect malformed `%xx`.
- `Form.of_body` bounded read: it currently `Body.read_all`s the whole body and *then* checks `> max_form_size`, so a hostile huge body is buffered before rejection. Mirror Go's `io.LimitReader(body, maxFormSize+1)` — pull at most `max_form_size + 1` bytes and error without buffering more. (Copied Go's constant but not its mechanism.)
- Consolidate hand-rolled trims: `header.ml`, `transfer.ml` (`trim_string` + `trim_ows`), `cookie.ml`, `fs.ml` all redefine the identical space+tab OWS trimmer. Hoist one `trim_ows` into `Httpg_base.Textproto` (Go's `textproto.trimString` / `httpguts.trimOWS`, space+tab only — deliberately *not* stdlib `String.trim`, which also strips CR/LF/FF and would mask injection on header values) and point them at it. `multipart.ml`'s `trim` (space/tab/nl/cr) is just `String.trim` — use the stdlib.
- `Form.create : unit -> t` → `empty : t`: a unit-returning "constructor" for an immutable empty `Map` mirrors `Header.create` but isn't idiomatic for a persistent value.
- `mime.TypeByExtension` database (today a small built-in table + `Sniff` fallback).
- `Uri.t` vs `url.URL` divergences: `RawPath`/opaque/scheme-relative URIs, `ParseRequestURI` semantics (a few `request_test.go` rows skipped).

## Explicit non-goal
- HTTP/3 / QUIC (would require porting a full QUIC stack first).
