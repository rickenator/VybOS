# Plan — VybOS Issue #1: First-class QEMU launcher (`tools/vybos-run`)

> Status: PLAN · 2026-08-25 · **reconciled 2026-08-26** (launcher shipped; derived kernel/QEMU boot real; blockers lifted)
> Tracks: https://github.com/rickenator/VybOS/issues/1 (enhancement, good-first-issue)
> Companion docs: `README.md`, `GOAL.md`, `doc/ARCHITECTURE.md`, `doc/STATUS.md`.

## TL;DR

Issue #1 asks for `tools/vybos-run` — a developer/CI launcher that boots a VybOS
image under QEMU, uses a disposable overlay, captures serial logs, and drives an
automated smoke test. **That launcher now exists and ships with three runtimes**
(`bwrap` default, `docker`, and `qemu` — kernel+initramfs self-boot). The boot
target that the issue's acceptance criteria were blocked on was **decided
(Option B: container rootfs first)**, and the QEMU line now boots the **derived
`linux-6.6` kernel** (compiled by the derived gcc) under the **derived QEMU
hypervisor**, purely from nested-store artifacts, to `VYBOS_READY`. The remaining
acceptance criteria (persistent root/disk image + gen-switch + VybOS's own
userspace) are still ahead; this plan front-loads and tracks that path.

---

## 1. Grounding: what VybOS actually produces today (verified)

| Thing | Current state (2026-08-26) |
| --- | --- |
| Config-as-program | ✅ `config/system.vyb` → `SystemSpec` (module-composed) |
| Framework | ✅ compose → validate → digest → plan → execute (all in vybey) |
| Build output | `store/` — **nested** content-addressed source+built artifacts (`store/<hexca>/<name>-<ver>.{src,bin,meta.json}`), full 256-bit SHA-256 hex |
| Rootfs | ✅ `build/build-rootfs.vyb` → `build/rootfs-out` (config-driven `/init`, `/etc/vyb-os`); boots to `VYBOS_READY` |
| Kernel | ✅ **DERIVED** `linux-6.6` bzImage (from source, compiled by the derived gcc; path-independent byte-deterministic) — replaces the fetched `vmlinuz` stop-gap |
| Hypervisor | ✅ **DERIVED** `qemu-system-x86_64` 8.2.2 (from source) packaged with glib + pc-bios into a nested store entry |
| Initramfs / initrd | ✅ rootfs booted as initramfs under the derived kernel (QEMU self-boot to READY) |
| Root/disk image + bootloader | ❌ none yet (`replace systemd/bootloader` is an explicit non-goal; no grub/syslinux) |
| `tools/` | ✅ `tools/vybos-run` ships: `--test` (bwrap/docker), `--runtime qemu --kernel <out> --test` |
| Boot target decision | ✅ **DECIDED 2026-08-25: Option B (container rootfs first)**; QEMU kernel+initramfs self-boot also demonstrated |

**Consequence:** a *bootable target* now exists (container rootfs + a derived
kernel+initramfs QEMU self-boot), so the launcher's core smoke path is real.
Issue #1's image-gated acceptance criteria (1, 2, 3, 5, 6, 10, 11 — "boot a
freshly built VybOS image", persistent disk image, gen-switch) still wait on the
remaining **B5 root/disk image + bootloader + VybOS's own userspace**, not on the
launcher itself.

**Two things issue #1 gets right (keep):**
- Launcher need not require Vyb itself — Bash/Python is fine; a native-Vyb
  rewrite is a later phase.
- Keep build / boot / test responsibilities separate; launcher must not rebuild
  the OS.

---

## 2. The gating prerequisite: pick a boot target — **LOCKED 2026-08-25**

Before any boot-line acceptance can pass, VybOS must produce *something*
bootable. Two live options (this is the open decision in README/STATUS):

- **Option A — QEMU x86_64: kernel + initramfs, minimal BusyBox-or-vyb rootfs.**
  Aligns with the issue's `x86_64/q35/KVM/virtio` scope; gives a real boot path
  to develop toward. Larger lift: kernel config/fetch, initramfs generation,
  rootfs assembly — and image assembly needs the `rename` RFE (for the atomic
  gen-switch), `mkdir`/real content hashing now landed (#195 items 1–2).
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

✅ **DECIDED (2026-08-25, Rick): Option B (container rootfs first).** So
`tools/vybos-run` v1 targets a bootable rootfs (container-runtime or
QEMU-with-host-kernel boot), with full QEMU kernel+initramfs as the follow-on
milestone. See `doc/PLAN_BOOTABLE_IMAGE.md` for the boot roadmap.

> This is Rick's call and touches host machinery (running builds/containers,
> mounting, loop devices), so it needs explicit approval — no host-side side
> effects until then. (Decision made; any host-affecting run still needs the
> approval.)

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

## 6. Launcher-first validation — **SHIPPED + SUPERSEDED by the derived boot**

The launcher was validated against a stand-in boot image to prove the **entire
launcher contract** (overlay lifecycle, logging, serial capture, `--test` exit
semantics, Ctrl-C cleanup, `--gdb`, `--share-vyb`, CLI/printing) against real
QEMU. That stand-in path is now **superseded**: `tools/vybos-run` ships three
runtimes — `bwrap` (default) and `docker` boot the materialized container
rootfs to `VYBOS_READY`, and `--runtime qemu --kernel <out>` boots the **derived
`linux-6.6` bzImage** (rootfs as initramfs) under the **derived QEMU hypervisor**
to `VYBOS_READY`. All three pass `--test`. The smoke checks point at VybOS's real
`VYBOS_READY` marker; no stand-in is pretending to be the real image.

