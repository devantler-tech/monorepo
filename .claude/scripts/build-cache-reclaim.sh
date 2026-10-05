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
# On 2026-09-29 the host reached 99% again (monorepo#3675) from two consumers this sweep
# could not see: 15.7 GB of Go's own orphaned work dirs, left in the per-user temp dir by
# go commands that were killed, and a 3.3 GB golangci-lint cache that nothing budgeted.
#
# This is the sibling of worktree-cleanup-all.sh, which reaps abandoned worktrees. That
# one covers ~4% of the agent's disk churn; this covers the rest.
#
# Usage:
#   build-cache-reclaim.sh [dry-run|apply] [min_age_days] [cache_budget_gb]
#
# Defaults: dry-run, 3 days, 10 GB.
#
# Exit: 0 every sweep read its input; 2 a usage or setting error, or a scan that could not be
# read (logged as UNKNOWN -- the summary is then partial, never clean).
#
# What it covers, in the order it runs:
#   1. GOCACHE and GOMODCACHE, each cleaned only when it exceeds cache_budget_gb.
#   2. Per-run agent trees (codex-*, war-*, dpc-*, ksail-*) under the temp root, older
#      than min_age_days.
#   2b. Per-run Go and golangci-lint caches directly under the temp root, or one level below
#      a Claude Code session scratchpad (claude-*/<project>/<session>/scratchpad/<cache>),
#      whatever they are named, recognised by the README each tool writes into its cache and
#      reclaimed once nothing was written to them for a threshold counted in HOURS
#      (2026-09-30: 75 GB). A Go build cache a lane REUSES is never idle, so while it is still
#      being written to it is emptied only when it exceeds cache_budget_gb (monorepo#3831).
#   2c. Per-lane fallback module caches (go-mod-*) directly under the temp root, each removed
#      only when it exceeds cache_budget_gb.
#   3. The golangci-lint cache, emptied only when it exceeds its own, smaller budget.
#   4. Go's orphaned work dirs (go-build<digits>, go-link-<digits>) directly under the
#      per-user temp dir, older than a threshold counted in HOURS.
#   5. The local container runtime's image store, when the `container` CLI is installed:
#      images no container uses, unpacked longer ago than a threshold counted in HOURS,
#      removed only while the store exceeds its own budget (2026-10-05: 57 GB unused,
#      monorepo#3848). Long-running containers are named in the output and never stopped.
#
# Environment (all optional):
#   BUILD_CACHE_RECLAIM_TMPDIR                temp root for (2); default /private/tmp
#   BUILD_CACHE_RECLAIM_LINT_BUDGET_GB        budget for (3); default 2
#   GOLANGCI_LINT_CACHE                       golangci-lint's own cache-dir override
#   BUILD_CACHE_RECLAIM_GO_TMPDIR             temp dir for (4); default `getconf
#                                             DARWIN_USER_TEMP_DIR`, else ${TMPDIR:-/tmp}
#   BUILD_CACHE_RECLAIM_GO_TMP_MIN_AGE_HOURS  age threshold for (4); default 6
#   BUILD_CACHE_RECLAIM_RUN_CACHE_IDLE_HOURS  idle threshold for (2b); default 6
#   BUILD_CACHE_RECLAIM_CONTAINER_CLI         container runtime CLI for (5); default
#                                             `container`, `off` skips the step
#   BUILD_CACHE_RECLAIM_CONTAINER_STORE       that runtime's store directory; default
#                                             ~/Library/Application Support/com.apple.container
#   BUILD_CACHE_RECLAIM_CONTAINER_BUDGET_GB   image-store budget for (5); default 10
#   BUILD_CACHE_RECLAIM_CONTAINER_IMAGE_MIN_AGE_HOURS  age threshold for (5); default 24
#   BUILD_CACHE_RECLAIM_CONTAINER_LONG_RUN_HOURS       reporting threshold for (5); default 24
#
# SAFETY — this deletes, so every rule below fails closed:
#   * Only trees matching a known agent-generated name pattern, carrying a Go or
#     golangci-lint cache README marker (2b), or named go-mod-* and laid out like a Go
#     module cache (2c), are ever considered.
#   * A tree younger than its age threshold is KEPT. The one exception is a marked Go build
#     cache over cache_budget_gb (2b), which is emptied while recent -- never while held open.
#   * A tree any running process holds open is KEPT, and each cache or tree is asked about
#     again immediately before it is removed.
#   * The caller's own session tree is KEPT.
#   * A Go work dir is KEPT while a Go toolchain process that could own it is running.
#   * The golangci-lint cache is KEPT while golangci-lint runs, and is emptied only when
#     it carries golangci-lint's own README marker.
#   * A container image is KEPT while any container, running or stopped, was created from
#     it, while it was unpacked within its age threshold, and whenever either cannot be told.
#     A container is never stopped or removed.
#   * Anything that cannot be positively classified is KEPT.
# The Go and golangci-lint caches are content-addressed and fully regenerable; removing
# them costs a rebuild, never data. A container image is the same kind of thing: removing
# one costs a pull, or a rebuild from its source when a lane built it locally.
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
# uint_setting validates one numeric setting and prints it as a decimal integer, or
# prints why not and returns 1. Every budget and threshold that reaches arithmetic goes
# through it.
#
# Bound the DIGITS before any arithmetic, then read them as decimal. Two distinct failures
# live here and a digits-only guard catches neither:
#   * a leading zero makes bash read the value as octal, so `08` is not mis-scaled -- it
#     is a hard parse error that aborts the GOCACHE branch, which is the reclaim that
#     actually recovers the space. `10#` forces base ten.
#   * a value beyond int64 wraps silently, and the `10#` conversion wraps with it, so the
#     bound has to be applied to the digit string rather than to the converted number.
#     Seven digits caps the budget near 9.5 PB, whose product with 1024 is nowhere near
#     the int64 limit. Unbounded, a wrapped negative budget makes every cache read as
#     over budget and be cleaned on every single sweep.
uint_setting() {
  local label=$1 value=$2
  case "$value" in
    '' | *[!0-9]*)
      printf 'build-cache-reclaim: %s must be a non-negative integer\n' "$label" >&2
      return 1
      ;;
  esac
  if [ "${#value}" -gt 7 ]; then
    printf 'build-cache-reclaim: %s is too large (max 7 digits)\n' "$label" >&2
    return 1
  fi
  printf '%s' "$((10#$value))"
}

CACHE_BUDGET_GB=$(uint_setting cache_budget_gb "$CACHE_BUDGET_GB") || exit 2
# The golangci-lint cache gets its OWN budget rather than cache_budget_gb. That argument is
# sized for the Go build cache, the largest and most valuable cache here; at 10 GB it
# would never have touched the 3.3 GB lint cache measured when the host filled, so the
# gap would have stayed open. A lint cache is cheap to rebuild, so it is held smaller.
LINT_BUDGET_GB=$(uint_setting BUILD_CACHE_RECLAIM_LINT_BUDGET_GB \
  "${BUILD_CACHE_RECLAIM_LINT_BUDGET_GB:-2}") || exit 2
# Go's work dirs are aged in HOURS, not min_age_days. A go command's work dir is live only
# while that command runs, and every holder check below still applies, so waiting three
# days only lets orphans pile up: 15.7 GB of them were 0-2 days old when the host filled.
GO_TMP_MIN_AGE_HOURS=$(uint_setting BUILD_CACHE_RECLAIM_GO_TMP_MIN_AGE_HOURS \
  "${BUILD_CACHE_RECLAIM_GO_TMP_MIN_AGE_HOURS:-6}") || exit 2
# A per-run build cache under the temp root is idle once nothing has been WRITTEN to it for
# this many hours. Hours, not min_age_days, for the same reason: lanes create several a
# day at 6-12 GB each, and 75 GB of them filled the host before any reached four days.
RUN_CACHE_IDLE_HOURS=$(uint_setting BUILD_CACHE_RECLAIM_RUN_CACHE_IDLE_HOURS \
  "${BUILD_CACHE_RECLAIM_RUN_CACHE_IDLE_HOURS:-6}") || exit 2

# The README each tool writes into every cache dir it opens, whenever it is missing. These
# are what prove a directory IS such a cache, whatever it is called (2b, 3).
GO_CACHE_MARKER='This directory holds cached build artifacts from the Go build system.'
LINT_CACHE_MARKER='This directory holds cached build artifacts from golangci-lint.'

TMPDIR_ROOT=${BUILD_CACHE_RECLAIM_TMPDIR:-/private/tmp}

