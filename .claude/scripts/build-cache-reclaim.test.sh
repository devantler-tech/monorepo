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

# Both Go caches are pointed at empty fixture directories for EVERY invocation, because
# `go env` honours these variables. Without that, each run measures the developer's real
# caches: `du` over a multi-gigabyte module cache took minutes per call, and the suite
# calls this many times. It is also a stronger safety guarantee than the absurd budget
# below -- that only stops a cache being CLEANED; this stops one being touched at all.
# The three cases that invoke the script DIRECTLY (10, 11, 12) must set both variables
# themselves for the same reason. Without them each of those runs `du` over the real
# multi-gigabyte module cache, which dominated this suite's runtime.
GO_BUILD_FIXTURE="$fixture_root/go-build-cache"
GO_MOD_FIXTURE="$fixture_root/go-mod-cache"
mkdir -p "$GO_BUILD_FIXTURE" "$GO_MOD_FIXTURE" || {
  printf 'cannot create Go cache fixtures\n' >&2
  exit 2
}

run() {
  BUILD_CACHE_RECLAIM_TMPDIR="$fixture_root" \
    GOCACHE="${GOCACHE_OVERRIDE:-$GO_BUILD_FIXTURE}" \
    GOMODCACHE="${GOMODCACHE_OVERRIDE:-$GO_MOD_FIXTURE}" \
    bash "$impl" "$@" 2>&1
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

# --- 6. BOTH Go caches are budget-gated ------------------------------------------
# `run` points both caches at empty fixtures (see above), so both labels can be asserted
# UNCONDITIONALLY. Keyed on the developer's real caches the module-cache assertion has to
# be written as "if it was reported, check it", which passes vacuously on a script that
# never mentions the module cache at all -- exactly the gap this case exists to close.
#
# Each label is matched ANCHORED, because a bare `grep GOCACHE` also matches
# "GOMODCACHE": unanchored, the build-cache branch could be deleted outright and the
# module cache's own lines would satisfy the assertion.
if command -v go > /dev/null 2>&1; then
  # Over a 0 GB budget a cache has to measure at least 1 MB, so give each one some bulk.
  # bs is NUMERIC deliberately: BSD dd takes `bs=1m`, GNU dd does not, and this suite runs
  # on both. A rejected dd would leave the fixtures empty and 6b would fail on ubuntu only.
  dd if=/dev/zero of="$GO_BUILD_FIXTURE/blob" bs=1024 count=2048 2> /dev/null
  dd if=/dev/zero of="$GO_MOD_FIXTURE/blob" bs=1024 count=2048 2> /dev/null

  # 6a. within budget -> both reported, NEITHER cleaned. This is the ablation partner:
  # the budget branch is what stops every sweep throwing away a warm cache.
  out=$(run dry-run 3 "$NEVER_CLEAN_BUDGET")
  for label in GOCACHE GOMODCACHE; do
    line=$(printf '%s\n' "$out" | grep -E "^build-cache-reclaim: ${label} ") || {
      fail "${label} was never reported"
      continue
    }
    printf '%s\n' "$line" | grep -q 'within budget' ||
      fail "${label} was not reported as within budget at an absurdly high budget"
    printf '%s\n' "$out" | grep -q "${label} would be cleaned" &&
      fail "${label} would be cleaned despite being within budget"
  done

  # 6b. OVER budget -> both selected for cleaning. Without this, 6a passes on a script
  # that reports a size and is wired to nothing; this is what proves the module cache
  # reaches the clean path. Still dry-run, so no cache is actually emptied.
  out=$(run dry-run 3 0)
  for label in GOCACHE GOMODCACHE; do
    printf '%s\n' "$out" | grep -q "${label} would be cleaned" ||
      fail "${label} over budget was not selected for cleaning"
  done

  # ...and the dry-run SUMMARY must include those caches. The tree sweep counts a WOULD
  # REAP toward the projected total, so a cache branch that does not is not merely
  # inconsistent -- it under-reports the larger half. Measured on the real host: the log
  # said GOMODCACHE would reclaim ~34794 MB while the summary beneath it read "would
  # reclaim=~43 MB", i.e. an operator reading the scheduled dry-run would conclude there
  # was nothing worth reclaiming. The issue's own acceptance criterion is that it reports
  # sizes so growth is visible before it is critical.
  summary_mb=$(printf '%s\n' "$out" | sed -n 's/.*would reclaim=~\([0-9]*\) MB.*/\1/p' | tail -1)
  case "$summary_mb" in
    '' | *[!0-9]*) fail "dry-run summary reported no parsable would-reclaim total" ;;
    *)
      [ "$summary_mb" -ge 4 ] ||
        fail "dry-run summary omitted the Go caches: would reclaim=~${summary_mb} MB, expected >= 4"
      ;;
  esac

  rm -f "$GO_BUILD_FIXTURE/blob" "$GO_MOD_FIXTURE/blob"
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
  GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="$GO_MOD_FIXTURE" \
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
  GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="$GO_MOD_FIXTURE" \
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
  GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="$GO_MOD_FIXTURE" \
  bash "$impl" apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null 2>&1
