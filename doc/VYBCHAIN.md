# VybChain — cryptographic package ledger (issue #8 design & status)

> last_updated: 2026-09-04. Source of truth for the VybChain effort:
> `rickenator/VybOS` issue **#8** (spec + acceptance criteria) and **#7**
> (adaptive source patching / provenance — the VybForge-side half). This doc
> is the VybOS-side design, tracking, and current-status record.
>
> **STATUS 2026-09-11:** the signature layer is LIVE. Vyb stdlib/chain now has
> `SignedChain` (+ `signed_genesis/signed_append/signed_verify`, in-ledger key
> rotation, `sign/verify_checkpoint`) back by stdlib/crypto Ed25519 (RFC 8032
> verified). VybOS `modules/bootlegit` now offers AUTHENTIC boot legitimization:
> `seal_boot_signed` / `is_legit_signed` (registry-root anchored, signature-gate
> tamper rejection) + `sign/verify_boot_checkpoint`, proven by
> `build/build-bootlegit-signed.vyb` (all 8 checks pass). It is also wired into
> **VybForge `forge_legit`** (AUTHENTIC package provenance: `forge_legit_signed.vyb`,
> 8 prove it) and **VybOS's content-addressed store index** (`modules/storeindex.vyb`:
> a deterministic signed state root over the store's objects, 10 checks prove
> it). The **domain-operation ledger** (`modules/ledger.vyb`) now models the full
> §2 operation set — publish/promote/revoke/yank/replace_key/checkpoint — each a
> SIGNED block with state DERIVED by replay from genesis (22 checks prove it).
> **Verify-before-install** (`modules/verifyinstall.vyb`) is the §5 resolver gate:
> trusted chain segment via registry checkpoint -> artifact audit (published,
> not revoked/yanked, content hash == ledger record) -> construct+verify the
> system state root -> roll back to a prior verified root (13 checks prove it).
> All five slices dogfood the same stdlib/chain SignedChain.

## 1. What it is

A tamper-evident, **signed** ledger engine written entirely in Vyb
(vybey), layered under VybOS package management. Every accepted package
artifact carries verifiable provenance: upstream source + exact revision,
pristine-source hash, ordered patch set with classification (upstream /
curated / AI-generated, with generator provenance), build environment,
validation results, dependency closure, and the final content-addressed
artifact hash — each step a deterministic, signed record hash-linked to the
previous one. Complete package/system states are identified by a
deterministic **state root**, enabling offline verification, checkpoints,
and rollback to a previously verified state.

Naming (per the issue): **VybChain** = the general native-Vyb engine
(`stdlib/chain` + `stdlib/crypto` primitives in the Vyb repo). The
VybOS-facing feature is the **cryptographic package ledger backed by
VybChain**. It is a provenance/trust-history structure — **not** a
currency: no tokens, no mining, no consensus, no network requirement for a
standalone installation.

## 2. Cleanroom port principle

The reference implementation is `rickenator/rust_chain` (educational
blockchain, 6 Rust files, ~582 LOC, deps: chrono/sha256/sha2/digest/
serde/serde_json). **Cleanroom port**: its *concepts* are the port target —
SHA-256 hash-linked blocks, Merkle root (odd-leaf self-pair),
mempool→block batching, JSON persistence, full-chain validation, Merkle
proofs — while the Vyb implementation is written fresh in vybey style
(aspect+bind, ownership types, `select`), not translated line-by-line.
`rust_chain`'s own transaction model (sender/receiver/amount, cryptocurrency
framing) is dropped: VybChain transactions are **deterministic domain
operations** (`publish`, `promote`, `revoke`, `yank`, `replace_key`,
`checkpoint`), each with deterministic serialization and validation rules.

## 3. Core model (in flight, verified)

Landed in the Vyb repo as **`stdlib/chain`** (plus
`test/modules/test_chain.vyb`) — one shared core, three consumers
(VybOS package/boot legitimization, VybForge build records,
smuggled-dependency receipts):

```
Record       { label<String>, value<String> }        one fact to seal
ChainBlock   { index, prev_hash, root, hash, records }
Chain        { origin, blocks }

root  = Merkle root over the block's records
        (per-record sha256(label="value"); adjacent digests pair-folded,
         odd leaf pairs with itself; empty -> sha256(""))
hash  = sha256(index | prev_hash | root)
prev  = previous block's hash (block 0 links to the chain origin marker)
```

