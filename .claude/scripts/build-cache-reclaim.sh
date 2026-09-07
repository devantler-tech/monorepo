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
# Bound the DIGITS before any arithmetic, then read them as decimal.
#
# Two distinct failures live here and the digits-only guard above catches neither:
#   * a leading zero makes bash read the value as octal, so `08` is not mis-scaled -- it
#     is a hard parse error that aborts the GOCACHE branch, which is the reclaim that
#     actually recovers the space. `10#` forces base ten.
#   * a value beyond int64 wraps silently, and the `10#` conversion wraps with it, so the
#     bound has to be applied to the digit string rather than to the converted number.
#     Seven digits caps the budget near 9.5 PB, whose product with 1024 is nowhere near
#     the int64 limit. Unbounded, a wrapped negative budget makes every cache read as
#     over budget and be cleaned on every single sweep.
if [ "${#CACHE_BUDGET_GB}" -gt 7 ]; then
  printf 'build-cache-reclaim: cache_budget_gb is too large (max 7 digits)\n' >&2
  exit 2
fi
CACHE_BUDGET_GB=$((10#$CACHE_BUDGET_GB))

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
# find_lsof resolves an lsof binary. Its path differs by platform (/usr/sbin on macOS,
# /usr/bin on most Linux), and hardcoding one turns the liveness check into a permanent
# "everything is in use" on the other -- fail-closed, but a silent no-op that reclaims
# nothing forever. CI caught exactly that: every assertion failed on ubuntu while macOS
# passed. Resolve it, and if it genuinely does not exist say so loudly rather than
# reaping nothing in silence.
find_lsof() {
  local candidate
  candidate=$(command -v lsof 2>/dev/null) && [ -x "$candidate" ] && {
    printf '%s' "$candidate"
    return 0
  }
  for candidate in /usr/sbin/lsof /usr/bin/lsof /bin/lsof; do
    [ -x "$candidate" ] && {
      printf '%s' "$candidate"
      return 0
    }
  done
  return 1
}

LSOF_BIN=$(find_lsof) || LSOF_BIN=''
[ -n "$LSOF_BIN" ] ||
  log 'WARNING: no lsof found — cannot prove a tree is idle, so every tree will be KEPT'

# LSOF_SNAPSHOT holds every open path on this host, captured ONCE and then narrowed to
# the temp root. Probing per tree with `lsof +D` was measured at ~2 s on a 26k-file tree
# and a sweep can have hundreds of candidates, so a per-tree descent would cost many
# minutes; one system-wide pass costs ~7 s no matter how many trees there are.
#
# LSOF_OK is tracked separately from the snapshot's contents on purpose: an empty
# snapshot is a perfectly ordinary state (nothing open under the temp root), whereas a
# failed lsof must keep every tree. Collapsing the two would turn a probe failure into
# "nothing is in use" — a fail-open in a script that deletes.
LSOF_OK=0
LSOF_SNAPSHOT=''
if [ -n "$LSOF_BIN" ]; then
  if lsof_raw=$("$LSOF_BIN" -Fn 2>/dev/null) && [ -n "$lsof_raw" ]; then
    LSOF_OK=1
    # lsof reports PHYSICAL paths, so narrow on the resolved root. On macOS the usual
    # temp roots are symlinks (/tmp -> /private/tmp, /var -> /private/var); narrowing on
    # the caller-supplied spelling would discard every matching row and leave an empty
    # snapshot, so every tree would read as free. When the root cannot be resolved, keep
    # the whole snapshot rather than a wrong subset.
    lsof_root=$(cd -- "$TMPDIR_ROOT" 2>/dev/null && pwd -P) || lsof_root=""
    if [ -n "$lsof_root" ]; then
      LSOF_SNAPSHOT=$(printf "%s\n" "$lsof_raw" | sed -n "s/^n//p" | grep -F -- "$lsof_root" || true)
    else
      LSOF_SNAPSHOT=$(printf "%s\n" "$lsof_raw" | sed -n "s/^n//p")
    fi
    unset lsof_raw
  else
    log 'WARNING: lsof produced no usable snapshot — cannot prove a tree is idle, so every tree will be KEPT'
  fi
fi

holds_open() {
  # Fail closed: without a usable snapshot, report "in use" so the tree is kept.
  #
  # The test is a literal, position-1 prefix match against the snapshot, which is what
  # makes a NESTED holder visible. Both halves were verified against a live holder:
  #   * a holder almost never has the top directory itself open — it holds a file, or has
  #     its cwd, somewhere beneath it. `lsof -- <dir>` reports only that exact node, so
  #     such a tree was reported free and reaped while genuinely in use. A shared Go cache
  #     is exactly this shape: entries land in subdirectories, so the top-level mtime goes
  #     stale while builds are still reading and writing underneath it.
  #   * `lsof +D <dir>` does see into the subtree, yet still exits 1 while PRINTING the
  #     holding processes — so an exit-status test calls the tree free at the very moment
  #     lsof is naming who is using it. Judge the rows, never the status.
  # `index()` is a literal match, so a path containing regex metacharacters cannot make
  # this silently match the wrong tree — or nothing at all.
  # lsof reports PHYSICAL paths, so compare on the resolved path. A tree whose real
  # path cannot be resolved is KEPT.
  local path=$1 canon
  [ "$LSOF_OK" -eq 1 ] || return 0
  canon=$(cd -- "$path" 2>/dev/null && pwd -P) || return 0
  [ -n "$canon" ] || return 0
  printf "%s\n" "$LSOF_SNAPSHOT" |
    awk -v p="$canon" 'index($0, p "/") == 1 || $0 == p { found = 1; exit } END { exit !found }'
}

still_idle() {
  # Re-verify a single tree immediately before it is removed.
  #
  # The snapshot above is captured once, up front, and the loop then measures the size of
  # every candidate before it deletes any of them -- so minutes can pass between that
  # snapshot and a given unlink. A process that opens a file under a candidate inside that
  # window is simply not in the snapshot, and the tree is deleted while genuinely in use.
  # One targeted probe per tree costs time proportional to the DELETION set rather than to
  # the ~1600 candidates a sweep scans, which is why it is affordable here and was not
  # affordable as the primary check.
  #
  # This NARROWS the window; it does not close it, and nothing available here could. The
  # trees are created by agent harnesses this script does not own, so there is no lock to
  # take between the last observation and unlink(2). What remains is the gap between this
  # probe and the `rm` a few lines below, and the cost of losing that race is a rebuild of
  # regenerable content.
  #
  # `+D` descends the subtree, and its rows are judged rather than its exit status: it
  # exits 1 while PRINTING the processes that hold a tree, so an exit-status test calls a
  # tree free at the very moment lsof is naming who is using it.
  # Probe the RESOLVED path: lsof works in physical paths, so a symlinked spelling would
  # be asking about a different name for the same tree. A path that cannot be resolved is
  # reported in use, so it is kept.
  local path=$1 rows canon errfile diagnostics
  [ -n "$LSOF_BIN" ] || return 1
  canon=$(cd -- "$path" 2>/dev/null && pwd -P) || return 1
  [ -n "$canon" ] || return 1
  errfile=$(mktemp 2>/dev/null) || return 1
  rows=$("$LSOF_BIN" +D "$canon" -Fn 2>"$errfile" | sed -n 's/^n//p')
  diagnostics=$(cat -- "$errfile" 2>/dev/null)
  rm -f -- "$errfile"
  # A non-empty row set names a holder, so the tree is in use.
  [ -z "$rows" ] || return 1
  # An EMPTY row set is a claim about the SCAN, not about the tree, and on its own it is
  # not evidence of anything. Measured here: lsof exits 1 for an idle tree, for a tree
  # with a holder, and for a scan it could not finish alike, so the exit status separates
  # none of the three -- and a subdirectory it cannot opendir() yields exactly the same
  # empty row set as a genuinely idle tree. The diagnostic stream is the only signal that
  # tells those two apart, so an empty result counts as idle only when the scan ran clean.
  # Anything else keeps the tree: the same fail-closed direction as every other rule here,
  # and the cheap side of the trade -- a kept tree costs one more cycle, while a tree
  # deleted on an answer lsof never gave costs a live run its working state.
  if [ -n "$diagnostics" ]; then
    log "KEEP  (scan incomplete) $canon: ${diagnostics%%$'\n'*}"
    return 1
  fi
  return 0
}

own_session_tree() {
  # Never reap the tree this very process is running out of.
  #
  # Compare RESOLVED paths, for the same reason holds_open does. On macOS the usual temp
  # roots are symlinks (/tmp -> /private/tmp, /var -> /private/var), so TMPDIR and the
  # candidate routinely name one directory in two spellings, and a lexical match misses
  # it. holds_open does NOT compensate here: TMPDIR by itself holds no file open, so a
  # session tree that has not been written to yet reads as idle and is reaped out from
  # under the very run that owns it.
  #
  # A path that cannot be resolved is treated as ours, so an unreadable candidate is kept
  # rather than deleted -- the same fail-closed direction as every other rule here.
  local path=$1 canon dir resolved
  canon=$(cd -- "$path" 2>/dev/null && pwd -P) || return 0
  [ -n "$canon" ] || return 0
  for dir in "${TMPDIR:-}" "$PWD"; do
    [ -n "$dir" ] || continue
    resolved=$(cd -- "$dir" 2>/dev/null && pwd -P) || continue
    [ -n "$resolved" ] || continue
    case "$resolved/" in
      "$canon"/*) return 0 ;;
    esac
  done
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
      # Everything above was decided from the up-front snapshot, which by now is minutes
      # old. Ask once more, about this tree alone, before destroying it.
      if ! still_idle "$tree"; then
        kept=$((kept + 1))
        log "KEEP  (in use, late)  $tree"
        continue
      fi
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

# Report in the mode's own vocabulary. The counters are shared between the two modes, so
# a dry-run summary phrased as apply ("reaped=N, reclaimed=~N MB") states that trees were
# deleted when none were -- and dry-run is the mode the scheduled sibling runs, so that is
# the line an operator actually reads. In a script whose value rests on being trustworthy
# about deletion, that is a reporting defect rather than a cosmetic one.
if [ "$MODE" = apply ]; then
  log "summary: reaped=${removed} kept=${kept} reclaimed=~${reclaimed_mb} MB"
else
  log "summary: would reap=${removed} kept=${kept} would reclaim=~${reclaimed_mb} MB (dry-run: nothing deleted)"
fi
if command -v df >/dev/null 2>&1; then
  log "free now: $(df -h / 2>/dev/null | awk 'NR==2{print $4}')"
fi
exit 0
