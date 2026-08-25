# VybOS — Session Status Report & Next Steps

> last_updated: 2026-08-25 (container-rootfs launcher: rootfs boots to READY)
> Purpose: a self-contained handoff so a fresh session can resume with no
> rediscovery. Toolchain, current state, what's done, open items, gotchas.

## 1. Toolchain (how to run everything)

VybOS uses an **isolated Vyb worktree**, not the main Vyb checkout:

```sh
VYBU=~/Projects/Vyb-vybos          # branch vyb-os-stable
VYB_STDLIB=$VYBU/stdlib
VYB=$VYBU/build/vyb
# update the toolchain to Vyb's latest COMMITTED+PUSHED main:
./build/sync-os-toolchain.sh       # fetches origin/main, ff + rebuild only if advanced
# (or rebuild manually after a manual sync:)
cd $VYBU && cmake --build build
```

- **vyb-os-stable tracks `origin/main` ONLY when Vyb main is committed AND
  pushed** (never the local `~/Projects/Vyb` checkout, which can carry
  uncommitted or committed-but-unpushed impl-agent churn). Enforced by
  `build/sync-os-toolchain.sh`: fetches the remote, fast-forwards
  `vyb-os-stable` to `origin/main` + rebuilds `build/vyb` only when new
  commits have been pushed; refuses on divergence; no-op when the remote is
  unreachable (stable stays). `./build/sync-os-toolchain.sh`.
  As of this session it is at `5656c62` = origin/main, and all VybOS slices
  PASS on the rebuilt binary.
- Decision that was OPEN is now resolved: **track main (pushed-state bound)**,
  not a hard pin.

Run a VybOS slice:
```sh
cd ~/Projects/VybOS
$VYB build/build-compose.vyb --module-path modules     # composition, offline
$VYB build/build-apply.vyb    --module-path modules    # apply dry-run, offline
$VYB build/build-exec.vyb     --module-path modules    # execute plan, needs httpbin
$VYB build/build-url-realize.vyb --module-path modules # real HTTPS, needs network
$VYB build/build-exec-real.vyb --module-path modules   # FULL pipeline over real HTTPS (~20MB fetch)
$ROOT/tools/vybos-run --test      # container-rootfs boot to READY (bwrap/docker; builds rootfs if absent)
$ROOT/tools/vybos-run --runtime qemu --test  # REAL QEMU kernel+initramfs boot to READY (fetches kernel)
```

## 2. Current state (all committed, pushed, 7/7 PASS)

Working tree clean, `main...origin/main` in sync. Recent commits (newest first):
`65fe578` (real HTTPS URL realization) → `610e273` (execute/realizer core) →
`3c94253` (apply dry-run) → `274c1e6` (RFE GitHub note) → `8204c8f`
(module-composition convention) → `dbc9d14` (M2 URL parser + worktree isolation).

**Framework now covers the full apply pipeline, all in vybey:**
1. **Compose** — `modules/compose.vyb`: `Module`, `compose(base, mods)` fold,
   `compose_issue()` validation gate; example modules `{sshd,getty,vim,nginx}.vyb`.
   Self-test `build/build-compose.vyb` (15 invariants).
2. **Validate** — `compose_issue` / `plan.resolve_issue` (dup pkg, dup enabled
   service, unknown dep, cycle) gating before any side effect.
3. **Digest** — `plan.spec_digest` content-addressed generation identity.
4. **Plan** — `plan.plan_lines` deterministic install/keep/remove
   (`build/build-apply.vyb`, 10 invariants).
5. **Execute** — `modules/realize.vyb` shared realizer core (closure identity,
   topological fetch → content-hash → write `.src` + `.drv`-style `.meta.json`)
   + `build/build-exec.vyb` (11 invariants).
6. **Real HTTPS** — `modules/urlrealize.vyb`: parses a pkg's own `source` URL
   (`url_split`), picks http/https transport by scheme, verified-TLS fetch,
   content-address into store. `build/build-url-realize.vyb` (9 invariants).
7. **Real HTTPS source-TREE** — `build/build-real-tree.vyb`: fetch a REAL GitHub
   tarball over verified TLS → inflate → extract → 59 file members realised
   content-addressed + `.tree.json` manifest (10 invariants).
