# Plan — VybOS Bootable Image (Roadmap)

> Status: PLAN · 2026-08-25 · Author: VybOS framework session
> Tracks: https://github.com/rickenator/VybOS/issues/3 (placeholder "Bootable Image")
> Companion: `doc/PLAN-QEMU-LAUNCHER.md` (tracks issue #1 — the QEMU launcher).
> Context docs: `README.md`, `GOAL.md`, `doc/ARCHITECTURE.md`, `doc/STATUS.md`.

## Purpose

This is the roadmap for the **bootable-image milestone** — the prerequisite that
issue #1's QEMU launcher (`tools/vybos-run`) depends on to actually boot a VybOS
artifact. It turns the open "Pick a boot target" item into a concrete,
dependency-ordered plan, and it reports honestly (per AGENTS/issue norms) that
**VybOS does not yet produce a bootable image**: today the build emits a
content-addressed `store/` of *source* blobs (`.src` + `.meta.json`) plus a
composed `SystemSpec` and generations — no kernel, initramfs, rootfs,
bootloader, or disk image.

## Current state (verified 2026-08-25)

| Component | State |
| --- | --- |
| Config-as-program | ✅ stable (module-composed `SystemSpec`) |
| Compose / plan / execute | ✅ stable (frame all vi vbey) |
| Realized store | ✅ `store/<hash>-<name>-<ver>.src` + `.meta.json` (source blobs & trees, flat; nested store blocked on `mkdir` RFE) |
| Rootfs materialize (B1) | ✅ `build-rootfs.vyb` → `build/rootfs-out` (`/etc/vyb-os/*` + config-driven `/init`) |
| Container-rootfs boot (B1+B3-lite) | ✅ `tools/vybos-run --test` boots the rootfs to `VYBOS_READY` (bwrap default, unprivileged; docker alt). Stand-in BusyBox userspace seeded in a disposable overlay; canonical rootfs untouched |
| Kernel / initramfs / bootloader | ❌ absent (B4 QEMU self-boot is the follow-on) |
| Boot target decision | ✅ DECIDED 2026-08-25: Option B (container rootfs first) + container boot landed |
| Image format / QEMU script | ❌ none yet |

---

## 1. Boot target decision (the fork) — needs Rick

**DECIDED (2026-08-25, Rick): Option B — container rootfs first.** Remaining
text below records both options and why B was chosen; the decision is locked.

The single most consequential choice. Two viable first-boot targets:

### Option A — QEMU x86_64 kernel + initramfs (+ minimal rootfs)
- **Shape:** fetch/assemble a Linux kernel, build a (minimal) initramfs/initrd,
  add a tiny rootfs (BusyBox-style) or boot to a store-backed root.
- **Aligns** with issue #1's QEMU `x86_64/q35/KVM/virtio` scope end-state; the
  truest "NixOS-like" boot.
- **Cost:** highest. Needs kernel config/fetch, initramfs generation, rootfs
  layout, boot cmdline/serial wiring. Touches several runtime RFEs (below).

### Option B — Container rootfs first (RECOMMENDED first-boot)
- **Shape:** materialize a *rootfs* (a laid-out directory tree: `/bin /etc
  /usr /lib ...`) from a module-composed `SystemSpec` + realized store; package
  it as a plain rootfs tarball/dir bootable under a container runtime or via
  QEMU with a host kernel + 9p/virtiofs.
- **Why first:** a rootfs is conceptually "the realized source tree + config
  laid out into directories" — the closest thing to what `store/` already is.
  It exercises the framework (compose/store → rootfs layout) with the **least
  new machinery**: no kernel bring-up, no initramfs engineering, no bootloader.
  It de-risks the tooling, config materialization, and file-layout decisions
  that every later boot path shares.
- **Downside:** not a self-booting image yet; QEMU kernel boot still awaits the
  Option-A-style lift.

**Recommendation:** **Option B first**, keep Option A as the next-boot milestone.
Both share the rootfs/config-materialization core, so B is not wasted work.

✅ **DECIDED (2026-08-25): Option B (container rootfs) first.** Rick confirmed;
this is the boot-target the rest of this roadmap and issue #1 build toward.

---

## 2. Roadmap phases (bootable image)

> Convention: `B<n>` boot phases. Items marked **[RFE]** need Vyb impl-agent
> runtime support; everything else is VybOS-framework-side (vybey).

### B0 — Decide + scaffold boot target (Rick's call; issue #3 resolution)
- Decide A vs B (recommend B first).
- Define the **bootable artifact contract**: what `build/*` produces
  (`rootfs/` dir, rootfs tarball, then later a disk image), where, and how
  `tools/vybos-run` consumes it. Keep build / boot / test roles separate.

### B1 — Rootfs layout + config materialization (core, framework-side)
- A **rootfs builder** (vybey, e.g. `build/build-rootfs.vyb`) that turns a
  module-composed `SystemSpec` + realized `store/` into a concrete directory
  layout: `/etc/vyb-os` (spec), `/bin`,`/usr`,`/lib`, service wrappers, etc.
- **Blocked on** the `mkdir` stdlib RFE (nested dirs). Until then, either use a
  host-side `freedom { exec }` fallback (compat path only) or a flat-to-nested
  staging.
- Reuse `compose`/`plan`/`realize` for identity; materialize only needed paths.

### B2 — Real content hashing (store soundness)
- Replace FNV-1a stand-in with SHA-256 (RFE-M2 #2) so store paths/rootfs
  identity are collision-safe as more content is realized.
- Independent of B1; can land in parallel once the impl agent ships the digest.

### B3 — Minimal init + userspace (rootfs-functional)
- Init (PID 1) + a minimal set of binaries (BusyBox or vyb-driven init that
  mounts, brings up configured services, reaches a **defined "ready"** state).
- The "ready" marker is what `tools/vybos-run --test` waits for (issue #1).
- Service activation driven by the composed `SystemSpec` (vybey), not hand-rolled.

### B4 — Kernel + initramfs (QEMU self-boot, Option A) [needs impl/RFE]
- Fetch/assemble a kernel; build an initramfs that mounts the rootfs; add
  boot cmdline (e.g. `console=ttyS0,115200`), serial-wired.
- This is what turns a rootfs into a `qemu-system-x86_64`-bootable image.
- **Note:** image assembly may trip on large real source archives → **Vyb
  issue #189** (string-registry cap) currently blocks realizing big trees;
  work with small sources or wait for the runtime fix.

### B5 — Image format + atomic generation switch
- Pack the built rootfs into a bootable artifact: raw/`qcow2` disk or ISO; a
  generation switch on boot (`/run/current-system`-style). The atomic
  profile/symlink flip needs the **`rename`/`symlink` stdlib RFE**.
- This is where `tools/vybos-run` boots a *real* VybOS image (closes issue #1
  acceptance criteria 1, 2, 3, 5, 6, 10, 11).

### B6 — VybOS-specific smoke tests
- `--test` checks against the real image: kernel booted, root mounted, init
  reached ready, config parsed, paths exist, `vyb`/runtime present, network init
  (when expected). Integrates with issue #1's extensible check list.

---

## 3. Dependency graph

```
B0 (decide boot target, Rick)
  └─ B1 rootfs layout+config    ── needs: [mkdir RFE]
       └─ B2 real hashing        ── needs: SHA-256 RFE   (parallel-safe)
       └─ B3 init+userspace      ── needs: "ready" marker
            └─ B4 kernel+initramfs ── needs: kernel bring-up, #189 workaround
                 └─ B5 image format + gen switch ── needs: rename/symlink RFE
                      └─ B6 VybOS smoke tests    ── closes issue #1 boot-line
```

- **Framework-blocked:** `mkdir`, `rename`/`symlink`, SHA-256 = Vyb impl-agent
  RFEs. VybOS does not wait idle: B1 staging, B2 parity tooling, and the
  `tools/vybos-run` launcher (issue #1) can proceed against a stand-in image now.
- **Vyb bug to watch:** **#189** (string registry cap) blocks realizing large
  sources — relevant to B4/B5 big-tree assembly.

---

## 4. Milestone definition (Definition-of-Done-ish)

A **first bootable VybOS image** milestone is reached when all of:
1. A rootfs is materialized from a module-composed `SystemSpec` + realized
   store, with config at `/etc/vyb-os`.
2. It boots to a defined "ready" state (init + minimal userspace, serial
   reachable).
3. `tools/vybos-run` (issue #1) boots it via a disposable overlay and returns
   `0` on `--test` (or the applicable variant for a rootfs/container boot).
4. The canonical build artifact is never modified in place; writes go through
   overlays/staging.
5. Existing VybOS builds/workflows (compose/plan/execute/HTTPS realization) are
   not broken.

---

## 5. Open questions (Rick)

1. **Boot target:** Option B (container/rootfs first — recommended) vs Option A
   (QEMU kernel+initramfs first)?
2. **Init choice:** BusyBox/minimal init vs a vyb-driven PID 1 for the first
   boot? A stand-in BusyBox POSIX `/init` (config-driven from the composed spec)
   already boots to READY under `tools/vybos-run`; the question is whether the
   real userspace init becomes vyb-driven (showcase) or stays minimal.
3. **Staging for B1 before `mkdir`:** acceptable to use a `freedom { exec }`
   host-side staging fallback temporarily, or wait for the runtime `mkdir` RFE?
4. **Stand-in validation** (shared with issue #1): OK to validate launcher +
   smoke plumbing against a tiny stand-in boot image now, before a real rootfs?
   — DONE: `tools/vybos-run --test` validates the launcher against the
   materialized container rootfs (stand-in BusyBox userspace); a real image
   with VybOS's own userspace is still ahead.

---

## 6. Deliverables

- This roadmap (done).
- After Rick answers §5: B0/B1 executable groundwork (rootfs layout + launcher
  stand-in validation) with the docs, committing framework-side pieces as they
  land, and reporting honestly what is real-bootable vs stand-in.
