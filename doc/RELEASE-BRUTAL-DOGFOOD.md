# VybOS 0.1 — "Brutal Dogfood"

> Release identity · 2026-08-26
> Kernel codename: **Brutal Dogfood**

The first VybOS release is **0.1 — Brutal Dogfood** (kernel: **Brutal Dogfood**).
The name says it plainly: this is the release where we bite our own dogfood hard —
every piece of the stack is exercised by VybOS itself.

## What "0.1" means (scope so far)

Config + build framework written in JIT **vybey**, with the OS built from real
sources via content-addressed build-stage derivations:

- **Config-as-program**: module-composed `SystemSpec` (`compose`, `compose_issue`
  gate, `spec_digest`, `plan_lines`), JIT-evaluated — config language *is* the
  language.
- **Real realization over genuine TLS**: verified-HTTPS fetch → content-address
  source, with same-scheme redirect-following (Vyb #194).
- **Build-stage derivations** (fetch source → build → content-address the
  OUTPUT, not just the source):
  - hello-vyb (framework determinism)
  - busybox 1.36.1 (real fetched source → built ELF)
  - **chibicc self-host bootstrap** (GEN-1 compiler → GEN-2 via self-recompile)
  - **derived toolchain, all from source** — gmp → mpfr → mpc → binutils
    (`as`/`ld`/`ar`) → gcc 13.2.0 (C-only); the derived gcc compiles real programs
  - **derived Linux kernel** — `linux-6.6` bzImage, compiled by the derived gcc
  - **derived hypervisor** — QEMU 8.2.2 from source, packaged with glib +
    pc-bios into a nested store entry
- **Determinism proofs**: path-independent byte-deterministic kernel; binutils +
    gcc-tower independent-build reproducibility; nested store keyed by full
    256-bit SHA-256 hex.
- **Boot to READY**: container rootfs (`tools/vybos-run` bwrap/docker) and a
  QEMU kernel+initramfs self-boot (`--runtime qemu`) under the **derived**
  toolchain→kernel→hypervisor chain.

## Road to a complete Brutal Dogfood

The plan that fills out 0.1:

1. **Toolchain-as-derivation (broken up)** — **DONE**: gmp → mpfr → mpc → binutils
   → gcc (C-only) all derived from source; the derived gcc replaces the host `cc`.
2. **Linux kernel as the flagship derivation** — **DONE**: a *derived* `bzImage`
   (replacing the fetched Alpine `vmlinuz`), built by the derived gcc.
3. **Root/disk image + bootloader + VybOS's own userspace** — the remaining piece
   for a genuinely self-contained VybOS that builds and boots itself.

## Honest status

Present: a vybey config/build framework that fetches and builds real components
into a content-addressed store, self-hosts a C compiler, **derives its own
toolchain, kernel, and hypervisor from source**, proves byte-determinism, and
boots a rootfs (QEMU self-boot included) using only store artifacts. Not-yet:
a full self-contained root/disk image with bootloader and VybOS's own
(non-stand-in) userspace. 0.1 closes toward that; everything is dogfood.
