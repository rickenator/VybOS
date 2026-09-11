# VybOS model-selection layer (VYBLLM-ARCHITECTURE.md §4/§5 step 4-5) — mapped plan

> Status: CHECKPOINT A + B DONE, verified (2026-09-11). A: `modules/modelselect.vyb`
> + `build/build-modelselect.vyb` — selection + verification core. B: `## models`
> section in the vybconfig model (`ModelReq {role,id}`, parse/serialize/validate/
> diff) + config-driven boot/reload wiring `boot_model(...)` (admin root-gated,
> builder unprivileged). Both run green under `build/vyb` (modelselect 15/15;
> vybconfig incl. models invariants). No real 4B artifact needed: the slice is
> SELECTION + VERIFICATION over signed registry entries, dogfooded with fixture
> records + a fixture tokenizer dir. The real Qwen3-4B swap is VybForge's
> in-progress track; it plugs in as another signed registry entry.
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

### Pinned mechanics (Checkpoint B, 2026-09-11)
- **The gate is a credential token, not an in-repo role enum:** `boot_model` /
  `select_model` take `cred` (caller's credential) + `root_token` (the root
  surface's). `role == "admin"` ⇒ selection/reload only when `cred ==
  root_token`; `is_admin(role)` marks the role root-gated so callers can render
  the privilege boundary. User any-model + builder default pass `cred=""`.
- **Maps onto the capability model as install-time trust-accept:** loading a
  SIGNED model artifact is exactly like smuggling a privileged package
  (trust-accept under a `freedom`/capability boundary, per `bindings/cuda` and
  the #204 gate stack). The root token is HELD ONLY by the root-owned boot/system-
  agent surface; it is never stored in the config, registry, or model records —
  it re-enters via the credentialing path at boot/reload time (same convention as
  seeds: caller-supplied, scaffold/test fixtures only, never the runtime).
- **Boot ordering:** VybOS boots → `boot_model(cfg, "admin", …)` loads `models.admin`
  by default (root cred). If a user later loads another model (a signed registry
  entry), returning to admin is the same call with a fresh root `cred` — refused
  without it. `models.builder` is VybForge's default (unprivileged within VybOS when
  Forge is included post-bootstrap).

## Checkpoints (each keeps VybOS green under build/vyb)
- **A. Selection + verification core.** `modules/modelselect.vyb`:
  role->model assignment matching, registry replay + record lookup,
  `is_legit_record` verification, `Model{name,dir}` construction, root-gated
  admin path. Proving program `build/build-modelselect.vyb` with FIXTURE
  registry (synthetic seeds/records: admin, builder, a generic user model +
  a tampered record that MUST verify-false) — asserts every selection and both
  an accept and a reject.
- **B. Boot + config wiring.** **DONE (2026-09-11):** `## models` section in
  the vybconfig model (`ModelReq {role,id}`; parse/serialize/validate/diff/
  `find_model`); `boot_model(cfg, role, …)` resolves a role's boot model against
  the signed registry (admin loads by default, root-gated via `cred`; builder
  unprivileged; unassigned role rejected). Root mechanics pinned above. All green
  under build/vyb (modelselect 15/15, vybconfig incl. models invariants).