---

## 7. Dependencies / blockers to watch (reconciled 2026-08-26)

- **#189 (Vyb, string-registry cap) CLOSED (2026-08-25)** — with #191's O(N)
  inflate + bounded probe chains, realistic MB-scale trees realize cleanly; no
  longer a launcher/rootfs blocker.
- **`mkdir` stdlib RFE: LANDED** (Vyb #195 item 1) — nested store + rootfs
  materialization no longer wait on the impl agent. The **`rename`/`symlink`**
  RFE is the one remaining runtime dep, for the atomic generation/profile flip
  (B5 gen-switch).
- **Boot target: LOCKED (2026-08-25, Option B)** — no longer a gate (§2).
- **Remaining boot-line work:** B5 persistent root/disk image + bootloader +
  VybOS's own (non-stand-in) userspace.

---

## 8. Implementation phases

| Phase | Scope | Status (2026-08-26) | Verify |
| --- | --- | --- | --- |
| P0 | Boot target decision + rootfs.v1 (Option B) | ✅ **done** — Option B locked 2026-08-25; `build-rootfs.vyb` → `build/rootfs-out` | `build-*` produce a rootfs dir |
| P1 | `tools/vybos-run` scaffold: CLI, overlay, QEMU defaults, serial, logging, `.gitignore` | ✅ **done** — launcher ships (bwrap/docker/qemu) | boots to `VYBOS_READY`; overlay removed; logs written |
| P2 | `--headless/--gui/--keep/--no-kvm/--memory/--cpus/--gdb` | ✅ **done (2026-08-28)** — full flag set for the `qemu` runtime: KVM auto-detect w/ TCG fallback (+`--no-kvm`), `-m`/`-smp`, `-nographic` vs display, `-gdb tcp::1234 -S`, persistent serial log under `.logs/qemu/` (gitignored), effective-params printout. `--disk` boots the persistent B5 root image; `--ssh-port/--share-vyb` still recognized + rejected (need in-guest SSH / guest virtiofs) | `--runtime qemu --test` and `--disk … --test` both PASS (READY) on TCG |
| P3 | `--test` + smoke-check list + timeout + exit semantics | ✅ **done** — `--test` returns 0 on READY across all three runtimes | `--test` 0 on ready; nonzero on induced failure |
| P4 | `--ssh-port` (only if VybOS runs SSH) + `--share-vyb` | ⏳ VybOS doesn't run SSH yet; follow-on | forwarding + host mount verified |
| P5 | Wire to a real VybOS boot target; VybOS-specific smoke checks | ⏳ **persistent root/disk image LANDED + `--disk` boots it to READY (B5, 2026-08-28)**; remaining: atomic gen-switch (needs the `rename`/`symlink` RFE) + bootloader | `--runtime qemu --disk store/<ca>/… --test` PASS — image-gated acceptance track here |
| P6 (later) | Native-Vyb rewrite of launcher; ARM64/UEFI/... as designed-for-provable | — | — |

Acceptance (issue criteria 1–14) is checked phase-by-phase; criteria that are
gated on a **persistent root/disk image + gen-switch** (B5) stay RED until that
image lands — the launcher and the derived self-boot are otherwise real.

---

## 9. Open questions for Rick (before/at P0)

1. ~~**Boot target:** Option A vs Option B?~~ — **DECIDED 2026-08-25: Option B**
   (container rootfs first); a QEMU kernel+initramfs self-boot was subsequently
   *also* demonstrated with the derived kernel/QEMU.
2. **Launcher language:** Python (recommended: robust CLI/traps/checks, permits
   Bash per issue) vs Bash — decided at implementation; launcher ships.
3. ~~**Stand-in validation image?**~~ — **DONE**: validated the launcher contract
   against a stand-in boot image, then **superseded** by the derived kernel/QEMU
   self-boot (all three runtimes boot `VYBOS_READY`).
4. **Log convention:** `.logs/qemu/` (+ gitignore) — established with the
   launcher; follow-if-present per issue guidance.
5. **`--share-vyb` guest support:** VirtioFS/9p needs guest kernel/driver
   support; acceptable to gate it behind the kernel having those.

---

## 10. Deliverable (this milestone)

- This planning document (done, reconciled 2026-08-26).
- ✅ P1 launcher (`tools/vybos-run`) shipped — three runtimes, `--test` smoke
  path, `VYBOS_READY` marker — with repo integration; the QEMU line now boots the
  **derived** kernel/QEMU from nested-store artifacts.
- ✅ **P5 partial: a persistent root/disk image (B5)** — `build/build-image.vyb`
  → nested `store/<ca>/vybos-0.1-root.img`, booted by the **derived kernel** as a
  real mounted `/dev/vda` root via `tools/vybos-run --runtime qemu --disk … --test`
  (reaches `VYBOS_READY`, state persists).
- ⏳ Remaining before issue #1's image-gated acceptance fully GO GREEN: the
  **atomic gen-switch** (needs the `rename`/`symlink` RFE) + bootloader + VybOS's
  own userspace.
