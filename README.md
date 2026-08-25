---
last_edited: 2026-08-23
---

<p align="center">
  <img src="vybos.png" alt="VybOS logo" width="220">
</p>

# VybOS

## Goal

A Linux distribution with declarative, reproducible, content-addressed system 
configuration — with the entire control framework written in JIT Vyb. 

PID 1 is Vyb.

The core idea: a system is not described to an interpreter, it is a **Vyb
program** that the Vyb JIT compiles and runs to produce the machine's
derivation graph, activation scripts, and immutable store. There is no separate
configuration language and no store daemon in a foreign language — the config
language *is* vybey, executed through the same JIT that runs the compiler's own
runtime. Configuration, packaging, and build logic are all vybish.

## Status

**M0 + M1 done (2026-08-23).** Config-as-program plumbing proven: a machine
declaration (`config/system.vyb`) imports the framework (`modules/vybos.vyb`)
and JIT-evaluates to a `SystemSpec`. **M1** adds real realisation:
`build/build-store.vyb` does a real HTTP fetch, hashes the **actual** source
bytes (content-address), materializes them into `store/`, and prints stable
store paths — verified **reproducible across runs**. A real boot/system image
is not built yet.

**M2 done (2026-08-24).** Dependency graph → real materialization of a
transitive **closure** with `.drv`-style metadata, a **generation store with
rollback**, and **real package source-tree realization** via the stdlib
`archive` module (gzip inflate + POSIX tar extraction, byte-verified). All run
under `build/vyb` with reproducible store paths.

- **`build/build-closure.vyb`** — walks a typed dependency graph in
  topological order, fetches each source, writes a source blob + per-derivation
  `.meta.json` (name/version/source, real content hash, closure-aware store
  identity, input closure w/ paths). Reproducible; a transitive dep bump
  changes exactly the affected closure's store paths.
- **`build/generations.vyb`** — generation store + rollback bookkeeping
  (pure Vyb, offline): an append-only `index.json` ledger (`cur=` + one
  `id|parent|digest` row per generation), a serialized `SystemSpec` and its
  reachable store-path set per generation, and an ancestor-chain rollback
  validity check. All invariants verified.
- **`build/build-package.vyb`** — realises a package **source tree** from a
  gzipped POSIX tar using the stdlib `archive` module: extracts members,
  content-addresses each by its real inflated bytes, writes them into the flat
  store, plus a `.meta.json` tree manifest. Every member verified
  byte-identical to its true source. Deterministic + content-addressed
  (a member change → new addresses).

A **compiler regression** (uncommitted in-flight deep-copy/ownership edits
double-freed on the graph code during this session) was escalated as
`rickenator/Vyb#184` and fixed upstream (`7a4b4a8`); this repo's M2 slices all
re-verified after rebounding the toolchain to the fixed commit.

Also see `doc/NIXOS-BORROWINGS.md`, `doc/VYB-LANGUAGE-NOTES.md`, and
`doc/STORE-LAYOUT.md`.

Namespace/release-channel note: `doc/NAMESPACES.md` records the intended future
split between upstream `rickenator/Vyb`, downstream `VybLang` SDK releases, and
the VybOS distro/package namespace.

## Conceptual Shape

- **Config as JIT program** — a machine's declaration is a `.vyb` program
  (`system.vyb`) that runs under `vyb --jit` and returns a `SystemSpec`
  (packages, services, boot entries, files, users, …) in a single pass.
- **Content-addressed store** — analogous to `/nix/store`, an immutable store
  keyed by hash of build inputs (name, version, source, dependency closure).
  This repo calls it the **store** (`/vyb/store` on a built system); exact
  layout is TBD.
- **Derivations** — Vyb value describing "build X from inputs with recipe Y".
  The framework walks the derivation graph, JIT-runs each build recipe, and
  populates the store.
- **Generations & rollback** — like NixOS, the active system is an atomic
  switchable profile (a symlink generation) so rollback is instant.
- **Modules** — declarative system services/options composed in Vyb, mirroring
  NixOS module composition but with Vyb's own type safety, `select` expressions,
  and ownership model.
- **JIT-first** — the framework is authored and exercised via the JIT for fast
  iteration; native/AOT compilation stays a later, portability-minded option.

## How To Run

Paths below are godzilla-relative (`~/Projects`). On apex the compiler repo
lives at `/usr/export/rick/Projects/Vyb` instead.

```sh
# Prerequisite: Vyb compiler JIT binary — use the ISOLATED vyb-os worktree
# toolchain (stable snapshot; insulated from impl-agent churn on main):
#   ~/Projects/Vyb-vybos  →  cmake --build build  →  build/vyb
#   (created via `git -C ~/Projects/Vyb worktree add -b vyb-os-stable \
#     ~/Projects/Vyb-vybos` pinned to the fixed commit)

VYBU=/home/rick/Projects/Vyb-vybos    # the isolated worktree
export VYB_STDLIB=$VYBU/stdlib        # stable stdlib snapshot
VYB=$VYBU/build/vyb

# M0 — JIT-evaluate the machine declaration through the framework:
cd ~/Projects/VybOS
$VYB config/system.vyb --module-path modules

# Module composition convention (pure Vyb, offline) — 15 invariant self-test:
$VYB build/build-compose.vyb --module-path modules

# Compose -> validate -> transition plan (the `vyb system apply` dry-run):
$VYB build/build-apply.vyb --module-path modules