# resolve_go_tmpdir prints the directory the go command puts its work dirs in.
#
# The go command uses TMPDIR, and in a macOS session TMPDIR is the per-user dir under
# /var/folders, NOT /private/tmp -- which is why the per-run sweep never saw these dirs.
# `getconf` asks the OS for that dir rather than reading the environment, so a LaunchAgent
# started with launchd's minimal environment still finds the directory the lanes' go
# commands wrote into. Elsewhere getconf fails and TMPDIR decides, as it does for go.
resolve_go_tmpdir() {
  local dir
  if [ -n "${BUILD_CACHE_RECLAIM_GO_TMPDIR:-}" ]; then
    dir=$BUILD_CACHE_RECLAIM_GO_TMPDIR
  else
    dir=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || dir=''
    [ -n "$dir" ] || dir=${TMPDIR:-/tmp}
  fi
  # getconf answers with a trailing slash; strip it so logged paths read cleanly.
  [ "$dir" = / ] || dir=${dir%/}
  printf '%s' "$dir"
}
GO_TMP_ROOT=$(resolve_go_tmpdir)

reclaimed_mb=0
kept=0
removed=0
# unknown counts scans that could not be read, so the summary and the exit status never call a
# partial pass clean.
unknown=0

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
log "go temp dir=${GO_TMP_ROOT} go_tmp_min_age_hours=${GO_TMP_MIN_AGE_HOURS} lint_budget_gb=${LINT_BUDGET_GB}"

# ---------------------------------------------------------------------------
# 0. Liveness probe, shared by the cache gate below and the tree sweep further down.
#
# This sits ahead of BOTH consumers on purpose. `go clean -modcache` empties the whole
# module cache, so it needs the same "can I prove nothing is using this?" answer the tree
# sweep needs -- and it runs first, so the probe has to exist by then.
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
LSOF_PATHS=''
LSOF_SNAPSHOT=''
if [ -n "$LSOF_BIN" ]; then
  if lsof_raw=$("$LSOF_BIN" -Fn 2>/dev/null) && [ -n "$lsof_raw" ]; then
    LSOF_OK=1
    # LSOF_PATHS keeps every open path on the host. The Go caches live OUTSIDE the temp
    # root, so the temp-root-narrowed snapshot below is the wrong instrument for them --
    # narrowing first and asking about a cache afterwards reports every cache as idle.
    LSOF_PATHS=$(printf "%s\n" "$lsof_raw" | sed -n "s/^n//p")
    # lsof reports PHYSICAL paths, so narrow on the resolved root. On macOS the usual
    # temp roots are symlinks (/tmp -> /private/tmp, /var -> /private/var); narrowing on
    # the caller-supplied spelling would discard every matching row and leave an empty
    # snapshot, so every tree would read as free. When the root cannot be resolved, keep
    # the whole snapshot rather than a wrong subset.
    lsof_root=$(cd -- "$TMPDIR_ROOT" 2>/dev/null && pwd -P) || lsof_root=""
    if [ -n "$lsof_root" ]; then
      LSOF_SNAPSHOT=$(printf "%s\n" "$LSOF_PATHS" | grep -F -- "$lsof_root" || true)
    else
      LSOF_SNAPSHOT=$LSOF_PATHS
    fi
    unset lsof_raw
  else
    log 'WARNING: lsof produced no usable snapshot — cannot prove a tree is idle, so every tree will be KEPT'
  fi
fi

# dir_in_use reports whether any process on this host holds a file at or below `dir`.
#
# It answers for a path that is NOT under the temp root, so it reads LSOF_PATHS rather
# than the narrowed snapshot. Same literal position-1 prefix test as holds_open, and for
# the same reason: a holder almost never has the top directory open, it holds something
# beneath it -- and a Go cache is exactly that shape, since every entry lands in a
# subdirectory. `index()` is literal, so a path containing regex metacharacters cannot
# make this match the wrong tree or nothing at all.
#
# Fail closed in every direction: no usable snapshot, or a path that cannot be resolved,
# reports "in use" so the caller keeps the cache. A cache kept costs one more sweep; a
# cache deleted under a running build costs that build its module files.
dir_in_use() {
  local dir=$1 canon
  [ "$LSOF_OK" -eq 1 ] || return 0
  canon=$(cd -- "$dir" 2>/dev/null && pwd -P) || return 0
  [ -n "$canon" ] || return 0
  # NO early `exit` in the match rule. Under `set -o pipefail`, an awk that exits on its
  # first hit closes the pipe, printf takes SIGPIPE, and the PIPELINE reports 141 -- which
  # this function reads as "not in use", and the caller then DELETES. Measured on a
  # ~20k-line snapshot: the early-exit form returns 141 on a genuine match, while the same
  # program over a short snapshot returns 0, so the bug only bites once the host is busy.
  # Scanning to EOF costs microseconds and is the only form whose status means what it says.
  printf "%s\n" "$LSOF_PATHS" |
    awk -v p="$canon" 'index($0, p "/") == 1 || $0 == p { found = 1 } END { exit !found }'
}

