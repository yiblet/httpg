# Module rewrite pattern (parallel-module migration)

How we rewrite a module in place without ever leaving the build red. Used for the
`Status` rewrite (untyped `int` status codes → a typed `Status.t` variant).

## The three steps

1. **Create a new module with the v2 code, alongside the old one.** Give it a
   temporary distinct name (e.g. `Status2`) so the old module keeps compiling.
   The new module carries the richer/target design from day one.
2. **Replace uses of the old module with the new one, one site at a time.**
   Migrate every consumer to the new module and its types. The old and new
   modules coexist while this happens, so the build stays green throughout.
3. **Delete the old module.** Once nothing references it, remove the old files
   and rename the new module into the old one's name (`Status2` → `Status`),
   sweeping the references in one mechanical pass.

The final rename is a pure search-and-replace with no semantic change.

**The build does not have to stay green at every step, and that is okay.** The
parallel-module structure makes a green-throughout migration *possible*, but in
practice the intermediate states are often red — e.g. a partial sed pass leaves
mismatched `.ml`/`.mli` signatures, or step 2 is committed half-finished. That
is a fine place to stop and hand off; the next pass just drives the type errors
to zero. Don't contort the work to keep every commit compiling — let the
compiler's error list be the worklist.

## Philosophy: maximally well-type the code

The point of the rewrite is usually to make illegal states unrepresentable, so:

- **Move all internal uses onto the new, richer type** — don't keep the weak
  type internally and only expose the strong one at the edges. The typed value
  is the one that flows through the program.
- **Push conversions to the boundaries.** Where the wire/format genuinely needs
  the underlying representation (e.g. formatting a status line, comparing a
  numeric range), convert there (`Status.to_int`, `Status.of_int_result`) rather
  than threading the weak type inward.
- **Make the public signatures speak the strong type.** `.mli` files, record
  fields, and function parameters take `Status.t`, not `int`. Tests then convert
  at the assertion site (`check int 200 (Status.to_int code)`), which keeps the
  ported Go test readable while exercising the typed path.

## Worked example: `Status`

- v2 module `Status2` defined `type t = Continue | Ok | NotFound | … | Custom of
  int`, with `to_int`, `of_int_result`, `of_string_result`, `to_string`.
- `Response.status_code`, `Transfer.message.status_code`,
  `Server.response_writer.write_header`, `Server.error`/`redirect`/
  `redirect_handler`, and `Api.cres_status_code` all moved to `Status.t`.
- Numeric boundaries (status-line `%03d`, `body_allowed_for_status`'s `1xx`
  range check, the h1↔h2 `Api` shim whose server-side writer stays `int`) call
  `Status.to_int` / `Status.of_int_result` locally.
- The old `int`-constant module was deleted and `Status2` renamed to `Status`.
