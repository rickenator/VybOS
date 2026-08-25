# VybOS Architecture Assessment (vybey, grounded in the real compiler)

> Status: draft · 2026-08-23 · every syntax claim below is either a
> `build/vyb` run or a direct quote from the Vyb `PROGRAMMERS_GUIDE.md`.
> Where a sketch is illustrative rather than run, it is labelled `[sketch]`.
> Follow-up RFEs live in `doc/RFE-M2.md`.

This document (1) evaluates and cleans the earlier ChatGPT-proposed concept and
(2) lays out a Vyb-native architecture for "the OS build is specified in Vyb".
It supersedes the pseudo-Vyb in that proposal. The existing M0/M1 core —
a machine declaration JIT-evaluates to a `SystemSpec`
(`config/system.vyb` → `modules/vybos.vyb`) — is the correct seed and is kept;
this document extends it toward dependencies, plans, generations, and AI/MCP.

---

## Part A — evaluation of the proposal (what stands, what is corrected)

### A.1 What stands verbatim

- **Config is Vyb code, not a separate DSL.** VybOS already does this
  (`config/system.vyb` returns a `SystemSpec`). No bespoke `vyb-os` DSL.
- **Desired state ≠ mutation.** Evaluation constructs a value; a separate
  realizer mutates the system.
- **Dependencies are a first-class graph**, not a flat list.
- **Plans, generations, rollback, GC-reachability** as first-class structured
  values.
- **Deterministic, side-effect-constrained config evaluation.**
- **AI talks to deterministic tooling** (an MCP surface over structured data),
  not to prose.
- **Incremental, bootstrappable** roadmap toward Vyb-native userspace (gzip →
  tar → fs → init), without gating VybOS on rewriting all Unix tools.
- **Secrets are references, not plaintext** in the config.

### A.2 What the proposal got wrong or over-assumed (corrected here)