API: `new_chain`, `append` (value semantics — the input chain is untouched),
`verify` (recomputes every root/hash/prev-link; any tamper with a record,
its order, or a link breaks it), `tip_hash` (the legitimizing token),
`contains`, `record_count`, `to_text`, plus the `block_root`/`block_hash`/
`record_digest` building blocks.

**Verified 2026-09-04 (real runs, toolchain @ Vyb `6d89575`):**

- seal → `verify` on genesis ✓; `append` + prev-link check + `record_count`
  / `contains` ✓
- **determinism**: sealing the same facts twice yields the same 64-hex tip ✓
- **checkpoint round-trip**: `to_string()` → `Chain.from_string()` re-
  verifies with an identical tip ✓ (this is the export/import primitive a
  clean machine needs)
- read/verify/append/round-trip flows are all crash-free

## 4. Security model — where it stands

**Current core = integrity, not authentication.** The docblock says it
plainly: the `origin` marker is a shared constant, so *anyone can forge a
chain that verifies*. That is a deliberate seam, but it does not yet meet
issue #8's "must be secure" bar (reject invalid signatures, key rotation in
the ledger, registry-signed checkpoints).

**Required increment: the signature layer**, designed on the same records:

1. **Signatures in `stdlib/crypto`** — the primitives belong next to
   `sha256`: `ed25519` keygen/sign/verify as C-runtime helpers behind thin
   Vyb wrappers (same pattern as `__vyb_sha256_hex`). Ed25519 is the
   recommended scheme (small fixed keys/sigs, no domain parameters, fast
   verify). Pure-Vyb field math is a fallback/dogfood option, not the
   production path. (Scheme choice still open to Rick; ECDSA-P256 is the
   interop alternative.)
2. **Keyed origins** — a chain's `origin` becomes a *keyed authority id*
   (e.g. `vybforge/forge-1` bound to a public key). `verify(chain, keyset)`
   checks each block's signature against the key current at that height.
3. **`replace_key` in-ledger** — rotation/revocation is a signed record
   *inside* the chain (old key, new key, effective height), never invisible
   mutable state.
4. **Registry checkpoints** — a registry signs a checkpoint record over a
   tip hash + state root; consumers accept a segment they can chain-verify
   up to a signed checkpoint. Multiple registries can replicate/federate
   later without changing the local data model.
5. **Package/system state roots** — deterministic Merkle roots over the
   resolved dependency closure / package set, so a complete state is one
   verifiable hash (rollback = selecting a previously verified state root).

**Package record** (Phase 2, one transaction domain on the core): name /
version / target / namespace; full resolved closure; upstream repo + exact
revision; pristine-source hash; ordered patches + hashes + classification
(upstream / curated VybOS / **generated**, with generator/model identity and
request/response provenance for AI patches); Vyb/compiler/toolchain
versions; build flags + relevant VybOS config; builder identity; test/
validation results; final artifact content hash; prev block hash; state
root; publisher signature + timestamp. Payloads stay in the content-
addressed artifact store — the ledger records identity, derivation,
validation, and trust state only.

**Verification must detect** (acceptance criteria): altered history,
invalid signatures, missing parents, invalid state transitions, and
artifact-hash mismatches.

## 5. VybOS integration (Phase 3)

