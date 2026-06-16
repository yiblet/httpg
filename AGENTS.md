# AGENTS.md

## Project

`httpg` is an OCaml port of Go's `net/http`, covering HTTP/1.0, HTTP/1.1, and HTTP/2 over TLS/ALPN for both clients and servers.

The vendored Go sources are the behavioral specification:

- `go/src/net/http/`
- `go/src/net/http/internal/http2/`
- `go/src/vendor/golang.org/x/net/http2/hpack/`

Each OCaml module should remain easy to map back to its Go counterpart. Match Go's observable behavior: wire format, framing, protocol decisions, and error conditions.

Use idiomatic OCaml where it improves safety or clarity without changing observable behavior.

## Core rules

1. **Behavior follows Go; representation follows OCaml.**
   - Preserve Go-compatible behavior.
   - Prefer `option`, variants, `result`, immutable data, and smart constructors over Go-style sentinels, nils, and mutation.
   - Keep names close to Go where useful for source navigation.
   - Document intentional API or architectural deviations in the relevant `.mli`. Add major deviations to **Deliberate deviations** below.

2. **Make illegal states unrepresentable.**
   - Convert sentinel states into types.
   - Example: Go `content_length = -1` means unknown, so use `None`; an actual zero-length body is `Some 0L`.
   - Do not wrap genuine data or quantities merely for stylistic consistency.

3. **Every public module has a handwritten `.mli`.**
   - Add one for every new `lib/` module.
   - Keep it synchronized with the implementation.

4. **Port and preserve Go's tests.**
   - `test/test_<x>.ml` should track the corresponding Go test file.
   - When a ported test fails, fix the implementation.
   - Change a test only for a genuine Go-specific artifact, and document why.

5. **Stream where Go streams.**
   - Do not buffer whole request or response bodies on hot paths.
   - Use bounded reads and writes.
   - Preserve incremental delivery and backpressure.

6. **Failures are typed data.**
   - Library code does not use exceptions for **error propagation**: a failure a
     caller could observe is a typed `result`, never a raised exception.
   - Fallible modules own a typed `error` variant and `error_to_string`.
   - Public signatures use `('a, error) result`, never string errors or bare `exn`.
   - Mid-stream failures must be represented in the stream, not raised.
   - A purely **local** control-flow break (`raise Exit`/`Stop` to short-circuit
     an internal `iter`/`fold` and return a value within the same function) is an
     accepted OCaml idiom — it carries no error and never crosses a function
     boundary. It is not error propagation and is allowed.

## Exceptions and Eio boundaries

Exceptions are allowed only where required by Eio interfaces:

- Let `Eio.Cancel.Cancelled` propagate.
- An implemented `Eio.Flow` source may raise `End_of_file` because the interface requires it.
- Catch exceptions raised by `Eio.Buf_read` or other Eio APIs immediately at the boundary and convert them to typed results.

Do not:

- declare exceptions in `.mli` files;
- raise private sentinels and catch them in another layer;
- translate one of our own exceptions back into `Error`;
- catch cancellation and reclassify it as a normal failure.

`assert false` is allowed only for a compiler-required, genuinely unreachable branch. Prefer restructuring the type or match.

## Data structure conventions

Mirror Go by default, then deviate deliberately when OCaml gains a clear safety or API benefit.

Established choices:

- Public `Header.t` is a persistent map with functional `add`, `set`, and `del`.
- HTTP/2 `Api.Header` remains a mutable `Hashtbl`; translate at the public/private boundary.
- Missing string fields such as cookie path/domain use `option`.
- `Cookie.make` is a smart constructor.
- `Client.timeout` is `float option`.
- Go maps normally become `Hashtbl` unless an established immutable representation is more appropriate.
- Go slices become lists or arrays according to access patterns.

## Architecture

The repository contains four libraries.

### `httpg_base` — `lib/base/`

Foundation shared by the public HTTP implementation and HTTP/2 internals.

Currently includes ports such as `Textproto`. It is public and re-exported.

### `httpg_internal` — `lib/internal/`

Private implementation details:

- ports of Go `net/http/internal` packages;
- unexported Go `net/http` implementation modules such as routing internals.

These modules never appear under `Httpg.*`.

### `httpg_http2` — `lib/internal/http2/`

Private HTTP/2 stack:

- HPACK;
- frame, flow, pipe, buffering, scheduling, server, and transport modules;
- decoupled `Api` types.

This library may depend on `httpg_base` and `httpg_internal`, but must not depend on public `Request`, `Response`, `Body`, `Header`, or `Status` types.

### `httpg` — `lib/`

Public flat API exposed as `Httpg.*`.

