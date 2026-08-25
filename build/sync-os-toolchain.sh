#!/usr/bin/env bash
# build/sync-os-toolchain.sh — synchronize the VybOS toolchain (vyb-os-stable)
# with the Vyb compiler's remote `main`, but ONLY when main is committed AND
# pushed to the remote.
#
# POLICY: vyb-os-stable tracks origin/main — the *pushed* state of the Vyb
# compiler repo — never this machine's local `main` checkout, because the local
# checkout can carry impl-agent churn that is uncommitted or committed-but-not-
# yet-pushed. Using origin/main as the only source of truth guarantees the
# worktree is never advanced by work that hasn't been durably published.
#
# Behavior:
#   - fetch origin in the Vyb repo
#   - if vyb-os-stable is already at origin/main       -> "in sync", exit 0
#   - if vyb-os-stable can fast-forward to origin/main -> advance + rebuild, exit 0
#   - if vyb-os-stable has diverged (not a fast-forward)-> refuse, exit 3
#   - if the Vyb repo remote is unreachable            -> no-op, exit 2 (keeps stable)
#
# On a fast-forward it also rebuilds build/vyb so the toolchain binary matches
# the synced source. Idempotent and safe to run any time.

set -uo pipefail

# Paths (override via env). VYB_REPO = the main Vyb compiler checkout; the
# remote is what we trust, so local working-tree state there is irrelevant.
VYB_REPO="${VYB_REPO:-$HOME/Projects/Vyb}"
VYB_STABLE="${VYB_STABLE:-$HOME/Projects/Vyb-vybos}"
REMOTE="${REMOTE:-origin}"
BRANCH="vyb-os-stable"

echo "== VybOS toolchain sync =="
echo "  repo:    $VYB_REPO   (remote $REMOTE)"
echo "  target:  $VYB_STABLE (branch $BRANCH)"

# --- locate the main checkout; it must exist to fetch the remote ---
if [ ! -d "$VYB_REPO/.git" ] && [ ! -d "$VYB_REPO" ]; then
    echo "ERROR: Vyb repo not found at $VYB_REPO (override VYB_REPO)" >&2
    exit 2
fi
# A git worktree has a `.git` FILE (pointing at the main repo's gitdir), not a
# `.git` directory — accept either.
if [ ! -e "$VYB_STABLE/.git" ]; then
    echo "ERROR: stable worktree not found at $VYB_STABLE (override VYB_STABLE)" >&2
    exit 2
fi

# --- ensure we're running in the intended stable worktree ---
CUR_BR=$(git -C "$VYB_STABLE" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$CUR_BR" != "$BRANCH" ]; then
    echo "ERROR: $VYB_STABLE is on '$CUR_BR', not '$BRANCH'; aborting" >&2
    exit 3
fi

# --- fetch the remote so origin/main reflects what is committed+pushed ---
echo "  fetching $REMOTE... "
if ! git -C "$VYB_REPO" fetch "$REMOTE" 2>/tmp/vyb-sync-fetch.log; then
    echo "  remote unreachable; leaving toolchain unchanged (stable stays)." >&2
    echo "  fetch stderr:"; sed 's/^/    /' /tmp/vyb-sync-fetch.log >&2
    exit 2
fi

TARGET=$(git -C "$VYB_REPO" rev-parse "$REMOTE/main" 2>/dev/null)
if [ -z "$TARGET" ]; then
    echo "ERROR: cannot resolve $REMOTE/main" >&2
    exit 2
fi
LOCAL=$(git -C "$VYB_STABLE" rev-parse HEAD)
TARGET_SHORT=${TARGET:0:10}
LOCAL_SHORT=${LOCAL:0:10}

echo "  vyb-os-stable @ $LOCAL_SHORT"
echo "  origin/main    @ $TARGET_SHORT"

# --- same commit: nothing to do ---
if [ "$LOCAL" = "$TARGET" ]; then
    echo "  -> in sync (no new commits pushed); nothing to do."
    exit 0
fi

# --- is it a fast-forward? (target = strict ancestor of local's history) ---
if git -C "$VYB_STABLE" merge-base --is-ancestor "$LOCAL" "$TARGET" 2>/dev/null; then
    echo "  -> advancing vyb-os-stable $LOCAL_SHORT -> $TARGET_SHORT (committed+pushed)"
    git -C "$VYB_STABLE" merge --ff-only "$TARGET" 2>/dev/null \
        || git -C "$VYB_STABLE" reset --hard "$TARGET"
    echo "  -> rebuilding toolchain..."
    if ( cd "$VYB_STABLE" && cmake --build build ); then
        echo "  -> done: vyb-os-stable at $(git -C "$VYB_STABLE" rev-parse --short HEAD), build/vyb rebuilt."
        exit 0
    else
        echo "  -> WARNING: advanced to $TARGET_SHORT but BUILD FAILED — toolchain binary is stale." >&2
        exit 1
    fi
else
    echo "  -> REFUSING: vyb-os-stable ($LOCAL_SHORT) has diverged from origin/main ($TARGET_SHORT);" >&2
    echo "     not a fast-forward. Reconcile manually (this is not auto-advanced)." >&2
    exit 3
fi
