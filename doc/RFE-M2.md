# RFE — VybOS M2: primitives to build a real dependency graph

> **Tracking:** filed as `rickenator/Vyb` **#195**, now CLOSED (2026-08-26):
> items 1–2 (mkdir, SHA-256) landed in the stdlib; items 3–4 carried
> framework-side. https://github.com/rickenator/Vyb/issues/195. Cross-link
> from STATUS §3.

Forward this whole file to the Vyb implementation agent. Every item is
self-contained: goal, verified current state (exact file:line), numbered
requirements, acceptance line. Companion project: `~/Projects/VybOS`
(NixOS-style distro whose build/config framework is written in JIT Vyb).

Verified build: `build/vyb` at `/usr/export/rick/Projects/Vyb`, JIT default,
stdlib modules present: `agents asyncs channels collections core curses env
http https io network process qt rand regex tasks term threads time tls utf8`.

---

## Item 1 — `mkdir` runtime primitive (P0)

### Goal
Let a Vyb program create directories, so the store can use a nested layout
(`/vyb/store/<hash>/<name>/...`) and write per-derivation `.drv`-style metadata
next to realised outputs. Currently VybOS is forced into a flat `store/`.

### Current state (verified)
- No `mkdir` / `create_dir` / `make_dir` anywhere in `src/`, `stdlib/`, or
  `runtime/` — `grep -rni mkdir src/ stdlib/` is empty.
- `open_write(path<String>)<File?>` (`stdlib/io/mod.vyb:93`) opens an existing
  path via libc `open`/`fopen` only; it cannot create intermediate directories,
  so writing `/vyb/store/x/y/file` fails if `x/y` doesn't exist.
- `std::filesystem::create_directories` exists internally in `src/main.cpp`
  (lines 1421, 1486), but only for the compiler's own build-output layout. It is
  **not** exposed to Vyb programs as a `__vyb_*` runtime symbol.

### Requirements
1. Runtime primitive `__vyb_mkdir(path_ptr, path_len)<i64>` — recursive
   (create parent dirs), returns 0 on success, non-zero on failure. Must be
   deterministic/idempotent when the directory already exists (0).
2. Register it in the JIT symbol table alongside `__vyb_file_write`
   (`src/main.cpp:1888`) and in the standalone `--compile` runtime linkage
   (same pattern as `src/main.cpp:2386`), so it works both JIT and co-linked.
3. Prevent the POSIX-name collision pitfall: name it `__vyb_mkdir` (prefixed),
   not a bare `mkdir`, so it never collides with libc `mkdir` when the runtime
   is co-linked into a standalone executable.
4. stdlib wrapper in a module VybOS already imports (io or a new `fs` module),
   using the io module's established `T?` shape (not a bare `Bool`):
   `mkdir(path<String>)<File?>` — returns a `File` handle to the created
   directory on success, empty optional `File?()` on failure. Mirrors
   `open_write`/`open_read` returning `File?` (`stdlib/io/mod.vyb:93`), so
   callers `match` on it exactly like other io calls.
5. Negative test: path with a file as an intermediate component returns the
   empty optional, does not panic.

### Acceptance
`build/vyb` JIT-runs a program that, via `match (mkdir("/tmp/vybos/a/b/c"))`,
gets a present `File`, then `mkdir` on the same path again is still a present
`File` (idempotent), and a sibling test under `test/modules/` passes via
`test/run_tests.py` with the existing suite unchanged.

---

## Item 2 — real digest (SHA-256) (P0)

### Goal
Replace VybOS's collision-unsafe FNV-1a two-i64 content-hash stand-in with a
real cryptographic digest so content-addressed store paths are sound.

### Current state (verified)
- No crypto hash anywhere. `grep -rniE 'sha(1|256|512)?|md5|digest|hmac' src/
  stdlib/ runtime/` returns only false positives (`std::shared_ptr`, `.bak`
  files). No `__vyb_sha*` symbol exists.
- VybOS `modules/vybos.vyb` therefore ships a documented FNV-1a (two i64
  accumulators, negatives normalized) as a placeholder — unusable at scale.

### Requirements
1. Runtime primitive returning the digest as a hex `String` (64 hex chars),
   simplest embeddable/exchangeable form and avoids inventing a `Bytes<N>` type:
   `__vyb_sha256_hex(data_ptr, data_len)<const char*, i64>` (or two symbols
   where the second returns length). Registered in JIT + standalone table like
   Item 1.
2. stdlib module (suggest a new `crypto` module; verify the name doesn't collide
   with a libc symbol before shipping — follow the `__vyb_` prefix / bare-name
   rule from the POSIX-collision pitfall). API: `sha256(data<String>)<String>`.
3. Avalanche & determinism: identical input → identical hex every run; a
   one-bit input change flips ~half the output bits.

### Acceptance
Known-vector test passes: `sha256("") ==
"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"`, plus
`sha256("VybOS")` matches an independently computed value. JIT-compilable;
`test/modules/` test via `run_tests.py`; existing suite untouched.

---

## Item 3 — tarball/gzip extraction (P1)

### Goal
Let `derive()` realise real packages: fetch a source tarball over HTTPS and
extract members into the store. Without this the build framework can only
materialise single fetched blobs, not real source trees.

