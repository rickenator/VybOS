---
last_edited: 2026-08-23
---

# VybOS — Long-Running Objective

Build a Linux distribution analogous to NixOS whose **entire framework** —
configuration language, module system, derivation/packaging engine, store
management, and build/activation tooling — is **written in JIT Vyb**
(vybey), executed through the Vyb JIT. No separate config interpreter;
the config language is the language.

## Definition of Done (north star, refined over time)

- A system is described entirely by a Vyb program JIT-evaluated to a
  content-addressed, reproducible store (the `/vyb/store` analog of
  `/nix/store`).
- An atomic generation/rollback model: switching the active system is a
  reversible symlink/profile flip, as in NixOS.
- A declarative module system for services/options composed in vybey with
  Vyb's type safety.
- All build/derivation logic lives in Vyb and runs under the JIT (native/AOT
  is a later portability option, not the default path).
- The full framework is demonstrable end-to-end: one hello-world config in
  `config/`, reproducible store output, and a first boot target (QEMU image or
  container rootfs).

## Non-Goals / Boundaries

- Not a rewrite of the Linux kernel or userspace; those stay upstream.
- Not a fork of the Vyb compiler; that repo stays the implementation agent's.
- The store's exact filesystem layout/name is unresolved until the derivation
  work begins (avoid churn).

## Current Milestone

**M0 — Bootstrap + config-as-program proof (done 2026-08-23)**: repo
scaffolded; a minimal `SystemSpec` (modules/vybos.vyb) JIT-evaluated by
config/system.vyb to a concrete spec.

**M1 — First real derivation (done 2026-08-23)**: real HTTP fetch → hash the
ACTUAL source bytes (content address) → materialize into `store/` →
reproducible store paths. Store layout settled in `doc/STORE-LAYOUT.md`.
Realised via `build/build-store.vyb` using the `http_get_full` client.

**M2 (done 2026-08-24)**: real dependency graph → materialize a transitive
closure with `.drv`-style metadata, a generation store with rollback, and real
package source-tree realization from a gzipped POSIX tar.

- **Closure realizer** `build/build-closure.vyb` (graph framework in
  `modules/plan.vyb`): topological resolve → closure-aware store identities →
  fetch in dep order → `.meta.json`. Reproducible; transitive-bump verified.
- **Generations** `build/generations.vyb`: append-only `index.json` ledger,
  per-generation spec + reachable-paths set, ancestor-chain rollback validity.
  All invariants pass.
- **Source-tree realization** `build/build-package.vyb` via the stdlib
  `archive` module (gzip inflate + POSIX tar extract, byte-verified): members
  content-addressed by real bytes into the flat store + tree manifest.

Remaining M2 pieces: nested store (needs the `mkdir` RFE; the tree realizer
flattens member paths for now), and URL→(host,port,path) parsing so
`build/build-package.vyb` can point at `https_get_full` bytes instead of a
local tar.gz. A Vyb compiler regression hit mid-M2 (uncommitted deep-copy
edits double-freed the graph code) — escalated as `rickenator/Vyb#184`, fixed
upstream (`7a4b4a8`), toolchain rebound here, all slices re-verified. Blockers
listed in `doc/STORE-LAYOUT.md` → `doc/NIXOS-BORROWINGS.md`.
