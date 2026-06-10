---
name: convert-zero
description: Convert a Go zero-value-as-missing field (a string/int where "" or 0 means "unset") into a properly typed OCaml field using the Httpg_base.Zero module. Use when porting or cleaning up a lib/ module whose record fields mirror Go fields that conflate "absent" with their zero value, or when the user asks to replace ""-means-missing / 0-means-missing sentinels with option types.
---

# convert-zero

## What we're trying to do

Go conflates "absent/unset" with a type's zero value: a `string` field left `""`
reads identically to one explicitly set to `""`, same for `0`/`int`. Ported 1:1
into OCaml that becomes a sentinel — `""` standing in for "missing" — which the
type system can't check and which silently breaks if a real empty value ever
appears. The goal is to **eliminate the zero-as-missing sentinel** so that
"absent" is a distinct, type-enforced state. Concretely, in a module we want to:

- **Remove all-zeros `default` records** that exist only to be `{ default with … }`'d.
  A floating zero record implies "an empty `t` is a valid thing," and it forces
  every construction to start from a pile of `""`/`0` sentinels.
- **Remove reads that test a field against its zero value** (`== ""`, `len > 0`, …)
  to mean "is it set?", replacing them with an explicit presence check.
- **Stop storing `""`/`0` to mean "unset"** — store `None` (or a typed value)
  instead, normalized at the boundaries so the sentinel never re-enters.

The aim is *not* to wrap every field: a field Go only ever uses as a raw value
should stay `string`. Convert only where the zero is overloaded to mean absence.

## Established strategies

Pick per field/module; they compose:

1. **`make` constructor** (replaces a zero `default`): required identity fields are
   non-optional args, attributes are optional. Construction can no longer omit the
   fields that are meaningless when zero. See Step 4.
2. **Typed-optional field** (replaces a `""`/`0` sentinel field): the field becomes
   `string option`/`int option` with `None` = unset, driven through
   `Httpg_base.Zero` (`ZS`/`ZI`) so `""`/`0` normalizes to `None` at the boundary
   and the presence check lives in one place. See Steps 2–3.
3. **Op-table read rewrite**: each Go zero-check idiom maps to exactly one `ZS`
   op (`is_set`/`iter`/`check`/`fold`/`to_zero`), so the translation is mechanical.

This skill replaces the sentinel faithfully and mechanically, using
`Httpg_base.Zero`.

## The Zero module

`Httpg_base.Zero.Make (V)` produces a type that *behaves like* the Go scalar but
makes the zero explicit. `ZS = Httpg_base.Zero.String`, `ZI = Httpg_base.Zero.Int`.
`ZS.t` is **transparently `string option`** (`None` = the zero value), so a public
field can be declared `string option` and the implementation can still call `ZS`
ops on it directly.

Ops (all derived from `of_zero` + `fold`):

| Op | Meaning |
|---|---|
| `zero` | the zero value (`None`) |
| `of_zero : string -> t` | the only constructor; normalizes `"" -> zero` |
| `to_zero : t -> string` | read as the Go base value (`zero -> ""`) |
| `is_zero` / `is_set` | Go `x == ""` / `x != ""` (and `len == 0` / `len > 0`) |
| `equal` / `compare` | agree with Go `==` / ordering |
| `check f` | Go `x != "" && f x` |
| `iter g` | Go `if x != "" { g x }` |
| `map f` / `filter f` | re-normalize the result (never produce `Some ""`) |
| `fold ~set ~zero` | the eliminator: `if x != "" { set x } else zero` |

## Step 1 — decide which fields to convert

Convert a field **only if Go presence-tests it**: `== ""`, `!= ""`, `len(x) == 0`,
`len(x) > 0`. Grep the Go source (`go/src/net/http/<x>.go`) for the field.

Do **not** convert a field that is only ever used as a raw value — passed to a
function, indexed (`x[i]`), or measured for real length. Wrapping those just
smears `to_zero` over every use site for no safety gain. (Example: cookie
`Name`/`Value` are never presence-tested, so they stay `string`; `Path`/`Domain`
are guarded by `len > 0`, so they convert.)

## Step 2 — the public type stays transparent

In the `.mli`, declare the field `string option` (or `int option`), **not**
`ZS.t`. The public API must not leak `Httpg_base.Zero`. Document `None` = the
unset meaning, e.g. `path : string option;  (** [None] = no Path attribute *)`.

## Step 3 — wire the implementation through ZS

In the `.ml`, `module ZS = Httpg_base.Zero.String` and:

- **Construction / parse boundary** — normalize the incoming string with
  `ZS.of_zero` so `""` becomes `None`; `{ r with path = ZS.of_zero v }`.
- **Read sites** — translate each Go idiom via the op-table:

  | Go | OCaml |
  |---|---|
  | `if len(x) > 0 { use(x) }` | `ZS.iter (fun x -> …) r.path` |
  | `if len(x) > 0 && f(x)` | `ZS.check (fun x -> f x) r.path` |
  | `if len(x) > 0 { e1 } else { e2 }` | `ZS.fold ~zero:e2 ~set:(fun x -> e1) r.path` |
  | `match x with Some v when f v -> e1 \| _ -> e2` | `r.path \|> ZS.filter f \|> ZS.fold ~zero:e2 ~set:(fun v -> e1)` |
  | use `x` as a plain string | `ZS.to_zero r.path` |

  Prefer `ZS.fold`/`iter`/`check` over hand-written `match … Some … when … <> ""`
  — `fold` encodes the zero check correctly in one place.

## Step 4 — prefer a `make` constructor over a zero `default`

If the module exposes an all-zeros `default` record used as `{ default with … }`,
replace it with a constructor that forces the required identity fields:

```ocaml
let make ~name ~value ?(quoted = false) ?(path = "") ?(domain = "") … () =
  { name; value; quoted; path = ZS.of_zero path; domain = ZS.of_zero domain; … }
```

- Required fields (the ones that are meaningless when zero) are non-optional.
- Optional attributes are **`?path:string`** (plain string), not `?path:string option`
  — clean call sites (`make ~path:"/" ()`), and `ZS.of_zero` in the body does the
  `"" -> None` normalization. `string option` args would let `Some ""` leak past
  the zero check.
- `.mli` shows `?path:string -> … -> unit -> t`. No `ZS` in the signature.

## Step 5 — migrate the ported tests (they are the spec)

- Rewrite `{ default with … }` fixtures to `make ~… ()`. Watch for record literals
  that were function arguments — `f { default with … }` becomes `f (make … ())`
  (the call needs parens). Beware inline comments and strings containing `;`/`\"`
  when scripting the rewrite.
- Printer: `%S` on the field becomes `Option.value ~default:"" r.path`.
- Equality: `a.path = b.path` works directly on `string option`.
- A ported test that fails is the implementation's fault — fix the code, not the
  test, unless it is a genuine Go-specific porting artifact (call it out).

## Step 6 — close out

`dune build` (warnings are errors) and `dune test` must be green, and
`dune build @fmt` clean (`dune fmt` to apply). Keep the `.mli` in sync. Land the
change as one `jj` commit per converted module, cross-referencing the matching
`go/src/net/http/<x>.go` lines.
