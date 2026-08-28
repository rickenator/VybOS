# Vyb language notes (verified for VybOS authoring)

Every item below was hit and verified while building VybOS M0 against
`/usr/export/rick/Projects/Vyb` (`build/vyb`, JIT on by default). They are the
sharp edges a VybOS author trips on when writing cross-module vybey. Recheck
against the compiler if a later version claims a fix.

## Module exports: `share(all)` + named imports

- A module exports a name only if that declaration is prefixed with
  `share(all)` (e.g. `share(all) struct Package { ... }`,
  `share(all) derive(...)`, `share(all) content_hash(...)`).
- `import someMod;` alone pulls in **nothing** for the importer — you must
  name the symbols: `import vybos::{SystemSpec, Package, derive, ...}` (and
  `import collections` too for `Vec`/iteration).
- A private helper still needs `share(all)` if a *shared* function's body calls
  it — shared bodies get spliced into the importer's scope and must be able to
  resolve every identifier they reference. (M0: `store_path`/`content_hash`
  were "Undefined identifier" until shared.)
- `core::` contracts (`Iterator` etc.) are auto-imported, but iterating a
  `Vec<T>` imported from another module needed `import collections` in the
  importer.

## Top-level functions: bare names, no `fn`

Top-level functions are declared with a bare name:

```
main()<Int> -> { ... }
factorial(n<Int>)<Int> -> { ... }
```

`fn content_hash(...)` is a **parse error** ("Expected ARROW but found LT"):
`fn` is not used for top-level named functions in a module/entry file.

## Reserved words

- `package` is reserved — a function named `package(...)` silently fails to
  export ("Imported symbol 'package' is not exported"). Renamed to `derive`.
- Check any name you plan to export against the parser's keyword list before
  using it.

## `for (x in structField)` does not resolve the iterator bind

Iterating a member Vec directly fails:

```
for (p in spec.packages) { ... }   // Unknown method 'next' on type 'Vec<Package>'
```

Workaround (verified): copy the member Vec to a local, then iterate the local:

```
our_pkgs<Vec<Package>> = spec.packages
for (p in our_pkgs) { ... }
```

A local `Vec<T>` iterates fine; only the struct-field form breaks.

## `String.char_at(i)` is narrow

`char_at` yields an i8; XOR/arithmetic directly into an i64 variable warns
"Storing i8 into location of type i64" (and can silently narrow). Widen first:

```
c<Int> = tag.char_at(i)   // widen to Int
h = (h * 16777619) ^ c
```

## Integer wrap

i64 multiply can wrap negative (e.g. an FNV hash → negative store path). For
things that must be non-negative, normalize explicitly:

```
if (h < 0) { h = -h }
```

Deterministic across runs; negative values are just ugly in paths.

## Enums are not struct-field types (verified 2026-08-23)

Tagged-union data enums are first-class *values* (local vars, `match`/`select`,
function args): `enum Shape { Circle(Float), Rect(Float, Float), Unit }`,
`r<Shape> = Shape::Circle(2.0)`. But **an enum used as a struct field type fails
to compile** on the current build — both unit (`enum DepKind { Build, Runtime }`)
and payload (`enum KindP { Runtime(Int) }`) forms error with "Unknown type
identifier / Could not determine LLVM type ... unsized" at the field decl. So a
serializable struct cannot carry an enum-typed field yet.

Workaround (verified): store the classifier as a `String` field and enforce
exhaustive, checkable classification with `select` set-patterns on string
literals `{ "build" } -> ...`. `select` is expression-first; enum variants in
`select` arms must be wrapped in a set pattern `{DepKind::Build} -> ...`
(a bare `DepKind::Build -> ...` is a parse error). If a nominal enum in a
struct becomes desirable, that's a language RFE.

## Nested in-place mutation through an accessor is a no-op (verified)

`sys.pkgs.get(0).deps.push(dep)` silently mutates a **copy** — the stored
element is unchanged. `Vec::get(i)` returns by value, so chained field mutation
does not reach the owned element. Build structure bottom-up in locals, then
assign whole values:

```
deps<Vec<Dep>> = Vec();  deps.push(...)
sys.pkgs.push(Pkg { name = ..., deps = deps })
```

## `main()` returning a struct does NOT emit clean JSON (verified)

`main()<Spec> -> { return Spec {...} }` prints a positional **array**
(`["x86_64-linux", "hera", null]`) and renders a `Vec` field as `null` — not the
`{"field": ...}` object form. Do not rely on `main`'s auto-serialization for
machine output. For clean JSON use the explicit, verified path:
`spec.to_string()` → `{\"name\":\"a\",\"pkgs\":[...]}` (lossless through
`T::from_string`) and have `main()<Int>` emit/print it.

## Ranges are INCLUSIVE of the upper bound — off-by-one trap (verified, #1 gotcha)

`0..b` iterates b+1 values: `for (i in 0..2)` yields `{0,1,2}`, NOT `{0,1}`.
So `for (i in 0..vec.len())` runs **len+1 times and reads `get(len)` — one past
the buffer**. On small vectors that OOB read returns garbage/dangling pointers
and can corrupt ownership metadata → spurious `free(): double free` (exit 134)
and wrong results. Iterate a length-`n` Vec exactly with `0..n-1`, and guard
everything that might be empty (`if (m > 0) { for (k in 0..m-1) ... }`) because
`0..0` still runs once (index 0).

```vyb
n<Int> = v.len()
if (n > 0) { for (i in 0..n-1) { ... } }   // exact, bounds-safe
```

## False alarms: most "compiler crashes" were the inclusive-range off-by-one

During the first prototype pass I hit several `free(): double free` (exit 134),
an LLVM-verifier failure (exit 139), and bizarre "Unknown struct type: Int?"
errors. I initially blamed `while` loops, spliced `share(all)` functions,
`Vec.set`, `if`-expressions, and local `T?` declarations, and worked around
them. **That attribution was wrong.** Every one of those constructs runs
cleanly once loop bounds are corrected — `while`+String accumulation,
`if` in a `print(...)` concat, spliced module helpers with loops, and
optional usage `g.parent == Int?()` all work. The real, single root cause was
the `0..vec.len()` off-by-one: the extra iteration read `get(len)` one past the
buffer, returned garbage/dangling pointers, and corrupted memory ownership and
LLVM IR. Before filing anything as a Vyb bug, **re-check every loop bound**.


## Other verified footguns

Earlier drafts blamed these on the compiler; clearer evidence says treat them
as **unverified/suspect** — re-test with correct loop bounds before filing:

- **Self-recursive `share(all)` functions** *may* expand indefinitely, and
  `Vec.set(i, v)` in-place mutation *may* mis-own — but both were first hit in
  code that also had off-by-one loops, so I no longer trust these attributions.
  Prefer building by `push`/full-value assignment and iterative helpers until
  re-verified.

Confirmed language facts (parse/semantic, independent of bounds):

- **`var` is not a keyword** — declarations are `name<Type> = value`.
- **`pass` is reserved** — cannot name a variable `pass`.
- **`if` alone as an assignment RHS** is a semantic error
  ("could not determine type"); used inside a `print(...)` concat it is fine.
- **`package` is reserved** (VybOS has no `package` keyword).

## Identifiers & expressions (verified 2026-08-28)
- `from` and `bare` are RESERVED words in Vyb — never use them as function or parameter names (`Expected parameter declaration` / `is a reserved word`).
- C-style ternary `cond ? a : b` is NOT supported (`Expected RPAREN but found QUESTION_MARK`) — use a small `Bool -> String` helper instead.
