#!/usr/bin/env bash
# build/samples/make_samples.sh — build the deterministic source tarball that
# build-package.vyb realises. This is the "fetched source" for a package: a
# real, gzipped POSIX tar of a small source tree. Deterministic so store
# paths are reproducible across runs (same inputs -> same content addresses).
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$DIR/_tree"
rm -rf "$WORK"
mkdir -p "$WORK/src/lib"

cat > "$WORK/src/lib/helper.vyb" <<'EOF'
// helper.vyb — a tiny library file, part of the "fetched" source tree.
pub fn add(a, b) -> { return a + b }
EOF

cat > "$WORK/src/Makefile" <<'EOF'
hello: hello.vyb
	@echo "build hello from source tree"
EOF

cat > "$WORK/README.md" <<'EOF'
# samplepkg 1.0
A tiny source tree used to exercise VybOS real-package realization
(archive inflate + tar extract -> flat content-addressed store).
EOF

# deterministic tar: sorted names, fixed mtime/owner/group, gzip -n
tar --sort=name --mtime='2020-01-01 00:00:00' --owner=0 --group=0 \
    -C "$WORK" -czf "$DIR/samplepkg-1.0.tar.gz" src README.md
echo "source tarball ready:"
tar -tvzf "$DIR/samplepkg-1.0.tar.gz" | sed 's/^/  /'
rm -rf "$WORK"
