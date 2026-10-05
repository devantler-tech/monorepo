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
# The container image step asks the host's real container runtime, and an apply run over its
# budget removes real images. It is off for every case; case 22 points it at a stub.
export BUILD_CACHE_RECLAIM_CONTAINER_CLI=off

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

# 17v. a temp root given as a SYMLINK to the real directory (/tmp on macOS) is still listed: a
# listing that does not follow it finds nothing and reports success.
linked_root="${fixture_root}/tmp-link-17v"
ln -s "$cache_root" "$linked_root" || fail 'fixture: 17v link'
via_link=$(make_run_cache 'daily-ai-engineer-gocache-17v' "$go_marker" 7) || fail 'fixture: 17v'
out=$(BUILD_CACHE_RECLAIM_TMPDIR="$linked_root" BUILD_CACHE_RECLAIM_GO_TMPDIR="$go_tmp_root" \
  GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="$GO_MOD_FIXTURE" PATH="${quiet_ps}:$PATH" \
  bash "$impl" dry-run 3 "$NEVER_CLEAN_BUDGET" 2>&1)
said "$out" "${linked_root}/daily-ai-engineer-gocache-17v" 'WOULD REAP' ||
  fail 'an idle per-run cache under a symlinked temp root was not selected'
rm -rf -- "$via_link" "$linked_root"

# 17w. a go that exits 0 but prints no GOCACHE path (a broken shim) is no better than a failed
# read: the exclusion would be incomplete, so the marker sweep is skipped as UNKNOWN.
silent_go="${fixture_root}/go-silent"
mkdir -p "$silent_go" || fail 'fixture: 17w stub dir'
cp "${quiet_ps}/ps" "${silent_go}/ps" || fail 'fixture: 17w ps'
printf '#!/bin/sh\nexit 0\n' > "${silent_go}/go" || fail 'fixture: 17w go'
chmod +x "${silent_go}/go" || fail 'fixture: 17w chmod'
silent_idle=$(make_run_cache 'daily-ai-engineer-gocache-17w' "$go_marker" 7) || fail 'fixture: 17w'
out=$(RUN_CACHE_PS="$silent_go" run_cache apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "a go printing no GOCACHE exited ${rc}, not 2 (UNKNOWN)"
grep -q "UNKNOWN (go env GOCACHE gave ''" <<<"$out" || fail 'a go printing no GOCACHE was not reported UNKNOWN'
[ -e "$silent_idle" ] || fail 'the marker sweep ran on an empty GOCACHE read'
rm -rf -- "$silent_idle"

# 17x. a temp-root child this run cannot search hides its README: that is "not examined" (UNKNOWN,
# exit 2), never "no marker".
opaque=$(make_run_cache 'opaque-cache-17x' "$go_marker" 7) || fail 'fixture: 17x'
chmod 000 "$opaque"
out=$(run_cache dry-run 3 "$NEVER_CLEAN_BUDGET")
rc=$?
chmod 755 "$opaque"
if [ "$(id -u)" -ne 0 ]; then
  [ "$rc" -eq 2 ] || fail "an unsearchable temp-root child exited ${rc}, not 2 (UNKNOWN)"
  said "$out" "$opaque" 'UNKNOWN (marker unreadable, cache not examined)' ||
    fail 'an unsearchable temp-root child was not reported UNKNOWN'
fi
rm -rf -- "$opaque"

# 17y. Go's DEFAULT build cache (os.UserCacheDir()/go-build) can resolve to a direct child of the
# temp root (XDG_CACHE_HOME there on Linux; ~/Library/Caches there on macOS). Section 1 owns it, so
# the marker sweep leaves it alone even when GOCACHE names somewhere else.
go_home="${fixture_root}/home-17y"
mkdir -p "${go_home}/Library" || fail 'fixture: 17y home'
ln -s "$cache_root" "${go_home}/Library/Caches" || fail 'fixture: 17y caches link'
default_go=$(make_run_cache 'go-build' "$go_marker" 7) || fail 'fixture: 17y'
out=$(HOME="$go_home" XDG_CACHE_HOME="$cache_root" run_cache apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "${default_go}/00/a1-d" ] || fail 'the marker sweep reaped the default Go build cache'
rm -rf -- "$default_go" "$go_home"

# 17z. a process table that cannot be read is UNKNOWN for an idle lint cache (exit 2), never a
# proven running linter and a clean KEEP.
no_ps="${fixture_root}/ps-none-17z"
make_ps_stub "$no_ps" || fail 'fixture: 17z ps stub'
blind_lint=$(make_run_cache 'lane-golangci-cache-17z' "$lint_marker" 7) || fail 'fixture: 17z'
out=$(RUN_CACHE_PS="$no_ps" run_cache dry-run 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "an unreadable process table exited ${rc}, not 2 (UNKNOWN)"
said "$out" "$blind_lint" 'UNKNOWN (scan failed, cache not examined)' ||
  fail 'an idle lint cache with an unreadable process table was not reported UNKNOWN'
rm -rf -- "$blind_lint"

# 17y. a cache one level below a Claude Code session scratchpad
# (claude-<uid>/<project>/<session>/scratchpad/<cache>) is swept like a top-level one; on
# 2026-10-02 two of them held 8.9 GB the depth-1 listing never saw. Its ablation partners differ
# in one dimension each and must not be considered at all: the same cache under a root not named
# claude-*, and one under a session dir that is not the scratchpad.
scratch_go=$(make_run_cache 'claude-501/proj-a/sess-1/scratchpad/gocache' "$go_marker" 7) ||
  fail 'fixture: 17y scratchpad cache'
scratch_fresh=$(make_run_cache 'claude-501/proj-a/sess-2/scratchpad/gocache' "$go_marker" 7) ||
  fail 'fixture: 17y fresh scratchpad cache'
printf 'entry\n' > "${scratch_fresh}/00/b2-d"
scratch_other_root=$(make_run_cache 'notclaude-501/proj-a/sess-1/scratchpad/gocache' "$go_marker" 7) ||
  fail 'fixture: 17y non-claude root'
scratch_not_pad=$(make_run_cache 'claude-501/proj-a/sess-1/elsewhere/gocache' "$go_marker" 7) ||
  fail 'fixture: 17y non-scratchpad dir'
out=$(run_cache dry-run 3 "$NEVER_CLEAN_BUDGET")
said "$out" "$scratch_go" 'WOULD REAP' ||
  fail 'an idle Go cache inside a session scratchpad was not selected'
said "$out" "$scratch_fresh" 'KEEP  (written within 6h)' ||
  fail 'a recently written Go cache inside a session scratchpad was not kept'
grep -qF "$scratch_other_root" <<<"$out" && fail 'a nested cache under a non-claude-* root was considered'
grep -qF "$scratch_not_pad" <<<"$out" && fail 'a nested cache outside the scratchpad dir was considered'
[ -e "${scratch_go}/00/a1-d" ] || fail 'dry-run deleted a scratchpad Go cache'
out=$(run_cache apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "$scratch_go" ] && fail "apply did not reap an idle scratchpad Go cache: $scratch_go"
[ -e "$scratch_fresh" ] || fail 'apply reaped a recently written scratchpad Go cache'
[ -e "$scratch_other_root" ] || fail 'apply reaped a nested cache under a non-claude-* root'
[ -e "$scratch_not_pad" ] || fail 'apply reaped a nested cache outside the scratchpad dir'
rm -rf -- "${cache_root}/claude-501" "${cache_root}/notclaude-501"

# --- 18. no go binary at all (the macOS CI runner): GOCACHE is read where go would read it -------
nogo_env() { # <GOENV value> <args...>
  local goenv=$1
  shift
  env -u GOCACHE BUILD_CACHE_RECLAIM_GO=none GOENV="$goenv" \
    BUILD_CACHE_RECLAIM_TMPDIR="$cache_root" BUILD_CACHE_RECLAIM_GO_TMPDIR="$go_tmp_root" \
    GOMODCACHE="$GO_MOD_FIXTURE" PATH="${quiet_ps}:$PATH" bash "$impl" "$@" 2>&1
}

# 18a. nothing configured: the sweep runs (exit 0) and reaps an idle marked cache, as on CI.
nogo_idle=$(make_run_cache 'daily-ai-engineer-gocache-18a' "$go_marker" 7) || fail 'fixture: 18a'
out=$(nogo_env off apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 0 ] || fail "with no go and nothing configured the sweep exited ${rc}, not 0: ${out}"
[ -e "$nogo_idle" ] && fail 'with no go and nothing configured an idle marked cache was not reaped'
rm -rf -- "$nogo_idle"

# 18b. a go env file assigning GOCACHE twice: go uses the last, and every assigned path is kept.
dup_env="${fixture_root}/go-env-18b"
nogo_kept=$(make_run_cache 'configured-gocache-18b' "$go_marker" 7) || fail 'fixture: 18b'
printf 'GOCACHE=%s\nGOCACHE=%s\n' "${fixture_root}/elsewhere" "$nogo_kept" > "$dup_env"
out=$(nogo_env "$dup_env" apply 3 "$NEVER_CLEAN_BUDGET")
[ -e "${nogo_kept}/00/a1-d" ] || fail 'the last GOCACHE assignment in the go env file was not excluded'
rm -rf -- "$nogo_kept" "$dup_env"

# 18c. a relative GOENV cannot be read from here: UNKNOWN (exit 2), and the run finishes.
out=$(nogo_env missing dry-run 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "a relative GOENV exited ${rc}, not 2 (UNKNOWN)"
grep -q 'is not absolute' <<<"$out" || fail 'a relative GOENV was not reported UNKNOWN'

# --- shared stubs for cases 19-20 ---------------------------------------------------
# One stub directory holding a `go`, a `ps` and an `lsof`, so both cases run the same way on a
# host with no go at all (the macOS CI runner) and can never touch a real cache.
#   go    answers `env GOCACHE|GOMODCACHE` from the environment and RECORDS each `clean` in
#         cache-stub-cleans instead of running one.
#   ps    the quiet table: no toolchain, no linter.
#   lsof  the up-front snapshot lists only STUB_LSOF_SNAPSHOT (default: an unrelated path). The
#         late per-tree probe (+D) names a holder under STUB_LSOF_LATE_HELD, and answers an
#         empty row set with a diagnostic for STUB_LSOF_LATE_BLOCKED: the three shapes case 12
#         measured on a real lsof. Both name a resolved directory.
cache_stubs="${fixture_root}/cache-stub-bin"
cache_cleans="${fixture_root}/cache-stub-cleans"
mkdir -p "$cache_stubs" || fail 'fixture: cache stub dir'
cp "${quiet_ps}/ps" "${cache_stubs}/ps" || fail 'fixture: cache stub ps'
cat > "${cache_stubs}/go" <<STUB
#!/bin/sh
case "\$1" in
  env)
    case "\$2" in
      GOCACHE) printf '%s\n' "\$GOCACHE" ;;
      GOMODCACHE) printf '%s\n' "\$GOMODCACHE" ;;
    esac
    ;;
  clean) printf '%s\n' "\$2" >> "${cache_cleans}" ;;