still_idle() {
  # Re-verify a single tree immediately before it is removed.
  #
  # It sits here, ahead of the cache gate, because every remover asks it: `go clean` on a Go
  # cache below, the golangci-lint cache, and the tree sweeps.
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

# PS_TABLE holds one "<elapsed-seconds> <name>" line per process on this host, captured
# ONCE. Open files alone cannot prove a Go work dir or the golangci-lint cache is idle: a
# running go command need not hold anything under its work dir between build steps, and
# golangci-lint opens cache entries only for the instant it reads or writes one. So both
# of those rules also ask which processes are running, and for how long.
#
# `comm` is read with -ww and cut to its last path component. macOS reports a full path
# and truncates it at the terminal width without -ww (measured here: a framework daemon's
# path ended in "Sup..."), and a truncated toolchain path would never match its name.
# Linux reports the bare name, so the cut is a no-op there.
#
# An elapsed time that does not parse is recorded as -1, which every reader treats as
# "cannot tell" -- never as young. PS_OK is tracked apart from the contents for the same
# reason LSOF_OK is: a failed ps must keep everything, not read as "nothing is running".
#
# PS_EPOCH is taken just BEFORE ps, so a process's age "now" is its elapsed time plus the
# seconds since PS_EPOCH -- an over-estimate by the ps call's own duration, which is the
# direction that keeps more, not less.
read_process_table() {
  local raw
  raw=$(ps -A -ww -o etime= -o comm= 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  # etime is [[dd-]hh:]mm:ss on both BSD and procps ps.
  printf '%s\n' "$raw" | awk '
    {
      t = $1
      name = $0
      sub(/^[ \t]*[^ \t]+[ \t]*/, "", name)
      sub(/[ \t]+$/, "", name)
      sub(/.*\//, "", name)
      if (name == "") next
      d = 0
      if (t ~ /^[0-9]+-/) {
        d = substr(t, 1, index(t, "-") - 1)
        t = substr(t, index(t, "-") + 1)
      }
      secs = -1
      if (t ~ /^[0-9]+:[0-9]+:[0-9]+$/) {
        split(t, f, ":")
        secs = d * 86400 + f[1] * 3600 + f[2] * 60 + f[3]
      } else if (t ~ /^[0-9]+:[0-9]+$/) {
        split(t, f, ":")
        secs = d * 86400 + f[1] * 60 + f[2]
      }
      print secs, name
    }'
}

PS_OK=0
PS_TABLE=''
PS_EPOCH=$(date +%s 2>/dev/null) || PS_EPOCH=''
case "$PS_EPOCH" in
  '' | *[!0-9]*) PS_EPOCH='' ;;
esac
if [ -n "$PS_EPOCH" ] && PS_TABLE=$(read_process_table) && [ -n "$PS_TABLE" ]; then
  PS_OK=1
fi
[ "$PS_OK" -eq 1 ] ||
  log 'WARNING: ps produced no usable process table — every Go work dir and the golangci-lint cache will be KEPT'

# oldest_in_table prints the longest elapsed time, in seconds, of any process in table $1
# with one of the names that follow, or -1 when none of them is running. It returns 1 when
# that cannot be told: an empty table, or a matching process whose elapsed time did not
# parse. Callers read a 1 as "a holder may exist" and keep what they were asked about.
oldest_in_table() {
  local table=$1
  shift
  [ -n "$table" ] || return 1
  # Scans to EOF with no early `exit` in the rules, for the SIGPIPE reason documented on
  # dir_in_use: under pipefail an awk that quits early turns a real answer into a 141.
  printf '%s\n' "$table" | awk -v names="$*" '
    BEGIN { n = split(names, w, " "); for (i = 1; i <= n; i++) want[w[i]] = 1; max = -1 }
    {
      name = $0
      sub(/^[^ ]+ /, "", name)
      if (!(name in want)) next
      if ($1 < 0) bad = 1
      else if ($1 > max) max = $1
    }
    END { if (bad) exit 1; print max }'
}

# oldest_process_secs asks the same question of the up-front table.
oldest_process_secs() {
  [ "$PS_OK" -eq 1 ] || return 1
  oldest_in_table "$PS_TABLE" "$@"
}
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
  # BUILD_CACHE_RECLAIM_GO=none simulates a host with no go at all (the macOS CI runner is one), so
  # the no-go path is testable on a machine that has go in a fixed location.
  [ "${BUILD_CACHE_RECLAIM_GO:-}" != none ] || return 1
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

# reclaim_go_cache trims ONE Go cache when it exceeds the budget, and keeps it otherwise.
#
# Both Go caches obey the same rule, so they share one implementation rather than two
# copies that can drift: an unconditional clean would throw away a warm cache on every
# sweep and make each following build far slower for no space benefit, so the budget is
# what decides. Every failure path KEEPS the cache -- an unmeasurable size and a failed
# clean are both "I could not tell", which must never become "delete".
#
# `go clean` is used rather than `rm -rf` deliberately: Go marks every file under the
# module cache read-only, so a plain recursive remove stops partway and leaves an
# orphaned remnant whose bumped mtime hides it from the age filter forever. `go clean`
# handles those permissions itself.
#
#   $1  label used in the log ("GOCACHE" / "GOMODCACHE")
#   $2  the `go env` variable naming the cache directory
#   $3  the `go clean` flag that empties it
reclaim_go_cache() {
  local label=$1 env_var=$2 clean_flag=$3
  local dir canon cache_mb budget_mb

  dir=$("$go_bin" env "$env_var" 2>/dev/null)
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  # Remembered by resolved path, so the fallback module-cache sweep (2c) does not decide, or
  # count, the same cache a second time when GOMODCACHE names one of its candidates.
  canon=$(cd -- "$dir" 2>/dev/null && pwd -P) || canon=''
  [ -z "$canon" ] || BUDGETED_CACHES="${BUDGETED_CACHES}${canon}"$'\n'

  if ! cache_mb=$(size_mb "$dir"); then
    log "${label} size unmeasurable — keeping"
    return 0
  fi

  budget_mb=$((CACHE_BUDGET_GB * 1024))
  log "${label} ${dir} = ${cache_mb} MB (budget ${budget_mb} MB)"

  if [ "$cache_mb" -le "$budget_mb" ]; then
    log "${label} within budget — keeping (a warm cache is worth more than the space)"
    return 0
  fi

  # The budget says this cache is worth trimming; liveness says whether it is safe to.
  # `go clean` empties the cache wholesale, so a build reading it mid-sweep loses files
  # from under itself. The tree sweep's own checks run later and only on its candidates,
  # so this cache is asked about here: from the snapshot now, and afresh before the clean.
  #
  # Checked BEFORE the mode branch so the dry-run projection matches what apply would do.
  # The scheduled sibling runs dry-run, so a summary promising space that apply would then
  # keep is the same class of defect as one that omits space it would reclaim.
  if dir_in_use "$dir"; then
    log "${label} ${dir} in use by a live process — keeping"
    return 0
  fi

  if [ "$MODE" != apply ]; then
    # Count the projection, exactly as the tree sweep below does for a WOULD REAP. Without
    # this the dry-run summary reports the tree total alone and silently omits the caches --
    # which are the larger half. Measured on the real host: the log said GOMODCACHE would
    # reclaim ~34794 MB while the summary beneath it read "would reclaim=~43 MB". Dry-run is
    # the mode the scheduled sibling runs, so that summary is the line an operator actually
    # reads to decide whether reclaiming is worth doing at all.
    reclaimed_mb=$((reclaimed_mb + cache_mb))
    log "${label} would be cleaned (over budget), ~${cache_mb} MB"
    return 0
  fi

  # dir_in_use answered from the snapshot taken at the start of the run, and `du` over this
  # cache alone takes minutes: ample time for a build to start and open files in it. Ask
  # again, about this cache only, immediately before emptying it -- the late re-check the
  # tree sweep and the golangci-lint cache already make (monorepo#3710). A probe that finds
  # a holder, or cannot finish, keeps the cache.
  if ! still_idle "$dir"; then
    log "${label} ${dir} in use at removal time — keeping"
    return 0
  fi

  if "$go_bin" clean "$clean_flag" 2>/dev/null; then
    reclaimed_mb=$((reclaimed_mb + cache_mb))
    log "${label} cleaned, reclaimed ~${cache_mb} MB"
  else
    log "${label} clean FAILED — keeping"
  fi
}

# BUDGETED_CACHES lists, by resolved path, every cache reclaim_go_cache decided.
BUDGETED_CACHES=''
if go_bin=$(find_go); then
  # The BUILD cache is the largest single consumer (55 GB when the host filled). The
  # MODULE cache is the second (34 GB) and is named by the issue's acceptance criteria;
  # leaving it out would let a third of the reclaimable space keep growing unowned.
  reclaim_go_cache GOCACHE GOCACHE -cache
  reclaim_go_cache GOMODCACHE GOMODCACHE -modcache
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
  # NO early `exit` in the match rule. Under `set -o pipefail`, an awk that exits on its
  # first hit closes the pipe, printf takes SIGPIPE, and the PIPELINE reports 141 -- which
  # this function reads as "not in use", and the caller then DELETES. Measured on a
  # ~20k-line snapshot: the early-exit form returns 141 on a genuine match, while the same
  # program over a short snapshot returns 0, so the bug only bites once the host is busy.
  # Scanning to EOF costs microseconds and is the only form whose status means what it says.
  printf "%s\n" "$LSOF_SNAPSHOT" |
    awk -v p="$canon" 'index($0, p "/") == 1 || $0 == p { found = 1 } END { exit !found }'
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

# tree_in_use asks the liveness snapshot about one tree, at the scope its root needs.
#   temp-root  holds_open: the snapshot narrowed to TMPDIR_ROOT, for the per-run sweep.
#   host       dir_in_use: the whole snapshot. The Go work-dir sweep MUST use this one:
#              the per-user temp dir is not under TMPDIR_ROOT, so the narrowed snapshot
#              would report every tree there as idle.
# An unknown scope reports "in use", so a caller's typo keeps the tree.
tree_in_use() {
  case "$2" in
    temp-root) holds_open "$1" ;;
    host) dir_in_use "$1" ;;
    *) return 0 ;;
  esac
}

# sweep_candidate reaps or keeps ONE candidate tree under the rules every sweep shares.
# Both sweeps go through it, so their guards cannot drift apart.
#
#   $1  the candidate tree
#   $2  the liveness scope for tree_in_use: temp-root or host
#   $3  optional: run-cache, which repeats the marked-cache hold check just before removal;
#       or budget-cache, for a marked Go cache over its budget while still written to (2b). Its
#       late check re-reads the marker but NOT the idle rule, which such a cache fails by
#       definition, and it is emptied (empty_marked_cache) rather than removed
#   $4  optional: the tree's size in MB, when the caller has already measured it
sweep_candidate() {
  local tree=$1 scope=$2 tree_mb=${4:-} late_hold late_kind
  [ -n "$tree" ] || return 0
  [ -d "$tree" ] || return 0
  if own_session_tree "$tree"; then
    kept=$((kept + 1))
    return 0
  fi
  if tree_in_use "$tree" "$scope"; then
    kept=$((kept + 1))
    log "KEEP  (in use)        $tree"
    return 0
  fi
  if [ -z "$tree_mb" ] && ! tree_mb=$(size_mb "$tree"); then
    # Kept, but not examined: a tree whose size could not be read is UNKNOWN, never a clean KEEP.
    unknown=$((unknown + 1))
    log "UNKNOWN (unmeasurable) $tree"
    return 0
  fi
  if [ "$MODE" = apply ]; then
    # Everything above was decided from the up-front snapshot, which by now is minutes
    # old. Ask once more, about this tree alone, before destroying it.
    if ! still_idle "$tree"; then
      kept=$((kept + 1))
      log "KEEP  (in use, late)  $tree"
      return 0
    fi
    # A marked cache can be written to without any file staying open across both lsof probes,
    # so its own recency (and, for a lint cache, a running linter) is asked again here too.
    if [ "${3:-}" = run-cache ]; then
      late_hold=$(run_cache_hold "$tree" late)
      case "$late_hold" in
        '') ;;
        unknown)
          unknown=$((unknown + 1))
          log "UNKNOWN (scan failed, cache not examined) $tree"
          return 0
          ;;
        *)
          kept=$((kept + 1))
          log "KEEP  (busy, late)    $tree"
          return 0
          ;;
      esac
    fi
    if [ "${3:-}" = budget-cache ]; then
      # The marker is what licenses emptying this directory, so it is read again through the
      # same bounded reader: a README that changed or vanished since the listing keeps the tree.
      if ! late_kind=$(run_cache_kind "$tree") || [ "$late_kind" != go ]; then
        unknown=$((unknown + 1))
        log "UNKNOWN (marker changed, cache not examined) $tree"
        return 0
      fi
      empty_marked_cache "$tree" "$tree_mb"
      return 0
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
}

