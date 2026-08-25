# VybOS 0.1 — "Brutal Dogfood"

> Release identity · 2026-08-25
> Kernel codename: **Brutal Dogfood**

The first VybOS release is **0.1 — Brutal Dogfood** (kernel: **Brutal Dogfood**).
The name says it plainly: this is the release where we bite our own dogfood hard —
every piece of the stack is exercised by VybOS itself.

## What "0.1" means (scope so far)

Config + build framework written in JIT **vybey**, with the OS built from real
sources via content-addressed build-stage derivations:

- **Config-as-program**: module-composed `SystemSpec` (`compose`, `compose_issue`
  gate, `spec_digest`, `plan_lines`) — NixOS-like, no separate language.
- **Real realization over genuine TLS**: verified-HTTPS fetch → content-address
  source, with same-scheme redirect-following (Vyb #194).
- **Build-stage derivations** (fetch source → build → content-address the
  OUTPUT, not just the source):
  - hello-vyb (framework determinism)
  - busybox 1.36.1 (real fetched source → built ELF)
  - **chibicc self-host bootstrap** (GEN-1 compiler → GEN-2 via self-recompile)
- **Boot to READY**: container rootfs (`tools/vybos-run` bwrap/docker) and a
  QEMU kernel+initramfs self-boot (`--runtime qemu`).

## Road to a complete Brutal Dogfood

The plan that will fill out 0.1:

1. **Toolchain-as-derivation (broken up)**: gmp → mpfr → mpc → binutils → gcc
   (C-only bootstrap) — replace the host `cc` everywhere.
2. **Linux kernel as the flagship derivation** — a *derived* `bzImage`
   (currently a fetched Alpine `vmlinuz`).
3. **Root/disk image + bootloader** (bootable-image B5) and real (non-stand-in)
   userspace — a genuinely self-contained VybOS that builds and boots itself.

## Honest status

Present: a vybey config/build framework that fetches and builds real components
into a content-addressed store, self-hosts a C compiler, and boots a rootfs (QEMU
self-boot included). Not-yet: a derived toolchain, a derived kernel, and a full
self-contained disk image. 0.1 closes toward that; everything is dogfood.