esac
exit 0
STUB
cat > "${cache_stubs}/lsof" <<STUB
#!/bin/sh
late=0
for a in "\$@"; do
  [ "\$a" = "+D" ] && late=1
done
if [ "\$late" -eq 0 ]; then
  printf 'n%s\n' "\${STUB_LSOF_SNAPSHOT:-${fixture_root}/unrelated-path}"
  exit 0
fi
for a in "\$@"; do
  if [ -n "\${STUB_LSOF_LATE_HELD:-}" ] && [ "\$a" = "\$STUB_LSOF_LATE_HELD" ]; then
    printf 'n%s\n' "\$a/held-file"
  fi
  if [ -n "\${STUB_LSOF_LATE_BLOCKED:-}" ] && [ "\$a" = "\$STUB_LSOF_LATE_BLOCKED" ]; then
    echo "lsof: WARNING: can't opendir(\$a/nested): Permission denied" >&2
  fi
done
exit 1
STUB
chmod +x "${cache_stubs}/go" "${cache_stubs}/lsof" || fail 'fixture: chmod cache stubs'
empty_go_tmp="${go_tmp_root}/empty-19"
mkdir -p "$empty_go_tmp" || fail 'fixture: empty Go temp root'

# --- 19. a Go cache is asked about AGAIN immediately before `go clean` (monorepo#3710) ---
# reclaim_go_cache decided "in use" from the snapshot taken at the start of the run and then, in
# apply mode, ran `go clean` with no fresh probe -- although measuring one multi-gigabyte cache
# takes minutes, and the tree sweep and the golangci-lint cache both re-check at removal time.
# A build that started inside that window lost its cache files mid-build.
#
# The snapshot here names neither cache, so the up-front check passes for both and only the
# late probe can keep one. It names a holder under the MODULE cache alone: the build cache is
# the ablation partner inside the very same run, and must still be cleaned.
late_go_cache="${fixture_root}/late-go-cache"
late_mod_cache="${fixture_root}/late-mod-cache"
mkdir -p "$late_go_cache" "$late_mod_cache" || fail 'fixture: case 19 caches'
dd if=/dev/zero of="${late_go_cache}/blob" bs=1024 count=2048 2> /dev/null
dd if=/dev/zero of="${late_mod_cache}/blob" bs=1024 count=2048 2> /dev/null
late_mod_canon=$(cd -- "$late_mod_cache" && pwd -P) || fail 'fixture: resolve case 19 module cache'
# run_late_go <mode> runs over a 0 GB budget, so both 2 MB caches are over it.
run_late_go() {
  rm -f "$cache_cleans"
  PATH="${cache_stubs}:$PATH" BUILD_CACHE_RECLAIM_TMPDIR="$iso_tmp" \
    BUILD_CACHE_RECLAIM_GO_TMPDIR="$empty_go_tmp" \
    GOCACHE="$late_go_cache" GOMODCACHE="$late_mod_cache" bash "$impl" "$1" 3 0 2>&1
}
# cleaned <flag> succeeds when the `go` stub recorded a `go clean <flag>`.
cleaned() {
  [ -f "$cache_cleans" ] && grep -qx -- "$1" "$cache_cleans"
}

