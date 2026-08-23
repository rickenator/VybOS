# Store layout (decision record)

## Current (M1, 2026-08-23)

- **Location:** repo-local `store/` during development. On a built system the
  same logical store is `/vyb/store` (immutable, read-only).
- **Shape:** FLAT, single file per package:
  `store/<hash>-<name>-<version>.src`
- **Hash:** two-accumulator FNV-1a over the **real fetched bytes** + identity
  (`name:version:bytes`), normalized non-negative. This is a *content address*
  in the NixOS sense — a pure function of the build inputs — so a source change
  yields a new path. It is a **stand-in**: FNV is NOT collision-safe. A real
  digest (SHA-256) is an RFE for the Vyb implementation agent.
- **Why flat:** the runtime has no `mkdir` yet, so `open_write` can only write
  into an already-existing dir; one file per package avoids needing
  directories.

## Demonstrated properties

- **Reproducibility:** identical store paths across two runs of
  `build/build-store.vyb` (httpbin `/html` + `/robots.txt`, fixed bodies).
- **Content addressing:** httpbin `/get` returns a slightly different body per
  request → its store path changed run-to-run. That is the mechanism working
  as intended (changed inputs ⇒ new path), which is also why m1 pins stable
  bodies for the reproducible demo.

## On-target expectations (not yet built)

- Read-only `/vyb/store` populated only by the build runner.
- Nested layout: `store/<hash>-<name>-<version>/…` with sub-files, not one .src
  blob.
- A per-derivation metadata record (inputs, dependency closure, build recipe) —
  the analogue of the Nix `.drv` / NAR metadata.

## Next slice (blockers)

1. **`mkdir` (or `open_write` creating parents)** in the Vyb runtime → enables
   nested store + separating metadata from source. *RFE.*
2. **Real digest (SHA-256, hex-formatted)** in the stdlib → collision-safe,
   shorter, canonical store hash. *RFE.*
3. **HTTPS/TLS fetch** (`stdlib/https` already exists) so real tarball URLs
   (multi-segment `https://…`) can be realised, plus `url`-style parsing of a
   `derive()` source string into (host, port, path).
4. **Generations/profiles** once realisation is solid (M2+).
