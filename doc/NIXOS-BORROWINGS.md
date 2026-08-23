# VybOS ← NixOS build-idea borrowings

VybOS is **not** a code fork of NixOS. It is a *conceptual* fork — chopsticks:
same intent, different material. NixOS proves the architecture (declarative,
reproducible, content-addressed); we reimplement the build machinery in vybey
and lean on the Vyb JIT instead of the Nix interpreter and store daemon. Every
idea below is a NixOS mechanism we intend to carry over into Vyb-shaped code.

## Borrowing map

| NixOS / Nix | VybOS analog (vybey) | Status |
| --- | --- | --- |
| `/nix/store` — immutable, content-addressed store keyed by hash of inputs | `/vyb/store/<hash>-<name>-<version>` | M0: hash is a stable FNV-1a stand-in; *real* digest pending stdlib crypto |
| Derivation (`.drv`) — a value: build X from inputs+recipe | `Package` struct (name, version, source, storePath) | M0: value only, no fetching |
| Realisation — fetch sources, run build recipes, populate store | derivation-graph walker, JIT-run each recipe | not built (M1+) |
| Generations & profiles — atomic profile symlink; `current → n-1 → n-2` | `<vyb-store>/profiles/<gen>` symlink chain via atomic rename | not built |
| Rollback — flip the profile symlink | same | not built |
| `/run/current-system` — pointer to the active generation | `/run/current-system` (already used as service path in M0) | not built |
| Flakes + `flake.lock` — pinned, reproducible inputs | pinned source manifest (e.g. `spec.lock`) | not built |
| Module system (`options`/`config`) — compose N modules into one config | Vyb module composition (`modules/*`) with type-safe structs | M0: skeleton |
| Build sandbox / pure builds (buildFHSEnv, restricted network) | isolation via build container/QEMU | not built |
| System closure — the full transitive dep set of a generation | transitive derivation closure in Vyb | not built |

## Principles we keep

1. **Determinism / reproducibility** — a declared config yields the same
   store paths every evaluation. Already demonstrated: identical hashes across
   runs in M0.
2. **Content addressing** — store identity is a pure function of the input
   declaration, so identical inputs dedupe and nothing is ever mutated in
   place.
3. **Generations as first-class** — the user never edits "the system"; they
   switch between atomic, named generations. Rollback is a symlink flip.
4. **Config *is* code** — with Nix this means an interpreter; with VybOS it
   means the config is a *JIT-compiled program*, so system declarations get the
   language's real type safety, ownership, `select` expressions, and (later)
   aspects, instead of a bespoke DSL.

## Divergences (the "weird" part)

- No Nix store daemon; the store is populated by JIT-run Vyb build code.
- No separate config language — vybey is the one language for config, modules,
  and build logic.
- FNV-1a stand-in for content hashing until a real digest exists; a proper
  content-address must eventually hash *build inputs* (source + settings +
  dep closure), not just the declared name/version.

## Open decisions

- Exact store layout under `/vyb/store` (hash component width, name/version
  encoding, negative-hash normalization).
- Whether profiles live under the store or in a separate `/vyb/var/profiles`.
- When to introduce real content hashing vs. keeping the deterministic
  stand-in for development speed.