# empty_marked_cache <dir> <size-mb> empties a marked cache and keeps the directory and its README,
# as reclaim_lint_cache and `go clean -cache` do. It is only reached through sweep_candidate, after
# every guard there.
#
# Emptied, not removed, because this cache is still in use between runs: a lane's GOCACHE names
# the directory, so it keeps the mode and owner the lane created it with, and the README keeps
# identifying it to the next sweep -- which then reports its size again, and reaps it whole under
# the idle rule once the lane stops using it.
empty_marked_cache() {
  local tree=$1 tree_mb=$2 leftover after_mb
  chmod -R u+w -- "$tree" 2>/dev/null || true
  find "$tree" -mindepth 1 -maxdepth 1 ! -name README -exec rm -rf -- {} + 2>/dev/null
  # Judged by what is LEFT, not by find's status (see reclaim_lint_cache).
  if leftover=$(find "$tree" -mindepth 1 -maxdepth 1 ! -name README 2>/dev/null) &&
    [ -z "$leftover" ]; then
    removed=$((removed + 1))
    reclaimed_mb=$((reclaimed_mb + tree_mb))
    log "REAP  ${tree_mb} MB  (emptied, README kept) $tree"
  elif after_mb=$(size_mb "$tree") && [ "$after_mb" -lt "$tree_mb" ]; then
    kept=$((kept + 1))
    reclaimed_mb=$((reclaimed_mb + tree_mb - after_mb))
    log "KEEP  (empty incomplete, reclaimed ~$((tree_mb - after_mb)) MB) $tree"
  else
    kept=$((kept + 1))
    log "KEEP  (remove failed) $tree"
  fi
}

# run_cache_kind <dir> prints `go` or `lint` when <dir>'s README opens with that tool's cache marker
# as its exact first line, and `none` otherwise; it returns 2 when the README could not be read.
# This is the ONE place a marker is read, so every decision uses the same fail-closed, bounded
# answer:
#   * the README must be a regular file that is not a symlink: a FIFO, a device or a link to a
#     stream would block the read, and any temp-root entry could plant one to stall the sweep;
#   * only the first 512 bytes are read: an unrelated README may be huge or still growing;
#   * the first line must BE the marker, not merely quote it: an unrelated directory whose README
#     mentions the sentence is not a regenerable cache.
# A cache whose marker was never read was never examined, so callers count a 2 as UNKNOWN.
run_cache_kind() {
  local readme="$1/README" prefix first
  # A directory this run cannot list or search hides its README: that is "not examined", never
  # "no marker".
  if [ ! -r "$1" ] || [ ! -x "$1" ]; then
    return 2
  fi
  if [ ! -f "$readme" ] || [ -L "$readme" ]; then
    printf none
    return 0
  fi
  prefix=$(head -c 512 -- "$readme" 2>/dev/null) || return 2
  first=${prefix%%$'\n'*}
  case "$first" in
    "$GO_CACHE_MARKER") printf go ;;
    "$LINT_CACHE_MARKER") printf lint ;;
    *) printf none ;;
  esac
}

# is_run_cache <dir> returns 0 for a marked cache, 1 for none, and 2 when the README could not
# be read (run_cache_kind).
is_run_cache() {
  local kind
  kind=$(run_cache_kind "$1") || return 2
  [ "$kind" != none ]
}

if [ -d "$TMPDIR_ROOT" ]; then
  while IFS= read -r tree; do
    # A marked cache is left to (2b), whose idle rule looks at its entries: the day-based
    # mtime of the root alone can be old while the cache was written minutes ago.
    [ -n "$tree" ] || continue
    if is_run_cache "$tree"; then continue; else marker_rc=$?; fi
    if [ "$marker_rc" -eq 2 ]; then
      unknown=$((unknown + 1))
      log "UNKNOWN (marker unreadable, cache not examined) $tree"
      continue
    fi
    sweep_candidate "$tree" temp-root
  done <<EOF
$(find -H "$TMPDIR_ROOT" -maxdepth 1 -type d \
  \( -name 'codex-*' -o -name 'war-*' -o -name 'dpc-*' -o -name 'ksail-*' \) \
  -mtime "+${MIN_AGE_DAYS}" 2>/dev/null)
EOF
fi

# ---------------------------------------------------------------------------
# 2b. Per-run Go and golangci-lint caches under the temp root, recognised by marker.
#
# Agent runs point GOCACHE (and golangci-lint's cache) at a fresh directory under the temp
# root, and each fills to 6-12 GB. On 2026-09-30 the host reached 100% again with 75 GB of
# them. The name patterns in (2) never match `daily-ai-engineer-gocache-*`, and
# `-mtime +3` (whole days, so four in practice) keeps every other one for days while lanes
# create several a day. So they are recognised by what they ARE -- the README each tool
# writes into its cache dir -- whatever the directory is called, and are reclaimed once
# nothing has been written to them for RUN_CACHE_IDLE_HOURS. Every guard in
# sweep_candidate still applies, and a cache is regenerable: removing one costs a rebuild.
#
# The idle rule alone leaves one gap. A lane that REUSES a single such cache every hour is never
# idle, so it was kept forever with no size and no budget: /private/tmp/go-cache-codex grew from
# 21 GB to 36 GB in five hours on 2026-10-04 (monorepo#3831). A Go build cache that is still
# being written to is therefore held to cache_budget_gb, like the default GOCACHE in (1) and the
# fallback module cache in (2c): within it the cache is kept and its size logged, over it the
# cache is emptied -- unless a live process holds it open, now or at removal time. A recent
# golangci-lint cache is not budgeted here: cache_budget_gb is sized for a Go build cache, and
# the lint budget belongs to (3).
# ---------------------------------------------------------------------------

# run_cache_idle <dir> succeeds (0) when nothing anywhere in the cache has changed within
# RUN_CACHE_IDLE_HOURS, and returns 1 when something has. The whole tree is scanned: Go overwrites
# an entry in place and refreshes its mtime on a cache hit without moving the fan-out dir's mtime,
# and a fuzz corpus entry (fuzz/<import-path>/<target>/<hash>) sits deeper still, so no fixed
# depth sees every write. The scan stops at the first recent node (-quit), so a busy cache costs
# little. A scan that fails before deciding returns 2: that cache was not examined.
run_cache_idle() {
  local recent
  recent=$(find "$1" -mmin "-$((RUN_CACHE_IDLE_HOURS * 60))" -print -quit 2>/dev/null) ||
    return 2
  [ -z "$recent" ]
}

# run_cache_hold <dir> [late] prints why a marked cache must be kept, and nothing when it may go.
# `late` (the removal-time recheck) reads a fresh process table instead of the startup one.
#   recent   written within RUN_CACHE_IDLE_HOURS
#   unknown  the recency scan failed
#   linting  a golangci-lint cache while a golangci-lint runs, or the process table cannot say.
#            A linter can sit between two cache reads with no file open, so the lsof probes
#            cannot see it -- the same rule reclaim_lint_cache applies to the configured cache.
run_cache_hold() {
  local tree=$1 when=${2:-early} rc oldest table kind
  if run_cache_idle "$tree"; then rc=0; else rc=$?; fi
  case "$rc" in
    0) ;;
    1) printf recent; return 0 ;;
    *) printf unknown; return 0 ;;
  esac
  # The kind is read again through the same bounded, typed reader: a README that can no longer be
  # read, or no longer carries a marker, is a changed tree and is kept.
  if ! kind=$(run_cache_kind "$tree") || [ "$kind" = none ]; then
    printf unknown
    return 0
  fi
  if [ "$kind" = lint ]; then
    if [ "$when" = late ]; then
      # The startup snapshot is minutes old by removal time; a linter started since then is
      # only in a fresh table (the same late read reclaim_lint_cache makes).
      # A table that cannot be read or parsed is `unknown`; only a proven process is `linting`.
      if ! table=$(read_process_table) || ! oldest=$(oldest_in_table "$table" golangci-lint); then
        printf unknown
      elif [ "$oldest" != -1 ]; then
        printf linting
      fi
    elif ! oldest=$(oldest_process_secs golangci-lint); then
      printf unknown
    elif [ "$oldest" != -1 ]; then
      printf linting
    fi
  fi
  return 0
}

