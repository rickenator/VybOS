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
scaffolded; vision written down; a minimal `SystemSpec` (modules/vybos.vyb)
JIT-evaluated by config/system.vyb to deterministic, content-addressed store
paths. Verified reproducible across runs.

**M1 (next)**: real fetching → materialize one derivation into `/vyb/store`
(hash the actual build inputs, not just the declared name/version), and decide
store layout. See `doc/NIXOS-BORROWINGS.md`.
