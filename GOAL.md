---
last_edited: 2026-08-26
---

# VybOS — Long-Running Objective

Build a Linux distribution whose **entire framework** — configuration language,
module system, derivation/packaging engine, store management, and
build/activation tooling — is **written in JIT Vyb** (vybey), executed through
the Vyb JIT. No separate config interpreter; the config language is the
language. VybOS is its own project, on its own terms: it shares the broad
declarative/config-as-code and content-addressing ideas common in the mode, but
it is not a clone and is not judged against anyone else's design or
reproducibility bar.

## Definition of Done (north star, refined over time)

- A system is described entirely by a Vyb program JIT-evaluated to a
  content-addressed, reproducible store (the `/vyb/store` on a built system).
- An atomic generation/rollback model: switching the active system is a
  reversible symlink/profile flip.
- A declarative module system for services/options composed in vybey with Vyb's
  type safety.
- All build/derivation logic lives in Vyb and runs under the JIT (native/AOT is
  a later portability option, not the default path).
- The full framework is demonstrable end-to-end: one hello-world config in
  `config/`, reproducible store output, and a first boot target (QEMU image or
  container rootfs).

## Non-Goals / Boundaries

- Not a rewrite of the Linux kernel or userspace; those stay upstream.
- Not a fork of the Vyb compiler; that repo stays the implementation agent's.
- First boot target **DECIDED (2026-08-25): Option B — container rootfs first**
  (see `doc/PLAN_BOOTABLE_IMAGE.md`); a QEMU kernel+initramfs self-boot is also
  demonstrated (real kernel under a derived boot chain), with a full bootable
  root/disk image + bootloader as the follow-on milestone.

## Current Milestone (2026-08-26)

Full status and handoff detail live in `doc/STATUS.md`; the milestone trail below
records the major landings.

**M0 — Bootstrap + config-as-program proof (done 2026-08-23)**: repo scaffolded;
a minimal `SystemSpec` (modules/vybos.vyb) JIT-evaluated by config/system.vyb to
a concrete spec.

**M1 — First real derivation (done 2026-08-23)**: real HTTP fetch → hash the
ACTUAL source bytes (content address) → materialize into `store/` →
reproducible store paths. Layout in `doc/STORE-LAYOUT.md`; realised via
`build/build-store.vyb` using the `http_get_full` client.

**M2 (done 2026-08-24)**: real dependency graph → materialize a transitive
closure with `.drv`-style metadata, a generation store with rollback, and real
package source-tree realization from a gzipped POSIX tar. Blockers tracked in
`doc/STORE-LAYOUT.md`.

**Module composition (2026-08-24)**: the *how `modules/*` combine* piece landed —
`modules/compose.vyb` (a `Module` contribution type, a pure `compose` fold over
module functions, and a `compose_issue` validation gate), example modules
(`sshd`/`getty`/`vim`/`nginx`), a 15-invariant self-test, and `doc/COMPOSITION.md`.
A module is a typed function (params are its options), so there is no separate
options schema to interpret — the call site is the declaration. Wired into the
transition pipeline via `build/build-apply.vyb` (compose → gate → `spec_digest`
→ deterministic `plan_lines`) and executed by `modules/realize.vyb` +
`build/build-exec.vyb`. **Real HTTPS URL-driven realization** via
`modules/urlrealize.vyb` + `build/build-url-realize.vyb` (verified-TLS fetch of a
package's own source → content-address → store).

**Toolchain isolation (2026-08-24)**: VybOS builds/runs against an **isolated Vyb
worktree** — `<VybOS toolchain checkout>` (branch `vyb-os-stable`) — created via
`git -C <Vyb checkout> worktree add -b vyb-os-stable <VybOS toolchain checkout>`,
insulating VybOS from impl-agent churn on the main checkout.

**Build-stage derivations → full derived boot chain (2026-08-25→26)** — the 0.1
"Brutal Dogfood" build stage (see `doc/RELEASE-BRUTAL-DOGFOOD.md` and
`doc/PLAN-BUILD-DERIVATIONS.md` for depth):

1. **Self-hosting C compiler** — `build-derive-compiler.vyb`: chibicc GEN-1 →
   GEN-2 via self-recompile (roll-your-own bootstrap).
2. **Derived toolchain, from source** — gmp → mpfr → mpc → binutils → gcc 13.2.0
   (C-only) as build-stage derivations; the derived gcc compiles real programs.
3. **T3: Linux kernel** — `linux-6.6` bzImage derived from source, compiled by
   the derived gcc, boots the rootfs to `VYBOS_READY=1` in QEMU.
4. **Derived hypervisor** — QEMU 8.2.2 from source, packaged with glib +
   pc-bios into a nested store entry; the whole boot now uses **only store
   artifacts** (toolchain → kernel → hypervisor).
5. **Determinism proofs** — path-independent byte-deterministic kernel (built
   twice, byte-identical); independent-build reproducibility proofs for binutils
   and the gcc tower; nested store keyed by full 256-bit SHA-256 hex.

## Remaining (see doc/STATUS.md §4)

- Bootable image: root/disk image (B5), bootloader, gen-switch, VybOS's own
  (non-stand-in) userspace.
- Generations wiring into an atomic profile flip (needs the `rename`/`symlink`
  RFE).
- Module-system deepening (service options beyond `enabled`).