[ -e "$blocked_tree" ] ||
  fail "a tree whose liveness scan could not complete was reaped: $blocked_tree"
[ -e "$clean_tree" ] &&
  fail "ablation partner: a tree with a COMPLETE empty scan was not reaped: $clean_tree"

# --- 13. a Go cache a LIVE process is using is kept (cache liveness ablation) ------
# `go clean -modcache` empties the ENTIRE module cache, and nothing above protected it:
# holds_open and still_idle both narrow to TMPDIR_ROOT and both run in the tree sweep
# that FOLLOWS, so a concurrent build's module files could vanish mid-build. That breaks
# the script's own invariant -- every "I could not tell" path keeps the cache -- so the
# budget must not be the only gate.
#
# The cache fixture deliberately lives OUTSIDE the swept temp root, exactly as the real
# GOMODCACHE does. Keyed on a cache inside TMPDIR_ROOT this case would pass on an
# implementation that only consulted the temp-root-narrowed snapshot -- which is the
# wrong instrument for a path that is never under it.
#
# The gate runs BEFORE the mode branch on purpose, so the dry-run PROJECTION is honest
# too: the scheduled sibling runs dry-run, and promising to reclaim a cache that apply
# would keep is the same class of defect as omitting one it would clean.
if command -v go > /dev/null 2>&1; then
  mod_outside_root=$(mktemp -d) || fail 'fixture: module-cache root outside the temp root'
  mkdir -p "${mod_outside_root}/nested" || fail 'fixture: module-cache nested dir'
  printf 'payload\n' > "${mod_outside_root}/nested/file"
  dd if=/dev/zero of="${mod_outside_root}/blob" bs=1024 count=2048 2> /dev/null

  # 13a. ABLATION PARTNER, no holder: over a 0 GB budget the cache IS selected. Without
  # this, 13b passes just as well on a script that never selects any cache at all.
  out=$(GOMODCACHE_OVERRIDE="$mod_outside_root" run dry-run 3 0)
  printf '%s\n' "$out" | grep -q 'GOMODCACHE would be cleaned' ||
    fail 'ablation partner: an idle over-budget module cache was not selected for cleaning'

  # 13b. the same cache, now held open by a live process, must be KEPT.
  /bin/sh -c "exec 9<'${mod_outside_root}/nested/file'; sleep 30" &
  mod_holder_pid=$!
  sleep 1
  if kill -0 "$mod_holder_pid" 2>/dev/null; then
    out=$(GOMODCACHE_OVERRIDE="$mod_outside_root" run dry-run 3 0)
    printf '%s\n' "$out" | grep -q 'GOMODCACHE would be cleaned' &&
      fail 'a module cache held open by a live process was selected for cleaning'
    printf '%s\n' "$out" | grep -qE '^build-cache-reclaim: GOMODCACHE .* in use' ||
      fail 'a module cache held open by a live process was not reported as in use'

    # ...and apply must leave it on disk, not merely log a keep.
    GOMODCACHE_OVERRIDE="$mod_outside_root" run apply 3 0 > /dev/null
    [ -e "${mod_outside_root}/nested/file" ] ||
      fail 'apply cleaned a module cache that a live process was using'

    kill "$mod_holder_pid" 2>/dev/null
    wait "$mod_holder_pid" 2>/dev/null
  else
    fail 'fixture: module-cache holder did not stay alive; liveness assertion not exercised'
  fi

  rm -rf -- "$mod_outside_root"