# lint_cache_dir prints the cache dir golangci-lint would use, resolved the way it does
# (internal/go/cache.DefaultDir): GOLANGCI_LINT_CACHE when set, which golangci-lint only
# honours as an absolute path, else os.UserCacheDir()/golangci-lint -- ~/Library/Caches on
# macOS, ${XDG_CACHE_HOME:-~/.cache} elsewhere. Returns 1 when golangci-lint would run
# with no cache at all ("off", a relative path, no home), so there is nothing to reclaim.
lint_cache_dir() {
  local base
  if [ -n "${GOLANGCI_LINT_CACHE:-}" ]; then
    case "$GOLANGCI_LINT_CACHE" in
      /*) printf '%s' "$GOLANGCI_LINT_CACHE" ;;
      *) return 1 ;;
    esac
    return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) base=${HOME:+${HOME}/Library/Caches} ;;
    *) base=${XDG_CACHE_HOME:-${HOME:+${HOME}/.cache}} ;;
  esac
  case "$base" in
    /*) printf '%s/golangci-lint' "$base" ;;
    *) return 1 ;;
  esac
}

# The Go build cache and the golangci-lint cache (its override, or the default it resolves to)
# are budget-managed by (1) and (3): a configured cache within its budget is kept on purpose,
# so this sweep must not reap it for idleness. Compared on resolved paths, like every other tree
# test here.
# go_default_cache_dir prints the build cache path go uses when GOCACHE is unset
# (os.UserCacheDir()/go-build): ~/Library/Caches on macOS, ${XDG_CACHE_HOME:-~/.cache} elsewhere.
# XDG_CACHE_HOME may point at the temp root, so this default is excluded too, whatever GOCACHE says.
go_default_cache_dir() {
  local base
  case "$(uname -s 2>/dev/null)" in
    Darwin) base=${HOME:+${HOME}/Library/Caches} ;;
    *) base=${XDG_CACHE_HOME:-${HOME:+${HOME}/.cache}} ;;
  esac
  case "$base" in
    /*) printf '%s/go-build' "$base" ;;
  esac
}

configured_caches=''
# Without the configured Go cache's path the exclusion is incomplete, so a read that fails or
# yields something other than `off` or an absolute path skips the marker sweep as UNKNOWN rather
# than risk reaping the budget-managed cache for idleness. With no go binary at all, the setting
# is read where go itself would read it: the GOCACHE variable, else a GOCACHE= line in the go env
# file (`go env -w`; $GOENV, or its default under the user config dir). A missing or `off` env
# file means GOCACHE is at Go's default in the user cache dir, never the temp root; an env file
# that exists but cannot be read is UNKNOWN.
configured_gocache=''
goenv_caches=''
run_caches_readable=0
if [ -z "${go_bin:-}" ]; then
  configured_gocache=${GOCACHE:-}
  run_caches_readable=1
  if [ -z "$configured_gocache" ]; then
    goenv_file=${GOENV:-}
    if [ -z "$goenv_file" ]; then
      case "$(uname -s 2>/dev/null)" in
        Darwin) goenv_file=${HOME:+${HOME}/Library/Application Support/go/env} ;;
        *) goenv_file=${XDG_CONFIG_HOME:-${HOME:+${HOME}/.config}}/go/env ;;
      esac
    fi
    if [ -n "$goenv_file" ] && [ "$goenv_file" != off ] && [ "${goenv_file#/}" = "$goenv_file" ]; then
      # Relative GOENV resolves against whatever directory go runs in, so it cannot be read here.
      run_caches_readable=0
      unknown=$((unknown + 1))
      log "UNKNOWN (GOENV '$goenv_file' is not absolute) $TMPDIR_ROOT: per-run caches not examined"
    elif [ "$goenv_file" != off ] && [ ! -e "$goenv_file" ]; then
      # Absent only if the nearest existing ancestor could be searched; otherwise the file may
      # exist behind it, so the setting is unknown.
      goenv_probe=${goenv_file%/*}
      while [ -n "$goenv_probe" ] && [ ! -e "$goenv_probe" ]; do goenv_probe=${goenv_probe%/*}; done
      if [ -n "$goenv_probe" ] && { [ ! -d "$goenv_probe" ] || [ ! -x "$goenv_probe" ]; }; then
        run_caches_readable=0
        unknown=$((unknown + 1))
        log "UNKNOWN (go env file uninspectable) $TMPDIR_ROOT: per-run caches not examined"
      fi
    elif [ "$goenv_file" != off ]; then
      # Every GOCACHE= line is excluded, not just the one go would pick (the last): excluding more
      # only keeps more, so duplicate assignments cannot leave the effective cache unprotected.
      if goenv_line=$(grep '^GOCACHE=' -- "$goenv_file" 2>/dev/null); then
        goenv_caches=$(printf '%s\n' "$goenv_line" | sed 's/^GOCACHE=//')
      elif [ $? -ne 1 ]; then
        run_caches_readable=0
        unknown=$((unknown + 1))
        log "UNKNOWN (go env file unreadable) $TMPDIR_ROOT: per-run caches not examined"
      fi
    fi
  fi
elif ! configured_gocache=$("$go_bin" env GOCACHE 2>/dev/null); then
  unknown=$((unknown + 1))
  log "UNKNOWN (go env GOCACHE failed) $TMPDIR_ROOT: per-run caches not examined"
else
  case "$configured_gocache" in
    off | /?*) run_caches_readable=1 ;;
    *)
      unknown=$((unknown + 1))
      log "UNKNOWN (go env GOCACHE gave '$configured_gocache') $TMPDIR_ROOT: per-run caches not examined"
      ;;
  esac
fi
while IFS= read -r configured; do
  case "$configured" in
    /*) ;;
    *) continue ;;
  esac
  configured=$(cd -- "$configured" 2>/dev/null && pwd -P) || continue
  [ -n "$configured" ] && configured_caches="${configured_caches}${configured}"$'\n'
done <<EOF
$configured_gocache
$(go_default_cache_dir)
$(lint_cache_dir)
$goenv_caches
EOF

run_cache_trees=''
if [ "$run_caches_readable" -eq 1 ] && [ -d "$TMPDIR_ROOT" ]; then
  # Read the listing on its own, so a failed scan is seen: inside a heredoc substitution its
  # status is lost, and a partial listing would end in a clean-looking summary.
  # -H follows the root itself when it is a symlink (/tmp on macOS); without it find lists
  # nothing and reports success.
  if ! run_cache_trees=$(find -H "$TMPDIR_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null); then
    run_cache_trees=''
    unknown=$((unknown + 1))
    log "UNKNOWN (scan failed) $TMPDIR_ROOT: per-run caches not examined"
  fi
fi
# Claude Code gives each session a scratchpad at <root>/claude-<uid>/<project>/<session>/scratchpad,
# and a run that sets GOCACHE there leaves a 3-6 GB cache one level below it, four levels deeper
# than the listing above reaches. On 2026-10-02 two of them held 8.9 GB that this sweep never saw.
# Only that exact depth under a claude-* root is listed; every marker and liveness guard still applies.
scratch_cache_trees=''
if [ -n "$run_cache_trees" ]; then
  while IFS= read -r session_root; do
    case "${session_root##*/}" in
      claude-*) ;;
      *) continue ;;
    esac
    [ -L "$session_root" ] && continue
    if ! nested=$(find "$session_root" -mindepth 4 -maxdepth 4 -type d \
      -path "${session_root}/*/*/scratchpad/*" 2>/dev/null); then
      unknown=$((unknown + 1))
      log "UNKNOWN (scan failed) $session_root: session scratchpad caches not examined"
      continue
    fi
    [ -n "$nested" ] && scratch_cache_trees="${scratch_cache_trees}${nested}"$'\n'
  done <<EOF
$run_cache_trees
EOF
  run_cache_trees="${run_cache_trees}"$'\n'"${scratch_cache_trees}"
fi
if [ -n "$run_cache_trees" ]; then
  while IFS= read -r tree; do
    [ -n "$tree" ] || continue
    # A symlink could make the marker check and the removal act on another tree.
    [ -L "$tree" ] && continue
    # The status is read in the else branch: `if ! f` would turn f's 2 into a 0.
    if is_run_cache "$tree"; then :; else
      marker_rc=$?
      if [ "$marker_rc" -eq 2 ]; then
        unknown=$((unknown + 1))
        log "UNKNOWN (marker unreadable, cache not examined) $tree"
      fi
      continue
    fi
    canon=$(cd -- "$tree" 2>/dev/null && pwd -P) || canon=''
    case $'\n'"$configured_caches" in
      *$'\n'"$canon"$'\n'*)
        [ -n "$canon" ] && continue
        ;;
    esac
    hold=$(run_cache_hold "$tree")
    case "$hold" in
      '') sweep_candidate "$tree" temp-root run-cache ;;
      recent)
        # A cache in use between runs: budgeted when it is a Go build cache (monorepo#3831).
        # The kind comes from the same bounded reader; anything but a readable Go marker keeps
        # the old answer, so a lint cache is kept for being recent exactly as before.
        kind=$(run_cache_kind "$tree") || kind=''
        if [ "$kind" != go ]; then
          kept=$((kept + 1))
          log "KEEP  (written within ${RUN_CACHE_IDLE_HOURS}h) $tree"
        elif ! cache_mb=$(size_mb "$tree"); then
          unknown=$((unknown + 1))
          log "UNKNOWN (unmeasurable) $tree"
        elif [ "$cache_mb" -le "$((CACHE_BUDGET_GB * 1024))" ]; then
          kept=$((kept + 1))
          log "KEEP  (written within ${RUN_CACHE_IDLE_HOURS}h) ${cache_mb} MB, budget $((CACHE_BUDGET_GB * 1024)) MB  $tree"
        else
          log "per-run GOCACHE ${tree} = ${cache_mb} MB (budget $((CACHE_BUDGET_GB * 1024)) MB), over budget while written within ${RUN_CACHE_IDLE_HOURS}h"
          sweep_candidate "$tree" temp-root budget-cache "$cache_mb"
        fi
        ;;
      linting)
        kept=$((kept + 1))
        log "KEEP  (golangci-lint running or unknown) $tree"
        ;;
      *)
        unknown=$((unknown + 1))
        log "UNKNOWN (scan failed, cache not examined) $tree"
        ;;
    esac
  done <<EOF
