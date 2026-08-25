# Plan — VybOS Issue #1: First-class QEMU launcher (`tools/vybos-run`)

> Status: PLAN · 2026-08-25 · Author: VybOS framework session
> Tracks: https://github.com/rickenator/VybOS/issues/1 (enhancement, good-first-issue)
> Companion docs: `README.md`, `GOAL.md`, `doc/ARCHITECTURE.md`, `doc/STATUS.md`.

## TL;DR

Issue #1 asks for `tools/vybos-run` — a developer/CI launcher that boots a VybOS
image under QEMU, uses a disposable overlay, captures serial logs, and drives an
automated smoke test. The **tooling design is sound and buildable now**. But the
issue's acceptance criteria assume a bootable `build/vybos.img` **does not exist
yet**: VybOS today produces only a content-addressed `store/` of *source* blobs,
not a bootable OS image. Per the issue's own instruction to report mismatches
rather than force an obsolete assumption, this plan **front-loads that blocker**
and splits the work into (A) a boot-target decision (prerequisite, needs Rick) and
(B) a launcher scaffold that is fully testable against a stand-in image.

---

## 1. Grounding: what VybOS actually produces today (verified)

| Thing | Current state |
| --- | --- |
| Config-as-program | ✅ `config/system.vyb` → `SystemSpec` (module-composed) |
| Framework | ✅ compose → validate → digest → plan → execute (all vi vbey) |
| Build output | `store/` — content-addressed **source blobs** (`.src` + `.meta.json`) per derivation, per member. NOT a filesystem/image. |
| Kernel | ❌ none fetched/assembled |
| Initramfs / initrd | ❌ none |
| Rootfs / disk image | ❌ none |
| Bootloader | ❌ none (`replace systemd/bootloader` is an explicit non-goal; no grub/syslinux) |
| `tools/` | ❌ does not exist |
| QEMU scripts/experiments | ❌ none in repo |
| Boot target decision | ⏳ **open** — kernel+initramfs on QEMU vs container rootfs first (README:158) |

**Consequence:** acceptance criteria 1, 2, 3, 5, 6, 10, 11 of issue #1 ("boot a
freshly built VybOS image", etc.) **cannot be met until a bootable target
exists**. They are not launcher bugs — they are blocked on a missing
prerequisite.

**Two things issue #1 gets right (keep):**
- Launcher need not require Vyb itself — Bash/Python is fine; a native-Vyb
  rewrite is a later phase.
- Keep build / boot / test responsibilities separate; launcher must not rebuild
  the OS.

---

## 2. The gating prerequisite: pick a boot target (needs Rick)

Before any boot-line acceptance can pass, VybOS must produce *something*
bootable. Two live options (this is the open decision in README/STATUS):

- **Option A — QEMU x86_64: kernel + initramfs, minimal BusyBox-or-vyb rootfs.**
  Aligns with the issue's `x86_64/q35/KVM/virtio` scope; gives a real boot path
  to develop toward. Larger lift: kernel config/fetch, initramfs generation,
  rootfs assembly — and image assembly needs the `mkdir`/`rename` RFEs and
  (ideally) real content hashing (issue #189 blocks big archives).
- **Option B — container rootfs (OCI/rootfs tarball, no kernel).**
  Much earlier win: a rootfs is "just" a realized source tree + config
  materialized into a directory layout — which is close to what `store/`
  already is. Bootable via a container runtime or `QEMU`/`systemd-nspawn` with a
  host kernel. **Recommended as the first boombable target** because it
  undercuts nearly the whole kernel/initramfs lift and exercises the framework
  (compose/store → rootfs) with the least new machinery.

**Recommendation:** decide **Option B (container rootfs) first**, ship
`tools/vybos-run` in "rootfs/container" mode, then evolve to full QEMU
kernel+initramfs as milestone two. The launcher is architected so the boot
mechanism is pluggable (see §5), so picking B does not compromise the issue's
QEMU end-state.

> This is Rick's call and touches host machinery (running builds/containers,
> mounting, loop devices), so it needs explicit approval — no host-side side
> effects until then.

---

## 3. Scope for the launcher (from the issue, kept)

**Target (v1):** `x86_64`, `q35`, KVM-when-available, VirtIO disk, user-mode
networking, serial console always present; interactive + headless; disposable
writable overlay; log capture to `.logs/qemu/`; deterministic `--test` smoke
mode for Hermes/CI; optional `--share-vyb <worktree>`; `--gdb` stub.

