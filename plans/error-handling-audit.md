# gohttp — Error-Handling Audit & Decomposition

**Status: COMPLETE.** All eight tickets of `plans/result-migration.plan.md` are done.
Every handleable error in `lib/`/`lib/internal/` is now a typed `Result.t` value; the
only surviving exceptions are the **unhandleable allowlist** below (programmer-bug /
invariant / internal control-flow sentinels). The regression guard
`test/test_error_policy.ml` (`Error_policy` suite) enforces this: no `*_exn` shim
identifier in any swept `.mli`, each migrated module declares its typed error type, and
the allowlist is enumerated. Verified by `grep -rn "_exn" lib/ lib/internal/` → empty.

Companion to `plans/result-migration.plan.md`. This is the durable, source-of-truth
classification of every error-handling site in `lib/` and `lib/internal/`, mapping
each one to **handleable (→ `Result.t` / typed `error` variant)** vs.
**unhandleable (→ stays an exception, documented)**, and to the ticket that converts it.

Line numbers reference the tree as of Ticket 1 (commit baseline `d48031c`). They will
drift as the migration lands; the **classification** is the stable contract — re-grep
for exact lines when working a later ticket.

---

## Conventions

### Error philosophy (mirrors `CLAUDE.md` / the migration plan)

- **Handleable errors** (malformed input, protocol violations, registration
  conflicts, framing errors — anything a caller could reasonably recover from or
  translate into an HTTP status) are surfaced as values:
  - Pure code: `('a, error) result`.
  - Lwt/IO code: `('a, error) result Lwt.t`.
  - Each module **owns a closed, typed `type error`** declared in its `.mli`,
    covering exactly its handleable failures. Lower-level error types are *embedded*
    in higher-level ones (e.g. `Io.error` will have a `Transfer of Transfer.error`
    arm). No global mega-error type.
- **Unhandleable errors** (programmer bugs, invariant violations, internal
  control-flow sentinels) stay as **exceptions**, owned where they are, and are
  **documented** in the `.mli` ("raises X on programmer error / invariant violation").
  These are *not* converted; see the allowlist below.

This matches Go's `(T, error)` for handleable cases and `panic` for bugs.

### `Lwt_result` syntax convention

**Decision: no new `lib/result_syntax.ml(i)` module.** Each migrated module opens the
stdlib/`lwt`-provided syntax locally:

- **Lwt/IO code** (`('a, error) result Lwt.t`): `open Lwt_result.Syntax` at the top
  of the `.ml` (or locally inside the function). `Lwt_result` ships with the `lwt`
  opam package (verified at `_opam/lib/lwt/lwt_result.mli`), and `lwt` is already a
  dependency in `lib/dune` — **no new opam dependency is needed.**
  `Lwt_result.Syntax` provides `( let* )` / `( let+ )` for `('a,'e) result Lwt.t`.
- **Pure code** (`('a, error) result`): `open Result.Syntax` (stdlib, available since
  OCaml 5.4; this switch is 5.4.1) for `( let* )` / `( let+ )`, or just an explicit
  `match` where that reads more clearly.