8. **FULL pipeline over real HTTPS** — `build/build-exec-real.vyb`: compose →
   gate → plan → execute, where the execution step realises each pkg from its
   OWN real source over verified TLS (`realize_spec_url`, no httpbin mirror).
   openssh/vim/nginx fetched in topological order (~20MB over TLS, 8s), 16
   invariants, deterministic. (vim's module source now points at the DIRECT
   codeload endpoint — github's /archive/ URL 302-redirects, which the verified
   client doesn't follow.)
9. **Rootfs launcher** — `tools/vybos-run` boots the staged rootfs to a defined
   `VYBOS_READY` state in a disposable overlay/container (canonical rootfs never
   modified; stand-in static BusyBox userspace). Three runtimes, all passing
   `--test`:
   - `bwrap` (default, unprivileged), `docker` (import + run) = container-rootfs
     boots (B1+B3-lite).
   - `qemu` = **real kernel+initramfs self-boot (B4/Option A)**: boots the
     rootfs as an initramfs under a fetched Linux kernel (Alpine 6.6 netboot
     `vmlinuz-virt`, cached in `build/kernel-cache/`) — reaches `VYBOS_READY` on
     the serial console (TCG; no /dev/kvm here). Requires `/init` `+x` for
     kernel execve. See PLAN_BOOTABLE_IMAGE.
10. **BUILD-STAGE derivation** — the missing build step (derivations were
    fetch-only). Realize source → gated build action (`freedom{exec_run}`
    recipe) → content-address the OUTPUT `.bin` + `.meta.json`
    (sourceUrl/sourceContentHash/buildRecipe/outputContentHash).
    - `build/build-derive.vyb` (spike) on `build/samples/hello-vyb/main.c`:
      static ELF, reproducible (`outputContentHash` identical across two
      builds), runs.
    - `build/build-derive-real.vyb` (real fetched source): **busybox 1.36.1**
      fetched from busybox.net over verified TLS → source realized → BUILT
      (recipe disables the gcc-13-broken `tc` applet) → busybox ELF (1.06MB)
      content-addressed + `.meta.json`, runs.
    Foundation for toolchain/Linux derivations + issue #4's `build.plan`.
    See doc/PLAN-BUILD-DERIVATIONS.md.
11. **COMPILER BOOTSTRAP (self-hosting)** — `build/build-derive-compiler.vyb`:
    a working C compiler as a derivation. Fetches chibicc source over verified
    TLS, builds GEN-1 (host cc), then **GEN-1 recompiles chibicc's own source
    into GEN-2** (roll-your-own bootstrap). Both generations are content-
    addressed ELF, both compile real programs (the GEN-2-built program runs).
    See doc/PLAN-BUILD-DERIVATIONS §1a.
12. **TOOLCHAIN T0a (gmp)** — `build/build-derive-gmp.vyb`: the first GNU lib as
    a build-stage derivation. Fetches GNU gmp, realizes source, builds
    `libgmp.a` (configure + make), content-addresses the built static archive
    (valid ar) + `.meta.json`. First piece of the BROKEN-UP toolchain:
    **gmp → mpfr → mpc → binutils → gcc (C-only) → Linux kernel**. (Release 0.1
    = **"Brutal Dogfood"**; see doc/RELEASE-BRUTAL-DOGFOOD.md.)

## 3. GitHub issues filed against Vyb (this session)

- **#188** — `https_get_full` (unverified) cannot connect to real hostnames;
  silently absent. Root cause: passes hostname straight to `socket_connect`
  without `socket_resolve` (unlike `http_get_full` and `https_get_full_verified`).
- **#189** — `VYB_STR_REG_CAP` cannot raise the string registry above 262144
  (clamped to fixed array); multi-MB workloads abort, error message promises an
  impossible fix. Distinct from closed #162 (safety); this is the "can't enlarge".
  STILL OPEN (aug 25); #191 largely sidesteps it for realistic sources.
- **#190 / #191 / #192 (closed in the 2026-08-25 sync)** — impl agent fixed the
  codegen ownership-reclaim gaps (#190, #192) and the root cause that blocked us:
  #191 (archive inflate O(N²) one-byte concat → O(N) Vec-buffer; runtime string
  registry probe chains bounded via rehash-on-churn). This unblocks real-HTTPS
  source-TREE realization (see §4).
- **#194 (filed, then FIXED 2026-08-25)** — the `http`/`https` fetch clients
  originally did NOT follow HTTP redirects (302) and exposed no `Location`, so
  GitHub's `/archive/<ref>.tar.gz` URL (302 → codeload) could not be realised
  over genuine TLS; VybOS pointed vim at the direct codeload endpoint. Impl
  agent fixed it in toolchain `5656c62`: **same-scheme redirects are now
  followed, bounded to 10 hops**, and `Location` is exposed on `HttpResponse`.
  Verified: `github.com/sharkdp/fd/archive/refs/heads/master.tar.gz` and
  `github.com/vim/vim/archive/refs/tags/v9.1.0.tar.gz` now fetch 200 (bytes
  match codeload). The codeload workaround in `modules/vim.vyb` still works but
  is no longer required.

## 4. Next steps (framework-side, no impl-agent dependency)

- [x] **Real-HTTP(S) source-TREE realization**: `build/build-real-tree.vyb`
      realises a FULL source *tree* from a REAL GitHub tarball over genuine TLS
      (`https_get_full_verified` + system CA) — `url_split` → verified-TLS fetch
      → `inflate_gzip` → `extract_tar` → each member content-addressed into the
      flat store + a `.tree.json` manifest. Unblocked 2026-08-25 by the
      toolchain sync pulling in #191: the archive inflate is now O(N) (Vec<Int>
      byte buffer + `flat_bytes`/`join_pieces`, not one-byte String.concat) and
      the runtime bounds string-registry probe chains, so MB-scale tarballs
      inflate+extract without the O(N²) stall / registry abort. Verified: fetch
      `sharkdp/fd` master → inflate (MB-scale) → 59 file members realized,
      deterministic pkgCA, repeat-stable. (Scale sanity: an underscore tarball
      inflating to 7.8MB / 400 members also extracted cleanly in probing.)