# 19a. ABLATION PARTNER, nothing holds either cache at removal time: both ARE cleaned. Without
# this, 19b passes just as well on a script that never reaches `go clean` at all.
out=$(run_late_go apply)
cleaned -cache || fail 'ablation partner: an idle over-budget build cache was not cleaned'
cleaned -modcache || fail 'ablation partner: an idle over-budget module cache was not cleaned'

# 19b. a holder that appears AFTER the snapshot keeps that cache, and only that cache.
out=$(STUB_LSOF_LATE_HELD="$late_mod_canon" run_late_go apply)
cleaned -modcache && fail 'go clean -modcache ran although a process opened the module cache after the snapshot'
grep -qE '^build-cache-reclaim: GOMODCACHE .* in use at removal time' <<<"$out" ||
  fail 'a module cache kept by the late re-check did not say why'
cleaned -cache || fail 'a late holder of the module cache also kept the idle build cache'

# 19c. a late probe that could not finish is not an idle answer: the cache is kept.
out=$(STUB_LSOF_LATE_BLOCKED="$late_mod_canon" run_late_go apply)
cleaned -modcache && fail 'go clean -modcache ran although the late liveness scan could not complete'
grep -q 'KEEP  (scan incomplete)' <<<"$out" ||
  fail 'a module cache whose late scan could not complete was not reported as such'

# 19d. dry-run never cleans, and its projection is the up-front answer: the late probe is
# about the moment of removal, which a dry-run never reaches.
out=$(STUB_LSOF_LATE_HELD="$late_mod_canon" run_late_go dry-run)
[ -e "$cache_cleans" ] && fail 'dry-run ran go clean'
grep -q 'GOMODCACHE would be cleaned' <<<"$out" ||
  fail 'dry-run did not project an over-budget module cache that is idle in the snapshot'

# --- 20. a per-lane fallback module cache is budgeted too (monorepo#3710) --------------
# A runtime whose sandbox cannot write the default caches points GOMODCACHE at
# <temp root>/go-mod-<lane>. Section 1 budgets only the GOMODCACHE its own `go env` reports, and
# a module cache carries no README marker, so the marker sweep of case 17 never selects it:
# nothing owned it and it grew without bound. Every reap below has an ablation partner that
# differs in exactly one dimension -- the budget, the name, the layout, a holder -- and is KEPT.
mod_root="${fixture_root}/modcache-tmp"
mkdir -p "$mod_root" || fail 'fixture: fallback module cache temp root'
# make_mod_cache <path> builds a 2 MB directory laid out like a Go module cache: the download
# cache the go command creates, and an unpacked module whose files Go marks read-only.
make_mod_cache() {
  mkdir -p "$1/cache/download/example.com/dep/@v" "$1/example.com/dep@v1.0.0" || return 1
  printf 'v1.0.0\n' > "$1/cache/download/example.com/dep/@v/list" || return 1
  dd if=/dev/zero of="$1/example.com/dep@v1.0.0/blob.go" bs=1024 count=2048 2> /dev/null
  chmod -R a-w "$1/example.com/dep@v1.0.0" || return 1
}
# run_mod <mode> <budget-gb> sweeps mod_root with the stubs of case 19.
run_mod() {
  rm -f "$cache_cleans"
  PATH="${cache_stubs}:$PATH" BUILD_CACHE_RECLAIM_TMPDIR="$mod_root" \
    BUILD_CACHE_RECLAIM_GO_TMPDIR="$empty_go_tmp" \
    GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="${MOD_GOMODCACHE:-$GO_MOD_FIXTURE}" \
    bash "$impl" "$1" 3 "$2" 2>&1
}
mod_idle="${mod_root}/go-mod-codex"
mod_held="${mod_root}/go-mod-claude"
mod_named_only="${mod_root}/go-mod-notes"
mod_shaped_only="${mod_root}/lane-modules"
mod_cache_link="${mod_root}/go-mod-cachelink"
mod_elsewhere="${fixture_root}/modcache-elsewhere"
make_mod_cache "$mod_idle" || fail 'fixture: idle fallback module cache'
make_mod_cache "$mod_held" || fail 'fixture: held fallback module cache'
# The name without the layout, the layout without the name, the name with `cache` a symlink into
# a real module cache, and a go-mod-* SYMLINK to one: none is positively a fallback module cache.
mkdir -p "$mod_named_only" || fail 'fixture: go-mod-notes'
dd if=/dev/zero of="${mod_named_only}/notes.bin" bs=1024 count=2048 2> /dev/null
make_mod_cache "$mod_shaped_only" || fail 'fixture: lane-modules'
make_mod_cache "$mod_elsewhere" || fail 'fixture: module cache outside the temp root'
mkdir -p "$mod_cache_link" || fail 'fixture: go-mod-cachelink'
ln -s "${mod_elsewhere}/cache" "${mod_cache_link}/cache" || fail 'fixture: cache symlink'
dd if=/dev/zero of="${mod_cache_link}/blob" bs=1024 count=2048 2> /dev/null
ln -s "$mod_elsewhere" "${mod_root}/go-mod-linked" || fail 'fixture: go-mod-linked'
mod_held_canon=$(cd -- "$mod_held" && pwd -P) || fail 'fixture: resolve held fallback module cache'

