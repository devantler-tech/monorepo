#!/usr/bin/env bash
# Reclaim agent-generated build caches and per-run temp trees.
#
# Why this exists: three agent lanes build and test Go continuously, and every run
# writes the shared Go build cache and often a dedicated per-run GOCACHE/GOPATH under
# the system temp directory. Nothing reaped any of it, and the host filled to 100%
# (monorepo#3253) with 55 GB of build cache and ~64 GB of per-run trees. Go's own
# trimming only evicts entries unused for ~5 days, and with hourly lanes touching the
# same packages those entries never go cold.
#
# This is the sibling of worktree-cleanup-all.sh, which reaps abandoned worktrees. That
# one covers ~4% of the agent's disk churn; this covers the rest.
#
# Usage:
#   build-cache-reclaim.sh [dry-run|apply] [min_age_days] [cache_budget_gb]
#
# Defaults: dry-run, 3 days, 10 GB.
#
# SAFETY — this deletes, so every rule below fails closed:
#   * Only trees matching a known agent-generated name pattern are ever considered.
#   * A tree younger than min_age_days is KEPT.
#   * A tree any running process holds open is KEPT.
#   * The caller's own session tree is KEPT.
#   * Anything that cannot be positively classified is KEPT.
# The Go caches are content-addressed and fully regenerable; removing them costs a
# rebuild, never data.
set -uo pipefail

MODE=${1:-dry-run}
MIN_AGE_DAYS=${2:-3}
CACHE_BUDGET_GB=${3:-10}

case "$MODE" in
  dry-run | apply) ;;
  *)
    printf 'build-cache-reclaim: mode must be dry-run or apply, got %s\n' "$MODE" >&2
    exit 2
    ;;
esac
case "$MIN_AGE_DAYS" in
  '' | *[!0-9]*)
    printf 'build-cache-reclaim: min_age_days must be a non-negative integer\n' >&2
    exit 2
    ;;
esac
case "$CACHE_BUDGET_GB" in
  '' | *[!0-9]*)
    printf 'build-cache-reclaim: cache_budget_gb must be a non-negative integer\n' >&2
    exit 2
    ;;
esac

TMPDIR_ROOT=${BUILD_CACHE_RECLAIM_TMPDIR:-/private/tmp}
reclaimed_mb=0
kept=0
removed=0

log() { printf 'build-cache-reclaim: %s\n' "$*"; }

# size_mb reports a directory's size, or the empty string when it cannot be measured.
# An unmeasurable tree is never removed: "I could not tell" must not become "delete".
size_mb() {
  local path=$1 out
  out=$(du -x -s -m "$path" 2>/dev/null | awk 'NR==1{print $1}') || return 1
  case "$out" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$out"
}

printf '\n===== %s  build-cache-reclaim (%s) =====\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE"
log "temp root=${TMPDIR_ROOT} min_age_days=${MIN_AGE_DAYS} cache_budget_gb=${CACHE_BUDGET_GB}"

# ---------------------------------------------------------------------------
# 1. Go build cache, trimmed only when it exceeds its budget.
#
# Unconditional cleaning would throw away a warm cache on every sweep and make each
# following build far slower for no space benefit, so the budget is what decides.
# ---------------------------------------------------------------------------
# find_go resolves a go binary. A LaunchAgent runs with launchd's minimal PATH
# (/usr/bin:/bin:/usr/sbin:/sbin), so a bare `command -v go` fails there and the Go
# cache -- the single largest consumer, and the whole reason this script exists -- would
# be silently skipped on every scheduled run while the script still exited 0. Verified
# live: the first scheduled run logged "go not on PATH".
find_go() {
  local candidate
  candidate=$(command -v go 2>/dev/null) && [ -x "$candidate" ] && {
    printf '%s' "$candidate"
    return 0
  }
  for candidate in \
    /opt/homebrew/bin/go \
    /usr/local/go/bin/go \
    /usr/local/bin/go \
    "${HOME}/go/bin/go" \
    /opt/local/bin/go; do
    [ -x "$candidate" ] && {
      printf '%s' "$candidate"
      return 0
    }
  done
  return 1
}