The public server and transport own the HTTP/1 ↔ HTTP/2 translation shims at the ALPN boundary.

## Dependency order

Keep dependencies moving upward to avoid OCaml module cycles:

1. Pure data: method, status, header, cookie, sniff, time, URI/form values.
2. Body and transfer framing.
3. Request/response parsing and serialization.
4. Networking and TLS.
5. Client, server, routing, and transport.
6. Private HTTP/2 stack plus boundary translation.

Do not introduce a dependency from a lower layer onto a higher one to avoid a local refactor.

## Concurrency and I/O

Use Eio directly in direct style.

- `Eio.Buf_read` / `Eio.Buf_write` correspond to Go `bufio`.
- `Eio.Net` handles sockets.
- TLS is driven through the sans-I/O `Tls.Engine`; do not introduce `tls-eio`.
- Use `Eio.Switch` and `Eio.Time` for lifetime, cancellation, and deadlines.
- Map goroutines/channels/condition variables to Eio fibers, streams, mutexes, and conditions.
- HTTP/2 uses one event-loop fiber per connection.
- The server may use `Eio.Domain_manager` to run accept loops across domains.

Do not add an alternate monad or I/O functor abstraction.

## Public endpoint model

Handlers use the project API, not Go's `ResponseWriter` shape:

```ocaml
type handler =
  sw:Eio.Switch.t ->
  Body.t Request.t ->
  Body.t Response.t
```

Responses are immutable builders. The serving loop writes and flushes them.

Open response-bound resources under the request switch so they remain alive until transmission completes.

A connection may be reused only after its body reaches EOF or is explicitly drained.

Client cancellation and deadlines use the caller's switch and the configured Eio clock. There is no Go-style context parameter.

## Deliberate deviations

These are intentional and should not be “fixed” toward a literal Go API.

### Forms and multipart

Request records do not cache parsed form fields.

- `Form` is a persistent multimap.
- `Form.parse_query` parses query strings.
- `Form.of_body` parses URL-encoded bodies.
- Callers explicitly merge query and body values.
- `Multipart.of_body` parses incrementally and may spill parts to switch-scoped temp files.
- Custom unstructured part headers and consume-once wire-streaming part readers are non-goals.

### Filesystem MIME detection

Use the built-in extension table, then `Sniff` fallback. There is no full Go `mime` package port.

### TLS

Clients verify certificates by default through `ca-certs`. `~insecure` exists for self-signed test endpoints.

### h2c

Only HTTP/2 prior knowledge is supported.

- No HTTP/1.1 `Upgrade: h2c`.
- `?force_h2:true` sends plaintext connections directly to HTTP/2.
- Over TLS, ALPN remains authoritative and the flag has no effect.

### Handler API

Handlers return immutable responses rather than mutating a Go-style `ResponseWriter`.

## Source work

When porting or correcting behavior:

1. Locate the corresponding Go source and tests.
2. Cross-reference the Go file and relevant line range in comments or the plan.
3. Preserve externally visible behavior.
4. Choose the smallest idiomatic OCaml representation that preserves that behavior.
5. Update the `.mli`.
6. Port or add tests.
7. Run the focused test, then the full fast suite.

Do not perform unrelated cleanup while fixing a behavioral discrepancy.

## Plans and commits

Substantial work uses an active `plans/*.plan.md` file organized as:

- problem;
- discovery;
- target shape;
- tickets;
- execution record.

Work one ticket at a time.

For each ticket:

1. confirm the existing tests are green;
2. implement the ticket;
3. add or port tests;
4. verify the focused and relevant broader suites;
5. update the plan's execution record;
6. create one semantic commit.

If the repository root contains `.jj`, use `jj`; otherwise use Git.

Completed plans are removed. Their execution history remains in version control.

## Commands

```sh
dune build
dune test
dune build @fmt --auto-promote 
HTTPG_SLOW=1 dune test
dune exec test/test_httpg.exe -- test Header
dune exec test/test_httpg.exe -- test Header 3
dune exec httpg
opam install . --deps-only --with-test
```

`dune build` treats warnings as errors.

The Alcotest runner is `test/test_httpg.ml`. Eio tests must have deadlines so hangs fail rather than block indefinitely.

Mark tests as `` `Slow `` when they use high iteration counts or real clock waits. Keep the default suite fast.

## Before finishing

Verify all of the following:

- observable behavior still matches Go;
- no whole-body buffering was added to a streaming path;
- errors are typed and no new internal exception bridge exists;
- every changed public module has an updated `.mli`;
- relevant Go tests are represented;
- focused tests pass;
- `dune build` and the fast test suite pass;
- the active plan and commit history reflect the completed ticket.

Remaining features and non-goals are tracked in `TODO.md`.