# 20a. within budget: reported and kept. The ablation partner for 20b.
out=$(run_mod apply "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 0 ] || fail "a readable fallback module cache sweep exited ${rc}, not 0"
grep -qF "fallback GOMODCACHE ${mod_idle} = " <<<"$out" ||
  fail 'a fallback module cache was never reported'
grep -q 'REAP' <<<"$out" && fail 'a fallback module cache within budget was selected'
[ -e "${mod_idle}/cache/download" ] || fail 'apply removed a fallback module cache within budget'

# 20b. over budget, dry-run: the idle one is selected and counted, the held one is kept for
# its holder, the four look-alikes are never considered, and nothing is deleted.
out=$(STUB_LSOF_SNAPSHOT="${mod_held_canon}/cache/download/example.com/dep/@v/list" run_mod dry-run 0)
said "$out" "$mod_idle" 'WOULD REAP' ||
  fail 'an idle over-budget fallback module cache was not selected'
said "$out" "$mod_held" 'KEEP  (in use)' ||
  fail 'a fallback module cache held open by a live process was not kept as in use'
for d in "$mod_named_only" "$mod_shaped_only" "$mod_cache_link" "${mod_root}/go-mod-linked"; do
  grep -qF "$d" <<<"$out" && fail "a directory that is not a fallback module cache was considered: $d"
done
mod_summary=$(printf '%s\n' "$out" | sed -n 's/.*would reclaim=~\([0-9]*\) MB.*/\1/p' | tail -1)
case "$mod_summary" in
  '' | *[!0-9]*) fail 'dry-run summary reported no parsable would-reclaim total' ;;
  *) [ "$mod_summary" -ge 2 ] ||
    fail "dry-run summary omitted the fallback module cache: would reclaim=~${mod_summary} MB" ;;
esac
[ -e "${mod_idle}/cache/download" ] || fail 'dry-run deleted a fallback module cache'

# 20c. over budget, apply: the idle one is removed whole, read-only files included; the held
# one and every look-alike remain, and so does the module cache the symlinks point at.
out=$(STUB_LSOF_SNAPSHOT="${mod_held_canon}/cache/download/example.com/dep/@v/list" run_mod apply 0)
if [ -e "$mod_idle" ]; then
  chmod -R u+w "$mod_idle" 2> /dev/null
  fail "apply did not remove an idle over-budget fallback module cache: $mod_idle"
fi
[ -e "${mod_held}/example.com/dep@v1.0.0/blob.go" ] ||
  fail 'apply removed a fallback module cache a live process held open'
[ -e "${mod_named_only}/notes.bin" ] || fail 'apply removed a go-mod-* directory that is not a module cache'
[ -e "${mod_shaped_only}/cache/download" ] ||
  fail 'apply removed a module cache whose name is outside the fallback pattern'
[ -e "${mod_cache_link}/blob" ] || fail 'apply removed a go-mod-* directory whose cache is a symlink'
[ -e "${mod_elsewhere}/example.com/dep@v1.0.0/blob.go" ] ||
  fail 'apply removed a module cache outside the temp root through a symlink'

# 20d. a holder that appears AFTER the snapshot keeps it: the same late re-probe as case 11.
out=$(STUB_LSOF_LATE_HELD="$mod_held_canon" run_mod apply 0)
[ -e "${mod_held}/example.com/dep@v1.0.0/blob.go" ] ||
  fail 'apply removed a fallback module cache whose holder appeared after the snapshot'
said "$out" "$mod_held" 'KEEP  (in use, late)' ||
  fail 'a fallback module cache kept by the late re-probe did not say why'

# 20e. the GOMODCACHE this run's own go reports is budgeted by section 1, so the fallback sweep
# must not decide it, or count it, a second time.
out=$(MOD_GOMODCACHE="$mod_held" run_mod dry-run 0)
grep -q 'GOMODCACHE would be cleaned' <<<"$out" ||
  fail 'the configured module cache under the temp root was not budgeted by section 1'
grep -qF "fallback GOMODCACHE ${mod_held}" <<<"$out" &&
  fail 'the configured module cache was budgeted a second time as a fallback'
said "$out" "$mod_held" 'REAP' && fail 'the configured module cache was selected a second time as a tree'

# 20f. a go-mod-* directory this run cannot search hides its layout: that is "not examined"
# (UNKNOWN, exit 2), never "not a module cache".
chmod 000 "$mod_held"
out=$(run_mod dry-run 0)
rc=$?
chmod 755 "$mod_held"
if [ "$(id -u)" -ne 0 ]; then
  [ "$rc" -eq 2 ] || fail "an unsearchable fallback module cache exited ${rc}, not 2 (UNKNOWN)"
  said "$out" "$mod_held" 'UNKNOWN (unreadable, module cache not examined)' ||
    fail 'an unsearchable fallback module cache was not reported UNKNOWN'
fi
chmod -R u+w "$mod_root" "$mod_elsewhere" 2> /dev/null
rm -rf -- "$mod_root" "$mod_elsewhere"

