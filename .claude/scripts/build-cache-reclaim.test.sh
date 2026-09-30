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
# Go's work dirs are swept from a SEPARATE root, deliberately outside fixture_root: the
# real per-user temp dir is not under the per-run temp root either, and a fixture inside
# it would let a liveness check that only reads the narrowed snapshot pass (case 15).
go_tmp_root=$(mktemp -d) || {
  printf 'cannot create Go temp fixture root\n' >&2
  exit 2
}
trap 'rm -rf -- "$fixture_root" "$go_tmp_root"' EXIT

# EXPORTED, not passed per call, so no invocation -- including the ones that call the
# script directly below -- can reach the host's real per-user temp dir or real
# golangci-lint cache. The Go work-dir sweep ages in hours, so an unsandboxed apply run
# would delete a real orphaned work dir on the developer's machine. The default lint
# cache is a path that does not exist ("nothing to do"); case 16 sets its own.
export BUILD_CACHE_RECLAIM_GO_TMPDIR="$go_tmp_root"
export GOLANGCI_LINT_CACHE="${fixture_root}/golangci-lint-absent"
export BUILD_CACHE_RECLAIM_LINT_BUDGET_GB="$NEVER_CLEAN_BUDGET"

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
# The cases that invoke the script DIRECTLY (10, 11, 12, 14) must set both variables
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
grep -q 'REAP' <<<"$out" || fail 'apply run reported no REAP for a stale tree'

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
grep -q 'WOULD REAP' <<<"$out" || fail 'dry-run did not report WOULD REAP'
# ...and its SUMMARY must not claim it reaped anything. The per-tree lines say
# "WOULD REAP", but the summary counter is shared with apply mode, so a dry-run
# reported "reaped=N ... reclaimed=~N MB" while deleting nothing. In a script whose
# entire value is that it is safe to trust, a summary that says it deleted trees it did
# not delete is a reporting defect, not a cosmetic one -- and the scheduled sibling runs
# in dry-run, so that is the line an operator actually reads.
grep -qE 'summary: reaped=[1-9]' <<<"$out" &&
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
    line=$(grep -E "^build-cache-reclaim: ${label} " <<<"$out") || {
      fail "${label} was never reported"
      continue
    }
    grep -q 'within budget' <<<"$line" ||
      fail "${label} was not reported as within budget at an absurdly high budget"
    grep -q "${label} would be cleaned" <<<"$out" &&
      fail "${label} would be cleaned despite being within budget"
  done

  # 6b. OVER budget -> both selected for cleaning. Without this, 6a passes on a script
  # that reports a size and is wired to nothing; this is what proves the module cache
  # reaches the clean path. Still dry-run, so no cache is actually emptied.
  out=$(run dry-run 3 0)
  for label in GOCACHE GOMODCACHE; do
    grep -q "${label} would be cleaned" <<<"$out" ||
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
grep -q 'value too great for base' <<<"$out" &&
  fail 'a zero-padded cache_budget_gb hit a bash octal parse error'
grep -q 'cache_budget_gb=8' <<<"$out" ||
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
  grep -q 'GOMODCACHE would be cleaned' <<<"$out" ||
    fail 'ablation partner: an idle over-budget module cache was not selected for cleaning'

  # 13b. the same cache, now held open by a live process, must be KEPT.
  /bin/sh -c "exec 9<'${mod_outside_root}/nested/file'; sleep 30" &
  mod_holder_pid=$!
  sleep 1
  if kill -0 "$mod_holder_pid" 2>/dev/null; then
    out=$(GOMODCACHE_OVERRIDE="$mod_outside_root" run dry-run 3 0)
    grep -q 'GOMODCACHE would be cleaned' <<<"$out" &&
      fail 'a module cache held open by a live process was selected for cleaning'
    grep -qE '^build-cache-reclaim: GOMODCACHE .* in use' <<<"$out" ||
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

# --- shared helpers for cases 15-16 -----------------------------------------------
# age_path <path> <hours> moves a path's mtime <hours> into the past. LOCAL time on
# purpose: `touch -t` reads its stamp as local time, so a UTC stamp would shift an
# hours-scale age by the host's UTC offset -- enough to carry a fixture across the
# 6-hour threshold in either direction.
age_path() {
  local stamp
  stamp=$(date -v-"$2"H +%Y%m%d%H%M 2>/dev/null) ||
    stamp=$(date -d "$2 hours ago" +%Y%m%d%H%M 2>/dev/null) || return 1
  touch -t "$stamp" "$1"
}

# make_go_dir <root> <name> <age-hours> builds a dir shaped like a go command's work dir.
make_go_dir() {
  local dir="$1/$2"
  mkdir -p "${dir}/b001" || return 1
  printf 'payload\n' > "${dir}/b001/file"
  age_path "$dir" "$3" || return 1
  printf '%s' "$dir"
}

# make_ps_stub <dir> [<table-file>] installs a `ps` that prints exactly that table, or --
# with no table -- one that fails with no output. The process-table rules are exercised
# through stubs because a toolchain process that has run for days cannot be conjured on
# demand; case 16 proves the same parser against the REAL ps.
make_ps_stub() {
  mkdir -p "$1" || return 1
  if [ -n "${2:-}" ]; then
    printf '#!/bin/sh\ncat "%s"\n' "$2" > "$1/ps"
  else
    printf '#!/bin/sh\nexit 1\n' > "$1/ps"
  fi
  chmod +x "$1/ps"
}

