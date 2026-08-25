---
last_edited: 2026-08-23
---

# VybOS

## Goal

A Linux distribution in the spirit of NixOS — declarative, reproducible,
content-addressed system configuration — but with the **entire framework written
in JIT Vyb** instead of Nix.

The core idea: a system is not described to an interpreter, it is a **Vyb
program** that the Vyb JIT compiles and runs to produce the machine's
derivation graph, activation scripts, and immutable store. There is no separate
configuration language and no store daemon in a foreign language — the config
language *is* vybey, executed through the same JIT that runs the compiler's own
runtime. Configuration, packaging, and build logic are all vybish.

## Status

**M0 + M1 done (2026-08-23).** Config-as-program plumbing proven: a machine
declaration (`config/system.vyb`) imports the framework (`modules/vybos.vyb`)
and JIT-evaluates to a `SystemSpec`. **M1** adds real realisation:
`build/build-store.vyb` does a real HTTP fetch, hashes the **actual** source
bytes (content-address), materializes them into `store/`, and prints stable
store paths — verified **reproducible across runs**. A real boot/system image
is not built yet.

**M2 done (2026-08-24).** Dependency graph → real materialization of a
transitive **closure** with `.drv`-style metadata, a **generation store with
rollback**, and **real package source-tree realization** via the stdlib
`archive` module (gzip inflate + POSIX tar extraction, byte-verified). All run
under `build/vyb` with reproducible store paths.

- **`build/build-closure.vyb`** — walks a typed dependency graph in
  topological order, fetches each source, writes a source blob + per-derivation
  `.meta.json` (name/version/source, real content hash, closure-aware store
  identity, input closure w/ paths). Reproducible; a transitive dep bump
  changes exactly the affected closure's store paths.
- **`build/generations.vyb`** — generation store + rollback bookkeeping
  (pure Vyb, offline): an append-only `index.json` ledger (`cur=` + one
  `id|parent|digest` row per generation), a serialized `SystemSpec` and its
  reachable store-path set per generation, and an ancestor-chain rollback
  validity check. All invariants verified.
- **`build/build-package.vyb`** — realises a package **source tree** from a
  gzipped POSIX tar using the stdlib `archive` module: extracts members,
  content-addresses each by its real inflated bytes, writes them into the flat
  store, plus a `.meta.json` tree manifest. Every member verified
  byte-identical to its true source. Deterministic + content-addressed
  (a member change → new addresses).

A **compiler regression** (uncommitted in-flight deep-copy/ownership edits
double-freed on the graph code during this session) was escalated as
`rickenator/Vyb#184` and fixed upstream (`7a4b4a8`); this repo's M2 slices all
re-verified after rebounding the toolchain to the fixed commit.

Also see `doc/NIXOS-BORROWINGS.md`, `doc/VYB-LANGUAGE-NOTES.md`, and
`doc/STORE-LAYOUT.md`.

## Conceptual Shape

- **Config as JIT program** — a machine's declaration is a `.vyb` program
  (`system.vyb`) that runs under `vyb --jit` and returns a `SystemSpec`
  (packages, services, boot entries, files, users, …) in a single pass.
- **Content-addressed store** — analogous to `/nix/store`, an immutable store
  keyed by hash of build inputs (name, version, source, dependency closure).
  This repo calls it the **store** (`/vyb/store` on a built system); exact
  layout is TBD.
- **Derivations** — Vyb value describing "build X from inputs with recipe Y".
  The framework walks the derivation graph, JIT-runs each build recipe, and
  populates the store.
- **Generations & rollback** — like NixOS, the active system is an atomic
  switchable profile (a symlink generation) so rollback is instant.
- **Modules** — declarative system services/options composed in Vyb, mirroring
  NixOS module composition but with Vyb's own type safety, `select` expressions,
  and ownership model.
- **JIT-first** — the framework is authored and exercised via the JIT for fast
  iteration; native/AOT compilation stays a later, portability-minded option.

## How To Run

Paths below are godzilla-relative (`~/Projects`). On apex the compiler repo
lives at `/usr/export/rick/Projects/Vyb` instead.

