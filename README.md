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

**M0 complete (2026-08-23).** The config-as-program plumbing is proven: a
machine declaration (`config/system.vyb`) imports a framework module
(`modules/vybos.vyb`), JIT-evaluates to a `SystemSpec`, and prints a
content-addressed store path for each package. Verified reproducible across
runs. Distro build machinery (real fetch→store→boot) is not built yet.

Also see `doc/NIXOS-BORROWINGS.md` (the build ideas we take from NixOS — "weird
fork / chopsticks") and `doc/VYB-LANGUAGE-NOTES.md` (verified Vyb gotchas for
authors).

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

```sh
# Prerequisite: Vyb compiler JIT binary
#   /usr/export/rick/Projects/Vyb  →  cmake --build build  →  build/vyb

# M0 — JIT-evaluate the machine declaration through the framework:
cd ~/Projects/VybOS
VYB_STDLIB=/usr/export/rick/Projects/Vyb/stdlib \
  /usr/export/rick/Projects/Vyb/build/vyb config/system.vyb --module-path modules
```

## Source Of Truth

- Primary docs: this `README.md`, `GOAL.md`, `AGENTS.md`, `doc/`
- Vyb compiler: `/usr/export/rick/Projects/Vyb` (lang refs in its
  `docs/refman/PROGRAMMERS_GUIDE.md`)
- Data sources: none yet
- Related projects: NixOS / Nix (the conceptual reference), Vyb (the language)

## Next Steps

- [ ] Write a minimal `SystemSpec` type and a `system.vyb` that JIT-evaluates to
      a concrete (even empty) spec, to prove the config-as-program plumbing.
- [ ] Decide store layout and a first trivial derivation (e.g. a fetched source
      → hashed store path).
- [ ] Define the module composition convention (how `modules/*` combine).
- [ ] Pick a boot target: kernel + initramfs image on QEMU as the first real
      boot, vs. a container/Distrobox-style rootfs first.
- [ ] Init GitHub repo + README lives here once the shape firms up.

## Notes

- Scoped to "framework written in JIT Vyb" — kernel/userspace can stay
  upstream/Linux; the distinguishing work is the vybey build+config system.
- Follow Vyb terminology: **vybey** = the language, **vybish** = its style.
- The store name/location (`/vyb/store` vs elsewhere) is deliberately unresolved;
  settle it when the derivation work starts to avoid churn.