# --- 21. a per-run Go cache a lane REUSES is budgeted while it is recent (monorepo#3831) ---
# The idle rule of case 17 never selects a cache that is written every hour: one lane's
# /private/tmp/go-cache-codex was kept as "written within 6h" on every sweep, with no size and
# no budget, and grew from 21 GB to 36 GB in five hours on 2026-10-04. Every cache below was
# written moments ago; each reap has an ablation partner that differs in exactly one dimension
# -- the budget, the cache kind, a holder -- and must be KEPT.
reuse_root="${fixture_root}/reuse-tmp"
mkdir -p "$reuse_root" || fail 'fixture: reused cache temp root'
# make_reused_cache <path> <marker-text> builds a 2 MB marked cache written just now.
make_reused_cache() {
  mkdir -p "$1/00" || return 1
  printf '%s\n' "$2" > "$1/README" || return 1
  dd if=/dev/zero of="$1/00/blob-d" bs=1024 count=2048 2> /dev/null
}
# run_reuse <mode> <budget-gb> sweeps reuse_root with the stubs of case 19.
run_reuse() {
  rm -f "$cache_cleans"
  PATH="${REUSE_PATH_PREFIX:+${REUSE_PATH_PREFIX}:}${cache_stubs}:$PATH" \
    BUILD_CACHE_RECLAIM_TMPDIR="$reuse_root" BUILD_CACHE_RECLAIM_GO_TMPDIR="$empty_go_tmp" \
    GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="$GO_MOD_FIXTURE" bash "$impl" "$1" 3 "$2" 2>&1
}
reuse_go="${reuse_root}/go-cache-codex"
reuse_held="${reuse_root}/go-cache-claude"
reuse_lint="${reuse_root}/lint-cache-codex"
make_reused_cache "$reuse_go" "$go_marker" || fail 'fixture: reused Go cache'
make_reused_cache "$reuse_held" "$go_marker" || fail 'fixture: held reused Go cache'
make_reused_cache "$reuse_lint" "$lint_marker" || fail 'fixture: reused lint cache'
reuse_held_canon=$(cd -- "$reuse_held" && pwd -P) || fail 'fixture: resolve held reused Go cache'

# 21a. within budget: kept as recent, and the line now carries its size and the budget, so
# growth is visible before it is critical. The ablation partner for 21b and 21c.
out=$(run_reuse apply "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 0 ] || fail "a readable reused-cache sweep exited ${rc}, not 0"
said "$out" "$reuse_go" 'KEEP  (written within 6h) [0-9][0-9]* MB, budget [0-9][0-9]* MB' ||
  fail 'a recent Go cache within budget was not kept with its size and budget reported'
grep -q 'REAP' <<<"$out" && fail 'a recent Go cache within budget was selected'
[ -e "${reuse_go}/00/blob-d" ] || fail 'apply emptied a recent Go cache within budget'

# 21b. over budget, dry-run: the idle-in-the-snapshot one is selected and counted, the one a
# live process holds open is kept for its holder, and nothing is deleted.
out=$(STUB_LSOF_SNAPSHOT="${reuse_held_canon}/00/blob-d" run_reuse dry-run 0)
said "$out" "$reuse_go" 'WOULD REAP' ||
  fail 'a recent over-budget Go cache was not selected by dry-run'
said "$out" "$reuse_held" 'KEEP  (in use)' ||
  fail 'a recent over-budget Go cache held open by a live process was not kept as in use'
reuse_summary=$(printf '%s\n' "$out" | sed -n 's/.*would reclaim=~\([0-9]*\) MB.*/\1/p' | tail -1)
case "$reuse_summary" in
  '' | *[!0-9]*) fail 'dry-run summary reported no parsable would-reclaim total' ;;
  *) [ "$reuse_summary" -ge 2 ] ||
    fail "dry-run summary omitted the reused Go cache: would reclaim=~${reuse_summary} MB" ;;
esac
[ -e "${reuse_go}/00/blob-d" ] || fail 'dry-run emptied a reused Go cache'

# 21c. a recent over-budget LINT cache is not budgeted here: kept for being recent, as before,
# with no size on the line. Asserted on the same over-budget runs as 21b and 21d.
said "$out" "$reuse_lint" 'KEEP  (written within 6h)' ||
  fail 'a recent lint cache was not kept for being recent'
said "$out" "$reuse_lint" ' MB' && fail 'a recent lint cache was measured against the Go cache budget'

# 21d. over budget, apply: the idle one is EMPTIED and keeps its README, so the lane's GOCACHE
# still exists and still identifies itself; the held one and the lint cache remain.
out=$(STUB_LSOF_SNAPSHOT="${reuse_held_canon}/00/blob-d" run_reuse apply 0)
[ -e "${reuse_go}/00" ] && fail "apply did not empty a recent over-budget Go cache: $reuse_go"
said "$out" "$reuse_go" 'REAP  [0-9][0-9]* MB  (emptied, README kept)' ||
  fail 'an emptied reused Go cache was not reported'
[ "$(head -n 1 "${reuse_go}/README" 2> /dev/null)" = "$go_marker" ] ||
  fail 'emptying a reused Go cache removed its directory or its README marker'
[ -e "${reuse_held}/00/blob-d" ] ||
  fail 'apply emptied a recent over-budget Go cache a live process held open'
[ -e "${reuse_lint}/00/blob-d" ] || fail 'apply emptied a recent over-budget lint cache'

# 21e. a holder that appears AFTER the snapshot keeps it: the late re-probe still applies to a
# cache the idle rule is not asked about again.
out=$(STUB_LSOF_LATE_HELD="$reuse_held_canon" run_reuse apply 0)
[ -e "${reuse_held}/00/blob-d" ] ||
  fail 'apply emptied a reused Go cache whose holder appeared after the snapshot'
said "$out" "$reuse_held" 'KEEP  (in use, late)' ||
  fail 'a reused Go cache kept by the late re-probe did not say why'

# 21f. a recent Go cache whose size cannot be read is UNKNOWN (exit 2), never emptied and never a
# clean KEEP. This `du` answers nothing for that one cache and is the real du for every other.
reuse_du="${fixture_root}/du-blind-21f"
real_du=$(command -v du) || fail 'fixture: no du to wrap'
mkdir -p "$reuse_du" || fail 'fixture: du stub dir'
cat > "${reuse_du}/du" <<STUB
#!/bin/sh
for a in "\$@"; do last=\$a; done
[ "\$last" = "${reuse_held}" ] && exit 1
exec "${real_du}" "\$@"
STUB
chmod +x "${reuse_du}/du" || fail 'fixture: chmod du stub'
out=$(REUSE_PATH_PREFIX="$reuse_du" run_reuse apply 0)
rc=$?
[ "$rc" -eq 2 ] || fail "an unmeasurable reused Go cache exited ${rc}, not 2 (UNKNOWN)"
said "$out" "$reuse_held" 'UNKNOWN (unmeasurable)' ||
  fail 'an unmeasurable reused Go cache was not reported UNKNOWN'
[ -e "${reuse_held}/00/blob-d" ] || fail 'apply emptied a reused Go cache it could not measure'
rm -rf -- "$reuse_root" "$reuse_du"