Rationale (from the plan's Detailed Design, Ticket 1.D): a shared module is only
worth it if 3+ modules need the *same pure+Lwt mix*; `open … .Syntax` locally is the
lighter, idiomatic choice. Revisit (add `Result_syntax`) only if that threshold is hit.

#### `let*` idiom for `('a, error) result Lwt.t`

```ocaml
(* In a module returning ('a, Io.error) result Lwt.t *)
open Lwt_result.Syntax   (* ( let* ), ( let+ ) bind over ('a,'e) result Lwt.t *)

let read_request ic : (Body.t Request.t, error) result Lwt.t =
  let* line   = read_request_line ic in        (* short-circuits on Error *)
  let* header = read_mime_header ic in          (* Transfer.error embedded *)
  let+ body   = read_body header ic in          (* let+ = map on the Ok value *)
  Request.make ~line ~header ~body

(* Helpers to move between worlds:
   Lwt_result.lift   : ('a,'e) result -> ('a,'e) result Lwt.t
   Lwt_result.ok     : 'a Lwt.t -> ('a,'e) result Lwt.t
   Lwt_result.fail   : 'e -> ('a,'e) result Lwt.t
   Lwt_result.map_error : ('e1 -> 'e2) -> ('a,'e1) t -> ('a,'e2) t  (* embed lower error *)
*)
```

For pure code:

```ocaml
open Result.Syntax   (* stdlib, OCaml >= 5.4 *)

let parse s : (t, error) result =
  let* tokens = tokenize s in
  let+ ast = build tokens in
  ast
```

---

## Migrated-module audit table

Columns: **module | site (file:line) | exception/raise kind | handleable? | target error arm | ticket**.

### Ticket 2 — Pure parsers (pattern, values, cookie)

| module | site (file:line) | exception/raise kind | handleable? | target error arm | ticket |
|---|---|---|---|---|---|
| pattern | pattern.ml:155 (`exception Parse_error of string`) | exception decl, raised at :161, caught in `parse` | yes (boundary) | `Pattern.error` variants: `Empty_pattern \| Invalid_method of string \| Missing_path \| Unclean_path of string \| Bad_wildcard of string \| Duplicate_wildcard of string` (`parse : string -> (t, error) result`) | 2 |
| pattern | pattern.ml:161 (`raise (Parse_error …)`) | raise | yes | folds into `Pattern.error` (above) | 2 |
| pattern | pattern.ml:340 (`let exception Done`) :347,:353 | internal control-flow sentinel | **no — keep** | (control flow only; documented) | 2 (doc) |
| pattern | pattern.ml:368, :386 (`failwith` in `describeConflict`/literal cmp) | failwith on invariant ("non-conflicting patterns", "literals differ") | **no — keep** (invariant) | document as programmer-error in `.mli` | 8 (doc) |
| values | values.mli:41 `parse_query : … * (unit, string) result` | already `result`, `string` payload | yes (normalize) | `Values.error = Invalid_semicolon_separator \| Invalid_escape of string` | 2 |
| values | values.mli:44 `parse_query_into : … (unit, string) result` | already `result`, `string` payload | yes (normalize) | folds into `Values.error` | 2 |
| cookie | cookie.mli:56 `valid : t -> (unit, string) result` | already `result`, `string` payload | yes (normalize) | `Cookie.error = Invalid_name of string \| Invalid_value of string \| Invalid_domain of string \| …` | 2 |
| cookie | cookie.ml:136,168,195,198,199,201 (`raise Exit`) | internal control-flow (early-exit of `String.iter`) | **no — keep** | (control flow only) | 2 (doc) |

### Ticket 3 — HPACK codec (hpack, hpack_huffman)

| module | site (file:line) | exception/raise kind | handleable? | target error arm | ticket |
|---|---|---|---|---|---|
| hpack | hpack.ml:17 / .mli:27 (`exception Decoding_error of string`) | exception decl | yes | `Hpack.error = Decoding of string \| …` | 3 |
| hpack | hpack.ml:18 / .mli:32 (`exception Invalid_indexed of int`) | exception decl | yes | `Hpack.error … \| Invalid_indexed of int` | 3 |
| hpack | hpack.ml:19 / .mli:36 (`exception String_too_long`) | exception decl | yes | `Hpack.error … \| String_too_long` | 3 |
| hpack | hpack.ml:22 / .mli:41 (`exception Need_more`) | decoder control-flow sentinel | **no — keep** | documented internal sentinel | 3 (doc) |
| hpack | hpack.ml:47 (`invalid_arg "read_var_int: bad n"`) | invalid_arg precondition (n∉1..8) | **no — keep** (programmer bug) | document in `.mli` | 3 (doc) |
| hpack | hpack.ml:66,71 (`raise Exit`) | internal control-flow in var-int loop | **no — keep** | (control flow) | 3 (doc) |
| hpack | hpack.ml:277,410 (`raise String_too_long`) | raise | yes | `Hpack.error … String_too_long` | 3 |
| hpack | hpack.ml:309,324 (`raise (Invalid_indexed …)`) | raise | yes | `Hpack.error … Invalid_indexed` | 3 |
| hpack | hpack.ml:368,380,422 (`raise (Decoding_error …)`) | raise | yes | `Hpack.error … Decoding` | 3 |
| hpack | hpack.ml:413 (`raise e` from `read_var_int` Error) | re-raise of result error | yes | propagate as `Hpack.error` (add `Var_int_overflow`) | 3 |
| hpack | hpack.mli:21 `read_var_int : … (int*int, exn) result` | already `result`, `exn` payload | yes (normalize) | `read_var_int : … ((int*int), error) result` | 3 |
| hpack_huffman | hpack_huffman.ml:4 / .mli:8 (`exception Invalid_huffman`) | exception decl | yes | `Hpack_huffman.error = Invalid_huffman` | 3 |
| hpack_huffman | hpack_huffman.ml:125,140,151,155 (`raise Invalid_huffman`) | raise | yes | `Hpack_huffman.error` (`decode : string -> (string, error) result`) | 3 |
| hpack_huffman | hpack_huffman.ml:142 (`raise Exit`) | internal control-flow | **no — keep** | (control flow) | 3 (doc) |

### Ticket 4 — Transfer framing (transfer, internal/chunked)

| module | site (file:line) | exception/raise kind | handleable? | target error arm | ticket |
|---|---|---|---|---|---|
| transfer | transfer.ml:21 / .mli:11 (`exception Bad_string_error of string * string`) | exception decl | yes | `Transfer.error … \| Bad_content_length of string \| Bad_header of string * string` | 4 |
| transfer | transfer.ml:15 / .mli:5 (`exception Err_line_too_long`, alias of Chunked) | exception decl | yes | `Transfer.error … \| Line_too_long` | 4 |
| transfer | transfer.ml:18 / .mli:8 (`exception Chunk_error of string`, alias) | exception decl | yes | `Transfer.error … \| Chunk of string` | 4 |
| transfer | transfer.ml:176,179,183,187 (`raise (bad_string_error … Content-Length)`) | raise | yes | `Bad_content_length of string` | 4 |
| transfer | transfer.ml:270 (`raise e` saved chunked err) | re-raise mid-read | yes (initial) / mid-stream see note | `Transfer.error` at boundary; mid-stream thunk **keeps raising** (Resolution #1) | 4 |
| transfer | transfer.ml:293 (`raise (Chunk_error "unsupported transfer encoding")`) | raise | yes | `Unsupported_transfer_encoding of string` | 4 |
| transfer | transfer.ml:386 (`raise (Chunk_error "unexpected EOF")`) | raise (inside stream thunk) | **mid-stream — keeps raising** | documented (`Unexpected_eof` arm at boundary only) | 4 (doc) |
| transfer | transfer.ml:495 (`raise (bad_string_error "invalid Trailer key")`) | raise | yes | `Bad_header of string * string` | 4 |
| transfer | transfer.ml:381,402 (`Lwt.fail e` on non-EOF read) | re-raise IO exn inside stream thunk | **mid-stream — keeps raising** | documented | 4 (doc) |
| internal/chunked | chunked.ml:8 / .mli:6 (`exception Err_line_too_long`) | exception decl | yes | `Chunked.error = Line_too_long \| …` | 4 |
| internal/chunked | chunked.ml:11 / .mli:10 (`exception Chunk_error of string`) | exception decl | yes | `Chunked.error … \| Chunk of string` | 4 |
| internal/chunked | chunked.ml:18,26,28 (`raise (Chunk_error …)` in `parse_hex_uint`) | raise | yes | `parse_hex_uint : string -> (int64, error) result` | 4 |
| internal/chunked | chunked.ml:60,70,71 (`raise (Chunk_error …)` chunked-line parse) | raise (header parse) | yes (boundary) | `Chunked.error` at reader init | 4 |
| internal/chunked | chunked.ml:63,73 (`raise Err_line_too_long`) | raise | yes | `Line_too_long` | 4 |
| internal/chunked | chunked.ml:84,106,119 (`raise (Chunk_error …)` mid-read) | raise inside reader thunk | **mid-stream — keeps raising** | documented | 4 (doc) |
| internal/chunked | chunked.ml:55,122 (`Lwt.fail …`) | re-raise IO exn in thunk | **mid-stream — keeps raising** | documented | 4 (doc) |

> **Mid-stream policy (Resolution #1, confirmed):** header/initial-framing errors are
> returned as `result`; errors discovered *after* `read_request`/reader init has
> returned `Ok` (inside the `Body.Stream` thunk) **keep raising**, mirroring Go's
> "later `Read` returns an error" model. To be documented in `body.mli` / `transfer.mli`
> in Ticket 4.

### Ticket 5 — Message read/write (io)

| module | site (file:line) | exception/raise kind | handleable? | target error arm | ticket |
|---|---|---|---|---|---|
| io | io.ml:9 / .mli:16 (`exception Protocol_error of string`) | exception decl | yes | `Io.error … \| Protocol of string` | 5 |
| io | io.ml:371 / .mli:20 (`exception Missing_host`) | exception decl | yes | `Io.error … \| Missing_host` | 5 |
| io | io.ml:71,201,294 (`Lwt.fail (Protocol_error / bad_string_error … malformed)`) | Lwt.fail (request/response line) | yes | `Protocol of string` | 5 |
| io | io.ml:78,84,88 (`raise (Protocol_error … MIME header line)`) | raise (mime header) | yes | `Protocol of string` | 5 |
| io | io.ml:204,207,303,306,307,310 (`Lwt.fail (bad_string_error …)`) | Lwt.fail (method/version/status) | yes | `Protocol of string` | 5 |
| io | io.ml:215 (`Lwt.fail (Protocol_error "too many Host headers")`) | Lwt.fail | yes | `Protocol of string` | 5 |
| io | io.ml:272,291 (`Lwt.fail (Protocol_error "unexpected EOF")`) | Lwt.fail | yes | `Unexpected_eof` | 5 |
| io | io.ml:379 (`Lwt.fail Missing_host`) | Lwt.fail (write_request) | yes | `Missing_host` | 5 |
| io | io.ml:386 (`Lwt.fail (Protocol_error "can't write control char in URL")`) | Lwt.fail | yes | `Protocol of string` | 5 |
| io | io.ml:27 (`Lwt.fail End_of_file`) / :25 (`e -> Lwt.fail e`) | re-raise of raw IO `End_of_file` | yes (mapped) | `Unexpected_eof` at boundary; underlying IO exn re-raised | 5 |
| io | (embeds Transfer) | — | yes | `Io.error … \| Transfer of Transfer.error` | 5 |

### Ticket 6 — HTTP/1.x endpoints (server, client, transport, fs, form)

| module | site (file:line) | exception/raise kind | handleable? | target error arm | ticket |
|---|---|---|---|---|---|
| server | server.ml:207 / .mli:63 (`exception Register_error of string`) | exception decl | yes | `Server.error = Register of string` (`handle/handle_func : … (unit, error) result`) | 6 |
| server | server.ml:211,214 (`raise (Register_error …)`) | raise (pattern register) | yes | `Register of string` | 6 |
| client | client.mli:8 `check_redirect : … (unit, string) result` | already `result`, `string` payload | yes (normalize) | `Client.error` (redirect/io); shape vs `check_redirect` confirmed in T6 | 6 |
| client | client.ml `Lwt.fail` (×3) on redirect-policy abort | Lwt.fail | yes | `Client.error … \| Redirect of string \| Io of Io.error` | 6 |
| transport | transport.ml `Lwt.fail` (×7), `raise` (×1) | re-raise of read/conn errors | yes (boundary) | consume `Io.error` result; surface `Transport`/`Client` error | 6 |
| fs | fs.ml:23 / .mli:53 (`exception Invalid_unsafe_path`) | exception decl | yes | `Fs.error … \| Invalid_unsafe_path` | 6 |
| fs | fs.ml:462 / .mli:114 (`exception No_overlap`) | exception decl | yes | `Fs.error … \| No_overlap` | 6 |
| fs | fs.ml:463 / .mli:118 (`exception Invalid_range`) | exception decl | yes | `Fs.error … \| Invalid_range of string` | 6 |
| fs | fs.ml:506,515,517,525,538,540 (`raise Invalid_range`) | raise (parse_range) | yes | `parse_range : … (http_range list, error) result` | 6 |
| fs | fs.mli:126 `parse_range : … (http_range list, exn) result` | already `result`, `exn` payload | yes (normalize) | `(http_range list, Fs.error) result` | 6 |
| fs | fs.mli:41 `open_ : … (file, exn) result Lwt.t` | already `result`, `exn` payload (extension point) | yes (normalize, **breaking, in-repo only**) | `open_ : … (file, Fs.error) result Lwt.t` (Resolution #3) | 6 |
| fs | fs.ml:139 (`Lwt.fail (Failure "not a directory")`) | Lwt.fail | yes | `Fs.error` arm | 6 |
| form | form.ml:16 / .mli:10 (`exception Form_error of string`) | exception decl | yes | `Form.error = Form of string \| Not_multipart` | 6 |
| form | form.ml:213 / .mli:14 (`exception Not_multipart`) | exception decl | yes | `Not_multipart` | 6 |
| form | form.ml:52,100 (`raise (Form_error …)`) | raise (media-param parse) | yes | `Form of string` | 6 |
| form | form.ml:244,250,293 (`Lwt.fail (Form_error …)`) | Lwt.fail | yes | `Form of string` | 6 |
| form | form.mli:28 `parse_form : … (unit, string) result Lwt.t` | already `result`, `string` payload | yes (normalize) | `(unit, Form.error) result Lwt.t` | 6 |

### Ticket 7 — HTTP/2 boundaries (h2_frame, h2_error, h2_pipe, h2_databuffer, h2_server, h2_transport)

| module | site (file:line) | exception/raise kind | handleable? | target error arm | ticket |
|---|---|---|---|---|---|
| h2_error | h2_error.ml:73 / .mli:35 (`exception Connection_error of err_code`) | exception decl | yes (unify) | `H2_error.t = Connection of err_code \| …`; keep `exception` only at internal raise points (`to_exn`) | 7 |
| h2_error | h2_error.ml:77 / .mli:42 (`exception Stream_error of stream_error`) | exception decl | yes (unify) | `H2_error.t … \| Stream of stream_error` | 7 |
| h2_frame | h2_frame.ml:92–95 / .mli:95–105 (`exception Frame_too_large \| Invalid_stream_id \| Invalid_dep_stream_id \| Pad_length_too_large`) | exception decls | yes | fold into unified `H2_error.t` (`Frame_too_large \| Invalid_stream_id \| Invalid_dep_stream_id \| Pad_length_too_large`) | 7 |
| h2_frame | h2_frame.ml:164–285, 573–595 (`raise (conn_error …)`, `Stream_error`, `End_of_file`) | raise (frame parse) | yes (read_frame boundary) | `read_frame : … (frame, H2_error.t) result Lwt.t` | 7 |
| h2_frame | h2_frame.ml:321,331,444 (`raise Frame_too_large`) | raise | yes | `Frame_too_large` | 7 |
| h2_frame | h2_frame.ml:337,358,380,389,424,430,434 (`raise Invalid_stream_id`) | raise (write-side frame build) | yes | `Invalid_stream_id` (or keep as write-side invariant — confirm in T7) | 7 |
| h2_frame | h2_frame.ml:339 (`raise Pad_length_too_large`), :370,:381 (`Invalid_dep_stream_id`) | raise | yes | corresponding `H2_error.t` arms | 7 |
| h2_frame | h2_frame.ml:418 (`raise (Invalid_argument "illegal window increment")`) | invalid_arg (write-side invariant) | **no — keep** (programmer bug) | document in `.mli` | 7 (doc) |
| h2_frame | h2_frame.ml:577,595 (`with _ -> raise (conn_error CompressionError)`) | raise wrapping Hpack decode failure | yes | `Compression of Hpack.error` | 7 |
| h2_pipe | h2_pipe.ml:4 / .mli:5 (`exception Closed_pipe_write`) | exception decl | partial | `result` arm where consumed by streaming; pure invariant write keeps raising (confirm T7) | 7 |
| h2_pipe | h2_pipe.ml:5 / .mli:9 (`exception Uninitialized_pipe_write`) | exception decl | **no — keep** (invariant: write before init) | document | 7 (doc) |
| h2_pipe | h2_pipe.ml:78,82 (`raise …`) | raise | see above | per-site (T7) | 7 |
| h2_pipe | h2_pipe.ml:53,67 (`Lwt.fail e`) | re-raise stored pipe err | mid-stream | keeps raising / `result` where consumed (T7) | 7 |
| h2_databuffer | h2_databuffer.ml:4 / .mli:5 (`exception Read_empty`) | exception decl | partial | `result` arm where consumed by streaming; pure read-past-len invariant keeps raising (confirm T7) | 7 |
| h2_databuffer | h2_databuffer.ml:53 (`raise Read_empty`) | raise | see above | per-site (T7) | 7 |
| h2_transport | h2_transport.ml:9–12 (`exception Client_conn_closed \| Conn_got_goaway \| Stream_aborted \| Malformed_response`) | exception decls (internal to conn loop) | **no — keep internal**; only `round_trip` boundary surfaces `result` | `round_trip : … (Body.t Response.t, H2_error.t) result Lwt.t` (confirm vs Go RoundTrip) | 7 |
| h2_transport | h2_transport.ml `Lwt.fail` (×13), `raise` (×2) | internal conn-loop control flow | **no — keep internal** | boundary-only conversion (Resolution #2) | 7 |
| h2_server | h2_server.ml `Lwt.fail` (×3) | internal conn-loop control flow | **no — keep internal**; `serve` boundary as needed | boundary-only (Resolution #2) | 7 |

### Ticket 8 — Final sweep / docs only

Documentation, guard test (`Error_policy.no_handleable_raise_escapes`,
`Error_policy.unhandleable_allowlisted`), and `CLAUDE.md`/`TODO.md` updates.
No new conversion sites — only confirmation that every remaining `raise`/`failwith`/
`invalid_arg` is on the allowlist below.

---

## Unhandleable allowlist (KEEP as exceptions — never convert) — FINAL

These are **programmer-bug / invariant** failures, **internal control-flow
sentinels**, or **boundary-only-converted internal exceptions** (the h2 event loop:
public boundaries surface `result`, the internal fiber keeps raising to drive
GOAWAY/RST). They are out of scope for the migration (a Non-Goal in the plan) and are
documented in their `.mli`s. This list is mirrored by the static enumeration in
`test/test_error_policy.ml` (`Error_policy.unhandleable_allowlisted`); the two must be
kept in sync. Line numbers are post-migration and approximate (re-grep as needed).

| module | site(s) | exception/raise | why it stays |
|---|---|---|---|
| h2_flow | h2_flow.ml:31,34,92 (`invalid_arg`); .mli:26,58 | `Invalid_argument` on negative update / window-overflow / "took too much" | window-accounting invariant (programmer bug) |
| h2_writesched | h2_writesched.ml:47,112,163,205 (`failwith`); .mli:76,90 | illegal stream-id / DATA-on-non-open / double-open / "invalid use of queue" | scheduler invariant (programmer bug) |
| net | net.ml:212 (`failwith "bound_port: not an INET socket"`) | `Failure` precondition | precondition on socket kind |
| net | net.ml:61,97,150,171,192 (`failwith` on bad TLS config / csr) | `Failure` | config/setup misuse (programmer error) |
| hpack_tables | hpack_tables.ml:51,71,171 (`invalid_arg`, incl. `evict_oldest`); .mli:32,48 | `Invalid_argument` | table-index invariant (programmer bug) |
| hpack | hpack.ml:66,92,311,319 (`exception Need_more`) | decoder control-flow sentinel | internal: signals "need more bytes"; not a caller-visible error (not part of `Hpack.error`) |
| hpack | hpack.ml:64 (`invalid_arg "read_var_int: bad n"`) | `Invalid_argument` precondition (n∉1..8) | precondition (programmer bug) |
| hpack | hpack.ml:83,88 (`raise Exit`) | internal var-int loop control flow | not an error |
| hpack_huffman | hpack_huffman.ml:150 (`raise Exit`) | internal loop control flow | not an error |
| pattern | pattern.ml:372,378 (`let exception Done`) | internal control-flow | not an error |
| pattern | pattern.ml:393,411 (`failwith` describeConflict / literal cmp) | `Failure` invariant | called only on already-conflicting patterns (programmer bug) |
| mapping | mapping.ml:58 (`let exception Stop`) | internal control-flow | not an error |
| cookie | cookie.ml:136,168,195,198,199,201 (`raise Exit`) | internal `String.iter` early-exit | control flow (the *result* is the `Cookie.error`, not the Exit) |
| h2_frame | h2_frame.ml:457 (`Invalid_argument "illegal window increment"`) | write-side invariant | programmer bug (building an invalid frame) |
| h2_frame | h2_frame.ml:370–483 (`raise Frame_too_large \| Invalid_stream_id \| Invalid_dep_stream_id \| Pad_length_too_large`) | write-side frame-builder invariants | building an invalid frame is a programmer bug; documented in `.mli` (kept as raises; the *read* path surfaces these via the unified `H2_error.t` `result`) |
| context | context.ml:18,19 / .mli:16,20 (`exception Canceled \| Deadline_exceeded`) | cancellation signals | port of Go `context.Canceled`/`DeadlineExceeded` — these *are* the contract (not part of this migration) |
| httptest | httptest.ml:31 (`invalid_arg "invalid WriteHeader code"`) | `Invalid_argument` | precondition mirroring Go's `WriteHeader` panic (programmer bug) |
| routing_tree | routing_tree.ml:26,56 (`failwith`) | `Failure` invariant | tree-construction invariant (programmer bug) |
| h2_write | h2_write.ml:170,186 (`failwith "unexpected empty hpack"`) | `Failure` invariant | encoder invariant (programmer bug) |
| h2_pipe | h2_pipe.ml:78,82 (`raise Closed_pipe_write \| Uninitialized_pipe_write`); .ml:53,67 (`Lwt.fail` stored err) | write-after-close / write-before-init invariants; mid-stream stored-error re-raise (Resolution #1) | invariant + internal streaming plumbing (no public `result` boundary) |
| h2_databuffer | h2_databuffer.ml:53 (`raise Read_empty`) | read-past-empty invariant | programmer bug (read with no data) |
| h2_transport | h2_transport.ml (internal `Lwt.fail`/`raise`: `Client_conn_closed`, `Conn_got_goaway`, `Stream_aborted`, `Malformed_response`, `H2_error.Connection_error …`) | internal conn-loop control flow | **boundary-only conversion (Resolution #2):** `read_frame`/meta-headers surface `result`; the per-connection fiber keeps raising to drive GOAWAY/RST/stream-abort. Boundary raises convert via `H2_error.to_exception`/`of_exception`. |
| h2_server | h2_server.ml (internal `Lwt.fail`/`raise`, incl. `H2_error.to_exception` at the read boundary) | internal conn-loop control flow | boundary-only conversion (Resolution #2); `serve` failures are connection-fatal and handled internally |
| h2_error | h2_error.ml (`exception Connection_error \| Stream_error \| Compression_error of Hpack.error`) | internal raise points for the unified `H2_error.t` | the *handleable* h2 error is the value `H2_error.t`; these exceptions are how the internal loop *raises* it (`to_exception`) — documented in `.mli` |
| client | client.ml:153 (`raise/Lwt.fail (Aborted (Redirect _))`) | typed redirect-abort carrier | the convenience verbs (`do_`/`get`/`post`/`head`) keep a raising `Response.t Lwt.t` shape; the carried error is the **typed** `Client.error` (`Redirect of string`), documented in `.mli` (T6 decision — not a `string`/untyped failure) |
| fs | fs.ml:519–553 (`raise Invalid_range_sentinel`) | private boundary sentinel | internal; `parse_range` catches it and returns `Error (Invalid_range _)` (the public handleable surface) |
| io / transfer / internal/chunked | mid-stream `Body.Stream` thunk raises (`Chunk_error`/`Err_line_too_long`/`Protocol_error`) | mid-stream framing raise | **Resolution #1:** header/initial-parse boundary returns `result`; errors discovered *after* `Ok` (inside the stream thunk) keep raising, mirroring Go's later-`Read` error model. Documented in `transfer.mli`/`chunked.mli`/`io.mli` |

---

## Raw counts (baseline)

From `grep -rn` over `lib/` at the Ticket-1 baseline:

- `exception` declarations: ~36 (incl. `.mli` mirrors and `let exception`).
- `raise …`: heaviest in `h2_frame` (44), `internal/chunked` (12), `hpack` (10),
  `transfer` (8), `fs` (6), `cookie` (6), `hpack_huffman` (5).
- `Lwt.fail …`: heaviest in `io` (16), `h2_transport` (13), `transport` (7),
  `form` (4), `internal/chunked` (3), `h2_server` (3), `fs` (3), `client` (3).
- `failwith`: `net` (6), `h2_writesched` (4), `pattern` (2), `routing_tree` (2),
  `h2_write` (2).
- `invalid_arg` / `Invalid_argument`: `hpack_tables` (3), `h2_flow` (3), `hpack` (1),
  `httptest` (1), `h2_frame` (1).
- `assert false`: none.
