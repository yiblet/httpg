# Move the HTTP/2 stack into `lib/internal/http2/` (mirror Go's `net/http/internal/http2`)

## Problem / motivation

Go's running `net/http` no longer bundles HTTP/2 in-package (the old generated
`h2_bundle.go`). In this vendored tree (2026) HTTP/2 is a first-class internal
package, `net/http/internal/http2/`, that **does not import `net/http`**. It
defines its own decoupled request/response types in `api.go`
(`ClientRequest`, `ClientResponse`, `ServerRequest`, `ResponseWriter`,
`Header = textproto.MIMEHeader`), and a thin shim file in package `http`
(`http2.go`) translates `http.Request`/`http.Response` ⇄ the http2 types.

Our port still keeps the whole `h2_*` stack flat in the public `gohttp` library,
using `Request.t`/`Response.t`/`Body.t`/`Header.t`/`Context.t` directly. That
matched the *legacy* `h2_bundle.go` layout (everything in one package) but not
the current `internal/http2` layout. This plan migrates the h2 stack into its
own internal sub-library `lib/internal/http2/` (`gohttp_http2`), decoupling it
from the public types via an `Api` module + translation shims — the same
technique we used for `httpcommon`, scaled to the whole subsystem.

A **subfolder/own-library** (`lib/internal/http2/`) is the right shape: it
mirrors Go's directory 1:1, and the package boundary is exactly what makes the
cycle-avoidance enforceable. The flat `gohttp_internal` library remains the
analogue of the *loose files* in `net/http/internal` (chunked, common, sniff,
httpcommon); `gohttp_http2` is the analogue of the `http2/` subdirectory.

## Target library graph (no cycles)

```
gohttp_base       (lib/base)           lwt, lwt.unix         -- foundation layer
   ^   ^   ^                           Context, Textproto    (ports of Go stdlib
   |   |   |                                                  context / net/textproto)
   |   |   +---------------------+
   |   |                         |
gohttp_internal (lib/internal)   |     + gohttp_base         -- net/http/internal
   ^        ^                    |       (chunked, common, sniff, ascii, httpcommon)
   |        |                    |
   |   gohttp_http2 (lib/internal/http2)  lwt, lwt.unix, uri, gohttp_base, gohttp_internal
   |        ^                              -- internal/http2; never names gohttp types
   |        |
gohttp (lib) + gohttp_base, gohttp_internal, gohttp_http2, uri, tls...
              -- net/http: public types + Server/Transport + h2 shim
```

`gohttp_base` is a **foundation library, not an internal one**: `context` and
`net/textproto` are ordinary stdlib packages in Go that both `net/http` and
`internal/http2` import, so their ports belong below the net/http layer, not
inside `net/http/internal`. It is depended on by `gohttp_internal`,
`gohttp_http2`, and `gohttp` alike. `Gohttp_base.Context` is re-exported as the
public `Gohttp.Context` (preserving the existing API and the `t` type identity,
so no conversion is needed at the shim).

`gohttp_http2` may use `Uri.t` (external `uri` lib, not `gohttp`),
`Gohttp_base.*`, and `Gohttp_internal.*` freely; it must never reference
`Request`/`Response`/`Body`/`Header`/`Status`/`Method` from `gohttp` (and it
gets `Context` from `gohttp_base`, not `gohttp`).

## Module inventory to move (≈4.5k LOC)

Pure (no public coupling — move as-is, just re-home): `hpack`, `hpack_tables`,
`hpack_huffman`, `h2`, `h2_error`, `h2_flow`, `h2_databuffer`, `h2_pipe`,
`h2_frame`, `h2_writesched`.

Coupled (decouple, then move): `h2_write` (Header), `h2_transport`
(Request/Response/Body/Header/Status), `h2_server`
(Request/Body/Header/Context).

Inside the new library, rename to mirror Go's filenames: `server.ml`,
`transport.ml`, `frame.ml`, `write.ml`, `flow.ml`, `error.ml`, `databuffer.ml`,
`pipe.ml`, `writesched.ml`, `api.ml` (accessed as `Gohttp_http2.Server`, …).
`hpack*` may either stay flat in `gohttp_http2` (`Gohttp_http2.Hpack`) or — for
maximal fidelity with Go's separately-vendored `x/net/http2/hpack` — become a
nested library `lib/internal/http2/hpack/` (`gohttp_hpack`). Default: nested
hpack library (it is already self-contained and `.mli`-wrapped).

## The `Api` module (mirror `internal/http2/api.go`)

