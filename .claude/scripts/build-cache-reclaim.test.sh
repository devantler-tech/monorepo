#!/usr/bin/env bash
# Contract tests for build-cache-reclaim.sh.
#
# Every assertion here is a SAFETY property. The script deletes, so each rule that keeps
# a tree is tested by ablation: a fixture that differs from a reapable one in exactly the
# tested dimension must be KEPT. A test that only proved reaping would pass just as well
# on a script that deleted everything.
#
# The cache budget is deliberately set absurdly high in every case, so no test run can
# ever clean the developer's real Go build cache as a side effect.
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
impl="${script_dir}/build-cache-reclaim.sh"
NEVER_CLEAN_BUDGET=1000000

failures=0
fail() {
  printf 'build-cache-reclaim contract: FAIL — %s\n' "$*" >&2
  failures=$((failures + 1))
}

fixture_root=$(mktemp -d) || {
  printf 'cannot create fixture root\n' >&2
  exit 2
}
trap 'rm -rf -- "$fixture_root"' EXIT

make_tree() {
  # make_tree <name> <age-days>
  local age=$2 dir="${fixture_root}/$1"
  mkdir -p "$dir" || return 1
  printf 'payload\n' > "$dir/file"
  if [ "$age" -gt 0 ]; then
    # BSD touch: -A adjusts the timestamp backwards by [-][[hh]mm]SS, so use -t with a
    # computed date instead, which behaves the same on both BSD and GNU.
    local stamp
    stamp=$(date -u -v-"${age}"d +%Y%m%d%H%M 2>/dev/null) ||
      stamp=$(date -u -d "${age} days ago" +%Y%m%d%H%M 2>/dev/null) || return 1
    touch -t "$stamp" "$dir" || return 1
  fi
  printf '%s' "$dir"
}

run() {
  BUILD_CACHE_RECLAIM_TMPDIR="$fixture_root" bash "$impl" "$@" 2>&1
}

# --- 1. a stale agent tree IS reaped (the positive case) --------------------------
stale=$(make_tree 'codex-stale-run' 10) || fail 'fixture: codex-stale-run'
out=$(run apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "$stale" ] && fail "a stale agent tree was not reaped: $stale"
printf '%s' "$out" | grep -q 'REAP' || fail 'apply run reported no REAP for a stale tree'

# --- 2. a YOUNG agent tree is kept (age ablation) ---------------------------------
young=$(make_tree 'codex-young-run' 0) || fail 'fixture: codex-young-run'
run apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null
[ -e "$young" ] || fail "a young agent tree was reaped: $young"

# --- 3. a stale NON-agent tree is kept (pattern ablation) -------------------------
foreign=$(make_tree 'some-other-tool-cache' 10) || fail 'fixture: some-other-tool-cache'
run apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null
[ -e "$foreign" ] || fail "a tree outside the agent name patterns was reaped: $foreign"

# --- 4. dry-run deletes nothing (mode ablation) -----------------------------------
dry=$(make_tree 'ksail-dry-run' 10) || fail 'fixture: ksail-dry-run'
out=$(run dry-run 3 "$NEVER_CLEAN_BUDGET")
[ -e "$dry" ] || fail "dry-run deleted a tree: $dry"
printf '%s' "$out" | grep -q 'WOULD REAP' || fail 'dry-run did not report WOULD REAP'

# --- 5. invalid arguments fail closed, before any deletion ------------------------
guard=$(make_tree 'war-guard-run' 10) || fail 'fixture: war-guard-run'
run bogus-mode 3 "$NEVER_CLEAN_BUDGET" > /dev/null 2>&1
[ $? -eq 2 ] || fail 'an invalid mode did not exit 2'
[ -e "$guard" ] || fail "an invalid mode still deleted a tree: $guard"
run apply notanumber "$NEVER_CLEAN_BUDGET" > /dev/null 2>&1
[ $? -eq 2 ] || fail 'a non-numeric min_age_days did not exit 2'
[ -e "$guard" ] || fail "a bad min_age_days still deleted a tree: $guard"

# --- 6. the Go cache is NOT cleaned while it is within budget ---------------------
# The budget branch is what stops every sweep throwing away a warm cache.
out=$(run dry-run 3 "$NEVER_CLEAN_BUDGET")
if printf '%s' "$out" | grep -q 'GOCACHE'; then
  printf '%s' "$out" | grep -q 'within budget' ||
    fail 'GOCACHE was not reported as within budget at an absurdly high budget'
  printf '%s' "$out" | grep -q 'would be cleaned' &&
    fail 'GOCACHE would be cleaned despite being within budget'
fi


# --- 7. a tree containing a READ-ONLY Go module cache is fully removed -------------
# Go marks everything under the module cache read-only, so a plain `rm -rf` fails
# partway. That is not merely a missed reclaim: the partial delete bumps the tree's
# mtime, so the age filter never selects it again and the remnant is orphaned forever
# -- the exact "immortal leftovers" class this script exists to end. Observed live on a
# 19.5 GB tree that shrank to 9.2 GB and then went invisible to the sweep.
readonly_tree="${fixture_root}/codex-readonly-modcache"
mkdir -p "${readonly_tree}/pkg/mod/example.com/dep@v1.0.0" || fail 'fixture: readonly tree'
printf 'payload\n' > "${readonly_tree}/pkg/mod/example.com/dep@v1.0.0/file.go"
chmod -R a-w "${readonly_tree}/pkg/mod/example.com/dep@v1.0.0" || fail 'fixture: chmod'
ro_stamp=$(date -u -v-10d +%Y%m%d%H%M 2>/dev/null) ||
  ro_stamp=$(date -u -d '10 days ago' +%Y%m%d%H%M 2>/dev/null)
touch -t "$ro_stamp" "$readonly_tree" || fail 'fixture: touch readonly tree'
run apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null
if [ -e "$readonly_tree" ]; then
  chmod -R u+w "$readonly_tree" 2>/dev/null
  fail "a tree with a read-only Go module cache was not fully removed: $readonly_tree"
fi
if [ "$failures" -eq 0 ]; then
  printf 'build-cache-reclaim contract: all assertions passed\n'
  exit 0
fi
printf 'build-cache-reclaim contract: %d assertion(s) failed\n' "$failures" >&2
exit 1
