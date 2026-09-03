# VybOS Module Composition Convention

> Status: implemented (2026-08-24) · framework in `modules/compose.vyb` ·
> self-test in `build/build-compose.vyb` · executable here: `config/system.vyb`.

This is the *how `modules/*` combine* piece of VybOS (the NixOS
`options`/`config` idea carried into vybey — minus the interpreter). There is
**no meta-DSL**: a "module" is a typed Vyb function, and composition is a pure
fold over the functions' contributions.

## The convention

1. **A module is a `.vyb` file in `modules/`** exporting one or more
   `share(all)` *contribution functions*. Each takes the module's **own
   options** (typically at least `enabled<Bool>`, plus any tuning params) and
   returns a `Module` — a typed value carrying zero or more `Pkg`s and zero or
   more `Service`s.
2. **Build the contribution with the constructor kit** from `compose.vyb` —
   `empty_module()`, then `with_pkg` / `with_service` (or hand the pkgs in
   directly). A module never reaches past into `plan.vyb` internals and never
   builds raw `Pkg`/`Service` literals on its own; it uses `mk_pkg` /
   `mk_service` / `dep` so store paths stay content-derived and dependency
   kinds stay `select`-validated.
3. **"Off" returns the empty module.** An `enabled=false` (or disabled)
   module returns `empty_module()` — contributing nothing. Toggling a module
   on/off is therefore a one-line call-site edit (`true` → `false`), exactly
   the NixOS `enable = true/false` feel.
4. **Composition is a fold.** `compose(base, mods<Vec<Module>>)` concatenates
   every module's pkgs and services onto the base `SystemSpec` in module
   order. It is pure (builds fresh aggregated `Vec`s — Vyb's nested in-place
   accessor mutation is a no-op) and deterministic.
