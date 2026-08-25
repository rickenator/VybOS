# Vyb / VybOS Namespace Plan

> Status: design note · 2026-08-25

## Current Reality

- `rickenator/Vyb` is public and remains the upstream compiler/language source
  repo.
- `rickenator/VybOS` is private for now. That is intentional while Rick is
  still carrying the language implementation, OS framework, and early package
  design work at the same time.
- Do not assume public end-user repos exist yet for either VybOS or VybLang.

## Intended Future Split

`VybLang` is the future downstream language distribution namespace, not the
compiler source-of-truth namespace.

Expected role:

- prebuilt Vyb SDK releases;
- install scripts and release manifests;
- checksums/signatures;
- user-facing SDK docs and examples;
- a stable artifact that downstream projects can pin.

`VybOS` is the future distro and package namespace.

Expected role:

- the VybOS framework repo;
- package recipes written in vybey;
- bootstrap/rootfs package sets;
- later cache or binary-index metadata.

## Supply Chain Shape

```text
rickenator/Vyb commit
    -> CI/release build
    -> VybLang SDK artifact
    -> VybOS pins SDK version + digest
    -> VybOS packages/builds run with that SDK
```

For now, the local `~/Projects/Vyb-vybos` isolated worktree fills the role that
a future pinned VybLang SDK release should occupy.

## Naming Guidance

- Reserve `VybLang` when practical, but do not treat creating or maintaining
  public end-user SDK repos as current milestone work.
- Reserve `VybOS` when practical, but the private `rickenator/VybOS` repo
  remains the active design space for now.
- Avoid naming a future downstream SDK repo `VybLang/Vyb` if `rickenator/Vyb`
  remains the upstream compiler repo; prefer names like `VybLang/sdk`,
  `VybLang/releases`, or `VybLang/VybLang` to avoid source-of-truth ambiguity.

