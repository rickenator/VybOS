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

## 2. The engine module (`stdlib/vllm/`)

Model-agnostic runtime, behind a stable typed facade:

```
llm.load(path)                                     -> Model        (GGUF + tokenizer)
llm.encode(model, text)                            -> Vec<Int> ids
llm.decode(model, ids)                             -> text
llm.chat(model, messages, {temp,top_k,top_p,seed}) -> completion
```

Implementation pieces (migrated from VybForge `native/`, which stays the
origin/R&D home):
- `kernels/` gemm, rmsnorm, vmath, q4k/q6k/q4_0 (GPU, inside `freedom`)
- `gguf/` parse, read_real_meta, dequant
- `tokenizer/` encode + decode
- `tensor/` ctx / PTX-load / dev-buffer / gemm+rmsnorm ops
- stack, decode, sampler

Nothing Qwen-configurator-specific (SystemSpec contract, interview flow) is in
the engine; that stays in VybForge and calls `llm::`.

## 3. GPU capability seam

All unsafe `freedom` libcuda FFI (raw driver handles, `loc`/`from`/`addr`,
`loc<CVoid>`) is confined to ONE module (e.g. `stdlib/vllm/vygpu.vyb`) declared
with the #204 package boundary:

```toml
[mod]
boundary = ["freedom"]
capabilities = ["ffi", "cuda-driver", "nvptx"]
```

Mirrors `bindings/cuda` and reuses the #204 gate stack: smuggle-only at build
(P0), trust-accept at install/consume (P2). Importer modules never inherit
lexical `freedom`. A future CPU path is a swap behind this seam, not a rewrite.

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
3. **Extract `vygpu.vyb`** with `[mod] boundary=["freedom"]`; route kernel
   entry points through it. Includes folding the GGUF loader + GPU kernels
   under `llm::` (the GGUF parse files in VybForge are currently verification
   DRIVERS, so the reusable loader form lands here).
4. **VybOS boot** wires `models.admin` (admin 4B) load + the root-privileged
   on-demand admin reload (capability-guarded); **VybForge** wires
   `models.builder` (os-builder 4B).
5. **VybOS user any-model loading** via the signed model registry
   (`vyllmcfg`-style selection on top of packagerecord/ledger).

Each checkpoint finish keeps the owning repo green (Vyb suite, VybOS module
suite, VybForge `make verify`) per the checkpointed-execution convention.

## 6. Open / deferred

- CPU (non-GPU) inference — swap behind `vygpu` seam, not built now.
- Real Qwen3-4B swap-in (VybForge in-progress) proceeds independently against
  `llm::`; the move does not block it.
- Exact privilege mechanics for root-level admin reload (how "root" is
  expressed in-repo) — to be pinned when wiring step 4.