# said <output> <path> <pattern> succeeds when a log line that ENDS in exactly <path>
# contains <pattern>, so go-build1111 can never be confused with a sibling sharing its
# prefix. The lines are captured before grep sees them: `grep -q` quits on its first hit,
# and under pipefail a writer still feeding it would turn that hit into a SIGPIPE failure.
said() {
  local lines
  lines=$(printf '%s\n' "$1" |
    awk -v p="$2" 'length($0) >= length(p) && substr($0, length($0) - length(p) + 1) == p')
  grep -q -- "$3" <<<"$lines"
}

# run_iso <go-temp-root> <path-prefix> <args...> runs the script over an EMPTY per-run temp
# root, so the debris of cases 1-14 cannot add lines or reaps to what is asserted here.
# An empty <path-prefix> runs against the real `ps` and `lsof`.
iso_tmp="${fixture_root}/iso-tmp"
mkdir -p "$iso_tmp" || fail 'fixture: isolated temp root'
run_iso() {
  local root=$1 prefix=$2
  shift 2
  PATH="${prefix:+${prefix}:}$PATH" BUILD_CACHE_RECLAIM_GO_TMPDIR="$root" \
    BUILD_CACHE_RECLAIM_TMPDIR="$iso_tmp" \
    GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="$GO_MOD_FIXTURE" \
    bash "$impl" "$@" 2>&1
}

# A process table naming no toolchain and no linter, for every case whose subject is not
# the process table itself. Stubbed rather than real so a long-running go command on the
# developer's machine cannot turn a reap assertion into a spurious failure.
quiet_table="${fixture_root}/ps-quiet.txt"
printf '%s\n' '00:05 /bin/sh' '400-00:00:00 /sbin/launchd' > "$quiet_table"
quiet_ps="${fixture_root}/ps-quiet"
make_ps_stub "$quiet_ps" "$quiet_table" || fail 'fixture: quiet ps stub'

# --- 15. Go's orphaned work dirs are swept from the per-user temp dir --------------
# The go command leaves its `go-build<digits>` work dir (the linker a `go-link-<digits>`
# one) behind whenever it is killed, and those held 15.7 GB when the host filled on
# 2026-09-29. They live in the per-user temp dir, which the per-run sweep never scanned.
#
# The fixtures differ from the reapable ones in exactly one dimension each: age (1 h
# against the 6 h default), name shape, file-vs-dir, and a live holder. The 12 h fixture
# pins the threshold to HOURS: with min_age_days=3 applied instead it would be kept.
g_root="${go_tmp_root}/sweep"
mkdir -p "$g_root" || fail 'fixture: Go temp sweep root'
g_stale=$(make_go_dir "$g_root" go-build1111 240) || fail 'fixture: stale go-build'
g_link=$(make_go_dir "$g_root" go-link-2222 240) || fail 'fixture: stale go-link'
g_hours=$(make_go_dir "$g_root" go-build3333 12) || fail 'fixture: 12h go-build'
g_young=$(make_go_dir "$g_root" go-build4444 1) || fail 'fixture: young go-build'
g_held=$(make_go_dir "$g_root" go-build7777 240) || fail 'fixture: held go-build'
g_foreign=()
for name in go-buildcache go-build12x go-link-9x gopls-5555 codex-5556; do
  d=$(make_go_dir "$g_root" "$name" 240) || fail "fixture: $name"
  g_foreign+=("$d")
done
g_file="${g_root}/go-build6666"
printf 'payload\n' > "$g_file" || fail 'fixture: go-build file'
age_path "$g_file" 240 || fail 'fixture: age go-build file'

# Hold a NESTED file of g_held open, never the top dir, as a running build would.
/bin/sh -c "exec 9<'${g_held}/b001/file'; sleep 30" &
g_holder=$!
sleep 1
kill -0 "$g_holder" 2>/dev/null ||
  fail 'fixture: Go work-dir holder did not stay alive; liveness assertion not exercised'

# 15a. dry-run: selects exactly the reapable three, deletes nothing.
out=$(run_iso "$g_root" "$quiet_ps" dry-run 3 "$NEVER_CLEAN_BUDGET")
for d in "$g_stale" "$g_link" "$g_hours"; do
  said "$out" "$d" 'WOULD REAP' ||
    fail "dry-run did not select an orphaned Go work dir: $d"
done
for d in "$g_young" "$g_held" "${g_foreign[@]}" "$g_file"; do
  said "$out" "$d" 'REAP' &&
    fail "dry-run selected a Go temp entry it must keep: $d"
done
for d in "$g_stale" "$g_link" "$g_hours" "$g_young" "$g_held" "${g_foreign[@]}" "$g_file"; do
  [ -e "$d" ] || fail "dry-run deleted a Go temp entry: $d"
done
# The held dir must be kept by the LIVENESS check, and in dry-run, where the late
# per-tree re-probe never runs. That is what makes this discriminate: the fixture sits
# outside the per-run temp root, so a sweep reading only the snapshot narrowed to that
# root would call it idle -- and in apply the late re-probe would hide that by keeping
# it anyway.
said "$out" "$g_held" 'KEEP  (in use)' ||
  fail "a Go work dir held open by a live process was not kept as in use: $g_held"

# 15b. apply: reaps exactly the reapable three.
out=$(run_iso "$g_root" "$quiet_ps" apply 3 "$NEVER_CLEAN_BUDGET")
for d in "$g_stale" "$g_link" "$g_hours"; do
  [ -e "$d" ] && fail "apply did not reap an orphaned Go work dir: $d"
