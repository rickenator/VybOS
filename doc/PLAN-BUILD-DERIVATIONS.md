# Plan — Build-Stage Derivations (fetch source → build → content-address OUTPUT)

> Status: PLAN + first spike landed · 2026-08-25
> Why this matters: kernels-from-source (build Linux "like the rest of the
> packages") and VybOS issue #4 (`build.plan`/`build.start`) both depend on a
> capability the repo does not yet have: a derivation whose **output** is a
> real built artifact and content-addressed. Today derivations are
> fetch-only (`realize` stores *source* blobs/trees, never compiles).
> Companion: `doc/PLAN_BOOTABLE_IMAGE.md` (B5 / image), `doc/STATUS.md`.

## Capability (the gap)

Current realizer (modules/realize.vyb + urlrealize.vyb):
`fetch URL → content-hash source → store .src/.meta.json`. **No build step.**

Build-stage derivation adds:
`realize source → run a gated build action → content-hash the OUTPUT → store .bin/.drv-style .meta.json (records sourceUrl, sourceContentHash, buildRecipe, outputContentHash)`.

The store path then tracks the *actual built output bytes*, so a source or
recipe change yields a new address — the content-addressable build model,
mirroring Nix derivations.

## Spike (landed 2026-08-25): `build/build-derive.vyb`

- Source: `build/samples/hello-vyb/main.c` (a small real C source).
- Build action: a SHELL recipe (`cc -static main.c -o vybhello`) run under
  `freedom { exec_run }` in a scratch dir (same gated host-exec path
  build-rootfs uses for `mkdir`).
- Output: `content_hash(built ELF)` → `store/<outCA>-hello-vyb-1.0.bin` +
  `.meta.json` (sourceUrl, sourceContentHash, buildRecipe, outputContentHash).
- Verified: builds **twice → identical outputContentHash** (reproducible); the
  output is a **real static ELF** and **runs** ("hello vyb build derivation").
- All BUILD-STAGE DERIVATION INVARIANTS PASS; no downstream slice regressed.

## Sequencing to the real targets

1. **Toolchain as a derivation** — today the spike uses the HOST `cc`/`make`
   (a `freedom exec` of the host toolchain is NOT a derived toolchain). A real
   VybOS `gcc`/`binutils` (or musl-based) toolchain, itself built from source,
   is the honest prerequisite for self-hosting builds. (Large; parallel-track.)
   - **1a. LANDED — a SELF-HOSTING C COMPILER as a derivation (chibicc)**:
     `build/build-derive-compiler.vyb` fetches `github.com/rui314/chibicc`
     source, realizes it, builds GEN-1 with the host cc, then BOOTSTRAPS:
     GEN-1 recompiles chibicc's own source into GEN-2. Both generations are
     content-addressed ELF and both compile real programs (the GEN-2-built
     program runs). This is the roll-your-own compiler bootstrap — "compilers
     are not magic" — and proves a compiler-in-a-derivation. Full gcc/binutils
     derivation remains the larger follow-on.
   - **1b. LANDED — gmp (T0a)**: `build/build-derive-gmp.vyb` builds the first
     GNU library (arbitrary-precision `libgmp.a`) as a build-stage derivation —
     bootstraps the broken-up toolchain: **gmp → mpfr → mpc → binutils → gcc
     (C-only) → Linux kernel**. gmp has no build deps beyond a C compiler;
     archive is `.tar.xz` (build step unpacks with host tar).
   - **1c. LANDED — mpfr (T0b)**: `build/build-derive-mpfr.vyb` builds
     `libmpfr.a` against a gmp dependency. Gotchas encoded: GNU configure
     rejects a relative `--prefix` (must be absolute), and `$PWD` must be
     captured BEFORE any `cd` (else it points into the source dir); mpfr's
     archive lands in `src/.libs/`. Source via `www.mpfr.org` (a host the
     verified TLS client handles; some GNU hosts hang it — a client robustness
     observation).
   - **1d. LANDED — mpc (T0c)**: `build/build-derive-mpc.vyb` builds `libmpc.a`
     against BOTH gmp + mpfr dependencies (all built into a scratch prefix; the
     store-input DAG remains a promoted follow-on). Completes the GNU lib trio
     that gcc links. Source via `www.multiprecision.org` (`.tar.gz`; archive
     lands in `src/.libs/libmpc.a`).
   - **1e. LANDED — binutils (T1)**: `build/build-derive-binutils.vyb` builds
     the assembler/linker/archiver (`as`/`ld`/`ar`) as a build-stage derivation
     — the "B" half of the C toolchain gcc drives. **Out-of-tree build**
     (binutils rejects in-source configure); host lacks `makeinfo`, so the
     recipe builds with `MAKEINFO=true` (skip info docs). All three binaries
     content-addressed; each is a runnable `GNU Binutils 2.43`. Source via the
     OSUOSL mirror (`ftp.gnu.org` hangs the verified TLS client; 28MB body
     still fits under the registry ceiling with #191).
   - **1f. LANDED — gcc C-only (T2)**: `build/build-derive-gcc.vyb` is the
     CAPSTONE of the bootstrapped C toolchain. It rebuilds the whole tree into
     one scratch prefix — gmp → mpfr → mpc → binutils (derived as/ld/ar on
     `PATH`) → gcc 13.2.0 (`--enable-languages=c --disable-bootstrap
     --disable-multilib`). `--disable-multilib` is REQUIRED (host lacks 32-bit
     libc/headers; configure's multilib link test aborts otherwise). Proves it
     end-to-end: **the derived gcc compiles a real C program that runs**
     ("hello from derived gcc 13.2.0"). Content-addresses the gcc driver +
     records cc1/libgcc. 88MB source also fits under the registry ceiling. Note:
     the flat store keeps the driver ELF + metadata; a full self-contained
     installed tree (cc1 + libgcc + headers/specs) needs dirs/a tarball (mkdir
     RFE) — builds reuse the in-scratch prefix for now.
2. **Real fetched source — LANDED (busybox 1.36.1)**: `build/build-derive-real.vyb`
   fetches `https://busybox.net/downloads/busybox-1.36.1.tar.bz2` over verified
   TLS, realizes the SOURCE (content-addressed `.src`, 2.5MB), and BUILDS it via
   a gated recipe (`tar xjf` → `make defconfig` → disable the gcc-13-broken `tc`
   applet by setting `CONFIG_TC` not-set → `make -j4`). The BUILT busybox ELF
   (1.06MB, pie) is content-addressed as `.bin` + `.meta.json`. Runs.
   NOTE: busybox.net ships `.tar.bz2`; the DERIVATION stores the fetched tarball
   and the build step unpacks it with host `tar` (Vyb's archive module handles
   gzip — a bzip2 inflate is an impl-agent RFE if we want Vyb-side extraction).
3. **Linux kernel as the flagship** — kernel `.tar.*` source → toolchain →
   config (`make defconfig`-style) → `bzImage`. This is what turns the QEMU
   boot (currently a *fetched* Alpine `vmlinuz`) into a *derived* VybOS kernel,
   and gives issue #4's `build.plan` a real `linux-<ver>-vyb` package.

## Honest limits / follow-ons

- **Not sandboxed yet**: build actions run on the host shell (gated by
  `freedom`, like the mkdir fallback). A real build sandbox (e.g. bubblewrap —
  already used by `tools/vybos-run`) with no network + ro-bind toolchain is the
  follow-on for isolation/reproducibility.
- **Not byte-reproducible yet (busybox)**: the default busybox build is
  byte-deterministic for a fixed path (`make clean && make` reproduces the SHA)
  but NOT across rebuilds/paths without reprobuild flags (`SOURCE_DATE_EPOCH`,
  `-frandom-seed`, `-fdebug-prefix-map`). hello-vyb certifies the DERIVATION
  machinery is byte-deterministic for a deterministic compile; hardening busybox
  (and later the kernel) for full reprobuilds is a follow-on.
- **Stand-in hash**: FNV-1a content address (B2 in PLAN_BOOTABLE_IMAGE wants
  SHA-256 once the stdlib has it).
- **Flat store**: single-file `.bin`/`.src`; nested dirs blocked on the `mkdir`
  RFE.
- **Large content**: string-registry/#189-adjacent ceilings still cap very large
  builds (a kernel build is many-MB staged output) — watch this as we scale.

## Relationship to issue #4 (AI configurator)

- `build.plan` / `build.start` get something real to reference once kernels (and
  toolchains) are derivations: a deterministic build plan over real packages.
- The AI proposes; VybOS validates; the user approves; VybOS executes — a
  `build.start` is exactly a confirmation-gated execution of this capability.
- Ordering recommendation (from the #4 comment): build-stage derivations +
  schema first, AI orchestrator on top.