The resolver/installer gains: resolve closure → verify the relevant chain
segment + trusted checkpoint → fetch artifacts from the content-addressed
store → verify each artifact against its ledger record → construct + verify
the resulting system-state root → refuse untrusted/revoked/mismatched/
historically inconsistent artifacts → roll back by selecting a previously
verified state root. VybForge owns build validation and records the result
(issue #7); VybChain makes the accepted history tamper-evident and
independently verifiable.

## 6. Toolchain blockers (found 2026-09-04, both on pushed `origin/main`)

1. **Nested `Vec.set` write-back heap corruption** — reading a nested
   element (`chain.blocks.get(i).records.get(j)`), mutating the copy, and
   writing it back through the `Vec<ChainBlock>` level corrupts the heap:
   abort at exit (`malloc(): unaligned tcache chunk` /
   `double free or corruption (!prev)`) even when *unmutated*, once a
   `verify()` pass follows; the `test_chain.vyb` tamper cases die this way
   (exit 134). Minimal isolations: `repro/probe_chain_heapcorr.vyb`
   (P13: 1-record block, copy write-back at both levels, then `verify`) and
   the P7/P11/P12 variants in the session probes. Read/verify/append/
   round-trip are clean; only the in-place-mutation pattern crashes.
2. **Copy-semantics probe still fails LLVM verification** — the pre-flight-
   pinned `repro/probe_vyb_copy_semantics.vyb` (HEAD `966a5a6`) aborts on
   *both* toolchains at `6d89575` (`Instruction does not dominate all uses`
   / PHI grouping in `main`). Same bug family as (1); unfixed after the
   #215 field-offset fix.

Both are filed (isolations pinned): (1) → **`rickenator/Vyb#217`** (OPEN, full
repro + variants + workaround); (2) → **`rickenator/Vyb#218`** (OPEN, LLVM
module-verification abort, repro pinned at VybOS HEAD `966a5a6`).
**FIXED + VERIFIED 2026-09-09 in the local Vyb working tree** (pending the
impl agent's commit/push + `sync-os-toolchain.sh`): #217 was a shallow,
ownership-blind whole-`Vec` field assignment (`b.records = rs` stored rs's data
pointer with no clone-on-borrow and no old-buffer release → both owners
free()'d the same buffer at scope exit); fixed in
`LLVMCodegen::visit(AssignmentExpression*)` by deep-copying borrowed-read Vec
RHSes and releasing the outgoing buffer for both var and member destinations
(mirrors the existing `ownedStructAst` value-semantics path). #218 was the
if-expression String type-unification `tryCast` emitted after
`SetInsertPoint(mergeBB)`, landing the wrap above the PHI and referencing a
`%if.else` value; fixed in `visit(IfExpression*)` by running the unification
cast inside the branch's own terminal block before its `br`. Both repro probes
(and `test_chain.vyb`'s previously-dying tamper sections, and the whole
Vec/ownership test corpus) now pass on the rebuilt `build/vyb`.

**Verified workaround** (used by the tamper tests in the meantime): never
do nested `Vec.set` write-back — construct the tampered/derived chain
*bottom-up from values* (fresh `Vec` pushes + whole-value assignment), or
go **through persistence** (parse/`from_string` a tampered JSON document).
Both patterns verified crash-free and correct (`verify` → false on tamper,
true on the original).

## 7. Phase status

| Phase | Status |
|---|---|
| 1 — Port & parity (core engine) | **In flight**: `stdlib/chain` written + core flows verified; acceptance-test tamper cases blocked by §6 codegen bugs (workaround proven); module docs + test landed in the Vyb repo (uncommitted at this writing) |
| 2 — Package ledger (records, signatures, state roots) | **Blocked** on the §4 signature layer: needs `crypto` signature primitives in the Vyb repo (impl-agent RFE) + the §6 fixes |
| 3 — VybForge/VybOS integration | Designed (§5); not started |
| 4 — Replication & federation | Not started (checkpoint exchange defined in §4.4) |

## 8. Open decisions / dependencies

- [ ] **Signature scheme**: Ed25519 (recommended) vs ECDSA-P256 — Rick.
- [x] **File the two codegen bugs** against `rickenator/Vyb` — **DONE**:
      heap-corruption write-back → `#217` (OPEN); copy-semantics LLVM
      module-verification → `#218` (OPEN). Both with pinned repros (§6).
- [x] **Crypto signature RFE** — **IMPLEMENTED + VERIFIED 2026-09-09** in the
      local Vyb working tree (pending impl-agent commit/push): `stdlib/crypto`
      gains `ed25519_publickey(seed)/ed25519_sign(seed,msg)/ed25519_verify(pub,
      msg,sig)` hosted on the `__vyb_ed25519_*` runtime helpers (OpenSSL EVP
      `EVP_PKEY_ED25519`, zero new build deps — the compiler already links
      OpenSSL). Hex key/sig I/O matching sha256's convention; deterministic RFC
      8032 signatures. Verified against the RFC 8032 TEST 1 vector (exact
      public-key + signature match) and tamper/determinism checks. Also filed
      as `rickenator/Vyb#219`. Still needs the impl agent to commit/push;
      VybOS's own safety gates forbid committing the Vyb repo from here.
- [x] `Vec.remove_at`-style nested mutation fixes land → re-enable the
      in-memory tamper test path. **DONE 2026-09-09**: the #217 Vec-assignment
      ownership fix un-blocked it — `test_chain.vyb`'s tamper sections now pass
      in memory (no more persistence-only workaround requirement).
- [ ] AI-patch classification naming: the `generated` classification +
      generator provenance fields are specified but not yet in the record
      type (Phase 2 work).