if go_bin=$(find_go); then
  gocache=$("$go_bin" env GOCACHE 2>/dev/null)
  if [ -n "$gocache" ] && [ -d "$gocache" ]; then
    if cache_mb=$(size_mb "$gocache"); then
      budget_mb=$((CACHE_BUDGET_GB * 1024))
      log "GOCACHE ${gocache} = ${cache_mb} MB (budget ${budget_mb} MB)"
      if [ "$cache_mb" -gt "$budget_mb" ]; then
        if [ "$MODE" = apply ]; then
          if "$go_bin" clean -cache 2>/dev/null; then
            reclaimed_mb=$((reclaimed_mb + cache_mb))
            log "GOCACHE cleaned, reclaimed ~${cache_mb} MB"
          else
            log "GOCACHE clean FAILED — keeping"
          fi
        else
          log "GOCACHE would be cleaned (over budget), ~${cache_mb} MB"
        fi
      else
        log 'GOCACHE within budget — keeping (a warm cache is worth more than the space)'
      fi
    else
      log 'GOCACHE size unmeasurable — keeping'
    fi
  fi
else
  log 'no go binary found (PATH or known locations) — skipping Go cache reclamation'
fi

# ---------------------------------------------------------------------------
# 2. Stale per-run agent trees under the temp root.
#
# Matched by name pattern AND age AND liveness. The patterns are the per-run prefixes
# the lanes actually create; anything else in the temp root belongs to some other tool
# and is never touched.
# ---------------------------------------------------------------------------
holds_open() {
  # Fail closed: if lsof is unavailable or errors, report "in use" so the tree is kept.
  local path=$1
  command -v /usr/sbin/lsof >/dev/null 2>&1 || return 0
  /usr/sbin/lsof -- "$path" >/dev/null 2>&1 && return 0
  return 1
}

own_session_tree() {
  # Never reap the tree this very process is running out of.
  local path=$1
  case "${TMPDIR:-}/" in
    "$path"/*) return 0 ;;
  esac
  case "$PWD/" in
    "$path"/*) return 0 ;;
  esac
  return 1
}

if [ -d "$TMPDIR_ROOT" ]; then
  while IFS= read -r tree; do
    [ -n "$tree" ] || continue
    [ -d "$tree" ] || continue
    if own_session_tree "$tree"; then
      kept=$((kept + 1))
      continue
    fi
    if holds_open "$tree"; then
      kept=$((kept + 1))
      log "KEEP  (in use)        $tree"
      continue
    fi
    if ! tree_mb=$(size_mb "$tree"); then
      kept=$((kept + 1))
      log "KEEP  (unmeasurable)  $tree"
      continue
    fi
    if [ "$MODE" = apply ]; then
      # Go marks every file under a module cache read-only, so a plain `rm -rf` stops
      # partway. That is worse than skipping the tree: the partial delete bumps its
      # mtime, the age filter then never selects it again, and the remnant is orphaned
      # forever. Restore write permission first so removal is all-or-nothing in practice.
      chmod -R u+w -- "$tree" 2>/dev/null || true
      if rm -rf -- "$tree" 2>/dev/null && [ ! -e "$tree" ]; then
        removed=$((removed + 1))
        reclaimed_mb=$((reclaimed_mb + tree_mb))
        log "REAP  ${tree_mb} MB  $tree"
      else
        kept=$((kept + 1))
        log "KEEP  (remove failed) $tree"
      fi
    else
      removed=$((removed + 1))
      reclaimed_mb=$((reclaimed_mb + tree_mb))
      log "WOULD REAP ${tree_mb} MB  $tree"
    fi
  done <<EOF
$(find "$TMPDIR_ROOT" -maxdepth 1 -type d \
  \( -name 'codex-*' -o -name 'war-*' -o -name 'dpc-*' -o -name 'ksail-*' \) \
  -mtime "+${MIN_AGE_DAYS}" 2>/dev/null)
EOF
fi

log "summary: reaped=${removed} kept=${kept} reclaimed=~${reclaimed_mb} MB"
if command -v df >/dev/null 2>&1; then
  log "free now: $(df -h / 2>/dev/null | awk 'NR==2{print $4}')"
fi
exit 0