**In-scope flags (conventional CLI):**
```
./tools/vybos-run                    # discover default build artifact
  --headless   --gui
  --disk path/to/vybos.img
  --memory 4G  --cpus 4
  --ssh-port 2222
  --keep       --no-kvm
  --gdb        --test  --timeout 120
  --share-vyb /path/to/Vyb (dev-only)
  --help
```

**Out of scope (do NOT build v1):** ARM64, UEFI variants, snapshots, TAP/bridge,
multi-NIC, CI matrix, installer/graphical tests, VM-lifecycle framework,
libvirt, root requirement, hidden state.

**Exit-code contract (`--test`):** `0` = booted + required smoke tests passed;
nonzero = boot failure / timeout / crash / test failure. Interpret QEMU's exit,
never pass it through blindly.

---

## 4. Design

### 4.1 Immutability + disposable overlay
- Locate base image (default: environment/build convention → discover; fallback
  `--disk`). Detect base format (`file` magic / `qemu-img info`) — never assume.
- Always boot with a temp QCOW2 overlay `-F <basefmt> -b <base>`; destroy on exit
  unless `--keep` (then print the retained path).
```
VybOS build image  →  /tmp/vybos-XXXX.qcow2 (overlay)  →  QEMU
```
### 4.2 QEMU invocation defaults (validated against target when real)
```
qemu-system-x86_64 -machine q35 [-enable-kvm|-accel tcg] -cpu host \
  -m 4G -smp 4 \
  -drive file=<overlay>,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -serial stdio[:file=...] -monitor none -nographic (headless)
```
- KVM detection: present → use; absent → **fall back to TCG automatically AND
  print a clear message** (least-surprising; `--no-kvm` forces TCG regardless).
  Document this choice.
- Serial `ttyS0,115200` is the canonical diagnostic channel; keep serial output
  captured even when GUI is enabled.

### 4.3 Logging → `.logs/qemu/vybos-<YYYYmmdd-HHMMSS>.log`
Timestamped; capture serial (kernel boot, early userspace, init, config parse,
service start, panics) + QEMU stderr. Print the log path on failure. Honor any
existing repo log convention (none today → introduce `.logs/`, gitignore it).

### 4.4 Automated `--test` lifecycle
```
launch → wait for boot-ready marker (serial) → run smoke checks →
collect results → request shutdown (poweroff/ACPI) → map exit code
```
- **Boot-ready marker:** a distinctive serial line VybOS prints when
  init/ready is reached. Until a boot target exists, use the stand-in image's
  marker (see §6). Parsing framework must be marker-driven and incremental.
- **Timeout** (`--test --timeout 120`, default ~120): on timeout terminate VM
  cleanly → keep logs → nonzero → print last serial tail / identify log file.
- **Smoke checks (v1, only what the current image supports — no fabrication):**
  kernel booted, root mount, init reached expected state, config parsed, key
  paths exist, `vyb` binary runs, stdlib/runtime resources visible, (network
  init when networking is expected), defined-ready reached. Structure as an
  extensible ordered check list.
- **SSH:** forward `--ssh-port` → guest:22 only if VybOS actually runs SSH; do
  not make SSH a hard dependency for v1 — serial may be the test channel.
  Design so SSH-based tests can be added without redesign.

### 4.5 `--share-vyb <worktree>` (dev-only)
- Mount host Vyb worktree at guest `/mnt/vyb`.
- Prefer VirtioFS; fall back to 9p when VirtioFS is impractical. Must NOT affect
  production image contents (dev-only flag). Enables: vyb-os agent tests a new
  compiler build inside the VM without copying into the canonical checkout or
  rebuilding the whole image per iteration.
- Note: VirtioFS/9p need guest-side drivers/kernel support — enforce the
  "stand-in kernel has them" requirement as a design constraint.

### 4.6 `--gdb`
- Expose `-gdb tcp::1234 -S` (start paused); print
  `QEMU waiting for GDB on localhost:1234`; document connect steps.
  Pause-on-start only when `--gdb` is used.

### 4.7 Cleanup (all paths)
Disposable overlay + temp sockets + PID files + temp VirtioFS resources + logs
must be removed on: normal shutdown, **Ctrl-C (trap)**, test failure, timeout,
and QEMU startup failure. `--keep` retains only debugging-useful resources
(notably the writable overlay) and prints them. Use an EXIT trap with a token
dir per invocation.

---

## 5. Repository integration & responsibilities

Keep three roles separate, don't create a parallel build convention:
```
build/ (build-*.vyb)   →  produces the VybOS artifact (store/ + a boot target)
tools/vybos-run        →  boots an existing artifact (never rebuilds the OS)
tools/vybos-test       →  (or a --test subcommand) validates a booted artifact
```
`vybos-run` must **not** silently rebuild the OS unless an explicit
`--build`-style option is later added. Print effective image path, overlay path,
arch, memory, cpus, accel mode, forwarded ports on launch (issue requirement).

