# VybLLM — shared Vyb stdlib model-runtime engine (architecture)

> Status: DESIGN (2026-09-11). The engine is a VYB STDLIB MODULE built once and
> consumed by BOTH VybOS and VybForge (both already build/run against the Vyb
> stdlib). Each deployment owns its OWN tuned 4B default model; users of VybOS
> may load any model, with on-demand admin reload guarded as a root-level
> privilege. Boot: VybOS loads the admin model by default.

## 1. Ownership (corrected)

The inference engine does NOT live in VybOS (it is not an OS-hosted service for
VybForge) and does NOT live in VybForge (it is not VybForge's private
substrate). It lives ONCE in the Vyb standard library and is shared:

```
Vyb stdlib  (stdlib/vllm/)  <-- the engine, built once, available to both
        |                        consumers resolve it from the same stdlib
        |
   +----+-----------------+
   |                      |
VybOS                 VybForge
  -> admin-tuned 4B      -> os-builder-tuned 4B
     (boot default)         (its own default model)
  -> users may load any model
  -> on-demand admin reload = root-level privilege
```

Both repos step against the same Vyb toolchain/stdlib, so the engine lands in
`Vyb/stdlib/vllm/` and both consume it with zero code duplication. This is the
same relationship VybOS/VybForge already have to `stdlib/chain` (the signed
ledger core both use): one canonical module, two consumers.

## 2. The engine module (`stdlib/vllm/`) — PORTABLE CPU core

Model-agnostic runtime, behind a stable typed facade. **Checkpoint milestone
(2026-09-11): the stdlib engine is CLOSED as a portable CPU core** (tokenizer +
sampler landed; see decision §7). The GPU surface is NOT stdlib-folded.

```vyb
import vllm::{encode, encode_str, decode_ids, filter_probs, SampleSet}
ids<Vec<Int>> = encode("Hello world")          # [9707, 1879]
ss<SampleSet> = filter_probs(logits)           # renormalized kept (id, prob)
```

Landed pieces (relocated byte-identical from VybForge `native/`, which stays
the origin/R&D home):
- `tokenizer/` encode + decode (reads model artifacts from `VYB_LLM_DIR`)
- `sampler/` filter_probs (temperature + top_k + top_p + renormalize)

NOT in the engine (see §7): the GPU kernels, GGUF drivers, and tensor wrapper
stay as Vyb bindings / VybForge native — they are the hardware/capability
surface, consumed as bindings, not folded into the portable stdlib module.

Nothing Qwen-configurator-specific (SystemSpec contract, interview flow) is in
the engine; that stays in VybForge and calls `llm::`.

## 3. GPU capability seam — `bindings/cuda` IS the seam (decided)

The unsafe `freedom` libcuda FFI (raw driver handles, `loc`/`from`/`addr`,
`loc<CVoid>`) is confined to ONE place — `Vyb/bindings/cuda/cuda_binding.vyb` —
already declared with the #204 package boundary (P3):

```toml
[mod]
boundary = ["freedom"]
capabilities = ["ffi", "cuda-driver", "nvptx"]
```

Both VybOS and VybForge consume this posted binding cross-repo (VybForge's
`native/tensor/tensor.vyb` imports it via `--module-path $(VYBDIR)/bindings/cuda`).
On inspection (checkpoint 3, 2026-09-11) it turns out NO separate `vygpu.vyb`
needs extracting — the seam is already this binding. Reuses the #204 gate
stack (smuggle-only at build, trust-accept at install). Importer modules never
inherit lexical `freedom`. A future CPU path is a swap behind this seam, not a
rewrite.

## 4. Models: per-deployment defaults + user-loaded any-model

Models are content-addressed, signed artifacts (reuse the VybChain registry:
a model = a signed package-record). What changes per consumer:

- **VybOS default = the VybForge admin-tuned 4B** (the Qwen LoRa we train). On
  **boot**, VybOS loads the admin model, so OS agent/automation has inference
  from the start. Config: `models.admin = <signed artifact>`.
- **VybForge default = the os-builder-tuned 4B** (its own tuned model for the
  configurator/desired-state work). Config: `models.builder = <signed artifact>`.
- **VybOS users may load any model** — generic LLM, vision, MTP, third-party.
  Loading a model is adding a signed registry entry, not code.

### On-demand admin reload (root-level privilege)