`lib/internal/http2/api.ml` defines the decoupled types. `Header` is the
structural `(string, string list) Hashtbl.t` (same trick as `httpcommon`,
matching Go's `Header = textproto.MIMEHeader`); `body` is a read-closer-shaped
stream so h2 never names `Body.t`:

```
type header = (string, string list) Hashtbl.t
type body = { read : unit -> string option Lwt.t; close : unit -> unit Lwt.t }
type client_request  = { ctx; meth; url : Uri.t; header; trailer; body;
                         host; content_length; close; res_trailer : header ref }
type client_response = { status_code : int; content_length; uncompressed;
                         header; trailer; body }       (* status TEXT applied by shim *)
type server_request  = { ctx; proto; proto_major; proto_minor; meth; url : Uri.t;
                         header; trailer; body; host; content_length;
                         remote_addr; request_uri }
type response_writer = { header : unit -> header; write_header : int -> unit;
                         write : string -> unit Lwt.t; flush : unit -> unit Lwt.t }
type handler = response_writer -> server_request -> unit Lwt.t
```
(Drop `api.go`'s `TLS`/`MultipartForm`/`GetBody`/`Cancel` fields — TLS isn't used
inside our h2 modules, and the others are unported; note each omission.)

## Shared-layer relocations (Phase 1 — prerequisites)

Create the foundation library `gohttp_base` at `lib/base/` (deps: lwt, lwt.unix)
and move the shared stdlib-analogue primitives into it:

- **Context → `gohttp_base`.** `context.ml` depends only on Lwt/Unix, so move it
  to `lib/base/context.{ml,mli}` (`Gohttp_base.Context`). Re-export publicly as
  `Gohttp.Context` via a thin `lib/context.{ml,mli}`: `include Gohttp_base.Context`
  with `include module type of Gohttp_base.Context with type t =
  Gohttp_base.Context.t` so the public `t` stays *identical* to the base type
  (no conversion needed when h2 and lib meet at the shim). All existing
  `Context.` uses in `lib/` keep working unchanged; `Request.t.ctx` is the same
  `t`. Mirrors Go's `context` being a low-level stdlib package both layers import.
- **Header canonicalization → `gohttp_base`.** Extract the core of
  `Header.canonical_header_key` into `Gohttp_base.Textproto.canonical_mime_header_key`
  (Go's `textproto.CanonicalMIMEHeaderKey`); public `Header.canonical_header_key`
  delegates. This gives `gohttp_http2` (and `gohttp_internal`'s `Httpcommon`)
  canonicalization without naming the public `Header` module.

## Tickets

1. **Create `gohttp_base`** (`lib/base/dune`) and relocate Context into it;
   re-export as `Gohttp.Context` preserving the `t` identity; `gohttp` depends on
   `gohttp_base`; build + full tests green.
2. **Relocate canonicalization** to `Gohttp_base.Textproto`; `Header` delegates;
   `gohttp_internal` depends on `gohttp_base`; green.
3. **Create `gohttp_http2` library** (`lib/internal/http2/dune`, deps incl.
   `gohttp_base` + `gohttp_internal`) and move the *pure* modules (hpack*, h2,
   h2_error, h2_flow, h2_databuffer, h2_pipe, h2_frame, h2_writesched) into it
   under Go-mirroring names; update references in the still-in-`lib`
   h2_write/h2_server/h2_transport and in `test/`; green.
   (Decide hpack-as-nested-library here.)
4. **Add `Api`** (`lib/internal/http2/api.ml` + `.mli`) per the blueprint above.
5. **Decouple + move `write.ml`**: `Header.t` → `Api.header` (raw Hashtbl ops +
   `Gohttp_internal.Textproto`); move into `gohttp_http2`; green.
6. **Decouple + move `transport.ml`**: `round_trip : client_conn ->
   Api.client_request -> Api.client_response Lwt.t`; drop `Status` (return
   `status_code` only), `Body.t` → `Api.body`, `Request/Response` → `Api`; move;
   green.
7. **Decouple + move `server.ml`**: `handler = response_writer ->
   Api.server_request -> unit Lwt.t`; build `Api.server_request` (not
   `Request.t`); `Body.t` → `Api.body`; `Context` →
   `Gohttp_internal.Context`; move; green.
8. **Client shim** in `lib/transport.ml`: translate `Request.t` →
   `Api.client_request`, call `Gohttp_http2.Transport.round_trip`, translate
   `Api.client_response` → `Response.t` (apply `Status.status_text`, wrap
   `Api.body` as `Body.Stream`). Mirrors Go's `http2RoundTrip`.
9. **Server shim** in `lib/server.ml`: replace `h2_handler_of_handler` with an
   adapter that converts `Api.server_request` → `Body.t Request.t` and bridges
   `Api.response_writer` ⇄ `Server.response_writer` (Header is the same Hashtbl;
   bridge `Body`). Mirrors Go's `http2Handler.ServeHTTP`.
10. **Cleanup + docs**: update every `.mli`; update `test/dune` (+`gohttp_http2`)
    and h2 test references; update `CLAUDE.md` architecture §6 (h2 now in
    `lib/internal/http2/` with `api.ml` decoupling + shims, replacing the
    legacy-bundle description) and remove this plan when done.

## Risks / notes

- **Body bridging** (Ticket 8/9) is the subtlest piece: `Body.t`
  (`Empty|String|Stream`) ⇄ `Api.body` (read/close). h2 already streams via
  `H2_pipe`, so the read-closer shape fits; the shim wraps both directions.
- **Test churn**: the h2 suites (`Hpack`, `H2Frame`, `H2Writesched`, `H2Server`,
  `H2Transport`, `H2Tls`, `H2ClientServer`, `StreamH2`) reference the moved
  modules and some build `Request.t`/`Response.t`; they must be re-pointed at
  `Gohttp_http2.*` and, where they exercised the endpoints, go through the
  shims or `Api` types. Treat the Go `internal/http2/*_test.go` files as the
  spec for the protocol-level suites.
- Keep each ticket's build green (warnings-as-errors) and the full `dune test`
  passing; re-run `dune exec gohttp` (h1 + streaming + h2-over-TLS) after the
  shims land. Do work one ticket per commit, per repo convention.

## Verification (whole effort)

1. `dune build` green after every ticket.
2. `dune test` green — all 487+ tests, especially the h2 suites and the
   client/server round-trips, now exercising the shim boundary.
3. `dune exec gohttp` round-trips h1 + streaming + h2-over-TLS.
4. Grep: `gohttp_http2` modules contain **no** reference to `Request`/`Response`/
   `Body`/`Header`/`Context`/`Status`/`Method` (only `Uri`, `Gohttp_internal`,
   Lwt, stdlib) — the decoupling invariant that mirrors `api.go`.

## Execution record

- **Ticket 1 (gohttp_base + Context)** — done. New `lib/base/` library
  (`gohttp_base`, deps lwt/lwt.unix/unix); `Context` moved to
  `lib/base/context.{ml,mli}`; `lib/context.{ml,mli}` re-exports it as
  `Gohttp.Context` with `with type t = Gohttp_base.Context.t` (identity
  preserved). `gohttp` depends on `gohttp_base`. 487 tests green.
- **Ticket 2 (Textproto)** — done. Canonicalization moved to
  `lib/base/textproto.{ml,mli}` (`Gohttp_base.Textproto.canonical_mime_header_key`
  + `valid_header_field_byte`); `Header` delegates. Green.
- **Ticket 3 (gohttp_http2 + pure modules)** — done. New
  `lib/internal/http2/` library (`gohttp_http2`, deps lwt/lwt.unix/uri/
  gohttp_base/gohttp_internal). Moved the independent pure modules: hpack,
  hpack_tables, hpack_huffman, h2, h2_error, h2_flow, h2_databuffer, h2_pipe,
  h2_frame. The still-in-`lib` coupled modules (h2_write, h2_writesched,
  h2_server, h2_transport) and the h2/hpack test files `open Gohttp_http2`.
  Filenames keep their `h2_`/`hpack` names for now (de-prefixing to Go's
  `frame.ml`/`server.ml`/… is deferred cosmetic cleanup). 487 tests green.
  Note: h2_writesched depends on h2_write (the `write_framer` type), so it moves
  with `write` in Ticket 5, not here.

- **Ticket 4 (Api)** — done. `lib/internal/http2/api.{ml,mli}` with prefixed
  records (creq_/cres_/sreq_/rw_), `Header`/`Body` submodules (incl.
  `Body.read_all`), `default_user_agent`. Mirrors Go's api.go.
- **Ticket 5 (write)** — done. `h2_write`/`h2_writesched` moved into
  `gohttp_http2`; `Header.` → `Api.Header.`; self-`open` dropped.
- **Ticket 6 (transport)** — done. `round_trip : client_conn ->
  Api.client_request -> Api.client_response`; `build_response` returns
  `client_response` (no `Status`, no status string); `Body`/`Header` are local
  `Api` aliases; `req.Request.X` → `req.creq_X`.
- **Ticket 7 (server)** — done. `handler = Api.handler`; `build_request` returns
  `Api.server_request` (http1-only fields dropped); `response_writer` is
  `Api.response_writer` (rw_ fields); `Context = Gohttp_base.Context`.
- **Tickets 8–9 (shims)** — done. `lib/transport.ml` (`http2RoundTrip`):
  `Request.t → client_request`, `client_response → Response.t` (applies
  `Status.status_text`, wraps body). `lib/server.ml` (`http2Handler.ServeHTTP`):
  `server_request → Request.t`, `Api.response_writer → Server.response_writer`.
- **Ticket 10 (tests + docs)** — done. Per the chosen strategy the h2 suites
  (`test_h2_server`/`test_h2_transport`/`test_stream_h2`) build `Api` values
  directly; the protocol suites `open Gohttp_http2`. AGENTS.md (= CLAUDE.md)
  architecture §ibraries + layering-6 updated.

### Result

All 10 tickets complete. `dune build` clean (warnings-as-errors), `dune test`
green (487 tests, incl. all h2 suites through the new `Api`/shim boundary),
`dune exec gohttp` round-trips h1 + streaming + h2-over-TLS. Invariant verified:
`gohttp_http2` names no public `Request`/`Response`/`Body`/`Header`/`Status`
type (only comments referencing the shim boundary remain).
