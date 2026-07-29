#!/usr/bin/env bash
# Sweep abandoned per-session worktrees across the monorepo AND every initialised
# submodule, in one invocation. This is the entry point the scheduled LaunchAgent
# calls; worktree-cleanup.sh holds the per-repo safety contract.
#
# Usage: worktree-cleanup-all.sh [dry-run|apply] [min_age_hours]
#   dry-run (default) — report only
#   apply             — reap, recording every removal to a timestamped manifest
#
# Manifests live OUTSIDE the repository (they name local paths and branches and must
# never be committed): ~/.claude/worktree-cleanup-manifests/<repo>-<utc>.tsv
#
# The Codex sibling's worktrees under ~/.codex/worktrees are deliberately NOT swept:
# that lane is owned by the sibling instance (AGENTS.md, Writer namespaces).
set -uo pipefail

MODE=${1:-dry-run}
MIN_AGE_HOURS=${2:-24}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUT="$SCRIPT_DIR/worktree-cleanup.sh"
[ -x "$SUT" ] || { printf 'worktree-cleanup-all: missing %s\n' "$SUT" >&2; exit 2; }

# Repo root. WORKTREE_CLEANUP_ROOT lets the script run from outside the checkout
# (the scheduled launcher does exactly that); otherwise it is two levels up from
# .claude/scripts.
if [ -n "${WORKTREE_CLEANUP_ROOT:-}" ]; then
  ROOT=$(cd "$WORKTREE_CLEANUP_ROOT" 2>/dev/null && pwd -P) \
    || { printf 'worktree-cleanup-all: WORKTREE_CLEANUP_ROOT not a directory: %s\n' \
         "$WORKTREE_CLEANUP_ROOT" >&2; exit 2; }
else
  ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
fi
# When this script runs from inside a session worktree, sweep the MAIN checkout, not
# the worktree copy — otherwise the sweep only ever sees its own nested tree.
case "$ROOT" in
  */.claude/worktrees/*) ROOT=${ROOT%%/.claude/worktrees/*} ;;
esac
git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1 \
  || { printf 'worktree-cleanup-all: not a git repository: %s\n' "$ROOT" >&2; exit 2; }

MANIFEST_DIR="$HOME/.claude/worktree-cleanup-manifests"
mkdir -p "$MANIFEST_DIR" || { printf 'cannot create %s\n' "$MANIFEST_DIR" >&2; exit 2; }
TS=$(date -u +%Y%m%dT%H%M%SZ)

printf '=== worktree-cleanup-all  mode=%s  min_age=%sh  root=%s ===\n' \
  "$MODE" "$MIN_AGE_HOURS" "$ROOT"

sweep() { # <repo_path>
  local path=$1 label toplevel expected
  [ -d "$path/.claude/worktrees" ] || return 0
  # Only sweep a repo whose toplevel resolves to ITSELF. A submodule with broken
  # worktree isolation resolves into the main checkout, and sweeping through that
  # alias would operate on the wrong tree (AGENTS.md, Execution model).
  toplevel=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 0
  expected=$(cd "$path" && pwd -P) || return 0
  if [ "$toplevel" != "$expected" ]; then
    printf '\n### SKIP %s (broken isolation: toplevel=%s)\n' "$path" "$toplevel"
    return 0
  fi
  local rel=${path#$ROOT/}
  if [ "$path" = "$ROOT" ]; then rel="(root)"; label=monorepo
  else label=$(printf '%s' "$rel" | tr '/' '-'); fi
  printf '\n### %s\n' "$rel"
  # Capture the sweep's OWN status, not the pipeline's tail. An infrastructure abort
  # (lsof, worktree list, manifest write) must not be reported as a successful sweep by
  # the scheduled entrypoint — and must stop the run rather than continuing into the
  # remaining repositories, since the same failure very likely applies to them too.
  local out rc
  out=$("$SUT" "$path" "$MANIFEST_DIR/$label-$TS.tsv" "$MODE" "$MIN_AGE_HOURS" 2>&1); rc=$?
  printf '%s\n' "$out" | tail -3
  if [ "$rc" -ne 0 ]; then
    printf 'worktree-cleanup-all: ABORTING — sweep of %s failed (exit %d)\n' "$rel" "$rc" >&2
    exit "$rc"
  fi
}

sweep "$ROOT"
# Every initialised submodule, from .gitmodules (never a hard-coded list — the
# portfolio gains and loses submodules over time).
while IFS= read -r sub; do
  [ -n "$sub" ] || continue
  sweep "$ROOT/$sub"
done < <(git -C "$ROOT" config -f "$ROOT/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')

printf '\n=== done (manifests in %s) ===\n' "$MANIFEST_DIR"