done
for d in "$g_young" "$g_held" "${g_foreign[@]}" "$g_file"; do
  [ -e "$d" ] || fail "apply removed a Go temp entry it must keep: $d"
done
kill "$g_holder" 2>/dev/null
wait "$g_holder" 2>/dev/null

# 15c. a running toolchain process that COULD own a dir keeps it. A go command need not
# hold any file under its work dir between build steps, so lsof alone can miss a live
# build; a dir last modified before every toolchain process started cannot be theirs.
# Each variant sweeps one 10-day-old work dir while `ps` reports only the given lines.
go_proc_case() {
  local label=$1 table stub="${fixture_root}/ps-$1" root="${go_tmp_root}/proc-$1"
  shift
  mkdir -p "$root" || return 1
  proc_dir=$(make_go_dir "$root" go-build424242 240) || return 1
  if [ "$#" -gt 0 ]; then
    table="${fixture_root}/ps-${label}.txt"
    printf '%s\n' "$@" > "$table" || return 1
    make_ps_stub "$stub" "$table" || return 1
  else
    make_ps_stub "$stub" || return 1
  fi
  proc_out=$(run_iso "$root" "$stub" apply 3 "$NEVER_CLEAN_BUDGET")
}
# Running for 11 days, so it could have created a 10-day-old dir: KEEP.
go_proc_case old '11-00:00:00 /usr/local/go/bin/go' '00:05 /bin/sh' ||
  fail 'fixture: old-toolchain case'
[ -e "$proc_dir" ] || fail 'a Go work dir was reaped while a go command that could own it ran'
said "$proc_out" "$proc_dir" 'KEEP  (go running)' ||
  fail 'a Go work dir kept for a running go command did not say why'
# ABLATION PARTNER: a toolchain process that started AFTER the dir was last modified, and
# a non-toolchain process older than the dir. Neither can own it, so it IS reaped.
go_proc_case young '23:59:59 /usr/local/go/pkg/tool/linux_amd64/compile' \
  '400-00:00:00 /sbin/launchd' || fail 'fixture: young-toolchain case'
[ -e "$proc_dir" ] &&
  fail 'ablation partner: a Go work dir no running process could own was not reaped'
# ps fails: nothing can be ruled out, so KEEP.
go_proc_case failed || fail 'fixture: failed-ps case'
[ -e "$proc_dir" ] || fail 'a Go work dir was reaped although ps produced no process table'
# A toolchain process whose elapsed time does not parse is "cannot tell", never "young".
go_proc_case garbled 'bogus /usr/local/go/bin/go' '00:05 /bin/sh' ||
  fail 'fixture: garbled-etime case'
[ -e "$proc_dir" ] ||
  fail 'a Go work dir was reaped although a go process had an unparsable elapsed time'
# The table is read at the START of the run and the work dirs are swept LAST, possibly
# many minutes later, so a process must be aged to the moment of the comparison. A `date`
# stub makes that gap deterministic: the table is read at T, the comparison happens at
# T + 2 days. A go command 9 days old at T is 11 days old by then, so it predates this
# 10-day-old dir and could own it. Read without the gap it looks younger than the dir --
# exactly the young-toolchain ablation above, which is reaped.
aged_stub="${fixture_root}/ps-aged"
aged_root="${go_tmp_root}/proc-aged"
mkdir -p "$aged_root" || fail 'fixture: aged-table root'
aged_dir=$(make_go_dir "$aged_root" go-build434343 240) || fail 'fixture: aged-table dir'
printf '%s\n' '9-00:00:00 /usr/local/go/bin/go' > "${fixture_root}/ps-aged.txt"
make_ps_stub "$aged_stub" "${fixture_root}/ps-aged.txt" || fail 'fixture: aged ps stub'
real_date=$(command -v date)
cat > "${aged_stub}/date" <<STUB
#!/bin/sh
# The first epoch read (when the table is taken) is now; every later one is 2 days on.
if [ "\$1" = "+%s" ]; then
  c="${fixture_root}/aged-date-calls"
  n=\$(cat "\$c" 2>/dev/null || echo 0)
  echo \$((n + 1)) > "\$c"
  t=\$("${real_date}" +%s)
  [ "\$n" -eq 0 ] || t=\$((t + 172800))
  echo "\$t"
  exit 0
fi
exec "${real_date}" "\$@"
STUB
chmod +x "${aged_stub}/date" || fail 'fixture: chmod date stub'
run_iso "$aged_root" "$aged_stub" apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null
[ -e "$aged_dir" ] ||
  fail 'a Go work dir was reaped because the process table was not aged to the present'

# 15d. bad settings fail closed, before anything is deleted.
bad_root="${go_tmp_root}/bad-settings"
bad_dir=$(make_go_dir "$bad_root" go-build515151 240) || fail 'fixture: bad-settings dir'
BUILD_CACHE_RECLAIM_GO_TMP_MIN_AGE_HOURS=six \
  run_iso "$bad_root" "$quiet_ps" apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null 2>&1
[ $? -eq 2 ] || fail 'a non-numeric Go work-dir age threshold did not exit 2'
BUILD_CACHE_RECLAIM_LINT_BUDGET_GB=-1 \
  run_iso "$bad_root" "$quiet_ps" apply 3 "$NEVER_CLEAN_BUDGET" > /dev/null 2>&1