Because users may occupy the inference surface with another model at runtime,
returning to the admin model is an **on-demand load**. That load is a
privileged action (it re-establishes VybOS's own trusted agent), so it is
guarded as a **root-level privilege** — not an ordinary user action. This maps
naturally onto the capability model: loading a signed model artifact is like
smuggling a privileged package (trust-accept under a capability boundary), and
the singleton system-agent surface is root-owned.

Boot ordering: VybOS boots -> loads admin 4B by default -> normal operation.
If a user later loads another model, returning to admin is the privileged
on-demand reload.

## 5. Migration plan (checkpointed, behavior-neutral each step)

1. **Create `Vyb/stdlib/vllm/`** — relocate the engine pieces from VybForge
   `native/` into the stdlib module behind the `llm.vyb` facade. No behavior
   change. **[DONE — checkpoint 1: tokenizer (PR #242); checkpoint 2: sampler
   (PR #243); both relocated byte-identical, artifact paths decoupled behind
   `VYB_LLM_DIR`, verified exact cross-repo from VybForge (probes in VybForge
   `native/legit/verify_vllm_{tokenizer,sampler}.vyb`), Vyb suite green]**
2. **Keep VybForge green** — VybForge imports `stdlib/vllm` (via the Vyb
   stdlib it already uses), so `make -f native/Makefile verify` keeps passing —
   proving a pure relocate, not a rewrite. **[DONE — cross-repo probes green]**
3. **GPU boundary — `bindings/cuda` is the seam (decided 2026-09-11).** On
   inspection, the `vygpu` freedom seam ALREADY exists as `Vyb/bindings/cuda`
   (`cuda_binding.vyb` = raw libcuda FFI decls, manifest `[mod]
   boundary=["freedom"]` per #204 P3), consumed cross-repo by both consumers.
   So there is NO separate `vygpu.vyb` to extract, and the GPU kernels (NVPTX
   device modules, PTX/RTX-only) + GGUF drivers stay as Vyb bindings / VybForge
   native respectively. **`stdlib/vllm` is therefore a PORTABLE CPU engine**
   (tokenizer + sampler) — the GPU surface is a binding the OS/Forge consume,
   not stdlib-folded. **[DECIDED — see §7]**
4. **VybOS boot** wires `models.admin` (admin 4B) load + the root-privileged
   on-demand admin reload (capability-guarded); **VybForge** wires
   `models.builder` (os-builder 4B).
5. **VybOS user any-model loading** via the signed model registry
   (`vyllmcfg`-style selection on top of packagerecord/ledger).

Each checkpoint finish keeps the owning repo green (Vyb suite, VybOS module
suite, VybForge `make verify`) per the checkpointed-execution convention.

## 7. Decision: the stdlib engine is the portable CPU core (2026-09-11)

Checkpoint 3's original plan — "extract `vygpu.vyb` + fold GGUF loader and GPU
kernels under `llm::`" — was revised after inspecting the actual code:

- **The vygpu freedom seam already exists** as `Vyb/bindings/cuda`
  (`cuda_binding.vyb` + `boundary=["freedom"]` manifest, per #204 P3). It is the
  single shared FFI seam both consumers already use cross-repo. Extracting a
  duplicate `vygpu.vyb` into stdlib would split the seam, not centralize it.
- **The GGUF files are main-level verification DRIVERS** (hardcode fixture/host
  paths, I/O in main), not reusable libraries; there is no committed `.gguf`
  fixture to verify a relocated loader against.
- **The GPU kernels are NVPTX device modules** (compile `--kernel` → PTX, run on
  RTX 3090) — not portable-stdlib material and only hardware-verifiable.

**Consequence: `stdlib/vllm` is closed as a PORTABLE CPU ENGINE** holding the
tokenizer + sampler. The GPU surface (cuda_binding, kernels, tensor wrapper,
real GGUF loader) stays where the hardware/capability boundary already lives:
Vyb bindings + VybForge native, consumed cross-repo. The engine's versioning
and doc are final for this slice; a future `llm::` facade / model-registry layer
sits on top without moving the GPU code.

## 6. Open / deferred

- GPU inference routing — the OS/Forge consume `bindings/cuda` (+ VybForge
  native kernels/tensor) as bindings; a higher-level `llm::` layer composes the
  CPU (vllm) + GPU (bindings) paths. **[Model facade landed 2026-09-11 — the
  portable CPU core now exposes `Model`/`model_load`/`model_encode`/
  `model_decode`/`model_sample` with per-model tokenizer dirs (PR #244),
  verified cross-repo from VybForge; a GPU-composing `llm::` forward remains
  the hardware-bound half]**
- Real Qwen3-4B swap-in (VybForge in-progress) proceeds independently; the
  closed engine does not block it.
- Exact privilege mechanics for root-level admin reload (how "root" is
  expressed in-repo) — to be pinned when wiring model selection.
