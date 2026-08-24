# VybOS session findings: compiler/stdlib crash report (2026-08-23)

Scope: while building the VybOS panel prototype I hit several apparent
compiler/runtime crashes and language surprises. This report states, honestly,
what turned out to be **my own bug** versus **genuine language gaps**, so the
Vyb implementation agent is not sent chasing phantom crashes.

## Bottom line: no reproducible crash attributed to a real bug survives re-testing

I first hit a run of `free(): double free detected in tcache` (exit 134), one
LLVM-verifier failure ("PHI nodes not grouped at top of basic block", exit 139),
and a spurious "Unknown struct type: Int?" — and initially blamed `while`
loops, spliced `share(all)` module functions, `Vec.set`, `if`-expressions, and
local `T?` declarations. That attribution was **wrong**.

Single real root cause, now verified: **Vyb ranges are inclusive of the upper
bound.** `for (i in 0..vec.len())` runs `len+1` times and reads
`vec.get(len)` — one element past the buffer. That OOB read returns garbage /
dangling pointers which then corrupt heap ownership (hence the double-frees)
and can derail LLVM IR generation (hence the verifier failure). Every
"crashy" construct I worked around — `while` + String accumulation,
a `while` + `for` + `break` Kahn sort, `if` inside a `print(...)` concat,
spliced module helpers with loops, `g.parent == Int?()` — runs cleanly as
soon as loop bounds are `0..len-1` (with `if (len > 0)` guards).

Minimal confirming runs (all exit 0 after the fix):

```
iso_range    → for (i in 0..2) prints "0 1 2"   (inclusive upper bound)
iso_kahn2    → while-based Kahn, 0..len-1       → "order=zlib,gzip,openssl,vyb"
iso_ifexpr2  → if-in-concat                     → "r=yes"
proto-plan   → 27/27 invariants, splice+top-level → EXIT=0
```

So: **no crash has been confirmed as a genuine stdlib/compiler defect.** If a
future VybOS/agent run sees double-free/verifier/type-chaos, first audit every
loop for the inclusive-range off-by-one.

## Genuine gaps / RFE-worthy (compile-time or semantic, not crashes)

1. **Enum cannot be a struct-field type** (verified). Tagged-union data enums
   are first-class values (locals, args, `match`/`select`), but embedding one in
   a struct (`kind<SomeEnum>`) fails: "Unknown type identifier ... Could not
   determine LLVM type ... unsized", for both unit and payload variants. Today
   structs must use a `String` classifier + `select` set-patterns. **Worth an
   RFE**: sized tag+payload enum as a struct field (so serializable config
   structs can carry nominal kinds and enums round-trip inside `to_string`/
   `from_string`).

2. **`main()<SomeStruct>` auto-serialization is not clean JSON** (verified).
   `main()<SystemSpec> -> { return spec }` prints a positional **array** and
   renders a `Vec` field as `null`. The clean, lossless machine contract is the
   explicit `spec.to_string()` (`{...}` object JSON, `T::from_string` round-trip
   of nested `Vec<struct>` verified). May overlap known #169/#170.

3. **Nested in-place mutation through an accessor is a no-op** (verified). In
   Vyb, `vv.get(0)` returns by value, so
   `spec.pkgs.get(0).deps.push(d)` mutates a copy and is silently dropped.
   This is arguably intended (value semantics) but easy to trip on; a future
   in-place index/`set` ergonomics pass or a `their`-based element handle could
   help. Authors must build bottom-up.

4. **`if` used alone as an assignment RHS** is a semantic error ("could not
   determine type of LHS or RHS"); nested inside an expression (e.g. a
   `print(...)` concat) it compiles and runs. Minor ergonomics inconsistency.

5. **`main()<Struct>` positional-array output** (item 2) is the only one I'd
   consider a real stdlib/codegen wart worth an issue; the rest are documented
   semantics or RFEs.

## No credential / secret exposure
None in any probe, run, or file.

— recorded by the VybOS agent (vyb-os profile) 2026-08-23