# Compose -> plan -> EXECUTE (realise the desired closure into the store):
$VYB build/build-exec.vyb --module-path modules   # needs network (httpbin)

# REAL HTTPS URL-driven realization (scheme -> verified TLS fetch -> store):
$VYB build/build-url-realize.vyb --module-path modules   # needs network (github raw)

# B1 rootfs materialization (Option B) — compose -> stage config layout:
$VYB build/build-rootfs.vyb --module-path modules   # stages build/rootfs-out/

# M1 — realise derivations: real fetch -> content-addressed store (needs network):
mkdir -p store   # store/ is gitignored (build cache)
$VYB build/build-store.vyb --module-path modules

# M2 step — realise a real dependency CLOSURE with .drv-style .meta.json:
$VYB build/build-closure.vyb --module-path modules

# M2 — generation store + rollback bookkeeping (pure Vyb, offline):
mkdir -p generations   # runtime state (gitignored)
$VYB build/generations.vyb --module-path modules

# M2 — real package source-tree realization (archive inflate + tar extract):
bash build/samples/make_samples.sh      # build the deterministic source tar.gz
$VYB build/build-package.vyb --module-path modules

# M2 — URL parser acceptance vectors (pure Vyb, offline):
$VYB build/build-url.vyb --module-path modules

# M2 — URL-driven realizer: parse ONE url -> fetch bytes -> realize the tree
#   (serves the sample tarball over a local HTTP server; edit url in main()):
$VYB build/build-package-url.vyb --module-path modules
```

## Source Of Truth

- Primary docs: this `README.md`, `GOAL.md`, `AGENTS.md`, `doc/`
- Vyb compiler: `/usr/export/rick/Projects/Vyb` (lang refs in its
  `docs/refman/PROGRAMMERS_GUIDE.md`)
- Data sources: none yet
- Related projects: NixOS / Nix (the conceptual reference), Vyb (the language)

## Next Steps

- [x] M0: `SystemSpec` + `system.vyb` JIT-evaluating to a concrete spec.
- [x] M1: store layout decision + first real derivation (fetch → hash → store file).
- [x] M2: real dependency-closure materialization + `.drv`-style metadata (`build/build-closure.vyb`).
- [x] M2: generation store + rollback bookkeeping (`build/generations.vyb`).
- [x] M2: real package **source-tree** realization via stdlib `archive` (`build/build-package.vyb`).
- [~] M2: nested store still waits on the runtime gaining `mkdir` (RFE-M2 #1); the tree realizer flattens member paths for now.
- [~] M2: URL→(host,port,path) parsing done **framework-side** (`modules/url.vyb` + `build/build-url.vyb` acceptance vectors, `build/build-package-url.vyb` URL-driven realizer); a stdlib `url` module stays an impl-agent RFE (Item 4) — VybOS no longer waits on it.
- [x] Module-composition convention: how `modules/*` combine — `modules/compose.vyb` (`Module`, `compose`, `compose_issue` gate) + example modules (`sshd`, `getty`, `vim`) + self-test (`build/build-compose.vyb`, 15 invariants) + `doc/COMPOSITION.md`; `config/system.vyb` now assembles the machine by folding modules.
- [x] Plan execution: shared realizer core `modules/realize.vyb` + `build/build-exec.vyb` (compose → plan → realise store objects; `build-apply.vyb` is the dry-run). Apply dry-run + execution both PASS on the isolated toolchain.
- [x] Real HTTPS URL-driven realization: `modules/urlrealize.vyb` (`fetch_url` picks http/https by scheme from `url_split`) + `build/build-url-realize.vyb` (fetch a real GitHub-raw source over verified TLS → content-address → store). PASS on the isolated toolchain.
- [x] Real crypto digest / HTTPS-fetch gaps scoped — `doc/RFE-M2.md` (mkdir, SHA-256, tarball, URL parser) drafted for the Vyb implementation agent; gzip+tar **extraction** landed in the stdlib `archive` module; HTTPS itself already works.
- [x] Generations/profiles + rollback bookkeeping (atomic symlink switch still awaits the `rename`/`symlink` RFE — current pointer is a file rewrite).
- [x] B1 rootfs materialization (Option B): `modules/rootfs.vyb` (pure `rootfs_files` layout) + `build/build-rootfs.vyb` (compose → stage `/etc/vyb-os` config into `build/rootfs-out/` via `freedom{exec_run}` mkdir fallback until stdlib `mkdir`). PASS on the isolated toolchain.
- [ ] Boot target (**DECIDED 2026-08-25: Option B — container rootfs first**): rootfs + launcher groundwork target a bootable rootfs; full QEMU kernel+initramfs is the follow-on (see `doc/PLAN_BOOTABLE_IMAGE.md`, `doc/PLAN-QEMU-LAUNCHER.md`).
- [x] Init GitHub repo (remote configured: `rickenator/VybOS`). Local commits (incl. M2) await push approval; Vyb toolchain regression escalated & fixed as `rickenator/Vyb#184`.

## Notes

- Scoped to "framework written in JIT Vyb" — kernel/userspace can stay
  upstream/Linux; the distinguishing work is the vybey build+config system.
- Follow Vyb terminology: **vybey** = the language, **vybish** = its style.
- Store layout is settled for M1 in `doc/STORE-LAYOUT.md` (repo-local `store/`,
  flat, FNV stand-in over real bytes; `/vyb/store` on-target).
