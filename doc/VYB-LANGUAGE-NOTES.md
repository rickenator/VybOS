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