[ $? -eq 2 ] || fail 'a negative golangci-lint budget did not exit 2'
[ -e "$bad_dir" ] || fail "an invalid setting still deleted a Go work dir: $bad_dir"

# --- 16. the golangci-lint cache is budget-gated, marker-gated and liveness-gated ---
# 3.3 GB of it sat unbudgeted when the host filled. The cache is emptied, not deleted:
# golangci-lint's own README marker stays, so the dir still identifies itself.
lint_cache="${fixture_root}/lint-cache"
lint_marker='This directory holds cached build artifacts from golangci-lint.'
mkdir -p "${lint_cache}/00" || fail 'fixture: lint cache'
printf '%s\n' "$lint_marker" > "${lint_cache}/README"
dd if=/dev/zero of="${lint_cache}/00/blob-d" bs=1024 count=2048 2> /dev/null
run_lint() {
  GOLANGCI_LINT_CACHE="$lint_cache" run_iso "$go_tmp_root" "$@"
}

# 16a. within budget: reported and kept. The ablation partner for 16b.
out=$(run_lint "$quiet_ps" dry-run 3 "$NEVER_CLEAN_BUDGET")
line=$(grep -E '^build-cache-reclaim: GOLANGCI_LINT_CACHE ' <<<"$out") ||
  fail 'the golangci-lint cache was never reported'
grep -q 'within budget' <<<"$line" ||
  fail 'the golangci-lint cache was not reported within budget at an absurdly high budget'
grep -q 'GOLANGCI_LINT_CACHE would be cleaned' <<<"$out" &&
  fail 'the golangci-lint cache would be cleaned despite being within budget'

# 16b. over budget, dry-run: selected, counted in the summary, and left on disk.
out=$(BUILD_CACHE_RECLAIM_LINT_BUDGET_GB=0 run_lint "$quiet_ps" dry-run 3 "$NEVER_CLEAN_BUDGET")
grep -q 'GOLANGCI_LINT_CACHE would be cleaned' <<<"$out" ||
  fail 'an over-budget golangci-lint cache was not selected for cleaning'
lint_summary=$(printf '%s\n' "$out" | sed -n 's/.*would reclaim=~\([0-9]*\) MB.*/\1/p' | tail -1)
case "$lint_summary" in
  '' | *[!0-9]*) fail 'dry-run summary reported no parsable would-reclaim total' ;;
  *) [ "$lint_summary" -ge 2 ] ||
    fail "dry-run summary omitted the golangci-lint cache: would reclaim=~${lint_summary} MB" ;;
esac
[ -e "${lint_cache}/00/blob-d" ] || fail 'dry-run emptied the golangci-lint cache'

# 16c. no README marker: KEPT, whatever the budget says. The override is a free-form
# path; the marker is what proves it names a golangci-lint cache and not a home dir.
mv "${lint_cache}/README" "${lint_cache}/README.away" || fail 'fixture: hide lint marker'
out=$(BUILD_CACHE_RECLAIM_LINT_BUDGET_GB=0 run_lint "$quiet_ps" apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "${lint_cache}/00/blob-d" ] || fail 'apply emptied a directory with no golangci-lint marker'
grep -q 'carries no golangci-lint README marker' <<<"$out" ||
  fail 'an unmarked golangci-lint cache dir was not reported as unmarked'
mv "${lint_cache}/README.away" "${lint_cache}/README" || fail 'fixture: restore lint marker'

# 16d. a RUNNING golangci-lint keeps it -- against the REAL ps, which also proves the
# process-table parser on this platform. A symlink named golangci-lint to `sleep` shows
# under that name on both macOS and Linux (a copied macOS system binary is killed on exec).
procs="${fixture_root}/procs"
mkdir -p "$procs" || fail 'fixture: procs dir'
ln -s "$(command -v sleep)" "${procs}/golangci-lint" || fail 'fixture: golangci-lint link'
"${procs}/golangci-lint" 30 &
lint_pid=$!
sleep 1
# Captured first, then matched: see `said` for why `grep -q` never reads from a pipe here.
ps_names=$(ps -A -ww -o comm= | sed 's|.*/||')
if kill -0 "$lint_pid" 2>/dev/null && grep -qx 'golangci-lint' <<<"$ps_names"; then
  out=$(BUILD_CACHE_RECLAIM_LINT_BUDGET_GB=0 run_lint '' apply 3 "$NEVER_CLEAN_BUDGET")
  [ -e "${lint_cache}/00/blob-d" ] ||
    fail 'apply emptied the golangci-lint cache while golangci-lint was running'
  grep -q 'GOLANGCI_LINT_CACHE golangci-lint process running' <<<"$out" ||
    fail 'a golangci-lint cache kept for a running linter did not say why'
else
  fail 'fixture: fake golangci-lint process not visible to ps; liveness assertion not exercised'
fi
kill "$lint_pid" 2>/dev/null
wait "$lint_pid" 2>/dev/null

