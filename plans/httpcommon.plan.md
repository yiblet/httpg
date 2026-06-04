# Align `lib/` with Go's `net/http/internal` package boundary

## Problem

`gohttp` mirrors Go's `net/http`, and `lib/internal/` (the private
`gohttp_internal` library) is meant to mirror Go's `net/http/internal` package.
A review found three divergences from Go's internal boundary:

1. **`sniff`** is public (`Gohttp.Sniff`) but Go keeps the algorithm in
   `internal/sniff.go` with a thin public `sniff.go` wrapper.
2. **`common.go`'s** four sentinel errors have no counterpart module.
3. **`httpcommon`** — the request/header machinery Go shares between `net/http`
   and `internal/http2` — exists only as ad-hoc inline code in `h2_transport.ml`,
   `h2_write.ml`, and `h2_server.ml`, and is only a *subset* of Go's package.

(`httpsfv` is also internal in Go, but it is used **only** by HTTP/2's RFC 9218
PRIORITY_UPDATE parsing, which this port has not implemented — so it has zero
consumers and is deliberately deferred; see TODO.md.)

## Key constraint

`gohttp_internal` may depend only on `lwt`/`lwt.unix` (+ stdlib) and **must not
depend on the public `gohttp` library** — `gohttp` already depends on it.
`Header.t` is structurally `(string, string list) Hashtbl.t` (exposed in
`header.mli:9`), so internal code can accept that Hashtbl type and callers pass a
`Header.t` directly with no conversion and no module dependency. Go's
`httpcommon` solves the same problem by defining its **own** primitive
param/result structs (`httpcommon.Request`, etc.) instead of importing
`net/http` — we replicate that decoupling.

## Target shape

`lib/internal/` gains `sniff.{ml,mli}`, `common.{ml,mli}`, `httpcommon.{ml,mli}`.
`httpcommon` defines primitive param/result types and ports `EncodeHeaders`,
`NewServerRequest`, `LowerHeader`, and the validators; the `H2_*` modules become
thin adapters (`Request.t` ⇆ httpcommon params). Where Go's `httpcommon` reuses
`textproto.CanonicalMIMEHeaderKey` and `httpguts`, we **inject** the public
`Header.canonical_header_key` as a `~canonical` parameter (so httpcommon stays
cycle-free while reusing the one real canonicalizer). URL construction stays in
the public adapter (httpcommon stays free of the `uri` lib) — httpcommon returns
the validated request-URI + reason, mirroring Go's `InvalidReason` pattern.

---

## Ticket A — faithful `sniff` split

- Move the algorithm from `lib/sniff.ml` to **`lib/internal/sniff.ml`**
  (`Gohttp_internal.Sniff`); add `lib/internal/sniff.mli` exposing
  `val sniff_len : int` and `val detect_content_type : string -> string`
  (the values Go exports from `internal/sniff.go`).
- `lib/sniff.ml` collapses to a one-line re-export
  (`let detect_content_type data = Gohttp_internal.Sniff.detect_content_type data`),
  mirroring the public `sniff.go`. `lib/sniff.mli` is **unchanged** — public
  `Gohttp.Sniff.detect_content_type` is preserved.
- No call-site churn (`server.ml:430`, `httptest.ml:50`, `fs.ml:678`,
  `test/test_sniff.ml`) — they keep using the public wrapper, exactly as Go's
  callers use the public `DetectContentType`.
- Verify: `dune build`; `dune exec test/test_gohttp.exe -- test Sniff`.

## Ticket B — `lib/internal/common.ml` (mirror `common.go`)

- New `common.{ml,mli}` as `Gohttp_internal.Common` defining the four sentinels
  as exceptions with doc comments citing `common.go` + Go's raise sites:
  `Abort_handler`, `Body_not_allowed`, `Request_canceled`, `Skip_alt_protocol`.
- **No behavior change.** These features are unported (handler-panic abort,
  alt-protocol) or use a different idiom (`Context.Canceled` for cancellation;
  `body_allowed_for_status` bool predicate for body suppression). The module is a
  faithful structural placeholder future tickets wire up. Document each.
- Verify: `dune build`.

## Ticket C — `httpcommon` skeleton + pure helpers + dedup

- New **`lib/internal/httpcommon.{ml,mli}`** (`Gohttp_internal.Httpcommon`) with:
  - types `request`, `encode_headers_param`, `encode_headers_result`,
    `server_request_param`, `server_request_result` (primitive fields; headers as
    `(string, string list) Hashtbl.t`); exn `Request_header_list_size`.
  - pure helpers ported from `h2_write.ml`: `lower_header` (Go `LowerHeader` /
    `asciiToLower` — ascii flag on byte≥0x80, lowercases A–Z), `is_token_byte`,
    `valid_wire_header_field_name`, `valid_header_field_value`; plus
    `valid_pseudo_path`, `should_send_req_content_length`, `is_request_gzip`,
    `check_conn_headers`, `comma_separated_trailers ~canonical`,
    `validate_headers`.
- Rewire `h2_write.ml` to call `Gohttp_internal.Httpcommon.*` for the moved
  helpers (delete the local copies). Replace `h2_transport.ml`'s local
  `ascii_eq_fold` with `Gohttp_internal.Ascii.equal_fold`.
