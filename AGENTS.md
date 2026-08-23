---
last_edited: 2026-08-23
---

# VybOS Agent Instructions

## Purpose

Build VybOS: a NixOS-like Linux distro whose entire config/build framework is
written in **JIT Vyb**. Agents work here to add/review the vybey framework,
example configs, and build tooling. This repo is Rick's design space; the Vyb
compiler itself lives in its own repo (`/usr/export/rick/Projects/Vyb`) and is
touched only by its implementation agent.

## Source Of Truth

1. `README.md` — goal, status, conceptual shape.
2. `GOAL.md` — the long-running objective and acceptance criteria.
3. `AGENTS.md` — these instructions.
4. `doc/` — design notes as they are written.
5. References to Vyb semantics: `/usr/export/rick/Projects/Vyb/docs/refman/PROGRAMMERS_GUIDE.md`.

## Commands

```sh
# Vyb prerequisite (Vyb repo, not this one):
cd /usr/export/rick/Projects/Vyb && cmake --build build
# run a Vyb program via the JIT:
/usr/export/rick/Projects/Vyb/build/vyb path/to/file.vyb
# this repo (when the framework exists):
#   vyb --jit build/system.vyb
```

## Safety Gates

- Do NOT modify or commit the Vyb compiler repo
  (`/usr/export/rick/Projects/Vyb`) from here — that is the implementation
  agent's territory.
- No external side effects (pushing to GitHub, publishing images, running
  build/activation against the host) without Rick's explicit approval. Nothing
  in this repo may touch the host machine's real system.
- Keep changes small and reversible; this is bootstrap-phase design work.
- Use Vyb terminology: **vybey** (the language), **vybish** (its style).

## Local Conventions

- Config programs live in `config/`, reusable framework pieces in `modules/`,
  build plumbing in `build/`, design notes in `doc/`.
- Prefer dogfooding Vyb's constructs (aspect+bind, `select` set-patterns,
  monomorphs, ownership types) over mechanical boilerplate — VybOS is both a
  product and a showcase of the language.
- Author new Vyb code with sample `.vyb` files runnable under `build/vyb` so
  claims of "works" are backed by real output, not prose.