$run_cache_trees
EOF
fi

# ---------------------------------------------------------------------------
# 2c. Per-lane fallback module caches under the temp root, budgeted like GOMODCACHE.
#
# A runtime whose sandbox cannot write the default caches points GOMODCACHE at
# <temp root>/go-mod-<lane> (git-and-worktrees guide). Nothing owned that cache: (1) budgets
# only the GOMODCACHE this run's own `go env` reports, and a module cache carries no README,
# so the marker sweep in (2b) never selects it. It could grow without bound (monorepo#3710).
#
# It is BUDGETED, not aged. A lane keeps one module cache and reads it far more often than
# it writes to it, so an idle rule would empty a warm cache between every two runs and each
# run would download its modules again. Over cache_budget_gb it goes through sweep_candidate,
# with every guard that applies to a tree: the caller's own tree, the liveness snapshot, the
# late re-probe, and the read-only files a module cache is made of.
#
# Recognised by name AND shape: a direct child of the temp root named go-mod-* that holds
# cache/download, which the go command creates in every module cache it downloads into.
# Anything else called go-mod-* is not positively a module cache and is KEPT.
# ---------------------------------------------------------------------------

# is_module_cache <dir> returns 0 when <dir> is laid out like a Go module cache, 1 when it is
# not, and 2 when it could not be inspected. Symlinks do not count: the measurement and the
# removal must act on this tree and no other.
is_module_cache() {
  local dir=$1
  # A directory this run cannot list or search hides its layout: "not examined", never "not one".
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    return 2
  fi
  if [ ! -d "${dir}/cache" ] || [ -L "${dir}/cache" ]; then
    return 1
  fi
  if [ ! -r "${dir}/cache" ] || [ ! -x "${dir}/cache" ]; then
    return 2
  fi
  if [ ! -d "${dir}/cache/download" ] || [ -L "${dir}/cache/download" ]; then
    return 1
  fi
  return 0
}

# reclaim_fallback_modcache <dir> keeps one fallback module cache within the budget.
reclaim_fallback_modcache() {
  local tree=$1 label='fallback GOMODCACHE' shape_rc canon cache_mb budget_mb
  # The status is read in the else branch: `if ! f` would turn f's 2 into a 0.
  if is_module_cache "$tree"; then :; else
    shape_rc=$?
    if [ "$shape_rc" -eq 2 ]; then
      unknown=$((unknown + 1))
      log "UNKNOWN (unreadable, module cache not examined) $tree"
    fi
    return 0
  fi
  canon=$(cd -- "$tree" 2>/dev/null && pwd -P) || canon=''
  if [ -z "$canon" ]; then
    unknown=$((unknown + 1))
    log "UNKNOWN (unresolvable, module cache not examined) $tree"
    return 0
  fi
  # (1) has already decided the GOMODCACHE this run's go reports.
  case $'\n'"$BUDGETED_CACHES" in
    *$'\n'"$canon"$'\n'*) return 0 ;;
  esac
  if ! cache_mb=$(size_mb "$tree"); then
    unknown=$((unknown + 1))
    log "UNKNOWN (unmeasurable) $tree"
    return 0
  fi
  budget_mb=$((CACHE_BUDGET_GB * 1024))
  log "${label} ${tree} = ${cache_mb} MB (budget ${budget_mb} MB)"
  if [ "$cache_mb" -le "$budget_mb" ]; then
    log "${label} within budget — keeping (a warm cache is worth more than the space)"
    return 0
  fi
  sweep_candidate "$tree" temp-root
}

if [ -d "$TMPDIR_ROOT" ]; then
  # Listed on its own, so a failed scan is seen (see the marker sweep above). -H follows the
  # root itself when it is a symlink; a symlinked CHILD is not `-type d` and is never listed.
  if ! fallback_modcaches=$(find -H "$TMPDIR_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name 'go-mod-*' 2>/dev/null); then
    fallback_modcaches=''
    unknown=$((unknown + 1))
    log "UNKNOWN (scan failed) $TMPDIR_ROOT: fallback module caches not examined"
  fi
  while IFS= read -r tree; do
    [ -n "$tree" ] || continue
    reclaim_fallback_modcache "$tree"
  done <<EOF
$fallback_modcaches
EOF
fi

# ---------------------------------------------------------------------------
# 3. golangci-lint cache, emptied only when it exceeds its own budget.
#
# golangci-lint keeps a content-addressed cache of its own, built from a copy of Go's
# build cache, and nothing here bounded it: 3.3 GB when the host filled. The binary is
# usually NOT on PATH on the host (it runs via `go run` or in containers), so this cannot
# lean on `golangci-lint cache clean` the way the Go caches lean on `go clean`.
# ---------------------------------------------------------------------------

# reclaim_lint_cache follows reclaim_go_cache's rules -- budget first, then liveness,
# with every "I could not tell" keeping the cache -- plus two of its own:
#   * the directory must carry golangci-lint's README marker. The override is a free-form
#     path, and this empties whatever it names; the marker is what proves it names a
#     golangci-lint cache rather than, say, a home directory.
#   * a running golangci-lint keeps it. The open-file check alone cannot see a linter
#     between two cache reads, and emptying the cache under it costs that run its results.
# The README itself is kept, so the directory still identifies itself on the next sweep.
reclaim_lint_cache() {
  local label=GOLANGCI_LINT_CACHE dir canon cache_mb budget_mb oldest fresh leftover after_mb

  if ! dir=$(lint_cache_dir); then
    log "${label} disabled or not an absolute path — nothing to reclaim"
    return 0
  fi
  if [ ! -d "$dir" ]; then
    log "${label} ${dir} absent — nothing to do"
    return 0
  fi
  # Work on the PHYSICAL path: lsof reports physical paths, and `find` does not descend
  # through a symlinked starting point, so the removal below would silently do nothing.
  canon=$(cd -- "$dir" 2>/dev/null && pwd -P) || canon=''
  if [ -z "$canon" ]; then
    log "${label} ${dir} cannot be resolved — keeping"
    return 0
  fi
  if ! grep -qF -- "$LINT_CACHE_MARKER" "${canon}/README" 2>/dev/null; then
    log "${label} ${canon} carries no golangci-lint README marker — keeping"
    return 0
  fi

  if ! cache_mb=$(size_mb "$canon"); then
    log "${label} size unmeasurable — keeping"
    return 0
  fi
  budget_mb=$((LINT_BUDGET_GB * 1024))
  log "${label} ${canon} = ${cache_mb} MB (budget ${budget_mb} MB)"
  if [ "$cache_mb" -le "$budget_mb" ]; then
    log "${label} within budget — keeping (a warm cache is worth more than the space)"
    return 0
  fi

  # Liveness, checked BEFORE the mode branch so the dry-run projection matches apply.
  if ! oldest=$(oldest_process_secs golangci-lint); then
    log "${label} cannot tell whether golangci-lint is running — keeping"
    return 0
  fi
  if [ "$oldest" != -1 ]; then
    log "${label} golangci-lint process running — keeping"
    return 0
  fi
  if dir_in_use "$canon"; then
    log "${label} ${canon} in use by a live process — keeping"
    return 0
  fi

  if [ "$MODE" != apply ]; then
    reclaimed_mb=$((reclaimed_mb + cache_mb))
    log "${label} would be cleaned (over budget), ~${cache_mb} MB"
    return 0
  fi

  # Both answers above come from snapshots taken at the start of the run, before the Go
  # caches and the per-run trees were measured, and `du` over one multi-gigabyte cache
  # alone takes minutes -- ample time for a lint run to start. Ask again, fresh,
  # immediately before emptying: the same late re-check the tree sweep makes.
  if ! fresh=$(read_process_table) || ! oldest=$(oldest_in_table "$fresh" golangci-lint) ||
    [ "$oldest" != -1 ]; then
    log "${label} golangci-lint running or unknown at removal time — keeping"
    return 0
  fi
  if ! still_idle "$canon"; then
    log "${label} ${canon} in use at removal time — keeping"
    return 0
  fi

  chmod -R u+w -- "$canon" 2>/dev/null || true
  find "$canon" -mindepth 1 -maxdepth 1 ! -name README -exec rm -rf -- {} + 2>/dev/null
  # Judge the result by what is LEFT, not by find's status: a partial removal still frees
  # space, and an unreadable leftover must not be reported as a clean sweep.
  if leftover=$(find "$canon" -mindepth 1 -maxdepth 1 ! -name README 2>/dev/null) &&
    [ -z "$leftover" ]; then
    reclaimed_mb=$((reclaimed_mb + cache_mb))
    log "${label} cleaned, reclaimed ~${cache_mb} MB"
  elif after_mb=$(size_mb "$canon") && [ "$after_mb" -lt "$cache_mb" ]; then
    reclaimed_mb=$((reclaimed_mb + cache_mb - after_mb))
    log "${label} clean INCOMPLETE, reclaimed ~$((cache_mb - after_mb)) MB"
  else
    log "${label} clean FAILED — keeping"
  fi
}

reclaim_lint_cache

# ---------------------------------------------------------------------------
# 4. Go's own orphaned work dirs under the per-user temp dir.
#
# The go command makes a `go-build<digits>` work dir (the linker a `go-link-<digits>` one)
# in the temp dir and deletes it when it exits normally. A go command that is KILLED -- a
# timeout, a cancelled agent run -- leaves it behind for good, and each one holds a whole
# build's objects and binaries: five of them, 0.9-4.75 GB each, held 15.7 GB when the
# host filled on 2026-09-29, with no Go process running.
#
# Matched by exact name shape AND an hours-scale age AND liveness, where liveness is both
# the open-file check and the toolchain check below.
# ---------------------------------------------------------------------------
# The toolchain processes that create or write into a Go work dir. A killed go command's
# children can outlive it, so the tools are listed as well as the go command itself.
GO_TOOLCHAIN_NAMES=(go compile link asm cgo vet)

# GO_TOOLCHAIN_OLDEST is how long the longest-running toolchain process has run, in
# seconds: -1 when none is running, "unknown" when the process table cannot say.
GO_TOOLCHAIN_OLDEST=unknown
if oldest=$(oldest_process_secs "${GO_TOOLCHAIN_NAMES[@]}"); then
  case "$oldest" in
    -1) GO_TOOLCHAIN_OLDEST=-1 ;;
    '' | *[!0-9]*) ;;
    *) GO_TOOLCHAIN_OLDEST=$oldest ;;
  esac
