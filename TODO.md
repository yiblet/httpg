# TODO

1. Create a README
2. ~~figure out a clearer error handling pattern than using exceptional ocaml~~
   **Done** (`plans/result-migration.plan.md`, 8 tickets): handleable errors are
   typed `('a, error) result` / `(_, error) result Lwt.t` with per-module `error`
   variants; only unhandleable invariants/control-flow stay as exceptions
   (allowlist in `plans/error-handling-audit.md`). Guarded by the `Error_policy`
   test suite.

---

## Production-readiness (server)
- Graceful `Shutdown` / `Close`, `SetKeepAlivesEnabled`.
- Timeouts: Read / Write / Idle / ReadHeader; `MaxHeaderBytes`.
- `ResponseController`, `Hijacker`, `CloseNotifier`.
- `Expect: 100-continue` handling.
- `DefaultServeMux` + package-level `Handle`/`HandleFunc`/`ListenAndServe`.

## Client / transport
- Cookie jar (`net/http/cookiejar`).
- Proxies: `ProxyFromEnvironment`, HTTP `CONNECT` tunneling, SOCKS5 (`socks_bundle.go`).
- Connection-pool limits: `MaxIdleConns`, `MaxConnsPerHost`, `IdleConnTimeout`; custom `DialContext`.
- `RegisterProtocol` + alternate-scheme RoundTrippers.
- Transparent gzip / `DisableCompression`; `GetBody` re-send on redirect; `ErrUseLastResponse`.

## HTTP/2 extras
- Server Push send (`PUSH_PROMISE`) — currently parse-only.
- RFC 9218 priority scheduler (round-robin only today); h2c (cleartext) upgrade.
- Trailers re-surfaced on `Response`; `maxConcurrentStreams` await; GOAWAY-retry-on-new-conn; extended CONNECT.
- HTTP/2 response content sniffing (reduced to a `text/plain` default).

## Subpackages not yet ported
- `net/http/httputil` — `ReverseProxy`, `DumpRequest`/`DumpResponse` (ReverseProxy is now very feasible).
- `net/http/httptrace`, `net/http/cgi`, `net/http/fcgi`, `net/http/pprof`, `csrf.go`.

## Smaller / cleanup
- `Request.Clone` (`clone.go`); `Header.clone` already exists.
- Multipart: enforce `max_memory` (temp-file spill) + a streaming `MultipartReader`; currently the `multipart_form-lwt` stand-in.
- `mime.TypeByExtension` database (today a small built-in table + `Sniff` fallback).
- `Uri.t` vs `url.URL` divergences: `RawPath`/opaque/scheme-relative URIs, `ParseRequestURI` semantics (a few `request_test.go` rows skipped).

## Explicit non-goal
- HTTP/3 / QUIC (would require porting a full QUIC stack first).