1. **`main() -> System` does not cleanly return a value in Vyb.** Empirically,
   `main()<Spec> -> { return Spec {...} }` prints a *positional array* and
   renders a `Vec` field as `null` (matches known main-serialization bugs
   #169/#170). The reliable machine contract is an explicit
   `spec.to_string()` (clean JSON, lossless through `T::from_string`), with
   `main()<Int>` emitting it. The proposal's "return the root" assumption is
   discarded; "serialize the root" is kept.
2. **No `instance`/`object`/`constructor`/`trait` terms.** Vyb's actual words:
   **struct** (`struct X { f<T> }`, `X { f = v }`), **aspect + bind** (data is
   dumb, behavior is bound), **enum** (tagged-union data enums), **`our`/`my`/
   `their`/`mild`** ownership. The proposal's instinct to "inspect before
   assuming" was correct — those are the real terms.
3. **Enums are not (yet) struct-field types.** A nominal enum cannot currently
   sit in a struct field (verified: `Unknown type identifier` / `unsized`).
   The dependency/service model therefore uses `String` classifiers enforced by
   `select` set-patterns, and enum-in-struct is logged as a language RFE.
4. **Nested in-place mutation is a no-op.** `spec.pkgs.get(0).deps.push(d)` mutates
   a copy. Config authors must build structure bottom-up. The proposal's fluent
   "populate the graph in place" sketch would silently lose data; corrected
   below.
5. **`File?` io, not raw `fd == -1`.** Absence is the failure. Already how
   `modules/vybos.vyb` writes.
6. **No `mkdir`/SHA-256 yet.** Already an RFE (`doc/RFE-M2.md`). The store is
   flat + FNV stand-in for now; nested layout and a real digest wait on the
   runtime.
7. **Markdown as strictly canonical executable source is the riskiest idea.**
   Vyb compiles whole `.vyb` modules; it has no Markdown parser. Making a
   Markdown file the *only* executable source either (a) reintroduces a
   text-extraction build step (a mini-DSL — the thing we are avoiding) or
   (b) splits truth. VybOS's resolution: the **executable config is a real
   `.vyb` module** (as in M0/M1); `/etc/vyb-os.md` is the canonical
   **human/AI documentation + review surface** whose fenced `vyb` blocks are
   the config and are mechanically (deterministically) extracted into the
   module — prose is never executable. Full line-mapped diagnostics from `.md`
   to `.vyb` is a liftable tool, not a language feature, and is deferred
   (Phase 3).

### A.3 Explicit non-goals that stay non-goals

New kernel, replacing systemd/bootloader, container orchestration,
distributed package caches, and full stateful-database rollback are all out of
scope for the first implementation. A Vyb service manager / PID 1 is a late,
optional phase, not a prerequisite.

---

## Part B — grounded architecture

### 1. Relevant existing Vyb capabilities (verified)

| Capability | Real Vyb shape | Matches a VybOS need |
|---|---|---|
| Structs (data) | `struct Pkg { name<String>, deps<Vec<Dep>> }`, `Pkg { name = … }` | Desired state graph, packages, plans, generations |
| Aspects + binds (behavior) | `aspect Drv { build(self)<Drv?> -> {} }`, `bind Drv -> Pkg { … }` | Attach `realize`/`validate`/`diff`/`serialize` behavior to config structs without stuffing methods everywhere |
| Data enums (values) | `enum Shape { Circle(Float), Unit }`, `match`/`select` | Option/none discriminators; **not yet usable as struct fields** (RFE) |
| `select` (expression matching) | `select(k) -> { {“build”} -> …, ? -> … }` set patterns, comparison patterns | Checked classification of dependency kinds, service states, plan actions |
| Optionals `T?` | `File?`, `Package?`, `else`, `match (x) { v -> …, ? -> … }` | Absence-as-failure across io/http/process |
| Errors | `fail` (statement), `trap (e<T>)`, `ensure`, `refail`; `IoError`/`ProcError`/`HttpError` | Failure semantics for fetch/build/activation |
| Ownership | `my`/`our`/`their`/`mild`, `view`/`borrow`, strong owns-free | Store values as `our<T>`; avoid `their`-reborrow (known gap) |
| JSON serialization | `value.to_string()` → JSON; `T::from_string(json)` lossless round-trip (Vec/struct/String/map/data-enum) | Canonical machine form for generations, diffing, MCP; store metadata |
| Modules/imports | `share(all)`, `import vybos::{A, f}` | Framework decomposition |
| Collections | `Vec` (push/get/set/map/filter/reduce/sort/find), `HashMap`, `HashSet`, `BTreeMap` | Package index, closure sets, store DB |
| Filesystem `io` | `open`/`read_all`/`write_str`/`close` → `File?`/`String?`/`Int?`/`Bool?`; `FileFlag` | Materializing store objects (no `mkdir` yet — RFE) |
| Process | `freedom { exec_run(cmd) }` / `exec_output`; `exec_status()` | Running external build tools (compat path; never the core) |
| HTTP(S) | `http_get_full`/`https_get_full[_verified]` → `HttpResponse?` | Fetching sources (verified TLS available) |
| Archive (native) | `stdlib/archive`: gzip inflate + tar extract (from this session) | Native decompression; extracting needs fs `mkdir` (RFE) |
| Env | `env_get`/`env_set`/`env_unset` | Build environment, secrets references |
| Async | `async`/`await`, `Future<T>`, fiber pool | Parallel fetches/builds (later) |
| `main()<Int>` entry | emits via `println`/`print` | CLI runner exit code |
| FNV + `hash_chars` | deterministic Int hashing | M1 store stand-in until SHA-256 (RFE) |

`stdlib/process`, `stdlib/env`, `stdlib/https`, `stdlib/archive`, and JSON
round-trip are all confirmed present and running on `build/vyb`.

### 2. Missing capabilities (categorized)

- **Vyb library (do in VybOS, now):**
  - Dependency resolver (closure/topological order/cycle detect) — pure Vyb.
  - Planner/diff (current vs desired) — pure Vyb.
  - Generation store + rollback bookkeeping (symlink/profile semantics) — pure
    Vyb; the actual atomic symlink swap needs one runtime fs call.
  - Markdown extractor (fenced `vyb` blocks → module + sidecar index) — io +
    string.
  - Tarball **extraction to a directory** (have inflate+parse; need mkdir).
- **Runtime support (RFE to the Vyb implementation agent):**
  - `mkdir` / recursive `mkdir -p` (blocks nested store + unpack). — RFE-M2 #1.
  - Real digest (SHA-256, hex) in stdlib. — RFE-M2 #2.
  - URL→(host,port,path) parsing for multi-segment `https://tarball` sources. — RFE-M2 #4.
  - `read_dir`/`stat`/`symlink`/`rename` for store & activation.
- **Compiler/language work:**
  - Enum as a struct-field type (sized tagged union in a struct) for nominal
    dependency kinds. (Verified missing.)
  - Possibly a canonical `T::from_string` for enums once embeddable.
- **OS-specific (VybOS only, later):**
  - initramfs generation, boot entry management, service reconciliation.

### 3. Proposed data model (real Vyb, verified constructs)

```vyb
// modules/plan.vyb — the VybOS panel of types (the actual prototype module).
// Data only; behavior attached via binds (Part B §autonomy).

struct Dep { name<String>, kind<String> }     // kind ∈ {build, runtime, host}
struct Pkg {
    name<String>,
    version<String>,
    source<String>,
    deps<Vec<Dep>>,
    storePath<String>
}
struct Service { name<String>, command<String>, enabled<Bool> }
struct SystemSpec {
    system<String>,            // "x86_64-linux"
    hostname<String>,
    pkgs<Vec<Pkg>>,
    services<Vec<Service>>
}

// validated classification of a dep edge (select set-patterns, checked)
classify(k<String>)<String> -> {
    return select(k) -> {
        {"build"}   -> "build-input",
        {"runtime"} -> "runtime-lib",
        {"host"}    -> "host-tool",
        ?           -> "invalid"
    }
}

struct ActionResult { name<String>, action<String> }   // "install"|"upgrade"|…
struct Plan {
    install<Vec<Pkg>>,          // not present in current
    remove<Vec<String>>,        // present in current, absent in desired
    rebuild<Vec<String>>,       // present both, but closure/inputs changed
    order<Vec<String>>,         // topological install order
    requiresReboot<Bool>,
    warnings<Vec<String>>
}
struct Generation { id<Int>, parent<Int?>, spec<SystemSpec>, hash<String> }

// store identity: pure function of (name, version, source, dep-closure)
share(all)
realize_hash(name<String>, version<String>, source<String>, closure<String>)<Int> -> { …FNV… }
```

**Canonical discovery from the probes:**
- Build graphs **bottom-up** in locals, then assign (nested in-place mutation
  copies and is dropped).
- `Plan`/`Generation`/`SystemSpec` all round-trip through `to_string()` /
  `from_string()` — that one call is the entire local "store metadata" and MCP
  wire format.

### 4. Configuration entrypoint

Use `main()<Int>` as the entry, and **emit `spec.to_string()`** (validated JSON)
at the end — or route through whichever of `list|dump|plan|apply|diff` subcommand
the runner dispatches on `argv`. Do **not** return the struct from `main`
(its auto-serialization is a positional array with `null` Vecs).

```
/run/vyb-os (the config program)   # generated/module boundary
    └─ main()<Int>:
         spec<SystemSpec> = assemble()          # build the desired-state value
         h<Int>           = realize_hash(...)   # the generation identity
         plan<Plan>       = plan(current, spec) # no side effects
         println(plan.to_string())              # machine-readable plan
         if apply: realizer runs plan; else: dry-run
```

`assemble()` is the user-authored part (like today's `config/system.vyb`),
`plan`/`realize`/`validate` come from the framework. This keeps config,
evaluation, and mutation cleanly separated, and every stage speaks JSON.

### 5. Markdown embedding design

- `/etc/vyb-os.md` is the human/AI surface: prose (non-executable) + fenced
  ```` ```vyb ```` blocks that *are* the config fragments.
- A deterministic extractor (we write it in Vyb) walks headings, concatenates
  the fenced `vyb` blocks **in document order** into a generated module body
  wrapped in `import … + main()<Int>`, and emits a **sidecar index**
  `{ block # → source.md line range → generated .vyb line range }`.
- Diagnostics from the compiler (which reports `.vyb` line numbers) are
  mapped back to `.md` via the sidecar — that is our own tool, not a language
  feature (Phase 3).
- The realization hash is over the **generated Vyb semantic value**, never the
  Markdown prose, so "prose-only edit ⇒ no system change" is guaranteed by
  construction (tested as an invariant).
- AI edits target fenced blocks + headings by section identity; structural
  editing preserves prose (Phase 3/4).

### 6. Dependency / resolution model

- Edges are typed `Dep { name, kind<String> }`, with `kind` validated by the
  `select` set-pattern classifier (compile-checked exhaustive today; nominal
  enums once embeddable).
- Resolver produces the **transitive closure** in **topological** (dependency-before-
  dependent) order and flags **cycles** (a `fail`/`trap` boundary, never a
  silent hang).
- A package's store identity hashes (`name, version, source, sorted dep
  closure`) so:
  - an unrelated package change leaves others' paths stable (invariant test);
  - a transitive change bumps only the affected closure (invariant test).
- Services/mounts/boot reuse the same `Dep` edge shape (a service depends on
  packages; a mount depends on a device) via a common `Dep` node.

### 7. Store / generation model

Mirrors `doc/STORE-LAYOUT.md` (flat, FNV stand-in today; nested + SHA-256 once
`mkdir`/digest RFEs land), extended:

```
/vyb/store/<hash>-<name>-<version>/            # once mkdir lands (nested)
/vyb/store/…/.meta.json                        # inputs+dep closure (a .drv analogue)
/vyb/generations/<n>/spec.json                 # serialized Generation
/vyb/generations/<n>/store-paths.json          # reachability set (GC roots)
/vyb/current -> generations/<n>                # atomic symlink switch
/vyb/var/profiles/<n>/…                        # rollback chain (parent links)
```

- **Generation** = `{ id, parent, spec, hash }`, serializable, human/AI
  viewable.
- **Realization identity** = pure function of inputs (above); dedupe + cache by
  path.
- **Rollback** = pick a parent in the chain, re-point `current`. OS config
  rollback (paths/config) is separated from mutable app data (databases) —
  we never claim database rollback.
- **GC roots** = reachable generations; store objects not reachable from any
  generation are collectable.
- Same `spec.json`/`store-paths.json` JSON doubles as the MCP `get_generation`
  / `diff` payload.

### 8. Activation model

`vyb system apply`:

1. evaluate config → `SystemSpec`
2. validate (structural + `select`-checked kinds + resolve closure)
3. plan(current, desired) — pure
4. realize missing store paths (fetch→hash→write; external tools gated behind
   `freedom { exec_run }` compat)
5. build candidate Generation + write `spec.json`
6. validate candidate (run diagnostics; a failed build ⇒ abort, current
   untouched)
7. swap `current` symlink atomically (needs one runtime `rename` — RFE)
8. leave prior generation in the rollback chain

Failure semantics are explicit: fetch/build failure aborts before step 7; a
failed candidate never becomes `current` (invariant test); activation is
"rename-swap" not in-place mutation wherever Linux allows.

### 9. MCP model

MCP is a thin adapter over the deterministic JSON surface — it never evaluates
prose and never shells out ad hoc. Initial tools (structured JSON in/out via
`to_string`/`from_string`):

- `vybos.get_config` → current `SystemSpec` JSON
- `vybos.validate` → errors/warnings
- `vybos.plan` → `Plan` JSON (dry-run; no mutation)
- `vybos.diff` → JSON (two generations/specs)
- `vybos.apply` / `vybos.rollback [<gen>]`
- `vybos.generations` / `vybos.search_packages` / `vybos.package_info`
- secrets returned only when explicitly authorized

One serialization is the source for CLI, tests, MCP, and logging — no separate
diff/plan/MCP logic (the proposal's "one Plan representation" requirement is
met by construction).

### 10. Implementation phases (proposal re-ordered to repo realities)

- **Phase 0 — panel + prototype (this PR).** `Dep`/`Pkg`+deps/`SystemSpec`/
  `Classify`/`Plan`/`Generation` + resolver(closure/order/cycle) + planner +
  config A→B demo, all pure Vyb, self-tested. **This repo, now.**
- **Phase 1 — local package store.** Realization hashing of inputs+closure,
  `.meta.json`, incremental builds, generation files. Needs `mkdir`/SHA-256
  (RFE-M2 #1/#2) or keeps the flat/FNV stand-in until then.
- **Phase 2 — system activation.** Store → generation symlink swap, generated
  config files, service reconciliation, rollback. Needs fs `rename` (RFE).
- **Phase 3 — Markdown + MCP.** Canonical `/etc/vyb-os.md` + deterministic
  extractor + sidecar diagnostics; MCP adapter over the JSON surface.
- **Phase 4 — Vyb-native system pieces.** tar-exact unpack, native file/network
  tools where they pay off (gzip already native here).
- **Phase 5 — deeper VybOS runtime (optional).** Vyb service manager / PID 1,
  deeper boot integration.

---

## Anchoring invariants (test coverage for the prototype + later)

1. same inputs ⇒ same realization identity
2. dependency order is topological
3. cycles are detected
4. an unrelated package change does not rebuild unrelated realizations
5. a transitive dependency change rebuilds exactly the affected closure
6. an invalid config fails before activation
7. a failed realization does not change the current generation
8. generation diff is deterministic
9. rollback selects a valid prior generation
10. GC never removes a reachable realization
11. a Markdown prose-only change does not change the system realization
12. a Vyb config change does change desired state when semantically relevant

---

## Open RFEs to the Vyb implementation agent (tracked separately)

- `mkdir` (with parents) — `doc/RFE-M2.md` #1
- SHA-256 hex digest in stdlib — `doc/RFE-M2.md` #2
- URL → (host, port, path) parsing — `doc/RFE-M2.md` #4
- Enum as a valid struct-field type (+ enum ser/deser in structs)
- `rename`/`symlink`/`read_dir`/`stat` for real activation

---

## §0 Prototype status (verified 2026-08-23)

`build/proto-plan.vyb` + `modules/plan.vyb` are a **running vertical slice** under
`build/vyb`. Command:

```sh
env VYB_STDLIB=/usr/export/rick/Projects/Vyb/stdlib \
    /usr/export/rick/Projects/Vyb/build/vyb build/proto-plan.vyb --module-path modules
```

**Result: 27/27 invariants PASS (exit 0).** Proven on the real compiler:

* Config A→B→C constructed as `SystemSpec` values (packages, typed deps, services).
* Validation: clean configs accepted; **cycle** and **unknown dep** rejected before
  any "activation".
* `resolve()` yields dependency-first topological order (`zlib,gzip,openssl,vyb`);
  `tokidx` confirms deps precede dependents.
* `spec_digest()` is deterministic AND closure-sensitive: gzip 1.0 vs 2.0 differ;
  a `zlib` 1.3→1.4 bump changes the digest; a **hostname-only change does NOT**
  (prose/metadata is not part of identity).
* `plan_lines()` is incremental: A→B installs `openssl`, rebuilds `gzip`,
  keeps `vyb`; B→C transitively rebuilds `gzip`+`openssl`+`zlib`, keeps `vyb`;
  plans are deterministic.
* Generations: `gen1` root, `gen2` parented on `gen1` (rollback target), distinct
  content digests.
* `SystemSpec.to_string()` emits clean nested JSON (the MCP serialization contract).

Design caveats of the current prototype (see doc/VYB-LANGUAGE-NOTES.md): Vyb
ranges are **inclusive of the upper bound** — every loop must use `0..len-1`
with empty-guards, or the extra iteration reads one-past-the-Vec (garbage →
spurious double-frees; the near-miss of this session). A generation references
its system by **content digest** rather than embedding the `SystemSpec` value
(it keeps generation records small and matches the store model); dependency
kind is a validated `String` + `select` set-patterns because **enums are not
yet struct-field types**.

### §0.1 Status addendum (2026-08-24, godzilla)

- The graph framework (`resolve` / `resolve_issue` / `real_of` / `real_table` /
  `spec_digest` / `plan_lines` / `tokidx`) was **promoted from the prototype
  entry into `modules/plan.vyb`** so every build/config program shares one
  audited, `share(all)` implementation (proto-plan still passes 27/27 using
  the module copies — no behavior change).
- **`build/build-closure.vyb`** is a real dependency-closure realizer and a
  Phase-1 step: config → `resolve()` topological order → `real_table()`
  closure-aware identities → fetch in dep-first order → write each source blob
  plus a per-derivation **`<real>-<name>-<ver>.meta.json`** (the `.drv`
  analogue). Verified on `build/vyb`:
  - reproducible across runs (identical closure paths), and
  - a transitive dep bump (zlib 1.3→1.4) changes exactly the affected closure's
    identities (`gzip`/`openssl` paths change while their own `contentHash`
    stays fixed).
  The realizer is still **flat** store (no `mkdir` needed yet); **nested**
  layout awaits RFE-M2 #1. HTTPS/tar/URL parsing remain RFE-M2 #3/#4.

### §0.2 Status addendum (2026-08-24, module composition)

- **Module-composition convention** landed so `modules/*` actually combine
  into a machine, answering the "how modules combine" open item. Framework:
  `modules/compose.vyb` — `Module { pkgs<Vec<Pkg>>, services<Vec<Service>> }`,
  `empty_module()`, pure appenders `with_pkg`/`with_service`, constructors
  `mk_pkg`/`mk_service`/`dep` (store paths content-derived via
  `realize_hash`), `blank_system()`, a pure ordered `compose(base, mods)` fold,
  and a `compose_issue(spec)` validation gate (duplicate pkg / duplicate
  *enabled* service / unknown-dep / cycle via `plan.resolve_issue`).
- Example modules `modules/{sshd,getty,vim}.vyb` demonstrate the convention
  (service+package, service-only, package-only; each behind an `enabled` flag
  that returns the empty module when off — a one-line call-site toggle).
- `config/system.vyb` now assembles the machine by folding those modules;
  `build/build-compose.vyb` is a 15-invariant self-test, all PASS on
  `build/vyb`. Design rationale in `doc/COMPOSITION.md`.
- This is the NixOS `options`/`config` idea in vybey minus the interpreter: a
  module is a typed function, its parameters ARE its options, so there is no
  options schema to interpret — composition is a fold over typed
  contributions, and `compose_issue` is the checked validation gate a realizer
  runs before any side effect.