fi

# go_toolchain_could_own reports whether a running toolchain process could own `tree`.
#
# A go command creates its work dir when it starts, so a dir last modified BEFORE every
# running toolchain process started cannot belong to any of them -- and that is the only
# case this lets through. Open files alone cannot make that call: a go command holds
# nothing under its work dir between build steps, so a live build can look idle to lsof.
#
# The table was read at the start of the run, which by now can be many minutes ago, so
# each process is aged to the present before comparing; otherwise a dir modified in that
# gap would read as older than a process that in fact predates it. The comparison runs in
# whole minutes with a margin of two, and every unknown keeps the tree.
go_toolchain_could_own() {
  local tree=$1 now age_s hit
  [ "$GO_TOOLCHAIN_OLDEST" != unknown ] || return 0
  [ "$GO_TOOLCHAIN_OLDEST" -ge 0 ] || return 1
  now=$(date +%s 2>/dev/null) || return 0
  case "$now" in
    '' | *[!0-9]*) return 0 ;;
  esac
  age_s=$((GO_TOOLCHAIN_OLDEST + now - PS_EPOCH))
  hit=$(find "$tree" -maxdepth 0 -mmin "-$((age_s / 60 + 2))" 2>/dev/null) || return 0
  [ -n "$hit" ]
}

if [ -d "$GO_TMP_ROOT" ]; then
  while IFS= read -r tree; do
    [ -n "$tree" ] || continue
    # `find -name` cannot say "digits only", so check the suffix here. Only the exact shape
    # the go command creates is ever considered; `go-buildcache` or `go-build-x` are not it.
    name=${tree##*/}
    case "$name" in
      go-build*) suffix=${name#go-build} ;;
      go-link-*) suffix=${name#go-link-} ;;
      *) continue ;;
    esac
    case "$suffix" in
      '' | *[!0-9]*) continue ;;
    esac
    if go_toolchain_could_own "$tree"; then
      kept=$((kept + 1))
      log "KEEP  (go running)    $tree"
      continue
    fi
    sweep_candidate "$tree" host
  done <<EOF
$(find "$GO_TMP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  \( -name 'go-build[0-9]*' -o -name 'go-link-[0-9]*' \) \
  -mmin "+$((GO_TMP_MIN_AGE_HOURS * 60))" 2>/dev/null)
EOF
fi

# ---------------------------------------------------------------------------
# 5. The local container runtime's image store, trimmed only when it exceeds its own budget.
#
# The lanes pull and build images with the `container` CLI for throwaway clusters and image
# checks, and nothing removed any of them. On 2026-10-05 the store held 65 GB, 57 GB of it
# images no container used, while the disk preflight read LOW and this sweep reclaimed 160 MB
# (monorepo#3848). Each unpacked platform variant costs about 2 GB whatever the image's real
# size, so the store grows far faster than the pulls suggest.
# ---------------------------------------------------------------------------

CONTAINER_BUDGET_GB=$(uint_setting BUILD_CACHE_RECLAIM_CONTAINER_BUDGET_GB \
  "${BUILD_CACHE_RECLAIM_CONTAINER_BUDGET_GB:-10}") || exit 2
# Hours since an image was UNPACKED, which is the only local timestamp the store keeps: the
# image's own creation date says when it was built upstream, not when a lane fetched it. An
# image a lane uses every hour is therefore removed too once it is this old, and pulled again
# on its next use. That is the cost of a cache, and it is paid only while over budget.
CONTAINER_IMAGE_MIN_AGE_HOURS=$(uint_setting BUILD_CACHE_RECLAIM_CONTAINER_IMAGE_MIN_AGE_HOURS \
  "${BUILD_CACHE_RECLAIM_CONTAINER_IMAGE_MIN_AGE_HOURS:-24}") || exit 2
CONTAINER_LONG_RUN_HOURS=$(uint_setting BUILD_CACHE_RECLAIM_CONTAINER_LONG_RUN_HOURS \
  "${BUILD_CACHE_RECLAIM_CONTAINER_LONG_RUN_HOURS:-24}") || exit 2
CONTAINER_CLI=${BUILD_CACHE_RECLAIM_CONTAINER_CLI:-container}
CONTAINER_STORE=${BUILD_CACHE_RECLAIM_CONTAINER_STORE:-${HOME:-}/Library/Application Support/com.apple.container}

# container_unknown records a read of the store that could not be made. The store may hold
# tens of gigabytes this sweep then never examined, so the summary is partial, never clean.
container_unknown() {
  unknown=$((unknown + 1))
  log "UNKNOWN: CONTAINER_IMAGES $*"
}

# container_image_usage prints "<size-bytes> <unused-bytes>" for the image store.
container_image_usage() {
  local json
  json=$("$CONTAINER_CLI" system df --format json 2>/dev/null) || return 1
  jq -er '
    [.images.sizeInBytes, .images.reclaimable] as $v
    | if ($v | all(type == "number" and . >= 0 and . == floor)) then "\($v[0]) \($v[1])"
      else error("image usage is not two whole numbers") end' <<<"$json" 2>/dev/null
}

# container_list prints every container, running or stopped, as JSON.
container_list() {
  local json
  json=$("$CONTAINER_CLI" list --all --format json 2>/dev/null) || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$json" || return 1
  printf '%s' "$json"
}

# container_image_in_use reports whether any container, running or stopped, was created from
# the image: 0 in use, 1 not in use, 2 could not tell. A stopped container still needs its
# image to start again, so it counts. The list is read fresh on every call, immediately
# before the image it guards is removed.
container_image_in_use() {
  local name=$1 digest=$2 json
  json=$(container_list) || return 2
  jq -e --arg name "$name" --arg digest "$digest" '
    any(.[]; (.configuration.image.reference == $name)
      or (.configuration.image.descriptor.digest == $digest))' >/dev/null 2>&1 <<<"$json"
  case $? in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# container_image_old reports whether every unpacked variant of an image is older than the
# threshold: 0 old, 1 young, 2 could not tell. An image with no unpacked variant on disk
# cannot be aged, and one whose variant list is not plain digests cannot be trusted as a
# path, so both keep the image.
container_image_old() {
  local variants=$1 hex dir found=0 old
  local IFS=,
  for hex in $variants; do
    case "$hex" in
      '' | *[!0-9a-f]*) return 2 ;;
    esac
    [ "${#hex}" -eq 64 ] || return 2
    dir="${CONTAINER_STORE}/snapshots/${hex}"
    [ -d "$dir" ] || continue
    found=1
    old=$(find "$dir" -maxdepth 0 -mmin "+$((CONTAINER_IMAGE_MIN_AGE_HOURS * 60))" 2>/dev/null) ||
      return 2
    [ -n "$old" ] || return 1
  done
  [ "$found" -eq 1 ] || return 2
  return 0
}

# container_image_estimate sets CONTAINER_ESTIMATE_MB to the on-disk size of an image's
# unpacked variants that no earlier call counted. Two references to one image share its
# variants, so each is counted once across the sweep. It sets a variable instead of printing,
# because the running list of counted variants would not survive a command substitution.
CONTAINER_COUNTED=,
CONTAINER_ESTIMATE_MB=0
container_image_estimate() {
  local variants=$1 hex dir part
  local IFS=,
  CONTAINER_ESTIMATE_MB=0
  for hex in $variants; do
    case "$CONTAINER_COUNTED" in
      *",${hex},"*) continue ;;
    esac
    CONTAINER_COUNTED="${CONTAINER_COUNTED}${hex},"
    dir="${CONTAINER_STORE}/snapshots/${hex}"
    [ -d "$dir" ] || continue
    part=$(size_mb "$dir") || continue
    CONTAINER_ESTIMATE_MB=$((CONTAINER_ESTIMATE_MB + part))
  done
}