### Current state (verified)
- HTTPS fetch now works: `stdlib/https/mod.vyb` exposes `https_get_full`
  (line 182), `https_get_full_verified` (line 194), `https_get` (line 207),
  `https_get_verified`. TLS is layered via `stdlib/tls`. This part of the old
  "no TLS" blocker is **already solved**.
- No decompression capability exists. `grep -rniE 'tar|gzip|zlib|inflate|
  deflate|unzip|\.tgz' stdlib/ src/` finds nothing in production code (only
  `.bak` false positives). No `__vyb_` inflate/tar symbol.

### Requirements
1. gzip (DEFLATE) inflate primitive in the runtime: `__vyb_gzip_inflate(
   in_ptr, in_len, &out_len)<const char*>` (zlib-compatible), registered in JIT
   + standalone tables. Writer side not needed (defence-in-depth, we only read).
2. A stdlib `archive` module that walks ustar headers on the inflated bytes and
   extracts members (read `name`, `size` (octal), `typeflag`, skip the 512-byte
   header + padded data) as `Vec<(path<String>, data<String>)>`. Pure Vyb is
   fine once inflate exists.
3. Combined VybOS API on the framework module: `fetch_tarball(url, name,
   version)` → fetches via `https_get_full`, inflates, extracts to the store.

### Acceptance
Build a gzipped tar of 2–3 text files in `/tmp` with `tar czf`, fetch + extract
it with the new code, and assert each member is byte-identical to the source.
JIT-compilable; `test/modules/` test; existing suite untouched.

### Testing HTTPS access + builds against GitHub
For exercising the **real-network** path (fetching a file over HTTPS, and
building/extracting it), GitHub is a convenient, always-up test surface — no
self-hosted server or certificate setup needed:
- **Raw files**: `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>`
  serves a single file over TLS; e.g.
  `https://raw.githubusercontent.com/rickenator/VybOS/main/README.md`. Use this
  to verify a single `https_get_full`-style fetch + utf8-to-string round-trip.
- **Release archives**: `https://github.com/<owner>/<repo>/archive/<ref>.tar.gz`
  (or `.zip`) serves a real tarball to feed the inflate + ustar-extract path;
  e.g. `https://github.com/rickenator/VybOS/archive/main.tar.gz`. This is the
  end-to-end fetch→inflate→extract→store case with a genuine remote TLS peer.
- A handy all-in-one target that always exists: the Vyb compiler repo itself at
  `https://github.com/rickenator/Vyb/archive/refs/heads/main.tar.gz` (retries
  gracefully; a pinned release tag is even more reproducible).
- Caveat: raw.githubusercontent.com may return a redirect (HTTP 3xx) — ensure
  the client follows it or that the acceptance test tolerates the final URL,
  so a flaky remote peer doesn't fail an otherwise-correct implementation.

---

## Item 4 — URL parser in stdlib (P1)

### Goal
Let VybOS `derive()` take one URL string and split it into
(scheme, host, port, path) so it can pick portable client + default port
(80/443) without hardcoding per-package. Currently the http/https clients take
`(host, port, path)` as three separate arguments, so every call site hardcodes
the split.

### Current state (verified)
- No URL parsing in stdlib: `grep -rlnE 'struct Url|UrlOps|parse_url' stdlib/`
  is empty. Neither `http` nor `https` parses a URL.
- A robust, behavior-verified URL parser exists as a **demo module**, not
  stdlib: `demos/VybLynx/src/url.vyb` (Url struct + UrlOps aspect/bind;
  authority-resolve, scheme handling, default_port; proven behavior-identical
  in the VybLynx rewrite). This is the obvious seed.

### Requirements
1. Promote a stdlib `url` module from `demos/VybLynx/src/url.vyb` (reuse the
   aspect/bind pattern — pure data struct + `bind` for behaviour, per the
   cross-module bind-scope rules in the review notes: the importer must import
   every helper the bind calls).
2. Keep at minimum a `parse_url(url<String>)<Url?>` + `Url{scheme,host,port,
   path}` and a free `split(url)<Vec<String>>` or tuple returning the four
   components including a resolved default port (80 for http, 443 for https).
3. Guard against the IPv6 pitfall already handled in the http/https clients:
   resolve host → IPv4 (`socket_resolve`) before connecting (`AF_INET` only;
   a bare hostname resolving to IPv6 first makes connect fail). Documented in
   `stdlib/http/mod.vyb` lines 427–432.

### Acceptance
`url_split("http://example.com/a/b")` yields `(http, example.com, 80, /a/b)` and
`url_split("https://example.com/x")` yields `(https, example.com, 443, /x)`
including fragment-drop behaviour matching the existing VybLynx parser. A VybOS
`derive(url)` call selects the http vs https client from the scheme. JIT-runs;
`test/modules/` test; existing suite untouched.

---

## Priority & sequencing note
- P0 (Items 1, 2) unblock the core store: nested layout + collision-safe
  content addressing. They are independent of each other and of P1.
- P1 (Items 3, 4) make `derive()` realise real packages from one URL. Both
  depend on the https module (already present) and on Item 1 for the nested
  store writes. Item 4 is quick if we promote the existing demo parser.
