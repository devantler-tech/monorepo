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
# ...and its SUMMARY must not claim it reaped anything. The per-tree lines say
# "WOULD REAP", but the summary counter is shared with apply mode, so a dry-run
# reported "reaped=N ... reclaimed=~N MB" while deleting nothing. In a script whose
# entire value is that it is safe to trust, a summary that says it deleted trees it did
# not delete is a reporting defect, not a cosmetic one -- and the scheduled sibling runs
# in dry-run, so that is the line an operator actually reads.
printf '%s' "$out" | grep -qE 'summary: reaped=[1-9]' &&
  fail 'dry-run summary claimed trees were reaped'

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

# --- 8. a stale tree a LIVE process is using is kept (liveness ablation) -----------
# The script's whole liveness claim is "a tree any running process holds open is KEPT".
# A holder almost never has the TOP directory itself open -- it holds a file, or has its
# cwd, somewhere beneath it -- and a shared Go cache is exactly this shape: entries are
# written into subdirectories, so the top-level mtime goes stale while builds are still
# reading and writing underneath. So the check has to see into the subtree.
#
# Two things must both hold, and each was verified against a live holder:
#   * the probe must recurse. `lsof -- <dir>` reports only that exact node, so a nested
#     holder is invisible and the tree is reaped while in use.
#   * the probe must be judged by its OUTPUT, not its exit status. `lsof +D <dir>` PRINTS
#     the holding processes and still exits 1, so an exit-status test calls the tree free
#     at the very moment lsof is naming who is using it.
# Test 1 is this test's ablation partner: same shape, no holder, and it must be reaped.
live_tree="${fixture_root}/codex-live-holder"
mkdir -p "${live_tree}/nested" || fail 'fixture: live-holder tree'
printf 'payload\n' > "${live_tree}/nested/file"
live_stamp=$(date -u -v-10d +%Y%m%d%H%M 2>/dev/null) ||
  live_stamp=$(date -u -d '10 days ago' +%Y%m%d%H%M 2>/dev/null)
touch -t "$live_stamp" "$live_tree" || fail 'fixture: touch live-holder tree'

# Hold the NESTED file open, never the top directory, in a separate process.
/bin/sh -c "exec 9<'${live_tree}/nested/file'; sleep 30" &
holder_pid=$!
sleep 1
if kill -0 "$holder_pid" 2>/dev/null; then
  run apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null
  [ -e "$live_tree" ] ||
    fail "a tree held open by a running process was reaped: $live_tree"
  kill "$holder_pid" 2>/dev/null
  wait "$holder_pid" 2>/dev/null
else
  fail 'fixture: live holder process did not stay alive; liveness assertion not exercised'
fi

# --- 9. the cache budget is read as DECIMAL and bounded ---------------------------
# `08` is a perfectly ordinary way to write eight, and it passes the digits-only guard.
# Bash arithmetic then reads a leading zero as octal and `$((08 * 1024))` is a hard parse
# error, not a mis-scaling -- so the GOCACHE branch aborts and the reclaim that actually
# recovers the space silently never runs. A value too long to multiply by 1024 wraps
# instead, and a negative budget makes every cache read as over budget and be cleaned on
# every sweep. Both directions are safety-relevant, so both are pinned.
out=$(run dry-run 3 08 2>&1)
printf '%s' "$out" | grep -q 'value too great for base' &&
  fail 'a zero-padded cache_budget_gb hit a bash octal parse error'
printf '%s' "$out" | grep -q 'cache_budget_gb=8' ||
  fail 'a zero-padded cache_budget_gb was not normalised to decimal 8'
run dry-run 3 99999999999999999999 > /dev/null 2>&1
[ $? -eq 2 ] || fail 'an unrepresentably large cache_budget_gb was not rejected'

