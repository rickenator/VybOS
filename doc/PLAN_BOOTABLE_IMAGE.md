# Plan — VybOS Bootable Image (Roadmap)

> Status: ROADMAP · 2026-08-25 · **reconciled 2026-08-26** (matches derived-kernel + derived-QEMU + determinism reality; boot target locked)
> Tracks: https://github.com/rickenator/VybOS/issues/3 (placeholder "Bootable Image")
> Companion: `doc/PLAN-QEMU-LAUNCHER.md` (tracks issue #1 — the QEMU launcher).
> Context docs: `README.md`, `GOAL.md`, `doc/ARCHITECTURE.md`, `doc/STATUS.md`.

## Purpose

This is the roadmap for the **bootable-image milestone** — turning the open
"Pick a boot target" item into a concrete, dependency-ordered plan and reporting
honestly (per AGENTS/issue norms) what VybOS can and cannot boot today.

**What's real now (2026-08-26):** VybOS materializes a container rootfs
(`modules/rootfs.vyb` → `build/rootfs-out/`) that boots to `VYBOS_READY=1`, and it
boots a **derived Linux kernel** (`linux-6.6` bzImage, built from source by the
**derived gcc**, byte-deterministic) under a **derived QEMU hypervisor** — the
whole boot uses **only nested-store artifacts** (toolchain → kernel → hypervisor).
The `store/` is a full 256-bit SHA-256-hex nested content-addressed store
(`mkdir` + SHA-256 landed in the stdlib). **Not yet:** a persistent root/disk
image, a bootloader, the atomic generation switch, and VybOS's own (non-stand-in)
userspace. This roadmap's remaining phases (B5/B6 + own userspace) target that.

## Current state (verified 2026-08-26)

| Component | State |
| --- | --- |
| Config-as-program | ✅ stable (module-composed `SystemSpec`) |
| Compose / plan / execute | ✅ stable (all in vybey) |
| Realized store | ✅ **NESTED** `store/<hexca>/<name>-<ver>.{src,bin,meta.json}`, full 256-bit SHA-256 hex (stdlib `fs::mkdir` + digest landed; flat store cleared) |
| Rootfs materialize (B1) | ✅ `build-rootfs.vyb` → `build/rootfs-out` (`/etc/vyb-os/*` + config-driven `/init`) |
| Container-rootfs boot (B1+B3-lite) | ✅ `tools/vybos-run --test` boots the rootfs to `VYBOS_READY` (bwrap default, unprivileged; docker alt). Stand-in BusyBox userspace seeded in a disposable overlay; canonical rootfs untouched |
| Kernel + initramfs (B4, Option A) | ✅ **DERIVED**: `tools/vybos-run --runtime qemu --kernel <out> --test` boots the **derived `linux-6.6` bzImage** (compiled from source by the **derived gcc**; path-independent byte-deterministic) under the **derived QEMU hypervisor**, entirely from nested-store artifacts, with the VybOS rootfs as initramfs → `VYBOS_READY` on serial (TCG — no /dev/kvm on this host). The earlier fetched Alpine `vmlinuz` stop-gap is **replaced** by the derived kernel. `/init` must be `+x` for kernel execve. REMAINING: disk image, bootloader, gen-switch, real Vyb userspace |
| Bootloader / disk image (B5) | ❌ none yet |
| Boot target decision | ✅ DECIDED 2026-08-25: Option B (container rootfs first); the QEMU kernel+initramfs self-boot is also demonstrated (B4, derived kernel/QEMU) |
| Image format / QEMU script | ⏳ QEMU boot runs via `tools/vybos-run --runtime qemu`; a packaged root/disk *image* is not yet produced |

---

## 1. Boot target decision (the fork) — **LOCKED**

**DECIDED (2026-08-25, Rick): Option B — container rootfs first.** Text below
records both options and why B was chosen; the decision is locked. (A QEMU
kernel+initramfs self-boot — Option A's shape — was subsequently *also*
demonstrated with the derived kernel, so both boot lines now run; B remains the
declared first-boot target, with a full disk image as the follow-on.)

The single most consequential choice. Two viable first-boot targets:

### Option A — QEMU x86_64 kernel + initramfs (+ minimal rootfs)
- **Shape:** fetch/assemble a Linux kernel, build a (minimal) initramfs/initrd,
  add a tiny rootfs (BusyBox-style) or boot to a store-backed root.
- **Aligns** with issue #1's QEMU `x86_64/q35/KVM/virtio` scope end-state; the
  truest *self-booting* VybOS boot (kernel + initramfs, no host container runtime).
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

### B1 — Rootfs layout + config materialization (core, framework-side) — ✅ LANDED
- A **rootfs builder** (vybey, `build/build-rootfs.vyb` + `modules/rootfs.vyb`)
  turns a module-composed `SystemSpec` + realized `store/` into a concrete
  directory layout: `/etc/vyb-os` (spec, version, hostname, `services.sh`) and a
  config-driven `/init`.
- Stdlib `mkdir` now exists (Vyb #195 item 1) — nested dirs are no longer an
  RFE; the rootfs materializer uses a `freedom{exec_run}` `mkdir -p` compat path
  for the staged tree.
- Reuse `compose`/`plan`/`realize` for identity; materialize only needed paths.

### B2 — Real content hashing (store soundness) — ✅ DONE
- FNV-1a stand-in **replaced**; store identity is now the **full 256-bit
  SHA-256 hex** `content_hash` of the real build-input bytes (stdlib digest,
  Vyb #195 item 2), in a **nested** `store/<hexca>/…` layout. Collision-safe
  and no longer a stand-in.

### B3 — Minimal init + userspace (rootfs-functional)
- Init (PID 1) + a minimal set of binaries (BusyBox or vyb-driven init that
  mounts, brings up configured services, reaches a **defined "ready"** state).
- The "ready" marker is what `tools/vybos-run --test` waits for (issue #1).
- Service activation driven by the composed `SystemSpec` (vybey), not hand-rolled.

### B4 — Kernel + initramfs (QEMU self-boot, Option A) — ✅ DERIVED + DETERMINISTIC (2026-08-25→26)
- **Fully derived boot:** `build/build-derive-kernel.vyb` (T3) builds a
  `linux-6.6` bzImage from source — **compiled by the derived gcc** (bison/flex +
  elfutils/libelf built in-scratch for kconfig/objtool), content-addressed into
  the nested store.
- **Byte-deterministic:** fixes `KBUILD_BUILD_TIMESTAMP/USER/HOST` +
  `SOURCE_DATE_EPOCH` + gcc `-frandom-seed`/`-fno-guess-branch-probability` +
  `-ffile-prefix-map=$B/=`, built **twice into two different build roots** → byte-
  identical bzImage (proven path-independent, sha `4201e8e4…`).
- **Derived hypervisor:** `build/build-derive-qemu.vyb` builds
  `qemu-system-x86_64` 8.2.2 from source; `build/build-package-qemu.vyb` packages
  it (with glib + pc-bios) into ONE nested store entry. The boot runs **purely
  from nested-store artifacts** — toolchain → kernel → hypervisor, no host qemu.
- ✅ **Boots to READY:** `tools/vybos-run --runtime qemu --kernel <out> --test`
  boots the rootfs as initramfs to `VYBOS_READY` on serial (TCG; no /dev/kvm on
  this host). The earlier fetched Alpine `vmlinuz` stop-gap is **replaced** by
  the derived kernel. `/init` must be `+x` for kernel execve; the expectable
  "Attempted to kill init" panic after READY is the natural stop.
- **Remaining:** bootloader, gen-switch, and VybOS's own userspace (not
  stand-in BusyBox). (A persistent disk image now exists — see B5.)

### B5 — Persistent root/disk image + atomic generation switch
- ✅ **PERSISTENT ROOT IMAGE LANDED (2026-08-28)** — `build/build-image.vyb`
  composes the spec → stages the rootfs → seeds busybox → `mke2fs -d` a **raw
  ext4** root image (64M), content-addressed (host `sha256sum` of the real
  bytes; a 60MB image is too large to hold as one Vyb String) into the **nested
  store**: `store/<ca>/vybos-0.1-root.img` + `.meta.json`.
- ✅ **Boots as a REAL mounted root (not initramfs)** — the **derived kernel**
  (`CONFIG_EXT4_FS=y` + `VIRTIO_BLK=y` built-in) mounts it as `/dev/vda`
  (`root=/dev/vda rw init=/init`) and reaches `VYBOS_READY`; state persists
  across boots. `tools/vybos-run --runtime qemu --disk store/<ca>/… --test`
  wires it (auto-finds the derived kernel). NOTE: the fetched Alpine `vmlinuz`
  CANNOT mount a disk root (its ext4/virtio are modules we don't ship) — the
  derived kernel is required, which is also the dogfood-correct choice.
- **Remaining (atomic gen-switch):** the `/run/current-system`-style profile
  flip needs the **`rename`/`symlink` stdlib RFE**; the bootloader (grub/syslinux
  are explicit non-goals — boot stays `-kernel` driven); VybOS's own userspace.
- This is where issue #1 acceptance criteria 1, 2, 3, 5, 6, 10, 11 close once
  the gen-switch lands.

### B6 — VybOS-specific smoke tests
- `--test` checks against the real image: kernel booted, root mounted, init
  reached ready, config parsed, paths exist, `vyb`/runtime present, network init
  (when expected). Integrates with issue #1's extensible check list.

---

## 3. Dependency graph (as-built 2026-08-26 — tracked phases done)

```
B0 (decide boot target, Rick)                 ✅ LOCKED: Option B
  └─ B1 rootfs layout+config    ✅ LANDED   (needs: mkdir → stdlib now has it)
       └─ B2 real hashing        ✅ DONE    (needs: SHA-256 → stdlib; 256-bit nested store)
       └─ B3 init+userspace      ⏳ lite     (needs: "ready" marker  → VYBOS_READY reached)
            └─ B4 kernel+initramfs ✅ DERIVED+DETERMINISTIC (derived gcc + derived QEMU)
                 └─ B5 image format + gen switch ── needs: rename/symlink RFE
                      └─ B6 VybOS smoke tests    ── closes issue #1 boot-line
```

- **Framework deps lifted:** `mkdir` (stdlib, Vyb #195 item 1) and **SHA-256**
  (stdlib, item 2) are **landed** — B1/B2 no longer wait on the impl agent; the
  store is nested with full 256-bit hex identity. The **`rename`/`symlink`** RFE
  (atomic generation/profile flip) is the remaining *runtime* dep for B5.
- **#189 (string-registry cap) CLOSED** (2026-08-25); #191 made realistic
  MB-scale trees work — it is no longer a blocker for image/tree assembly.
- B3's "ready" marker, B4's kernel bring-up, and the derived boot are real; the
  remaining boot-line work is persistent-image (B5) + VybOS's own userspace.

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

1. ~~**Boot target:** Option B vs Option A?~~ — **DECIDED 2026-08-25: Option B**
   (container rootfs first). A QEMU kernel+initramfs self-boot was subsequently
   *also* demonstrated with the derived kernel/QEMU (both boot lines run).
2. **Init choice:** BusyBox/minimal init vs a vyb-driven PID 1 for the first
   boot? A stand-in BusyBox POSIX `/init` (config-driven from the composed spec)
   boots to READY under `tools/vybos-run`; the question is whether the real
   userspace init becomes vyb-driven (showcase) or stays minimal. **Still open.**
3. ~~**Staging for B1 before `mkdir`?**~~ — **RESOLVED**: stdlib `mkdir` landed
   (Vyb #195 item 1); the rootfs materializer uses a `freedom{exec_run}`
   `mkdir -p` compat path.
4. **Stand-in validation** — **DONE**: `tools/vybos-run --test` validates the
   launcher against the materialized container rootfs (stand-in BusyBox
   userspace); the QEMU self-boot now uses the **derived** kernel, not a
   stand-in <code>vmlinuz</code>. VybOS's own (non-stand-in) userspace is still
   ahead.

---

## 6. Deliverables

- This roadmap (done).
- After Rick answers §5: B0/B1 executable groundwork (rootfs layout + launcher
  stand-in validation) with the docs, committing framework-side pieces as they
  land, and reporting honestly what is real-bootable vs stand-in.
