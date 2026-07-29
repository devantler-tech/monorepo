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

# Validate arguments HERE, not only in the per-repo script. If no repository happens to
# have a .claude/worktrees/ directory, every per-repo call returns before validating,
# and a malformed launcher invocation (`worktree-cleanup-all.sh alpply 24`) would print
# "done" and exit 0 — a misconfigured scheduled job that looks healthy.
case "$MODE" in
  apply|dry-run) ;;
  *) printf "worktree-cleanup-all: invalid MODE '%s' (expected 'apply' or 'dry-run')\n" \
       "$MODE" >&2; exit 2 ;;
esac
case "$MIN_AGE_HOURS" in
  ''|*[!0-9]*) printf "worktree-cleanup-all: min_age_hours must be a non-negative integer, got '%s'\n" \
                 "$MIN_AGE_HOURS" >&2; exit 2 ;;
esac

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
  # "$ROOT" is QUOTED: unquoted it is a glob pattern, so a root path containing
  # [, * or ? would strip the wrong prefix (or none) and mislabel the manifest.
  local rel=${path#"$ROOT"/}
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

# Every submodule, from .gitmodules (never a hard-coded list — the portfolio gains and
# loses submodules over time).
# The read is status-checked: an unreadable .gitmodules yields an empty list, which is
# indistinguishable from "no submodules", and would silently degrade this to a
# root-only sweep while still reporting success. `cut -d' ' -f2-` (not `awk '{print $2}'`)
# so a submodule path containing whitespace is not truncated.
if [ -f "$ROOT/.gitmodules" ]; then
  # Two distinct statuses, checked INDEPENDENTLY. `--get-regexp` exits nonzero both when
  # the file is unparseable AND when it simply matches nothing, so it cannot distinguish
  # them alone. The probe below settles it — but its own status must be captured too:
  # on a malformed .gitmodules BOTH commands fail and produce no output, and testing
  # only the probe's emptiness would read that as "no submodules" and silently degrade
  # the scheduled sweep to the root repository.
  raw=$(git -C "$ROOT" config -f "$ROOT/.gitmodules" \
          --get-regexp '^submodule\..*\.path$' 2>/dev/null); get_rc=$?
  probe=$(git -C "$ROOT" config -f "$ROOT/.gitmodules" --list 2>/dev/null); probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    printf 'worktree-cleanup-all: ABORTING — .gitmodules is unreadable or malformed\n' >&2
    exit 2
  fi
  if [ "$get_rc" -ne 0 ] && [ -n "$probe" ]; then
    printf 'worktree-cleanup-all: ABORTING — cannot read submodule paths from .gitmodules\n' >&2
    exit 2
  fi
  submodules=$(printf '%s\n' "$raw" | cut -d' ' -f2-)
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    sweep "$ROOT/$sub"
  done <<< "$submodules"
fi

printf '\n=== done (manifests in %s) ===\n' "$MANIFEST_DIR"