# --- 22. the container image store is budgeted too (monorepo#3848) ----------------------
# 57 GB of images no container used sat in the local container runtime's store while the
# disk preflight read LOW, because nothing here looked at it. Every keep rule is tested by
# ablation against one removable image: `old-unused` is over the age threshold and no
# container was created from it. Each other image differs from it in exactly one way.
ct_root="${fixture_root}/container-22"
ct_state="${ct_root}/state"
ct_store="${ct_root}/store"
ct_tmp="${ct_root}/tmp"
mkdir -p "$ct_state" "${ct_store}/snapshots" "$ct_tmp" "${ct_root}/bin" ||
  fail 'fixture: container dirs'
# The stub answers from files, records every call, and fails a read when told to. It knows
# no verb that stops or removes a CONTAINER, so such a call exits 64 and shows in `calls`.
# `fail-list-after` holds how many container listings succeed before every later one fails.
cat > "${ct_root}/bin/container" <<STUB
#!/bin/sh
s="${ct_state}"
printf '%s\n' "\$*" >> "\$s/calls"
case "\$1 \$2" in
  'system df')
    [ -e "\$s/fail-df" ] && exit 1
    cat "\$s/df.json"
    ;;
  'list --all')
    [ -e "\$s/fail-list" ] && exit 1
    if [ -e "\$s/fail-list-after" ]; then
      n=\$(grep -c '^list --all' "\$s/calls")
      [ "\$n" -gt "\$(cat "\$s/fail-list-after")" ] && exit 1
    fi
    cat "\$s/containers.json"
    ;;
  'image list')
    [ -e "\$s/fail-images" ] && exit 1
    cat "\$s/images.json"
    ;;
  'image delete')
    printf '%s\n' "\$3" >> "\$s/deleted"
    [ -e "\$s/df-after.json" ] && cp "\$s/df-after.json" "\$s/df.json"
    exit 0
    ;;
  *) exit 64 ;;
esac
STUB
chmod +x "${ct_root}/bin/container" || fail 'fixture: chmod container stub'

# Digests carry the letters a-f, so a rule that accepted digits only would refuse them all.
ct_hex() { printf 'abcdef%058d' "$1"; }
# ct_snapshot <n> <age-days> unpacks variant n, that many days ago.
ct_snapshot() {
  local dir stamp
  dir="${ct_store}/snapshots/$(ct_hex "$1")"
  mkdir -p "$dir" || return 1
  # A real payload, so a size is a number a second count of it would visibly double.
  dd if=/dev/zero of="${dir}/layer" bs=1024 count=2048 2>/dev/null || return 1
  if [ "$2" -gt 0 ]; then
    stamp=$(date -u -v-"$2"d +%Y%m%d%H%M 2>/dev/null) ||
      stamp=$(date -u -d "$2 days ago" +%Y%m%d%H%M 2>/dev/null) || return 1
    touch -t "$stamp" "$dir" || return 1
  fi
}
ct_image() { # <name> <index-digest> <variant-digest>...
  local name=$1 digest=$2 v sep='' variants=''
  shift 2
  for v in "$@"; do
    variants="${variants}${sep}{\"digest\":\"${v}\"}"
    sep=,
  done
  printf '{"configuration":{"name":"%s","descriptor":{"digest":"%s"}},"variants":[%s]}' \
    "$name" "$digest" "$variants"
}
ct_container() { # <id> <image-reference> <image-digest> <state> [<startedDate>]
  printf '{"configuration":{"id":"%s","image":{"reference":"%s","descriptor":{"digest":"%s"}}},"status":{"state":"%s","startedDate":"%s"}}' \
    "$1" "$2" "$3" "$4" "${5:-}"
}
ct_reset() {
  rm -f "${ct_state}/calls" "${ct_state}/deleted" "${ct_state}/fail-df" \
    "${ct_state}/fail-list" "${ct_state}/fail-list-after" "${ct_state}/fail-images" \
    "${ct_state}/df-after.json"
  # 5 GiB of images, 4 GiB of it unused.
  printf '{"images":{"sizeInBytes":5368709120,"reclaimable":4294967296}}\n' \
    > "${ct_state}/df.json"
  printf '[%s,%s,%s,%s,%s]\n' \
    "$(ct_container uses-by-name registry.test/old-in-use:1 sha256:other stopped)" \
    "$(ct_container uses-by-digest registry.test/another-name:1 sha256:digest-in-use running 2020-01-01T00:00:00.123Z)" \
    "$(ct_container uses-by-variant registry.test/yet-another:1 "sha256:$(ct_hex 7)" stopped)" \
    "$(ct_container just-started registry.test/another-name:1 sha256:digest-in-use running "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
    "$(ct_container no-clock registry.test/another-name:1 sha256:digest-in-use running not-a-time)" \
    > "${ct_state}/containers.json"
  # The twin is a second reference to the same image, as a tag and a digest pull produce.
  # Variant 9 is the unpacked-nowhere attestation manifest every multi-platform image
  # carries; variant 5 is never unpacked at all; variant 2 was unpacked just now.
  printf '[%s,%s,%s,%s,%s,%s,%s]\n' \
    "$(ct_image registry.test/old-unused:1 sha256:d1 "sha256:$(ct_hex 1)" "sha256:$(ct_hex 9)")" \
    "$(ct_image registry.test/old-unused-twin:1 sha256:d1 "sha256:$(ct_hex 1)" "sha256:$(ct_hex 9)")" \
    "$(ct_image registry.test/young-unused:1 sha256:d2 "sha256:$(ct_hex 2)")" \
    "$(ct_image registry.test/old-in-use:1 sha256:d3 "sha256:$(ct_hex 3)")" \
    "$(ct_image registry.test/old-in-use-by-digest:1 sha256:digest-in-use "sha256:$(ct_hex 4)")" \
    "$(ct_image registry.test/old-in-use-by-variant:1 sha256:d7 "sha256:$(ct_hex 7)")" \
    "$(ct_image registry.test/never-unpacked:1 sha256:d5 "sha256:$(ct_hex 5)")" \
    > "${ct_state}/images.json"
}
{ ct_snapshot 1 3 && ct_snapshot 2 0 && ct_snapshot 3 3 && ct_snapshot 4 3 && ct_snapshot 6 3 &&
  ct_snapshot 7 3; } || fail 'fixture: container snapshots'
