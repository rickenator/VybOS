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

**M2 step landed (2026-08-24):** a real dependency-**closure** realizer.
`build/build-closure.vyb` walks a typed dependency graph in topological order,
fetches each source, and writes every derivation as a source blob plus a
per-derivation `.meta.json` (the `.drv` analogue: name/version/source, real
content hash of the fetched bytes, closure-aware store identity, and the
closure of direct inputs with store paths). The graph resolvers/planners were
promoted into `modules/plan.vyb` so every entry program shares one audited
implementation. Verified on `build/vyb`: reproducible across runs, and a
transitive dep bump changes exactly the affected closure's store paths.

Also see `doc/NIXOS-BORROWINGS.md` (the "weird fork / chopsticks" build-idea
map), `doc/VYB-LANGUAGE-NOTES.md` (verified Vyb gotchas), and
`doc/STORE-LAYOUT.md` (store-layout decision + blockers).

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
- [~] M2 store slice (partial): real dependency-graph materialization + per-derivation `.drv`-style `.meta.json` are done in the flat store (`build/build-closure.vyb`); **nested** store still waits on the runtime gaining `mkdir` (RFE-M2 #1).
- [x] Real crypto digest / HTTPS-fetch gaps scoped — drafted `doc/RFE-M2.md` (mkdir, SHA-256, tarball, URL parser) for the Vyb implementation agent; HTTPS itself already landed in stdlib.
- [ ] URL→(host,port,path) parsing in stdlib (Item 4 of `doc/RFE-M2.md`); HTTPS fetch itself already works.
- [ ] Generations/profiles + atomic switch/rollback.
- [ ] Define the module composition convention (how `modules/*` combine).
- [ ] Pick a boot target: kernel + initramfs on QEMU vs. a container rootfs first.
- [ ] Init GitHub repo (no remote yet).

## Notes

- Scoped to "framework written in JIT Vyb" — kernel/userspace can stay
  upstream/Linux; the distinguishing work is the vybey build+config system.
- Follow Vyb terminology: **vybey** = the language, **vybish** = its style.
- Store layout is settled for M1 in `doc/STORE-LAYOUT.md` (repo-local `store/`,
  flat, FNV stand-in over real bytes; `/vyb/store` on-target).
