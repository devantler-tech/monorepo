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
#   2b. Per-run Go and golangci-lint caches directly under the temp root, whatever they are
#      named, recognised by the README each tool writes into its cache and reclaimed once
#      nothing was written to them for a threshold counted in HOURS (2026-09-30: 75 GB).
#   3. The golangci-lint cache, emptied only when it exceeds its own, smaller budget.
#   4. Go's orphaned work dirs (go-build<digits>, go-link-<digits>) directly under the
#      per-user temp dir, older than a threshold counted in HOURS.
#
# Environment (all optional):
#   BUILD_CACHE_RECLAIM_TMPDIR                temp root for (2); default /private/tmp
#   BUILD_CACHE_RECLAIM_LINT_BUDGET_GB        budget for (3); default 2
#   GOLANGCI_LINT_CACHE                       golangci-lint's own cache-dir override
#   BUILD_CACHE_RECLAIM_GO_TMPDIR             temp dir for (4); default `getconf
#                                             DARWIN_USER_TEMP_DIR`, else ${TMPDIR:-/tmp}
#   BUILD_CACHE_RECLAIM_GO_TMP_MIN_AGE_HOURS  age threshold for (4); default 6
#   BUILD_CACHE_RECLAIM_RUN_CACHE_IDLE_HOURS  idle threshold for (2b); default 6
#
# SAFETY — this deletes, so every rule below fails closed:
#   * Only trees matching a known agent-generated name pattern, or carrying a Go or
#     golangci-lint cache README marker (2b), are ever considered.
#   * A tree younger than its age threshold is KEPT.
#   * A tree any running process holds open is KEPT.
#   * The caller's own session tree is KEPT.
#   * A Go work dir is KEPT while a Go toolchain process that could own it is running.
#   * The golangci-lint cache is KEPT while golangci-lint runs, and is emptied only when
#     it carries golangci-lint's own README marker.
#   * Anything that cannot be positively classified is KEPT.
# The Go and golangci-lint caches are content-addressed and fully regenerable; removing
# them costs a rebuild, never data.
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
  local dir cache_mb budget_mb

  dir=$("$go_bin" env "$env_var" 2>/dev/null)
  [ -n "$dir" ] && [ -d "$dir" ] || return 0

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
  # from under itself. Nothing later protects this: holds_open and still_idle both narrow
  # to the temp root, and both run in the sweep that FOLLOWS.
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

  if "$go_bin" clean "$clean_flag" 2>/dev/null; then
    reclaimed_mb=$((reclaimed_mb + cache_mb))
    log "${label} cleaned, reclaimed ~${cache_mb} MB"
  else
    log "${label} clean FAILED — keeping"
  fi
}

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
#   $3  optional: run-cache, which repeats the marked-cache hold check just before removal
sweep_candidate() {
  local tree=$1 scope=$2 tree_mb late_hold
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
  if ! tree_mb=$(size_mb "$tree"); then
    kept=$((kept + 1))
    log "KEEP  (unmeasurable)  $tree"
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

# is_run_cache <dir> succeeds when <dir> carries a Go or golangci-lint cache README marker. The
# README must be a regular file that is not a symlink: a FIFO, a device or a link to a stream
# would block the read, and any temp-root entry could plant one to stall the whole sweep.
# Only the first 512 bytes are read: each tool writes its marker as the README's first line, and
# an unrelated README may be huge or still growing. Returns 0 for a marker, 1 for none, and 2 when
# the README could not be read: a cache whose marker was never read was never examined, so
# callers count it UNKNOWN and keep it.
is_run_cache() {
  local readme="$1/README" prefix
  [ -f "$readme" ] && [ ! -L "$readme" ] || return 1
  prefix=$(head -c 512 -- "$readme" 2>/dev/null) || return 2
  grep -qF -e "$GO_CACHE_MARKER" -e "$LINT_CACHE_MARKER" <<<"$prefix"
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
$(find "$TMPDIR_ROOT" -maxdepth 1 -type d \
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
# ---------------------------------------------------------------------------

# run_cache_idle <dir> succeeds (0) when neither the cache dir, its fan-out dirs, nor any entry
# in them has changed within RUN_CACHE_IDLE_HOURS, and returns 1 when something has. Depth 2
# reaches the entries (00/<hash>-a): Go overwrites an existing entry in place and refreshes an
# entry's mtime on a cache hit, and neither moves the fan-out dir's mtime, so a cache busy with
# hits would look idle at depth 1. A scan that fails returns 2: that cache was not examined.
run_cache_idle() {
  local recent
  recent=$(find "$1" -maxdepth 2 -mmin "-$((RUN_CACHE_IDLE_HOURS * 60))" -print 2>/dev/null) ||
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
  local tree=$1 when=${2:-early} rc oldest table
  if run_cache_idle "$tree"; then rc=0; else rc=$?; fi
  case "$rc" in
    0) ;;
    1) printf recent; return 0 ;;
    *) printf unknown; return 0 ;;
  esac
  if grep -qF -e "$LINT_CACHE_MARKER" -- "${tree}/README" 2>/dev/null; then
    if [ "$when" = late ]; then
      # The startup snapshot is minutes old by removal time; a linter started since then is
      # only in a fresh table (the same late read reclaim_lint_cache makes).
      if ! table=$(read_process_table) || ! oldest=$(oldest_in_table "$table" golangci-lint) ||
        [ "$oldest" != -1 ]; then
        printf linting
      fi
    elif ! oldest=$(oldest_process_secs golangci-lint) || [ "$oldest" != -1 ]; then
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
configured_caches=''
# Without the configured Go cache's path the exclusion is incomplete, so a failed read skips the
# marker sweep as UNKNOWN rather than risk reaping the budget-managed cache for idleness.
configured_gocache=''
run_caches_readable=1
if [ -n "${go_bin:-}" ] && ! configured_gocache=$("$go_bin" env GOCACHE 2>/dev/null); then
  run_caches_readable=0
  unknown=$((unknown + 1))
  log "UNKNOWN (go env GOCACHE failed) $TMPDIR_ROOT: per-run caches not examined"
fi
for configured in "$configured_gocache" "$(lint_cache_dir)"; do
  case "$configured" in
    /*) ;;
    *) continue ;;
  esac
  configured=$(cd -- "$configured" 2>/dev/null && pwd -P) || continue
  [ -n "$configured" ] && configured_caches="${configured_caches}${configured}"$'\n'
done

run_cache_trees=''
if [ "$run_caches_readable" -eq 1 ] && [ -d "$TMPDIR_ROOT" ]; then
  # Read the listing on its own, so a failed scan is seen: inside a heredoc substitution its
  # status is lost, and a partial listing would end in a clean-looking summary.
  if ! run_cache_trees=$(find "$TMPDIR_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null); then
    run_cache_trees=''
    unknown=$((unknown + 1))
    log "UNKNOWN (scan failed) $TMPDIR_ROOT: per-run caches not examined"
  fi
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
        kept=$((kept + 1))
        log "KEEP  (written within ${RUN_CACHE_IDLE_HOURS}h) $tree"
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
