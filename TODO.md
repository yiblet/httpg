# TODO

1. Create a README
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
- `net/http/internal/httpsfv` (RFC 8941 Structured Field Values parser): its only consumer is `internal/http2/frame.go`'s `parseRFC9218Priority` (the PRIORITY_UPDATE frame), which is unported — bring `httpsfv` in alongside that frame, in the RFC 9218 priority work above.

## Smaller / cleanup
- `Request.Clone` (`clone.go`); `Header.clone` already exists.
- Multipart: enforce `max_memory` (temp-file spill) + a streaming `MultipartReader`; currently the `multipart_form-lwt` stand-in.
- `mime.TypeByExtension` database (today a small built-in table + `Sniff` fallback).
- `Uri.t` vs `url.URL` divergences: `RawPath`/opaque/scheme-relative URIs, `ParseRequestURI` semantics (a few `request_test.go` rows skipped).

## Explicit non-goal
- HTTP/3 / QUIC (would require porting a full QUIC stack first).
