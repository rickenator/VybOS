# Adaptive Source Patching — lifecycle + provenance (issue #7)

> Status: DESIGN + CORE LIFECYCLE IMPLEMENTED (2026-09-11). The patch-class
> lifecycle, repair escalation order, high-risk guardrails, and deterministic
> patch-set fingerprint are implemented and proven in `modules/patchlife.vyb`
> (28 checks via `build/build-patchlife.vyb`). This doc records the architecture
> #7 asks to define; the follow-on (sealing patches into realization records,
> real build-failure -> model-repair loop, VybForge build-record integration)
> is tracked below.

## Principle

> **AI may author a repair, but VybForge owns, validates, hashes, records,
> reproduces, and promotes the patch.**

A generated patch is a first-class immutable build artifact with full
provenance — never an invisible mutation of the source tree. The model authors
a *proposal*; VybForge decides whether to accept it, and once accepted it is
sealed into the realization record so a rebuild applies the exact stored patch
instead of re-running inference.

## Pipeline

```
upstream source repo/tag/commit
        -> verified pristine source (content hash)
        -> patch assembly (ordered, classified)
             upstream | curated VybOS | generated (model+prompt/response provenance)
        -> configure / build
        -> package tests
        -> VybOS integration validation
        -> candidate realization
        -> promotion lifecycle (experimental -> candidate -> reviewed -> submitted -> retired)
```

## Patch classes

1. **upstream** — a fix already accepted upstream / a specific upstream commit.
2. **curated** — a reviewed, versioned VybOS-specific patch maintained here.
3. **generated** — a narrowly scoped patch authored during assembly for a
   specific source-revision/toolchain/arch/platform combination, possibly by a
   local in-OS model (e.g. a Qwen MoE).

## Promotion lifecycle (`modules/patchlife.vyb`)

State machine over `experimental -> validated-candidate -> reviewed -> submitted
-> retired`:

- a **generated** patch enters `experimental`, must gather build+test evidence
  to become `validated-candidate`, needs **human review** for `reviewed`, and
  may then be `submitted` upstream; `retired` once upstream no longer needs it.
- **curated** patches start already-`reviewed` (VybOS vetted) and may be
  `submitted` / retired.
- **upstream** patches start `submitted`.
- Retired is terminal; illegal jumps (e.g. `experimental -> reviewed`) rejected.

`promote(p, target)` is **value semantics** — the caller's patch is untouched,
`can_promote`/`promotable` gate every move.

## Repair escalation order

Prefer the existing trusted fix before invoking generation:

1. pristine upstream builds -> 2. curated VybOS patch applies -> 3. known
   upstream fix exists -> 4. model proposes a generated patch -> 5. build +
   test + integration validation -> 6. accept or require human review.

`escalate(curated_ok, upstream_ok, high_risk)` returns which path to take:
`curated` > `upstream` > (`human` if the surface is high-risk) > `generate`.

## Guardrails

High-risk surfaces (crypto, auth, privilege boundaries, kernel security code,
memory-safety-sensitive parsers, storage/filesystem correctness, destructive
paths) **may never be auto-promoted** past a candidate to reviewed/submitted —
they require human intervention regardless of build success. A successful build
is not sufficient evidence for these classes.

## Provenance record

The sealed package record (`modules/packagerecord.vyb`) already carries each
patch's content hash + classification + generator/model identity +
prompt/response. `patchset_fingerprint` (this module) adds an order-independent
deterministic identity over the whole managed patch set, for the realization
record. Combined: a realization reproduces by applying the exact stored,
fingerprinted, sealed patches — never by re-running the model.

## Implemented (2026-09-11)

- `modules/patchlife.vyb` — states/transitions, escalation, guardrail, fingerprint.
- `build/build-patchlife.vyb` — 28 checks prove the lifecycle, escalation order,
  guardrail, and fingerprint determinism/order-independence.
- `modules/packagerealization.vyb` — seals the ACCEPTED, state-tagged patch set
  into an AUTHENTIC signed realization record (realization_identity = sha256 of
  the sorted accepted patches; only `is_legally_sealable` patches pass, so an
  unreviewed or high-risk-unapproved patch can never be sealed as accepted).
- `build/build-packagerealization.vyb` — 11 checks prove a reviewed generated
  patch + curated patch seal into an authentic realization, unreviewed /
  high-risk patches are refused, signature-gate tamper rejects, and identity is
  order-independent.
- `modules/repair.vyb` + `build/build-repair-loop.vyb` — the ADAPTIVE REPAIR
  LOOP core (10 checks): apply a generated minimal `-old/+new` diff in place,
  re-hash the patched source, run build/test + integration validation gates,
  auto-accept only a low-risk repair (high-risk -> human), refuse non-applying /
  no-op / test-failing patches — and seal the accepted patch into the authentic
  realization record (exact reproduction). MODEL BOUNDARY: the proposal is a
  caller-supplied `PatchProposal` (the in-OS model lives in VybForge; pure Vyb
  JIT can't invoke it) — this module owns apply/validate/promote/seal
  downstream of the model.

## Open follow-ons (split from #7 once the realization model stabilizes)

- Seal the patch set into a `packagerecord` PackageRealization (patch class +
  hash + state + reason sealed per patch).
- Real build-failure -> constrained-repair-context -> model-proposes-diff ->
  apply -> rebuild -> validate loop (driver, not the pure lifecycle core).
- VybForge build-record posting to the shared ledger (ties the two repos).
- Promotion criteria from generated -> curated; upstream-replacement detection;
  near-identical generated-patch dedup.
