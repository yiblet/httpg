# httpg

**HTTP for OCaml that works the way you'd expect** — a client and server for
HTTP/1.0, HTTP/1.1, and HTTP/2, with TLS, modeled directly on Go's
[`net/http`](https://pkg.go.dev/net/http).

If you've used Go's `net/http` — or honestly any mainstream HTTP library —
`httpg` should feel familiar. The types and functions carry the same names and
behave the same way, so Go's documentation doubles as a reference and you don't
need a background in functional programming to get going.

```ocaml
open Lwt.Infix
open Httpg

(* Fetch a URL. *)
let () =
  Lwt_main.run
    (Client.get Client.default_client "http://example.com/" >>= fun resp ->
     Body.read_all resp.body >|= fun body ->
     Printf.printf "%d\n%s" resp.status_code body)
```

## Why httpg exists

- **One library for HTTP/1, HTTP/2, and TLS — both client and server.** Other
  OCaml libraries cover pieces of this, but I couldn't find a single, cohesive
  one that does all of it. In particular, there wasn't an OCaml *client* that
  speaks HTTP/1 and HTTP/2 at the same time. Unless you wanted to depend on libcurl
  `httpg`'s client negotiates the protocol per connection (via TLS ALPN), so the same 
  code talks to HTTP/1 and HTTP/2 servers without you having to choose up front.

- **Approachable if functional programming isn't your background.** OCaml's
  existing HTTP libraries are great once you're comfortable with FP — but that's
  a real barrier for newcomers. By mirroring an API that a huge number of
  developers already know (Go's), `httpg` tries to meet you where you are: the
  concepts are HTTP concepts, not type-theory ones.

- **Trustworthy enough to build on.** The hard, security-sensitive parts of HTTP
  — request parsing, framing, chunked encoding, the connection lifecycle — are
  easy to get subtly wrong. Rather than design those from scratch, `httpg` ports
  Go's battle-tested `net/http`, *including its test suite*, so it starts from a
  known-good reference. That makes it something you can reasonably put near the
  root of your stack.

It's a work in progress, but `httpg` is already comfortably usable as an HTTP
client and server for most purposes. That being said, it is still pre-alpha. 

There is more work to do to further harden the implementation, and I have some ideas 
for how we make it more ergonomic to use and bring the API closer to a balance of 
functional but not "advanced and functional". 

## Install

```sh
opam install . --deps-only --with-test
```

`httpg` is built on [Lwt](https://github.com/ocsigen/lwt) for concurrency and
[tls](https://github.com/mirleft/ocaml-tls) for HTTPS.

## A first server

Handlers receive a writer (`w`) and the request. You set a status and write a
body — that's it.

```ocaml
open Lwt.Infix
open Httpg

let () =
  let mux = Server.new_serve_mux () in
  Result.get_ok
    (Server.handle_func mux "/hello" (fun w _req ->
         w.write_header 200;
         w.write "Hello, world\n"));
  Lwt_main.run
    (Server.listen_and_serve ~addr:"127.0.0.1" ~port:8080
       (Server.serve_mux_handler mux))
```

## Making a request

```ocaml
open Lwt.Infix
open Httpg

let () =
  Lwt_main.run
    (Client.get Client.default_client "http://example.com/" >>= fun resp ->
     (* Bodies stream in; read to the end to free the connection for reuse. *)
     Body.read_all resp.body >|= fun body ->
     Printf.printf "%d\n%s" resp.status_code body)
```

There's more — POSTs and form posts, custom clients and servers (timeouts,
redirect policy, TLS), and testing your handlers in-memory with `Httptest`. See
[`doc/index.mld`](doc/index.mld) or the generated API docs (`dune build @doc`).

## What you can count on

- **It behaves like `net/http`.** This is a structural port, not a loose
  imitation: each module mirrors the matching Go source file, the data
  structures match Go's, and Go's own tests are ported and kept passing. The
  fiddly corners — header canonicalization, content-length vs. chunked framing,
  trailers, redirect header stripping, keep-alive teardown — match too.
- **Errors are values, not surprises.** Anything that can fail in normal use
  returns a `result` you pattern-match on (`Ok` / `Error`), with a clear error
  type per module — so you handle failures explicitly instead of catching stray
  exceptions. Only genuine bugs raise.
- **Bodies stream.** Requests and responses are read and written in bounded
  chunks, never buffered whole, so large payloads don't blow up memory.
- **HTTP/2 just happens.** Over HTTPS, the client and server negotiate HTTP/2
  automatically (ALPN) and fall back to HTTP/1.1 when the peer doesn't support
  it. Plain `http://` stays HTTP/1.x.

## Status

Working today: HTTP/1.0–1.1 and HTTP/2 for both client and server, ServeMux
routing, keep-alive connection pooling, redirects, cookies, multipart/form
parsing, static file serving, and the `Httptest` helpers for testing.

It is still a work in progress — remaining gaps and deliberate non-goals
(HTTP/3, proxies, a cookie jar, server push, …) are tracked in
[`TODO.md`](TODO.md).

## Build, test, docs

```sh
dune build                 # build (warnings are errors)
dune runtest               # run the full ported test suite
dune build @doc            # generate the API documentation
dune exec httpg            # run the demo (HTTP/1 + streaming + HTTP/2-over-TLS)
```

## License

[BSD 3-Clause](LICENSE). `httpg` ports Go's `net/http`, which is itself
BSD-3-Clause (`Copyright 2009 The Go Authors`); that notice is retained in
[`LICENSE`](LICENSE) alongside the port's copyright.
