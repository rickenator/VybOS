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
2. **Real fetched source** — build a genuinely fetched upstream source tarball
   (e.g. busybox `.tar.gz` via the existing verified-TLS fetch → inflate →
   build recipe), replacing the repo-local sample. busybox is the right
   mid-size target (static, self-contained).
3. **Linux kernel as the flagship** — kernel `.tar.*` source → toolchain →
   config (`make defconfig`-style) → `bzImage`. This is what turns the QEMU
   boot (currently a *fetched* Alpine `vmlinuz`) into a *derived* VybOS kernel,
   and gives issue #4's `build.plan` a real `linux-<ver>-vyb` package.

## Honest limits / follow-ons

- **Not sandboxed yet**: build actions run on the host shell (gated by
  `freedom`, like the mkdir fallback). A real build sandbox (e.g. bubblewrap —
  already used by `tools/vybos-run`) with no network + ro-bind toolchain is the
  follow-on for isolation/reproducibility.
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