- [x] **Realizer consumes a module-composed spec over real HTTPS**: `build-exec`
      used the httpbin mirror; `build/build-exec-real.vyb` swaps the fetch to
      `fetch_url` per-pkg so the whole compose→plan→execute pipeline runs over
      genuine TLS (verified ~20MB / 8s; 16 invariants). (Filename collision
      note: module was renamed `modules/urlrealize.vyb`, not `realize-url.vyb`,
      because `-` is invalid in a module identifier.)
- [ ] **Generations wiring**: tie `spec_digest` + `plan_lines` into
      `build/generations.vyb` so a module-composed switch is recorded as a
      generation with rollback (needs `rename`/`symlink` RFE for the atomic
      profile flip).
- [x] **Boot target decision** (needs Rick): kernel+initramfs on QEMU vs
      container rootfs first. **DECIDED 2026-08-25: Option B — container rootfs
      first** (see `doc/PLAN_BOOTABLE_IMAGE.md`). Both halves now boot to READY:
      container-rootfs via `tools/vybos-run --test` (bwrap/docker) AND a real
      QEMU kernel+initramfs self-boot via `--runtime qemu --test` (B4 early
      demo). Remaining for a full bootable image: root/disk image (B5),
      bootloader, gen-switch, and VybOS's own (non-stand-in) userspace.
- [ ] **Module-system deepening**: service options (port, args) beyond
      `enabled`; `select`-validated dep kinds; possibly an `options`-style
      carrier struct per module.
- [ ] **Build-stage derivations → kernels-from-source** (see
      doc/PLAN-BUILD-DERIVATIONS.md): landed — hello-vyb (byte-reproducible),
      busybox 1.36.1 (real fetched source → built ELF), a SELF-HOSTING C
      compiler bootstrap (chibicc: GEN-1 → GEN-2 via self-recompile), and
      toolchain T0a (gmp → libgmp.a). NEXT (broken up, per release 0.1 "Brutal
      Dogfood"): mpfr → mpc → binutils → gcc (C-only) → Linux kernel — turning
      the fetched QEMU vmlinuz into a *derived* VybOS kernel and giving issue
      #4's `build.plan` a real `linux-<ver>-vyb` package.
- [x] RFE-M2 impl-agent items (mkdir/SHA-256/tar/URL) mostly done or
      framework-side; see `doc/RFE-M2.md` for what the impl agent still owes.

## 5. Gotchas to remember (see also doc/VYB-LANGUAGE-NOTES.md)

- **Vyb ranges are INCLUSIVE**: iterate `0..len-1`, guard empties or you read
  one-past (double-free). #1 gotcha.
- **Nested in-place mutation is a no-op** (`a.b.get(i).x.push` mutates a copy);
  build bottom-up in locals.
- **`import A::B` (no braces) = nested-module path**; use `import A::{B}` for a
  flat module file. Module identifiers can't contain `-`.
- **Module fn bodies are spliced into the importer**: the importer must import
  EVERY name a shared fn references (types + helpers), or "Unknown type
  identifier". Proven in build-exec/build-url-realize.
- **Forward refs fail**: define a top-level fn before it's used.
- **HTTPS**: `https_get_full_verified(host,port,path,"")` for real hosts
  (unverified variant can't resolve hostnames — issue #188).
- **String registry / archive perf (since 2026-08-25 sync)**:
  `inflate_gzip` is now O(N), not O(N²) one-byte concat, and the runtime bounds
  string-registry probe chains via rehash-on-churn (#191 fixed). MB-scale real
  tarballs now inflate+extract (verified 7.8MB / 400 members). Two ceilings
  remain (both #189, not yet fixed): the registry table is still a fixed
  `VYB_STR_REG_CAP` array (262144) that cannot be enlarged — pieces in
  `flat_bytes` are 64B, so a single inflated buffer near ~16MB keeps ~N/64
  pieces live and can approach that cap; and the per-byte `String::from_byte`/
  concat flatten floor is ~100us/byte superlinear near ~1M, so keep committed
  real-tree demos to a few-hundred-KB sources for fast runs.

## 6. Sources of truth

- `README.md`, `GOAL.md`, `AGENTS.md`, `doc/` (RTD: `doc/COMPOSITION.md`,
  `doc/ARCHITECTURE.md`, `doc/STORE-LAYOUT.md`, `doc/VYB-LANGUAGE-NOTES.md`,
  `doc/RFE-M2.md`, `doc/NIXOS-BORROWINGS.md`).
- Vyb semantics: `~/Projects/Vyb-vybos` stdlib + the compiler repo's
  `docs/refman/PROGRAMMERS_GUIDE.md`.