# A variant that is not a plain digest must never be followed as a path: this directory is
# where `../../escape` lands, old enough to make that image removable if it were.
{ mkdir -p "${ct_root}/escape" && touch -t 202001010000 "${ct_root}/escape"; } ||
  fail 'fixture: escape dir'
# ...and a digest of the wrong length must not be either, though this one exists and is old.
{ mkdir -p "${ct_store}/snapshots/abcdef" && touch -t 202001010000 "${ct_store}/snapshots/abcdef"; } ||
  fail 'fixture: short digest dir'
# ...nor one of the right length that is not hexadecimal.
{ mkdir -p "${ct_store}/snapshots/gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg" &&
  touch -t 202001010000 "${ct_store}/snapshots/gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"; } || fail 'fixture: non-hex digest dir'

run_container() {
  BUILD_CACHE_RECLAIM_CONTAINER_CLI="${CT_CLI:-${ct_root}/bin/container}" \
    BUILD_CACHE_RECLAIM_CONTAINER_STORE="${CT_STORE:-$ct_store}" \
    BUILD_CACHE_RECLAIM_CONTAINER_BUDGET_GB="${CT_BUDGET:-1}" \
    BUILD_CACHE_RECLAIM_TMPDIR="$ct_tmp" \
    GOCACHE="$GO_BUILD_FIXTURE" GOMODCACHE="$GO_MOD_FIXTURE" \
    bash "$impl" "$@" 2>&1
}
ct_deleted() { cat "${ct_state}/deleted" 2>/dev/null; }
ct_expected_deleted='registry.test/old-unused:1
registry.test/old-unused-twin:1'
# No call may ever stop or remove a container: only reads, and `image delete`.
ct_only_safe_calls() {
  local other
  [ -s "${ct_state}/calls" ] || return 1
  other=$(grep -vE '^(system df --format json|list --all --format json|image list --format json|image delete [^ ]+)$' \
    "${ct_state}/calls")
  [ -z "$other" ]
}

# 22a. over budget, apply: exactly the old, unused image goes, under both its references.
ct_reset
printf '{"images":{"sizeInBytes":3221225472,"reclaimable":2147483648}}\n' \
  > "${ct_state}/df-after.json"
out=$(run_container apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 0 ] || fail "22a: a clean container sweep exited ${rc}"
[ "$(ct_deleted)" = "$ct_expected_deleted" ] ||
  fail "22a: expected only the old unused image to be removed, got: $(ct_deleted | tr '\n' ' ')"
grep -qF 'CONTAINER_IMAGES = 5120 MB, 4096 MB of it used by no container' <<<"$out" ||
  fail '22a: the store size and its unused share were not reported'
grep -qF 'removed 2 image reference(s), reclaimed ~2048 MB' <<<"$out" ||
  fail '22a: the reclaimed size was not taken from the store afterwards'
grep -qF 'KEEP  (unpacked within 24h) container image registry.test/young-unused:1' <<<"$out" ||
  fail '22a: a young image was not kept for its age'
grep -qF 'KEEP  (in use)        container image registry.test/old-in-use:1' <<<"$out" ||
  fail '22a: an image a stopped container was created from was not kept'
grep -qF 'KEEP  (in use)        container image registry.test/old-in-use-by-digest:1' <<<"$out" ||
  fail '22a: an image in use under another name was not kept'
grep -qF 'KEEP  (in use)        container image registry.test/old-in-use-by-variant:1' <<<"$out" ||
  fail '22a: an image a container names by one of its variants was not kept'
grep -qF 'KEEP  (not unpacked)  container image registry.test/never-unpacked:1' <<<"$out" ||
  fail '22a: an image with nothing unpacked was not kept'
grep -qF 'NOTE  container uses-by-digest running since 2020-01-01T00:00:00.123Z' <<<"$out" ||
  fail '22a: a long-running container was not named'
grep -qF 'NOTE  container no-clock running, start time unreadable' <<<"$out" ||
  fail '22a: a running container with an unreadable start time was not named'
grep -qF 'container just-started' <<<"$out" &&
  fail '22a: a container started just now was reported as long-running'
ct_only_safe_calls || fail "22a: the sweep made a call beyond reads and image delete: $(cat "${ct_state}/calls")"

# 22b. dry-run removes nothing, says what it would remove, and counts a shared image once.
ct_reset
out=$(run_container dry-run 3 "$NEVER_CLEAN_BUDGET")
[ -z "$(ct_deleted)" ] || fail '22b: dry-run removed a container image'
grep -qE 'WOULD REMOVE  ~[1-9][0-9]* MB  container image registry.test/old-unused:1' <<<"$out" ||
  fail '22b: dry-run did not name the image it would remove'
grep -qF 'WOULD REMOVE  ~0 MB  container image registry.test/old-unused-twin:1' <<<"$out" ||
  fail '22b: a second reference to one image was sized again'
grep -qF 'summary: would reap=2 ' <<<"$out" || fail '22b: the dry-run summary did not count both references'

# 22c. within budget, nothing is removed however old and unused (budget ablation).
ct_reset
out=$(CT_BUDGET=100 run_container apply 3 "$NEVER_CLEAN_BUDGET")
[ -z "$(ct_deleted)" ] || fail '22c: an image was removed while the store was within budget'
grep -qF 'CONTAINER_IMAGES within budget' <<<"$out" || fail '22c: within-budget was not reported'
grep -qF 'NOTE  container uses-by-digest' <<<"$out" ||
  fail '22c: a long-running container was not named while within budget'