# 16e. a linter that starts AFTER the up-front process table still keeps it. The table is
# read at the start of the run, and measuring the Go caches alone can take minutes before
# the lint cache is reached. This `ps` answers "no linter" to its first call (the table)
# and "linter running" to every later one, so only a fresh re-check at removal time can
# see it -- the same ordering case 11 pins for the tree sweep's late re-probe.
late_ps="${fixture_root}/ps-late-lint"
mkdir -p "$late_ps" || fail 'fixture: late-lint stub dir'
cat > "${late_ps}/ps" <<STUB
#!/bin/sh
c="${fixture_root}/late-lint-calls"
n=\$(cat "\$c" 2>/dev/null || echo 0)
echo \$((n + 1)) > "\$c"
echo '00:05 /bin/sh'
[ "\$n" -eq 0 ] || echo '00:01 /opt/tools/golangci-lint'
exit 0
STUB
chmod +x "${late_ps}/ps" || fail 'fixture: chmod late-lint stub'
out=$(BUILD_CACHE_RECLAIM_LINT_BUDGET_GB=0 run_lint "$late_ps" apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "${lint_cache}/00/blob-d" ] ||
  fail 'apply emptied the golangci-lint cache while a linter started after the snapshot ran'
grep -q 'GOLANGCI_LINT_CACHE golangci-lint running or unknown at removal time' <<<"$out" ||
  fail 'a golangci-lint cache kept by the late re-check did not say why'
# ...and the same for an open-file holder that appears after the lsof snapshot: the
# snapshot names an unrelated path, and only the late `+D` probe names the holder.
lint_canon=$(cd -- "$lint_cache" && pwd -P) || fail 'fixture: resolve lint cache'
late_lsof="${fixture_root}/lsof-late-lint"
make_ps_stub "$late_lsof" "$quiet_table" || fail 'fixture: late-lsof ps stub'
cat > "${late_lsof}/lsof" <<STUB
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "+D" ] && { printf 'n%s\n' "${lint_canon}/00/blob-d"; exit 1; }
done
printf 'n%s\n' "${fixture_root}/unrelated-path"
exit 0
STUB
chmod +x "${late_lsof}/lsof" || fail 'fixture: chmod late-lsof stub'
out=$(BUILD_CACHE_RECLAIM_LINT_BUDGET_GB=0 run_lint "$late_lsof" apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "${lint_cache}/00/blob-d" ] ||
  fail 'apply emptied the golangci-lint cache while a late holder had it open'
grep -q 'GOLANGCI_LINT_CACHE .* in use at removal time' <<<"$out" ||
  fail 'a golangci-lint cache kept by the late open-file re-check did not say why'

# 16f. over budget, idle, marked, apply: emptied, marker kept.
out=$(BUILD_CACHE_RECLAIM_LINT_BUDGET_GB=0 run_lint "$quiet_ps" apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "${lint_cache}/00" ] && fail 'apply did not empty an idle over-budget golangci-lint cache'
[ -e "${lint_cache}/README" ] || fail 'emptying the golangci-lint cache removed its marker'
grep -q 'GOLANGCI_LINT_CACHE cleaned' <<<"$out" ||
  fail 'an emptied golangci-lint cache was not reported as cleaned'

# 16g. no cache is nothing to do: an absent dir, and golangci-lint's own "off".
out=$(run_iso "$go_tmp_root" "$quiet_ps" dry-run 3 "$NEVER_CLEAN_BUDGET")
grep -q 'GOLANGCI_LINT_CACHE .* absent — nothing to do' <<<"$out" ||
  fail 'an absent golangci-lint cache was not reported as nothing to do'
out=$(GOLANGCI_LINT_CACHE=off run_iso "$go_tmp_root" "$quiet_ps" dry-run 3 "$NEVER_CLEAN_BUDGET")
grep -q 'GOLANGCI_LINT_CACHE disabled or not an absolute path' <<<"$out" ||
  fail 'GOLANGCI_LINT_CACHE=off was not reported as disabled'

# --- 17. per-run build caches under the temp root are recognised by their marker -----
# Lanes point GOCACHE at fresh dirs under the temp root with names no pattern in case 1
# matches (daily-ai-engineer-gocache-*), 6-12 GB each; 75 GB of them filled the host on
# 2026-09-30. Every reap below has an ablation partner that differs in exactly one
# dimension -- the marker, the last write, a live holder -- and must be KEPT.
cache_root="${fixture_root}/cache-tmp"
mkdir -p "$cache_root" || fail 'fixture: per-run cache temp root'
# make_run_cache <name> <marker-text> <idle-hours> builds a dir shaped like a Go build cache
# (README + a fan-out dir holding an entry) whose every entry was last written <idle-hours>
# ago. An empty <marker-text> writes no README.
make_run_cache() {
  local dir="${cache_root}/$1"
  mkdir -p "${dir}/00" || return 1
  printf 'entry\n' > "${dir}/00/a1-d"
  [ -z "$2" ] || printf '%s\nRun "go clean -cache" if the directory is getting too large.\n' "$2" \
    > "${dir}/README"
  age_path "${dir}/00/a1-d" "$3" && age_path "${dir}/00" "$3" && age_path "$dir" "$3" || return 1
  [ -z "$2" ] || age_path "${dir}/README" "$3" || return 1
  printf '%s' "$dir"
}
run_cache() {
  BUILD_CACHE_RECLAIM_TMPDIR="$cache_root" BUILD_CACHE_RECLAIM_GO_TMPDIR="$go_tmp_root" \
    GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="$GO_MOD_FIXTURE" PATH="${RUN_CACHE_PS:-$quiet_ps}:$PATH" \
    bash "$impl" "$@" 2>&1
}
go_marker='This directory holds cached build artifacts from the Go build system.'
lint_marker='This directory holds cached build artifacts from golangci-lint.'
idle_go=$(make_run_cache 'daily-ai-engineer-gocache-17a' "$go_marker" 7) || fail 'fixture: 17a'
idle_lint=$(make_run_cache 'lane-golangci-cache-17b' "$lint_marker" 7) || fail 'fixture: 17b'
fresh_go=$(make_run_cache 'daily-ai-engineer-gocache-17c' "$go_marker" 7) || fail 'fixture: 17c'
printf 'entry\n' > "${fresh_go}/00/b2-d"   # a write moments ago: the fan-out dir's mtime moves
unmarked=$(make_run_cache 'daily-ai-engineer-gocache-17d' '' 7) || fail 'fixture: 17d'