# --- 10. the caller's own session tree is matched across SYMLINKED spellings -------
# `holds_open` resolves paths with `pwd -P` because lsof reports physical paths; the
# own-session guard has to do the same. On macOS the usual temp roots are symlinks
# (/tmp -> /private/tmp, /var -> /private/var), so TMPDIR and the candidate routinely name
# one directory in two spellings. A lexical compare misses that, and `holds_open` does NOT
# compensate: TMPDIR alone holds no file open, so a session tree not yet written to reads
# as idle and is reaped out from under the run that owns it.
# Test 1 is the ablation partner: same shape, not our session, and it must be reaped.
mkdir -p "${fixture_root}/phys" || fail 'fixture: phys root'
ln -sfn "${fixture_root}/phys" "${fixture_root}/link" || fail 'fixture: root symlink'
own_tree="${fixture_root}/phys/codex-own-session"
mkdir -p "$own_tree" || fail 'fixture: own-session tree'
printf 'payload\n' > "${own_tree}/file"
own_stamp=$(date -u -v-10d +%Y%m%d%H%M 2>/dev/null) ||
  own_stamp=$(date -u -d '10 days ago' +%Y%m%d%H%M 2>/dev/null)
touch -t "$own_stamp" "$own_tree" || fail 'fixture: touch own-session tree'
# Run over the PHYSICAL root while TMPDIR names the SAME tree through the symlink.
TMPDIR="${fixture_root}/link/codex-own-session" \
  BUILD_CACHE_RECLAIM_TMPDIR="${fixture_root}/phys" \
  bash "$impl" apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null 2>&1
[ -e "$own_tree" ] ||
  fail "the caller's own session tree was reaped through a symlinked TMPDIR: $own_tree"

# --- 11. a holder that appears AFTER the snapshot still keeps the tree -------------
# The liveness snapshot is captured once, up front, and the loop then measures sizes
# across every candidate before it deletes any of them -- so minutes can pass between the
# snapshot and a given unlink. A process that opens a file under a candidate inside that
# window is invisible to the snapshot, and the tree is deleted while genuinely in use.
# The stub below reproduces exactly that ordering deterministically: its FIRST call (the
# snapshot) reports an unrelated path, so the snapshot is valid but does not name the
# tree; every later call reports the holder. A script that trusts only the snapshot reaps
# the tree; one that re-verifies immediately before removing keeps it.
stub_dir="${fixture_root}/stub-bin"
mkdir -p "$stub_dir" || fail 'fixture: stub dir'
# Give this case its OWN root. Sweeping the debris of the earlier cases would make the
# stub answer for whichever tree the scan reached first, which is directory order and
# therefore not reproducible -- a flaky safety test is worse than no safety test.
late_root="${fixture_root}/late-root"
mkdir -p "$late_root" || fail 'fixture: late-holder root'
late_tree="${late_root}/codex-late-holder"
mkdir -p "${late_tree}/nested" || fail 'fixture: late-holder tree'
printf 'payload\n' > "${late_tree}/nested/file"
late_stamp=$(date -u -v-10d +%Y%m%d%H%M 2>/dev/null) ||
  late_stamp=$(date -u -d '10 days ago' +%Y%m%d%H%M 2>/dev/null)
touch -t "$late_stamp" "$late_tree" || fail 'fixture: touch late-holder tree'
late_canon=$(cd -- "$late_tree" && pwd -P) || fail 'fixture: resolve late-holder tree'
late_canon_parent=$(cd -- "$late_root" && pwd -P) || fail 'fixture: resolve late-holder root'
cat > "${stub_dir}/lsof" <<STUB
#!/bin/sh
# Call 1 is the up-front snapshot: valid output, but the tree is not in it.
# Every later call is a re-verification: the holder is now present.
c="${fixture_root}/stub-calls"
n=\$(cat "\$c" 2>/dev/null || echo 0)
echo \$((n + 1)) > "\$c"
if [ "\$n" -eq 0 ]; then
  # The snapshot: valid, non-empty, and deliberately does not name the tree.
  printf 'n%s\n' "${late_canon_parent}/unrelated-path"
  exit 0