# 22d. a store that cannot be measured is UNKNOWN, never empty -- whether the read fails...
ct_reset
: > "${ct_state}/fail-df"
out=$(run_container apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "22d: an unreadable store exited ${rc}, not 2 (UNKNOWN)"
grep -qF 'UNKNOWN: CONTAINER_IMAGES store usage could not be read' <<<"$out" ||
  fail '22d: an unreadable store was not reported UNKNOWN'
[ -z "$(ct_deleted)" ] || fail '22d: an image was removed from a store that could not be measured'
# ...or succeeds and says nothing this sweep can read.
ct_reset
printf '{}\n' > "${ct_state}/df.json"
out=$(run_container apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "22d: a store usage answer with no figures exited ${rc}, not 2"
[ -z "$(ct_deleted)" ] || fail '22d: an image was removed on a usage answer with no figures'

# 22e. an image list that cannot be read is UNKNOWN, and nothing is removed.
ct_reset
: > "${ct_state}/fail-images"
out=$(run_container apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "22e: an unreadable image list exited ${rc}, not 2 (UNKNOWN)"
grep -qF 'UNKNOWN: CONTAINER_IMAGES image list could not be read' <<<"$out" ||
  fail '22e: an unreadable image list was not reported UNKNOWN'
[ -z "$(ct_deleted)" ] || fail '22e: an image was removed without a readable image list'

# 22f. when the containers cannot be listed, no image can be shown unused, so all are kept.
# The first listing succeeds, so the UNKNOWN below comes from the per-image check alone and
# not from the long-running report, which reads the same list earlier.
ct_reset
printf '1\n' > "${ct_state}/fail-list-after"
out=$(run_container apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "22f: an unreadable container list exited ${rc}, not 2 (UNKNOWN)"
[ -z "$(ct_deleted)" ] || fail '22f: an image was removed without knowing which are in use'
grep -qF 'KEEP  (use unknown)   container image registry.test/old-unused:1' <<<"$out" ||
  fail '22f: an image whose use could not be told was not kept for that reason'
grep -qF 'long-running containers not reported' <<<"$out" &&
  fail '22f: the fixture failed the first listing, so this case proves nothing about the per-image check'
grep -qE 'UNKNOWN: CONTAINER_IMAGES [0-9]+ image\(s\) could not be classified' <<<"$out" ||
  fail '22f: images of unknown use were not reported UNKNOWN'

# 22g. a container that does not say which image it was created from makes every image's
# use unknown: it is not a container created from nothing.
ct_reset
printf '[{"configuration":{"id":"shapeless"},"status":{"state":"stopped"}}]\n' \
  > "${ct_state}/containers.json"
out=$(run_container apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "22g: an unrecognised container shape exited ${rc}, not 2 (UNKNOWN)"
[ -z "$(ct_deleted)" ] || fail '22g: an image was removed although a container did not name its image'

# 22h. an empty image list in a store that measured over budget contradicts the measurement.
ct_reset
printf '[]\n' > "${ct_state}/images.json"
out=$(run_container apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "22h: an empty image list in an over-budget store exited ${rc}, not 2"
grep -qF 'lists nothing in a store of 5120 MB' <<<"$out" ||
  fail '22h: the disagreement between the two reads was not reported'

# 22i. images that cannot be classified are kept and reported; the removable one still goes.
ct_reset
printf '[%s,%s,%s,%s,%s,%s,%s,%s]\n' \
  "$(ct_image registry.test/old-unused:1 sha256:d1 "sha256:$(ct_hex 1)")" \
  "$(ct_image --all sha256:d6 "sha256:$(ct_hex 6)")" \
  "$(ct_image 'registry.test/has space:1' sha256:d6 "sha256:$(ct_hex 6)")" \
  "$(ct_image 'registry.test/semi;colon:1' sha256:d6 "sha256:$(ct_hex 6)")" \
  "$(ct_image registry.test/odd-variant:1 sha256:d8 'sha256:../../escape')" \
  "$(ct_image registry.test/short-variant:1 sha256:d8 sha256:abcdef)" \
  "$(ct_image registry.test/non-hex-variant:1 sha256:d8 sha256:gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg)" \
  "$(ct_image registry.test/no-digest:1 '' "sha256:$(ct_hex 1)")" \
  > "${ct_state}/images.json"
out=$(run_container apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "22i: unclassifiable images exited ${rc}, not 2 (UNKNOWN)"
[ "$(ct_deleted)" = 'registry.test/old-unused:1' ] ||
  fail "22i: expected only the classifiable image to be removed, got: $(ct_deleted | tr '\n' ' ')"
[ "$(grep -cF 'KEEP  (unreadable name) container image' <<<"$out")" -eq 3 ] ||
  fail '22i: a name that is not a plain image reference was not kept'
grep -qF 'KEEP  (age unknown)   container image registry.test/odd-variant:1' <<<"$out" ||
  fail '22i: an image whose variant is not a plain digest was not kept'
grep -qF 'KEEP  (age unknown)   container image registry.test/short-variant:1' <<<"$out" ||
  fail '22i: an image whose variant digest has the wrong length was not kept'
grep -qF 'KEEP  (age unknown)   container image registry.test/non-hex-variant:1' <<<"$out" ||
  fail '22i: an image whose variant digest is not hexadecimal was not kept'
grep -qF 'KEEP  (use unknown)   container image registry.test/no-digest:1' <<<"$out" ||
  fail '22i: an image that carries no digest of its own was not kept'
grep -qF 'UNKNOWN: CONTAINER_IMAGES 7 image(s) could not be classified' <<<"$out" ||
  fail '22i: unclassifiable images were not reported UNKNOWN'

# 22j. a store whose unpacked images cannot be found is UNKNOWN, not "nothing old enough".
ct_reset
out=$(CT_STORE="${ct_root}/no-such-store" run_container apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 2 ] || fail "22j: a store with no unpacked images directory exited ${rc}, not 2"
[ -z "$(ct_deleted)" ] || fail '22j: an image was removed from a store that could not be found'

# 22k. a host without the runtime, and a disabled step, are quiet and clean.
ct_reset
out=$(CT_CLI="${ct_root}/bin/absent" run_container apply 3 "$NEVER_CLEAN_BUDGET")
rc=$?
[ "$rc" -eq 0 ] || fail "22k: a host without a container runtime exited ${rc}"
grep -qF 'CONTAINER_IMAGES no container runtime on this host' <<<"$out" ||
  fail '22k: a missing runtime was not reported as nothing to do'
out=$(CT_CLI=off run_container apply 3 "$NEVER_CLEAN_BUDGET")
grep -qF 'CONTAINER_IMAGES disabled' <<<"$out" || fail '22k: the off switch was not honoured'
[ ! -e "${ct_state}/calls" ] || fail '22k: a disabled or absent runtime was still called'
rm -rf -- "$ct_root"

if [ "$failures" -eq 0 ]; then
  printf 'build-cache-reclaim contract: all assertions passed\n'
  exit 0
fi
printf 'build-cache-reclaim contract: %d assertion(s) failed\n' "$failures" >&2
exit 1
