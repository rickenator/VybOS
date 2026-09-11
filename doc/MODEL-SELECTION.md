# VybOS model-selection layer (VYBLLM-ARCHITECTURE.md §4/§5 step 4-5) — mapped plan

> Status: CHECKPOINT A DONE, verified (2026-09-11). `modules/modelselect.vyb` +
> `build/build-modelselect.vyb` run 10/10 assertions PASS under `build/vyb`
> (fixture signed registry: admin/builder/user models + tamper/revoke/wrong-key/
> root-gate rejects). Checkpoint B (config + boot wiring) is the forward slice.
> No real 4B artifact needed: the slice is SELECTION + VERIFICATION over signed
> registry entries, dogfooded with fixture records + a fixture tokenizer dir. The
> real Qwen3-4B swap is VybForge's in-progress track; it plugs in as another
> signed registry entry.
>
> Steering: VybOS issue #9. Engine facade already landed (stdlib/vllm Model).

## Goal
Given a config of model assignments — `models.admin`, `models.builder`, and
user-loaded any-model — resolve each role to a SIGNED model registry entry,
verify it is authentic (signed_verify + record_root under the registry pubkey),
and produce the `Model{name, dir}` the stdlib/vllm facade loads (per-model
tokenizer dir). Admin load / on-demand admin reload is ROOT-GUARDED; user
any-model load is unprivileged.

## Model = signed package-record (reuse, no new crypto)
A model IS a signed `ModuleRecord` on the `stdlib/chain` core:
- `packagerecord.vyb` seals the full record (name@version, artifactHash =
  the model's content hash, publisher Ed25519 sig) -> `seal_module_record`.
- `ledger.vyb` replays publish/promote/revoke/yank over that registry.
- Selecting `models.admin` = resolve id -> active published ModuleRecord ->
  verify `is_legit_record` under the registry pubkey -> build
  `Model{name, dir}` where `dir` = the model's content-addressed store path
  (`store/models/<name>-<ver>`, mirroring storeindex's address scheme).

## Root-guarded admin reload (the open design item to pin)
On-demand admin reload re-establishes VybOS's own trusted agent, so it is a
privileged action. Representation (recommended, no new machinery): a
capability classifier on the selection call — `select_model(role, cfg, cred)`
where an admin role requires an explicit root credential token (analogous to
the freedom/trust-accept capability gate); a user role passes the default
(non-root) credential. Kinds: "admin" (boot default + root-gated reload) vs
"user" (unprivileged any-model).

## Checkpoints (each keeps VybOS green under build/vyb)
- **A. Selection + verification core.** `modules/modelselect.vyb`:
  role->model assignment matching, registry replay + record lookup,
  `is_legit_record` verification, `Model{name,dir}` construction, root-gated
  admin path. Proving program `build/build-modelselect.vyb` with FIXTURE
  registry (synthetic seeds/records: admin, builder, a generic user model +
  a tampered record that MUST verify-false) — asserts every selection and both
  an accept and a reject.
- **B. Boot + config wiring.** `models.admin`/`models.builder` in the vybconfig
  model; boot loads admin by default; user any-model path; pin exact root
  mechanics against the capability model.