- Verify: `dune build`; `dune test` (Hpack/H2Frame and h2 round-trips green).

## Ticket D — `EncodeHeaders` + client adapter

- Port Go `EncodeHeaders` (httpcommon.go:215-415) into
  `Httpcommon.encode_headers ~canonical param headerf`, including the gaps the
  current inline subset omits: `check_conn_headers`, `validate_headers`,
  `comma_separated_trailers`/`trailer` field, `:protocol`/extended-CONNECT
  handling, cookie splitting on `;`, `accept-encoding: gzip` (gated by
  `add_gzip_header`), `peer_max_header_list_size` pre-pass
  (→ `Request_header_list_size`), and the `LowerHeader` ascii-skip on emit.
- Rewrite `h2_transport.ml`'s `enumerate_headers`/`encode_request_headers` to
  build an `encode_headers_param` from the `Request.t` (compute `request_uri`,
  `actual_content_length`, host, gzip flag, peer max list size, default UA) and
  drive the HPACK encoder from `encode_headers`'s `headerf` callback. Keep the
  existing HPACK buffering wrapper.
- Verify: `dune build`; `dune test` (client h2 round-trips + demo path green).

## Ticket E — `NewServerRequest` + server adapter

- Port Go `NewServerRequest` (httpcommon.go:558-626) into
  `Httpcommon.new_server_request ~canonical param`, returning
  `server_request_result` with: `Expect: 100-continue` detection (`needs_continue`,
  strip the header), Cookie-header merge into one `"; "`-joined value, Trailer
  extraction (canonicalize keys, drop Transfer-Encoding/Trailer/Content-Length),
  userinfo-in-authority rejection (`@` → `invalid_reason`), and `bad_path`
  validation. URL/Uri construction stays in the caller.
- Rewrite `h2_server.ml`'s `build_request` to assemble a `server_request_param`
  from the meta-headers, call `new_server_request`, map `invalid_reason`→
  `H2_error.ProtocolError`, then build the `Uri.t`/`Request.t`/body pipe as today
  (now also honoring merged cookies + extracted trailer + needs_continue).
- Verify: `dune build`; `dune test` (server h2 tests green).

## Ticket F — defer `httpsfv`

- Add a TODO.md note: `httpsfv` (RFC 8941 SFV parser) is internal in Go but only
  consumed by RFC 9218 PRIORITY_UPDATE parsing, which is unported; bring it in
  with that frame in a future ticket.

## Verification (whole effort)

1. `dune build` green after every ticket (warnings are errors).
2. `dune test` — full alcotest suite green; specifically `Sniff`, `Hpack`,
   `H2Frame`, `Fs`, `Httptest`, and the h2 client/server round-trips.
3. `dune exec gohttp` — demo (h1 + streaming + h2-over-TLS) still round-trips.
4. Grep: no public surface leaked (`Gohttp.Sniff` still resolves; `sniff_len`
   not public); `Gohttp_internal.{Sniff,Common,Httpcommon}` resolve.

## Execution record

- **Ticket A (sniff split)** — done. Algorithm moved to `lib/internal/sniff.{ml,mli}`
  (`Gohttp_internal.Sniff`); `lib/sniff.ml` is now a one-line wrapper, `sniff.mli`
  unchanged. No call-site churn. `dune exec ... -- test Sniff` green (38 cases).
- **Ticket B (common.ml)** — done. `lib/internal/common.{ml,mli}`
  (`Gohttp_internal.Common`) defines `Abort_handler`/`Body_not_allowed`/
  `Request_canceled`/`Skip_alt_protocol`; no behavior change (placeholders).
- **Ticket C (httpcommon skeleton + helpers)** — done. `lib/internal/httpcommon.{ml,mli}`
  with primitive param/result types + all helpers. `h2_write.ml`'s
  `lower_header`/`valid_wire_header_field_name`/`valid_header_field_value`/
  `is_token_byte` replaced by `Httpcommon` aliases.
- **Ticket D (EncodeHeaders + client adapter)** — done. `Httpcommon.encode_headers`
  ports the full Go function (incl. check_conn/validate/trailers/cookie-split/
  :protocol/gzip/size pre-pass); `h2_transport.encode_request_headers` builds the
  param and drives HPACK from `headerf`. Kept behavior: `add_gzip_header=false`
  (no transparent gzip decode), `peer_max_header_list_size=0L` (untracked).
  `ascii_eq_fold`/`enumerate_headers`/local `lower_header` removed.
- **Ticket E (NewServerRequest + server adapter)** — done. `Httpcommon.new_server_request`
  ports Expect/Cookie-merge/Trailer-extract/userinfo/bad_path; `h2_server.build_request`
  now delegates (keeps the http2-level pseudo-header check + Uri/body construction),
  gaining cookie merge, Expect strip, announced trailers, and request_uri from the result.
- **Ticket F (defer httpsfv)** — done. Noted in TODO.md under "Subpackages not yet ported".

Verification: `dune build` green (warnings-as-errors); `dune test` green (487 tests,
incl. Sniff, Hpack, H2Frame, Fs, Httptest, h2 client/server round-trips);
`dune exec gohttp` demo round-trips h1 + streaming + h2-over-TLS.