fi
# Every later call is a per-tree re-verification. Answer only for the tree that is
# actually held, so the other fixtures still reap and this test stays an instrument
# rather than a blanket keep-everything.
for a in "\$@"; do
  case "\$a" in
    "${late_canon}"|"${late_canon}"/*) printf 'n%s\n' "${late_canon}/nested/file" ;;
  esac
done
exit 0
STUB
chmod +x "${stub_dir}/lsof" || fail 'fixture: chmod stub'
PATH="${stub_dir}:$PATH" BUILD_CACHE_RECLAIM_TMPDIR="$late_root" \
  bash "$impl" apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null 2>&1
[ -e "$late_tree" ] ||
  fail "a tree whose holder appeared after the snapshot was reaped: $late_tree"

# --- 12. an INCOMPLETE liveness scan keeps the tree (completeness ablation) --------
# `lsof +D` exits 1 in EVERY case that matters here -- an idle tree, a tree with a
# holder, and a scan it could not finish -- so the exit status discriminates nothing.
# Measured on this host:
#     idle, readable        status=1  rows=[]      stderr=[]
#     holder present        status=1  rows=[path]  stderr=[]
#     unreadable subdir     status=1  rows=[]      stderr=[lsof: WARNING: can't opendir]
# So "no rows" is a claim about the SCAN, not about the tree: an unreadable
# subdirectory yields exactly the same empty row set as a genuinely idle tree, and the
# tree is then deleted on the strength of an answer lsof never gave. The diagnostic
# stream is the only signal that separates the two.
#
# The two fixtures below differ in exactly that dimension and nothing else -- same
# shape, same age, same empty row set, same exit status -- so this test is its own
# ablation: the blocked one must be KEPT and the clean one must still be REAPED. A
# script that simply kept everything would fail on the second.
scan_root="${fixture_root}/scan-root"
mkdir -p "$scan_root" || fail 'fixture: scan root'
blocked_tree="${scan_root}/codex-blocked-scan"
clean_tree="${scan_root}/codex-clean-scan"
for d in "$blocked_tree" "$clean_tree"; do
  mkdir -p "${d}/nested" || fail "fixture: $d"
  printf 'payload\n' > "${d}/nested/file"
  scan_stamp=$(date -u -v-10d +%Y%m%d%H%M 2>/dev/null) ||
    scan_stamp=$(date -u -d '10 days ago' +%Y%m%d%H%M 2>/dev/null)
  touch -t "$scan_stamp" "$d" || fail "fixture: touch $d"
done
blocked_canon=$(cd -- "$blocked_tree" && pwd -P) || fail 'fixture: resolve blocked tree'
scan_stub="${fixture_root}/scan-stub-bin"
mkdir -p "$scan_stub" || fail 'fixture: scan stub dir'
scan_canon_parent=$(cd -- "$scan_root" && pwd -P) || fail 'fixture: resolve scan root'
cat > "${scan_stub}/lsof" <<STUB
#!/bin/sh
# Call 1 is the up-front snapshot: valid, and names neither tree, so both reach the
# per-tree re-verification that this test is about.
c="${fixture_root}/scan-stub-calls"
n=\$(cat "\$c" 2>/dev/null || echo 0)
echo \$((n + 1)) > "\$c"
if [ "\$n" -eq 0 ]; then
  printf 'n%s\n' "${scan_canon_parent}/unrelated-path"
  exit 0
fi
# Re-verification. Both answers carry an EMPTY row set and exit 1 -- the shapes are
# identical except for the diagnostic, which is the whole point of the ablation.
for a in "\$@"; do
  case "\$a" in
    "${blocked_canon}"|"${blocked_canon}"/*)
      echo "lsof: WARNING: can't opendir(${blocked_canon}/nested): Permission denied" >&2
      exit 1
      ;;
  esac
done
exit 1
STUB
chmod +x "${scan_stub}/lsof" || fail 'fixture: chmod scan stub'
PATH="${scan_stub}:$PATH" BUILD_CACHE_RECLAIM_TMPDIR="$scan_root" \
  bash "$impl" apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null 2>&1
[ -e "$blocked_tree" ] ||
  fail "a tree whose liveness scan could not complete was reaped: $blocked_tree"
[ -e "$clean_tree" ] &&
  fail "ablation partner: a tree with a COMPLETE empty scan was not reaped: $clean_tree"

if [ "$failures" -eq 0 ]; then
  printf 'build-cache-reclaim contract: all assertions passed\n'
  exit 0
fi
printf 'build-cache-reclaim contract: %d assertion(s) failed\n' "$failures" >&2
exit 1