```sh
# Prerequisite: Vyb compiler JIT binary
#   ~/Projects/Vyb  →  cmake --build build  →  build/vyb

# M0 — JIT-evaluate the machine declaration through the framework:
cd ~/Projects/VybOS
VYB_STDLIB=/home/rick/Projects/Vyb/stdlib \
  /home/rick/Projects/Vyb/build/vyb config/system.vyb --module-path modules

# M1 — realise derivations: real fetch -> content-addressed store (needs network):
mkdir -p store   # store/ is gitignored (build cache)
VYB_STDLIB=/home/rick/Projects/Vyb/stdlib \
  /home/rick/Projects/Vyb/build/vyb build/build-store.vyb --module-path modules

# M2 step — realise a real dependency CLOSURE with .drv-style .meta.json:
VYB_STDLIB=/home/rick/Projects/Vyb/stdlib \
  /home/rick/Projects/Vyb/build/vyb build/build-closure.vyb --module-path modules

# M2 — generation store + rollback bookkeeping (pure Vyb, offline):
mkdir -p generations   # runtime state (gitignored)
VYB_STDLIB=/home/rick/Projects/Vyb/stdlib \
  /home/rick/Projects/Vyb/build/vyb build/generations.vyb --module-path modules

# M2 — real package source-tree realization (archive inflate + tar extract):
bash build/samples/make_samples.sh      # build the deterministic source tar.gz
VYB_STDLIB=/home/rick/Projects/Vyb/stdlib \
  /home/rick/Projects/Vyb/build/vyb build/build-package.vyb --module-path modules
```

## Source Of Truth

- Primary docs: this `README.md`, `GOAL.md`, `AGENTS.md`, `doc/`
- Vyb compiler: `/usr/export/rick/Projects/Vyb` (lang refs in its
  `docs/refman/PROGRAMMERS_GUIDE.md`)
- Data sources: none yet
- Related projects: NixOS / Nix (the conceptual reference), Vyb (the language)

## Next Steps

- [x] M0: `SystemSpec` + `system.vyb` JIT-evaluating to a concrete spec.
- [x] M1: store layout decision + first real derivation (fetch → hash → store file).
- [x] M2: real dependency-closure materialization + `.drv`-style metadata (`build/build-closure.vyb`).
- [x] M2: generation store + rollback bookkeeping (`build/generations.vyb`).
- [x] M2: real package **source-tree** realization via stdlib `archive` (`build/build-package.vyb`).
- [~] M2: nested store still waits on the runtime gaining `mkdir` (RFE-M2 #1); the tree realizer flattens member paths into the flat store for now.
- [x] Real crypto digest / HTTPS-fetch gaps scoped — `doc/RFE-M2.md` (mkdir, SHA-256, tarball, URL parser) drafted for the Vyb implementation agent; gzip+tar **extraction** landed in the stdlib `archive` module; HTTPS itself already works.
- [ ] URL→(host,port,path) parsing in stdlib (Item 4 of `doc/RFE-M2.md`); when landed, point `build/build-package.vyb` at `https_get_full` bytes instead of a local tar.gz.
- [x] Generations/profiles + rollback bookkeeping (atomic symlink switch still awaits the `rename`/`symlink` RFE — current pointer is a file rewrite).
- [ ] Define the module composition convention (how `modules/*` combine).
- [ ] Pick a boot target: kernel + initramfs on QEMU vs. a container rootfs first.
- [x] Init GitHub repo (remote configured: `rickenator/VybOS`). Local commits (incl. M2) await push approval; Vyb toolchain regression escalated & fixed as `rickenator/Vyb#184`.

## Notes

- Scoped to "framework written in JIT Vyb" — kernel/userspace can stay
  upstream/Linux; the distinguishing work is the vybey build+config system.
- Follow Vyb terminology: **vybey** = the language, **vybish** = its style.
- Store layout is settled for M1 in `doc/STORE-LAYOUT.md` (repo-local `store/`,
  flat, FNV stand-in over real bytes; `/vyb/store` on-target).