fi

# --- 14. a LARGE snapshot must not fail OPEN (SIGPIPE / pipefail ablation) ---------
# The liveness matchers pipe the snapshot into awk. An awk that `exit`s on its first hit
# closes that pipe, printf takes SIGPIPE, and under `set -o pipefail` the PIPELINE reports
# 141 -- which the matcher reads as "not in use" and the caller acts on by DELETING. It is
# invisible on a small snapshot, because printf finishes before awk can exit; it appears
# once enough files are open, which is exactly when a sweep matters.
#
# The filler paths must sit UNDER the temp root, because the snapshot is narrowed to that
# root before holds_open ever sees it -- filler outside it is stripped, the snapshot
# collapses to one line, printf completes, and this case passes on the broken matcher.
# Verified both ways: with the filler narrowed away the pre-fix matcher KEEPS the tree;
# with it retained the pre-fix matcher REAPS a tree lsof has explicitly named as held.
#
# `+D` (still_idle's targeted re-probe) deliberately answers with a CLEAN EMPTY scan, so
# holds_open is the ONLY check that can keep this tree -- without that, still_idle rescues
# it and the case passes on the broken matcher too.
sigpipe_root="${fixture_root}/sigpipe-root"
mkdir -p "$sigpipe_root" || fail 'fixture: sigpipe root'
sigpipe_tree="${sigpipe_root}/codex-sigpipe-holder"
mkdir -p "${sigpipe_tree}/nested" || fail 'fixture: sigpipe tree'
printf 'payload\n' > "${sigpipe_tree}/nested/file"
sigpipe_stamp=$(date -u -v-10d +%Y%m%d%H%M 2>/dev/null) ||
  sigpipe_stamp=$(date -u -d '10 days ago' +%Y%m%d%H%M 2>/dev/null)
touch -t "$sigpipe_stamp" "$sigpipe_tree" || fail 'fixture: touch sigpipe tree'
sigpipe_canon=$(cd -- "$sigpipe_tree" && pwd -P) || fail 'fixture: resolve sigpipe tree'
sigpipe_root_canon=$(cd -- "$sigpipe_root" && pwd -P) || fail 'fixture: resolve sigpipe root'
sigpipe_stub="${fixture_root}/sigpipe-bin"
mkdir -p "$sigpipe_stub" || fail 'fixture: sigpipe stub dir'
cat > "${sigpipe_stub}/lsof" <<STUB
#!/bin/sh
for a in "\$@"; do
  # still_idle's targeted re-probe: a clean, empty scan (idle). This is what forces the
  # assertion below to be about holds_open alone.
  [ "\$a" = "+D" ] && exit 0
done
# The up-front snapshot: holder FIRST, then bulk that SURVIVES the temp-root narrowing, so
# an early-exiting awk closes the pipe with most of the input still unwritten.
printf 'n%s\n' "${sigpipe_canon}/nested/file"
seq 1 20000 | sed 's|^|n${sigpipe_root_canon}/filler-|'
exit 0
STUB
chmod +x "${sigpipe_stub}/lsof" || fail 'fixture: chmod sigpipe stub'
PATH="${sigpipe_stub}:$PATH" BUILD_CACHE_RECLAIM_TMPDIR="$sigpipe_root" \
  GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="$GO_MOD_FIXTURE" \
  bash "$impl" apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null 2>&1
[ -e "$sigpipe_tree" ] ||
  fail "a tree named in a LARGE liveness snapshot was reaped (matcher failed open on SIGPIPE): $sigpipe_tree"

if [ "$failures" -eq 0 ]; then
  printf 'build-cache-reclaim contract: all assertions passed\n'
  exit 0
fi
printf 'build-cache-reclaim contract: %d assertion(s) failed\n' "$failures" >&2
exit 1