# 17a-d, dry-run: the idle marked caches are selected, the rest are not, and nothing goes.
out=$(run_cache dry-run 3 "$NEVER_CLEAN_BUDGET")
said "$out" "$idle_go" 'WOULD REAP' || fail 'an idle per-run Go cache was not selected by its marker'
said "$out" "$idle_lint" 'WOULD REAP' || fail 'an idle per-run golangci-lint cache was not selected'
said "$out" "$fresh_go" 'KEEP  (written within 6h)' ||
  fail 'a per-run Go cache written moments ago was not kept for being recent'
grep -qF "$unmarked" <<<"$out" && fail 'a dir with no cache marker was considered at all'
[ -e "$idle_go" ] || fail 'dry-run deleted a per-run Go cache'

# 17e. the same idle marked cache, held open by a live process, is KEPT by apply.
held=$(make_run_cache 'codex-held-gocache-17e' "$go_marker" 7) || fail 'fixture: 17e'
/bin/sh -c "exec 9<'${held}/00/a1-d'; sleep 30" &
cache_holder_pid=$!
sleep 1
if kill -0 "$cache_holder_pid" 2>/dev/null; then
  out=$(run_cache apply 3 "$NEVER_CLEAN_BUDGET")
  [ -e "${held}/00/a1-d" ] || fail 'apply removed a per-run Go cache a live process held open'
  kill "$cache_holder_pid" 2>/dev/null
  wait "$cache_holder_pid" 2>/dev/null
else
  fail 'fixture: per-run cache holder did not stay alive; liveness assertion not exercised'
  out=$(run_cache apply 3 "$NEVER_CLEAN_BUDGET")
fi

# 17a-d, apply: the idle marked caches are gone; the recent and unmarked ones remain.
[ -e "$idle_go" ] && fail "apply did not reap an idle per-run Go cache: $idle_go"
[ -e "$idle_lint" ] && fail "apply did not reap an idle per-run golangci-lint cache: $idle_lint"
[ -e "$fresh_go" ] || fail 'apply reaped a per-run Go cache written moments ago'
[ -e "$unmarked" ] || fail 'apply reaped a dir that carries no cache marker'