Implementation: **Bash or Python** (recommend Python for arg parsing + trap
robustness + test check list; the issue permits either). No libvirt, no root.

---

## 6. Launcher-first, stand-in-image validation (unblocks now)

Because there is no real VybOS image yet, still ship and validate the launcher
now against a **stand-in boot image**: a minimal QEMU-bootable initramfs/rootfs
(micro HiSys / BusyBox initrd) that:
- boots under the same `q35 + KVM/TCG + virtio + serial` invocation, and
- prints a distinctive `READY` serial marker and answers the same `--test`
  smoke checks (kernel booted, root mounted, init reached, marker seen).

This proves the **entire launcher contract** (overlay lifecycle, logging,
serial capture, `--test` exit semantics, Ctrl-C cleanup, `--gdb`, `--share-vyb`
setup, CLI/printing) against real QEMU — without pretending it's the real VybOS
image. When a real rootfs/image lands (boot target milestone), the stand-in is
replaced by wiring the launcher's "boot mechanism" to the new artifact (pluggable
per §4.7/§5) and pointing smoke checks at VybOS's real markers.

**This is the honest path the issue's "report mismatches, don't fabricate"
instruction points to:** the smoke tests test the launcher + a real boot now,
and the real VybOS smoke tests get added the moment a bootable target exists.

---

## 7. Dependencies / blockers to watch

- **#189 (Vyb, open):** string-registry cap blocks realizing large source
  archives → a rootfs/image assembly may trip on big trees. Workaround: build
  rootfs from small sources, or wait for the runtime fix. (VybOS-side, not a
  launcher blocker.)
- **`mkdir`/`rename` stdlib RFEs:** nested store / rootfs materialization and
  atomic profile swap. Rootfs assembly needs `mkdir`; generation switch wants
  `rename`/`symlink`. (Blocked on impl agent.)
- **Boot target decision** (Rick) gate on everything boot-line (this is the
  #1 prerequisite milestone → see §2).

---

## 8. Implementation phases

| Phase | Scope | Depends on | Verify |
| --- | --- | --- | --- |
| P0 | Boot target decision + rootfs.v1 (Option B recommended) | Rick approval; `mkdir` RFE | `build-*` produce a rootfs dir/tarball |
| P1 | `tools/vybos-run` scaffold: CLI, overlay, QEMU defaults, serial, logging, `.gitignore` | — | boots a **stand-in** image; overlay removed; logs written |
| P2 | `--headless/--gui/--keep/--no-kvm/--memory/--cpus/--gdb` | P1 | interactive + flags verified |
| P3 | `--test` + smoke-check list + timeout + exit semantics | P1 | `--test` returns 0 on stand-in ready; nonzero on induced failure |
| P4 | `--ssh-port` (only if VybOS runs SSH) + `--share-vyb` | P1, VybOS SSH | forwarding + host mount verified |
| P5 | Wire to real VybOS boot target; VybOS-specific smoke checks | P0, real image | issue acceptance 1–14 against the real image |
| P6 (later) | Native-Vyb rewrite of launcher; ARM64/UEFI/... as designed-for-provable | — | — |

Acceptance (issue criteria 1–14) will be checked phase-by-phase; criteria that
are image-gated stay RED until P0/P5 deliver a bootable VybOS artifact.

---

## 9. Open questions for Rick (before/at P0)

1. **Boot target:** Option A (QEMU kernel+initramfs) vs **Option B (container
   rootfs first, recommended)** — pick the first-boot milestone.
2. **Launcher language:** Python (recommended: robust CLI/traps/checks, permits
   Bash per issue) vs Bash.
3. **Stand-in validation image:** OK to introduce a tiny BusyBox/initramfs
   stand-in now so the launcher contract is proven against real QEMU before the
   real image exists? (Recommended yes.)
4. **Log convention:** OK to establish `.logs/qemu/` (+ gitignore) as the repo
   convention the issue asks us to follow-if-present? (No convention exists yet.)
5. **`--share-vyb` guest support:** VirtioFS/9p needs guest kernel/driver
   support; acceptable to gate it behind the stand-in/real kernel having those?

---

## 10. Deliverable (this milestone)

- This planning document (done).
- After Rick answers §9: P1 launcher scaffold validated against the stand-in
  image, with docs (`README` section + a `tools/vybos-run --help`),
  smoke-test list, and repo integration — **before** any marked-DONE acceptance
  that requires a real VybOS image.