5. **Validate before realising.** `compose_issue(spec)` returns a non-empty
   String if the merged system is invalid — duplicate package name, duplicate
   *enabled* service, unknown dependency, or dependency cycle (the last two
   delegate to `plan.resolve_issue`). A realizer/activator MUST check this gate
   before any side effect. Disabled services are exempt from the duplicate
   check (they don't activate).

## Why a function, not an options table

NixOS needs a declarative `options`/`config` slab because Nix has no type
system and module code must be *interpreted* against declared options. VybOS
config *is* a JIT program, so a module is just a function: its parameters *are*
its options, and Vyb's real type checking replaces the options schema. There is
nothing to interpret — the call site is the declaration.

## A module looks like this

```vyb
// modules/sshd.vyb
import collections
import compose::{Module, empty_module, mk_pkg, mk_service, with_pkg, with_service}

share(all)
sshd(enabled<Bool>)<Module> -> {
    m<Module> = empty_module()
    if (enabled) {
        m = with_pkg(m, mk_pkg("openssh", "9.8",
            "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.8p1.tar.gz",
            Vec()))
        m = with_service(m, mk_service("sshd", "/run/current-system/sw/sbin/sshd"))
    }
    return m
}
```

A module may add packages only (`modules/vim.vyb`), services only
(`modules/getty.vyb`), or both. Dependencies are added with `dep(name, kind)`
where `kind ∈ {build, runtime, host}` — validated by the `select` set-pattern
classifier in `plan.vyb`.

## Composing a machine

`config/system.vyb` declares which modules run and with what options, folds
them, validates, then emits the spec:

```vyb
mods<Vec<Module>> = Vec()
mods.push(sshd(true))
mods.push(getty(true))
mods.push(vim(true))
base = blank_system("x86_64-linux", "vybos-test")
spec = compose(base, mods)
issue = compose_issue(spec)          // "" == clean; abort if non-empty
println(spec.to_string())            // clean nested JSON (the machine contract)
```

## Invariants it holds (see `build/build-compose.vyb`)

1. Folding N modules concatenates exactly their pkgs + services, in order.
2. `enabled=false` contributes nothing (no-op toggle).
3. Composed store paths are content-derived (`mk_pkg` → `realize_hash`) and
   deterministic across runs.
4. Duplicate package names and duplicate *enabled* service names are detected
   by `compose_issue` before realisation.
5. Disabled services are not flagged as conflicts.

## Framework surface (`modules/compose.vyb`)

| Symbol | Meaning |
| --- | --- |
| `empty_module() -> Module` | identity contribution ("disabled") |
| `dep(name, kind) -> Dep` | typed dependency edge |
| `mk_pkg(name, version, source, deps) -> Pkg` | content-addressed package |
| `mk_service(name, command) -> Service` | enabled service entry (no options) |
| `mk_service_opts(name, command, port, args) -> Service` | enabled service WITH options (M3 deepening) |
| `with_pkg(m, p) -> Module` / `with_service(m, s) -> Module` | pure appenders |
| `blank_system(system, hostname) -> SystemSpec` | empty base to compose onto |
| `compose(base, mods) -> SystemSpec` | fold modules (pure, ordered) |
| `compose_issue(spec) -> String` | validation gate ("" = clean) |
| `pkg_index` / `service_index` | lookup helpers |

## Service options (M3 deepening)

A `Service` is no longer a bare on/off switch: it carries **`port<Int>`**
(the declared listening port, `0` = none) and **`args<Vec<String>>`** (extra
argv the activator appends after `command`). Modules opt in via
`mk_service_opts` — the plain `mk_service` is now a thin wrapper over it with
`port=0`, `args=[]`.

```vyb
// modules/nginx.vyb — declares port 80 + foreground argv
ngArgs<Vec<String>> = Vec()
ngArgs.push("-g"); ngArgs.push("daemon off;")
m = with_service(m, mk_service_opts("nginx", "/run/current-system/sw/sbin/nginx", 80, ngArgs))
```

The options flow end-to-end: the composed spec (visible in `system.json` and
`spec.to_string()`), the human-readable listing in `config/system.vyb`, the
generated `/etc/vyb-os/services.sh` activator (which runs `command` + `args`),
and the init banner (`nginx port=80`). `port` is supervisor metadata — it is
*not* part of the argv.

**Field-order caveat (Vyb#215):** `plan.Service` declares `enabled<Bool>`
FIRST. A Vyb toolchain bug (rickenator/Vyb#215) makes `to_string()` emit
garbage for any `Int` field that follows a `Bool` field at index ≥ 1;
bool-first serializes cleanly. Do not reorder the fields until the compiler
fix lands (regression probe: `build/build-compose.vyb` invariant 9,
repro/workaround probes `build/probe-bool-matrix.vyb` /
`build/probe-bool-first.vyb`).

## Status / next

Implemented and verified on the isolated `Vyb-vybos` toolchain. The convention
is already wired into the transition pipeline: `build/build-apply.vyb` composes
a *current* and *desired* machine from modules, gates them with
`compose_issue`, and produces a deterministic `plan_lines()` diff
(install/keep/remove) keyed by closure-aware store identities — the `vyb
system apply` dry-run. The execution half is `modules/realize.vyb` — the
shared realizer core (promoted out of `build/build-closure.vyb`): closure
identity (`real_table`), topological order, and the fetch → content-hash →
write `.src` + `.drv`-style `.meta.json` loop, plus `closure_real(spec, name)`
for verifying expected store paths. `build/build-exec.vyb` drives it against a
module-composed desired spec (compose → gate → plan → realise); all execution,
apply, and composition invariants PASS on the isolated Vyb-vybos toolchain.

Next natural step: teach the *real* URL-driven fetch path (build-package-url)
to serve a module-composed spec, so the realizer can realise genuine HTTPS
sources (github tarballs per the RFE-M2 testing note) instead of the
deterministic local mirror — a wiring change, since everything shares the same
`plan.vyb` / `realize.vyb` types.

**Added:** `modules/urlrealize.vyb` provides `fetch_url()` — parses a package's
own `source` URL with `url_split` and selects the transport by scheme
(`http` → `http_get_full`; `https` → `https_get_full_verified` with the system
CA) — and `realize_spec_url()` realises a whole spec from each package's real
URL. `build/build-url-realize.vyb` drives it: one package, a real GitHub-raw
`https://...` source, fetched over verified TLS, content-addressed, written to
the store. 9 invariants PASS on the isolated toolchain. This is the RFE-M2 note
realised: genuine HTTPS access to files, actually built into the store.
