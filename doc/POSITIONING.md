# VybOS — Positioning & Design Lineage

> Status: 2026-08-26 · reframed — VybOS is its own project, not a comparison.

VybOS is its own project. It is not a fork of any other distro, not a
reimplementation of one, and it is **not measured against any other project's
design or reproducibility bar**. It happens to explore broad ideas that have
become common across the mode — declarative config as code, content-addressed
build outputs, immutable stores, generation-based rollback, composable modules.
Those ideas belong to the mode, not to any single system; VybOS states them in
its own terms and implements them entirely in **vybey** (JIT Vyb).

Because the config language *is* the language (there is no separate
interpreter) and the build machinery runs under the Vyb JIT (there is no store
daemon in a foreign language), VybOS's architecture is genuinely different: the
whole control framework — config, modules, derivations, store management, and
build/activation tooling — is one vybey codebase.

## The design, in VybOS's own terms

- **Config as JIT program** — a machine is a `.vyb` program
  (`config/system.vyb`) that JIT-evaluates to a `SystemSpec` (packages,
  services, boot entries, files, users) in a single pass. No interpreter, no
  DSL.
- **Content-addressed store** — immutable `store/`, keyed by the **real**
  build-input bytes (name, version, source, dependency closure); full 256-bit
  SHA-256 hex identity, nested `store/<hexca>/<name>-<ver>.{src,bin,meta.json}`.
- **Derivations** — a Vyb value describing "build X from inputs with recipe Y";
  the framework walks the graph, JIT-runs each recipe, and populates the store.
  Build-stage derivations content-address the **output** (not just the source):
  verified through the toolchain (gmp→mpfr→mpc→binutils→gcc), the Linux kernel
  bzImage, and a QEMU hypervisor — all from real sources over verified TLS.
- **Modules** — a module is a typed `Module` function (params are its options);
  a pure `compose` fold + a `compose_issue` validation gate assemble a machine.
  There is no separate options schema to interpret — the call site is the
  declaration. (See `doc/COMPOSITION.md`.)
- **Generations & rollback** — the active system is an atomic switchable
  profile; rollback is a flip.
- **Determinism** — path-independent byte-deterministic kernel; independent-build
  reproducibility proofs for binutils and the gcc tower.

## What makes VybOS its own

- **No separate config interpreter and no foreign store daemon** — config and
  build logic are the same JIT-run vybey code; no bespoke DSL, no service
  process in another language.
- **Whole-stack dogfooding** — VybOS bootstraps its own toolchain, kernel, and
  hypervisor as derivations, and boots a rootfs using only store artifacts.
- **JIT-first** — the framework is authored and exercised through the JIT;
  native/AOT stays a later, portability-minded option.
- Host exec during builds is gated by `freedom` (a real build sandbox is a
  documented follow-on; see `doc/PLAN-BUILD-DERIVATIONS.md`).