# 17f-g share one dry-run, which also serves as 17h's readable control (exit 0).
# 17f. a marked cache that ALSO matches the name-and-age sweep (an old codex-* Go cache) is
# decided once: a dry-run that leaves it in place must not select or count it twice.
both=$(make_run_cache 'codex-old-gocache-17f' "$go_marker" 120) || fail 'fixture: 17f'
# 17g. a cache whose only recent write is an entry refreshed in place (a Go cache hit) is
# KEPT: the fan-out dir's mtime does not move, so a depth-1 idle check would miss it.
hit=$(make_run_cache 'daily-ai-engineer-gocache-17g' "$go_marker" 7) || fail 'fixture: 17g'
touch "${hit}/00/a1-d"
out=$(run_cache dry-run 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$(grep -cF "$both" <<<"$out")" -eq 1 ] ||
  fail 'a cache matching both the name sweep and the marker sweep was decided more than once'
said "$out" "$hit" 'KEEP  (written within 6h)' ||
  fail 'a per-run Go cache refreshed by a cache hit was not kept for being recent'
[ "$rc" -eq 0 ] || fail "a readable temp root exited ${rc}, not 0"
rm -rf -- "$both" "$hit"

# 17h. a temp root the marker sweep cannot list is UNKNOWN (exit 2), never a clean summary.
chmod 311 "$cache_root"
out=$(run_cache dry-run 3 "$NEVER_CLEAN_BUDGET")
rc=$?
chmod 755 "$cache_root"
if [ "$(id -u)" -ne 0 ]; then
  [ "$rc" -eq 2 ] || fail "an unreadable temp root exited ${rc}, not 2 (UNKNOWN)"
  grep -q 'UNKNOWN (scan failed)' <<<"$out" || fail 'an unreadable temp root was not reported UNKNOWN'
fi


# 17i. a marked cache whose recency scan fails is UNKNOWN (exit 2), never "recent" and KEPT
# with a clean summary: a failed scan examined nothing.
blind=$(make_run_cache 'daily-ai-engineer-gocache-17i' "$go_marker" 7) || fail 'fixture: 17i'
chmod 000 "${blind}/00"
out=$(run_cache dry-run 3 "$NEVER_CLEAN_BUDGET")
rc=$?
chmod 755 "${blind}/00"
if [ "$(id -u)" -ne 0 ]; then
  [ "$rc" -eq 2 ] || fail "a per-run cache whose scan failed exited ${rc}, not 2 (UNKNOWN)"
  said "$out" "$blind" 'UNKNOWN (scan failed, cache not examined)' ||
    fail 'a per-run cache whose scan failed was not reported UNKNOWN'
fi
rm -rf -- "$blind"

# 17j. an old codex-* marked cache whose only recent write is an entry refreshed in place is
# KEPT: the name sweep's day-based root mtime must not decide a marked cache.
old_hit=$(make_run_cache 'codex-old-gocache-17j' "$go_marker" 120) || fail 'fixture: 17j'
touch "${old_hit}/00/a1-d"
out=$(run_cache apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "$old_hit" ] || fail 'the name sweep reaped a marked cache written moments ago'
said "$out" "$old_hit" 'KEEP  (written within 6h)' ||
  fail 'an old-named marked cache with a fresh entry was not kept for being recent'
rm -rf -- "$old_hit"

# 17k. an idle cache that GOLANGCI_LINT_CACHE names is budget-managed by (3), so the marker
# sweep leaves it alone even though it is idle and marked.
configured=$(make_run_cache 'configured-lint-17k' "$lint_marker" 7) || fail 'fixture: 17k'
out=$(GOLANGCI_LINT_CACHE="$configured" run_cache apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "${configured}/00/a1-d" ] || fail 'the marker sweep reaped the configured, within-budget lint cache'
rm -rf -- "$configured"

# 17l. an idle marked golangci-lint cache is KEPT while a golangci-lint runs: a linter can sit
# between two cache reads with no file open, so the lsof probes cannot see it.
busy_table="${fixture_root}/ps-busy-lint.txt"
printf '%s\n' '00:05 /bin/sh' '03:00 /opt/bin/golangci-lint' > "$busy_table"
busy_ps="${fixture_root}/ps-busy-lint"
make_ps_stub "$busy_ps" "$busy_table" || fail 'fixture: busy lint ps stub'
linted=$(make_run_cache 'lane-golangci-cache-17l' "$lint_marker" 7) || fail 'fixture: 17l'
out=$(RUN_CACHE_PS="$busy_ps" run_cache apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "$linted" ] || fail 'apply reaped a per-run lint cache while golangci-lint was running'
said "$out" "$linted" 'KEEP  (golangci-lint running or unknown)' ||
  fail 'a per-run lint cache was not kept for a running golangci-lint'
rm -rf -- "$linted"

# 17m. a README that is a symlink is not a marker, even when it points at one: the read must
# never follow a planted link (to a FIFO or a stream it would block on).
linked=$(make_run_cache 'daily-ai-engineer-gocache-17m' '' 7) || fail 'fixture: 17m'
printf '%s\n' "$go_marker" > "${fixture_root}/marker-17m"
ln -s "${fixture_root}/marker-17m" "${linked}/README"
# Backdate the link itself and the dir its creation touched, so recency cannot be what keeps it.
stamp17m=$(date -v-7H +%Y%m%d%H%M 2>/dev/null) || stamp17m=$(date -d "7 hours ago" +%Y%m%d%H%M)
touch -h -t "$stamp17m" "${linked}/README" || fail 'fixture: age 17m link'
age_path "$linked" 7 || fail 'fixture: age 17m dir'
out=$(run_cache apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "$linked" ] || fail 'a dir whose README is a symlink was reaped as a marked cache'
rm -rf -- "$linked"

# 17n. with no override, golangci-lint's DEFAULT cache can resolve to a direct child of the temp
# root (XDG_CACHE_HOME there on Linux; ~/Library/Caches there on macOS). It is budget-managed by
# (3), so the marker sweep leaves it alone even though it is idle and marked.
default_home="${fixture_root}/home-17n"
mkdir -p "${default_home}/Library" || fail 'fixture: 17n home'
ln -s "$cache_root" "${default_home}/Library/Caches" || fail 'fixture: 17n caches link'
default_lint=$(make_run_cache 'golangci-lint' "$lint_marker" 7) || fail 'fixture: 17n'
out=$(env -u GOLANGCI_LINT_CACHE HOME="$default_home" XDG_CACHE_HOME="$cache_root" \
  BUILD_CACHE_RECLAIM_TMPDIR="$cache_root" BUILD_CACHE_RECLAIM_GO_TMPDIR="$go_tmp_root" \
  GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="$GO_MOD_FIXTURE" PATH="${quiet_ps}:$PATH" \
  bash "$impl" apply 3 "$NEVER_CLEAN_BUDGET" 2>&1)
[ -e "${default_lint}/00/a1-d" ] || fail 'the marker sweep reaped the default, within-budget lint cache'
rm -rf -- "$default_lint" "$default_home"

# 17o. a README that cannot be read is UNKNOWN (exit 2), never "not a cache": an old-named
# cache must not then fall through to the name sweep and be reaped on its root mtime alone.
unreadable=$(make_run_cache 'codex-old-gocache-17o' "$go_marker" 120) || fail 'fixture: 17o'
chmod 000 "${unreadable}/README"
out=$(run_cache apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
chmod 644 "${unreadable}/README"
if [ "$(id -u)" -ne 0 ]; then
  [ "$rc" -eq 2 ] || fail "a cache whose marker could not be read exited ${rc}, not 2 (UNKNOWN)"
  said "$out" "$unreadable" 'UNKNOWN (marker unreadable, cache not examined)' ||
    fail 'a cache whose marker could not be read was not reported UNKNOWN'
  [ -e "${unreadable}/00/a1-d" ] || fail 'a cache whose marker could not be read was reaped'
fi
rm -rf -- "$unreadable"

# 17p. a golangci-lint that starts after the startup process snapshot keeps an idle lint cache
# at removal time: the late recheck must read a fresh process table, not the startup one.
rm -f "${fixture_root}/late-lint-calls"
late_linted=$(make_run_cache 'lane-golangci-cache-17p' "$lint_marker" 7) || fail 'fixture: 17p'
out=$(RUN_CACHE_PS="$late_ps" run_cache apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "$late_linted" ] || fail 'apply reaped a per-run lint cache whose linter started after the snapshot'
said "$out" "$late_linted" 'KEEP  (busy, late)' ||
  fail 'a per-run lint cache was not kept at removal time for a linter started after the snapshot'
rm -rf -- "$late_linted"

# 17q. the marker sweep's own unreadable-README path (a name no pattern in (2) matches) is
# UNKNOWN too, not a silent skip.
unread2=$(make_run_cache 'daily-ai-engineer-gocache-17q' "$go_marker" 7) || fail 'fixture: 17q'
chmod 000 "${unread2}/README"
out=$(run_cache dry-run 3 "$NEVER_CLEAN_BUDGET")
rc=$?
chmod 644 "${unread2}/README"
if [ "$(id -u)" -ne 0 ]; then
  [ "$rc" -eq 2 ] || fail "an unreadable marker in the marker sweep exited ${rc}, not 2 (UNKNOWN)"
  said "$out" "$unread2" 'UNKNOWN (marker unreadable, cache not examined)' ||
    fail 'an unreadable marker in the marker sweep was not reported UNKNOWN'
fi
rm -rf -- "$unread2"

# 17r. a failed `go env GOCACHE` leaves the configured-cache exclusion incomplete, so the marker
# sweep is skipped as UNKNOWN (exit 2) and an idle marked cache is left in place.
broken_go="${fixture_root}/go-broken"
mkdir -p "$broken_go" || fail 'fixture: 17r stub dir'
cp "${quiet_ps}/ps" "${broken_go}/ps" || fail 'fixture: 17r ps'
printf '#!/bin/sh\nexit 1\n' > "${broken_go}/go" && chmod +x "${broken_go}/go" || fail 'fixture: 17r go'
kept_idle=$(make_run_cache 'daily-ai-engineer-gocache-17r' "$go_marker" 7) || fail 'fixture: 17r'
out=$(RUN_CACHE_PS="$broken_go" run_cache apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "a failed go env GOCACHE exited ${rc}, not 2 (UNKNOWN)"
grep -q 'UNKNOWN (go env GOCACHE failed)' <<<"$out" || fail 'a failed go env GOCACHE was not reported UNKNOWN'
[ -e "$kept_idle" ] || fail 'the marker sweep ran without the configured-cache exclusion'
rm -rf -- "$kept_idle"

# 17s. only a bounded prefix of README is read: a marker past the first 512 bytes is not a marker,
# so a huge or growing unrelated README can neither stall the sweep nor get its dir reaped.
padded=$(make_run_cache 'daily-ai-engineer-gocache-17s' '' 7) || fail 'fixture: 17s'
{ head -c 600 /dev/zero | tr '\0' 'x'; printf '\n%s\n' "$go_marker"; } > "${padded}/README"
age_path "${padded}/README" 7 && age_path "$padded" 7 || fail 'fixture: age 17s'
out=$(run_cache apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "$padded" ] || fail 'a README whose marker sits past the read bound was treated as a cache'
rm -rf -- "$padded"

# 17t. a write deep in the cache (a fuzz corpus entry, fuzz/<import-path>/<target>/<hash>) keeps it:
# once those directories exist, a new entry moves no node at depth 1 or 2.
fuzzed=$(make_run_cache 'daily-ai-engineer-gocache-17t' "$go_marker" 7) || fail 'fixture: 17t'
mkdir -p "${fuzzed}/fuzz/example.com/pkg/FuzzX" || fail 'fixture: 17t fuzz dirs'
age_path "${fuzzed}/fuzz/example.com/pkg/FuzzX" 7 && age_path "${fuzzed}/fuzz/example.com/pkg" 7 &&
  age_path "${fuzzed}/fuzz/example.com" 7 && age_path "${fuzzed}/fuzz" 7 && age_path "$fuzzed" 7 ||
  fail 'fixture: age 17t dirs'
printf 'corpus\n' > "${fuzzed}/fuzz/example.com/pkg/FuzzX/0123abcd"
age_path "${fuzzed}/fuzz/example.com/pkg/FuzzX" 7 || fail 'fixture: age 17t target dir'
out=$(run_cache apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "$fuzzed" ] || fail 'apply reaped a per-run Go cache with a fresh fuzz corpus entry'
said "$out" "$fuzzed" 'KEEP  (written within 6h)' ||
  fail 'a per-run Go cache with a fresh fuzz corpus entry was not kept for being recent'
rm -rf -- "$fuzzed"

# 17u. a README that only QUOTES a marker (not as its first line) is not a cache: an unrelated
# directory that mentions the sentence may hold work nothing can regenerate.
quoting=$(make_run_cache 'notes-about-caches-17u' '' 7) || fail 'fixture: 17u'
printf 'Notes on Go caches. Go writes:\n%s\n' "$go_marker" > "${quoting}/README"
age_path "${quoting}/README" 7 && age_path "$quoting" 7 || fail 'fixture: age 17u'
out=$(run_cache apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "$quoting" ] || fail 'a directory whose README merely quotes the marker was reaped as a cache'
rm -rf -- "$quoting"

if [ "$failures" -eq 0 ]; then
  printf 'build-cache-reclaim contract: all assertions passed\n'
  exit 0
fi
printf 'build-cache-reclaim contract: %d assertion(s) failed\n' "$failures" >&2
exit 1