# report_long_running_containers names containers that have run longer than the threshold.
# It never stops one: a cluster somebody is using must not be ended by a cache sweep, and
# nothing here can tell an abandoned throwaway from a cluster in use. The line exists so the
# lane that started it can decide.
report_long_running_containers() {
  local json rows id started
  if ! json=$(container_list) || ! rows=$(jq -er --argjson hours "$CONTAINER_LONG_RUN_HOURS" '
      .[]
      | select(.status.state == "running")
      | (.status.startedDate | if type == "string" then (try fromdateiso8601 catch null) else null end) as $t
      | select($t != null and (now - $t) > ($hours * 3600))
      | [(.configuration.id | tostring), .status.startedDate] | @tsv' <<<"$json" 2>/dev/null); then
    # jq -e exits 4 when nothing matched, which is the ordinary "none" answer.
    [ -n "${json:-}" ] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$json" && return 0
    container_unknown "container list could not be read — long-running containers not reported"
    return 0
  fi
  while IFS=$'\t' read -r id started; do
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9_.-]*) id='<unprintable id>' ;;
    esac
    case "$started" in
      *[!0-9TZ:.+-]*) started='<unprintable time>' ;;
    esac
    log "NOTE  container ${id} running since ${started} (over ${CONTAINER_LONG_RUN_HOURS}h) — left running; the lane that started it decides"
  done <<<"$rows"
}

reclaim_container_images() {
  local label=CONTAINER_IMAGES usage size_b unused_b size_mb_before budget_mb images rows
  local name digest variants est_mb after after_b freed_mb verdict
  local would=0 deleted=0

  if [ "$CONTAINER_CLI" = off ]; then
    log "${label} disabled — nothing to reclaim"
    return 0
  fi
  if ! command -v "$CONTAINER_CLI" >/dev/null 2>&1; then
    log "${label} no container runtime on this host — nothing to do"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    container_unknown "jq is not available, so the store cannot be read"
    return 0
  fi
  if ! usage=$(container_image_usage); then
    container_unknown "store usage could not be read (is the container runtime running?)"
    return 0
  fi
  size_b=${usage%% *}
  unused_b=${usage##* }
  case "${size_b}${unused_b}" in
    '' | *[!0-9]*)
      container_unknown "store usage is not numeric"
      return 0
      ;;
  esac
  if [ "${#size_b}" -gt 15 ] || [ "${#unused_b}" -gt 15 ]; then
    container_unknown "store usage is implausibly large"
    return 0
  fi
  size_mb_before=$((10#$size_b / 1048576))
  budget_mb=$((CONTAINER_BUDGET_GB * 1024))
  log "${label} = ${size_mb_before} MB, $((10#$unused_b / 1048576)) MB of it used by no container (budget ${budget_mb} MB)"

  report_long_running_containers

  if [ "$size_mb_before" -le "$budget_mb" ]; then
    log "${label} within budget — keeping (a pulled image is worth more than the space)"
    return 0
  fi

  if ! images=$("$CONTAINER_CLI" image list --format json 2>/dev/null) ||
    ! rows=$(jq -er '
      if type != "array" then error("image list is not an array") else .[] end
      | [(.configuration.name // "-" | tostring | if . == "" then "-" else . end),
         (.configuration.descriptor.digest // "-" | tostring | if . == "" then "-" else . end),
         ([.variants[]?.digest | tostring | ltrimstr("sha256:")] | join(",") | if . == "" then "-" else . end)]
      | @tsv' <<<"$images" 2>/dev/null); then
    if [ -n "${images:-}" ] && jq -e 'type == "array" and length == 0' >/dev/null 2>&1 <<<"$images"; then
      log "${label} no images listed — nothing to remove"
      return 0
    fi
    container_unknown "image list could not be read — nothing removed"
    return 0
  fi

  while IFS=$'\t' read -r name digest variants; do
    [ -n "$name" ] || continue
    # The name becomes an argument to the runtime, so it must be a plain image reference.
    case "$name" in
      - | -* | *[!A-Za-z0-9_./:@-]*)
        kept=$((kept + 1))
        log "KEEP  (unreadable name) container image"
        continue
        ;;
    esac
    container_image_old "$variants"
    case $? in
      0) ;;
      1)
        kept=$((kept + 1))
        log "KEEP  (unpacked within ${CONTAINER_IMAGE_MIN_AGE_HOURS}h) container image ${name}"
        continue
        ;;
      *)
        kept=$((kept + 1))
        log "KEEP  (age unknown)   container image ${name}"
        continue
        ;;
    esac
    container_image_in_use "$name" "$digest"
    verdict=$?
    if [ "$verdict" -eq 0 ]; then
      kept=$((kept + 1))
      log "KEEP  (in use)        container image ${name}"
      continue
    elif [ "$verdict" -ne 1 ]; then
      kept=$((kept + 1))
      log "KEEP  (use unknown)   container image ${name}"
      continue
    fi

    if [ "$MODE" != apply ]; then
      container_image_estimate "$variants"
      est_mb=$CONTAINER_ESTIMATE_MB
      removed=$((removed + 1))
      would=$((would + 1))
      reclaimed_mb=$((reclaimed_mb + est_mb))
      log "WOULD REMOVE  ~${est_mb} MB  container image ${name}"
      continue
    fi

    if "$CONTAINER_CLI" image delete "$name" >/dev/null 2>&1; then
      removed=$((removed + 1))
      deleted=$((deleted + 1))
      log "REMOVE  container image ${name}"
    else
      kept=$((kept + 1))
      log "KEEP  (delete refused) container image ${name}"
    fi
  done <<<"$rows"

  if [ "$MODE" != apply ]; then
    log "${label} would remove ${would} image reference(s) (over budget)"
    return 0
  fi
  [ "$deleted" -gt 0 ] || {
    log "${label} over budget, but no image was both old and unused — nothing removed"
    return 0
  }
  # Judge the result by what the store reports afterwards, not by the delete calls: two
  # references can share one image, and only the last removal frees its space.
  if after=$(container_image_usage); then
    after_b=${after%% *}
    case "$after_b" in
      '' | *[!0-9]*) after_b='' ;;
    esac
  else
    after_b=''
  fi
  if [ -z "$after_b" ] || [ "${#after_b}" -gt 15 ]; then
    container_unknown "removed ${deleted} image reference(s), but the store could not be measured afterwards"
    return 0
  fi
  freed_mb=$((size_mb_before - 10#$after_b / 1048576))
  [ "$freed_mb" -ge 0 ] || freed_mb=0
  reclaimed_mb=$((reclaimed_mb + freed_mb))
  log "${label} removed ${deleted} image reference(s), reclaimed ~${freed_mb} MB"
}

reclaim_container_images

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
# Measure the volume the reclaimed space lives on, which `/` is not on macOS: there `/` is
# the sealed, read-only system volume, and the caches and temp dirs live on the data volume
# that holds $HOME. APFS volumes share their container's free space, so the free figure
# happened to agree (both read 74Gi on 2026-09-29) while the fullness did not (15% vs 83%),
# and on a host with a separate /home even the free figure differs. -P stops GNU df from
# wrapping a long device name onto a second line, where NR==2 would read the wrong row.
if command -v df >/dev/null 2>&1; then
  log "free now: $(df -P -h "${HOME:-/}" 2>/dev/null | awk 'NR==2{print $4 " (" $5 " used)"}')"
fi
if [ "$unknown" -gt 0 ]; then
  log "UNKNOWN: ${unknown} scan(s) could not be read; the summary above is partial"
  exit 2
fi
exit 0
