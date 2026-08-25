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
| `mk_service(name, command) -> Service` | enabled service entry |
| `with_pkg(m, p) -> Module` / `with_service(m, s) -> Module` | pure appenders |
| `blank_system(system, hostname) -> SystemSpec` | empty base to compose onto |
| `compose(base, mods) -> SystemSpec` | fold modules (pure, ordered) |
| `compose_issue(spec) -> String` | validation gate ("" = clean) |
| `pkg_index` / `service_index` | lookup helpers |

## Status / next

Implemented and verified on the isolated `Vyb-vybos` toolchain. The convention
is already wired into the transition pipeline: `build/build-apply.vyb` composes
a *current* and *desired* machine from modules, gates them with
`compose_issue`, and produces a deterministic `plan_lines()` diff
(install/keep/remove) keyed by closure-aware store identities — the `vyb
system apply` dry-run. Next natural step: teach the realizer
(`build/build-closure.vyb`) to execute that plan against a module-composed
`SystemSpec` (it already validates via `plan.resolve_issue`); the convention,
the graph framework, and the planner share the same `plan.vyb` types by
construction, so this is a wiring change, not a new model.
