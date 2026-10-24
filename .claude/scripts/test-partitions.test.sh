#!/usr/bin/env bash
# Exercise the real bounded partition driver with tiny suites, including dishonest
# completion receipts. No production cleanup scenario is replaced by these controls.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
driver="$here/test-partitions.sh"
tmp="$(mktemp -d)"
partition_test_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$partition_test_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo 'test-partitions.test: aborted before finishing' >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
fail() { echo "test-partitions test: $*" >&2; exit 1; }
[ -r "$driver" ] || fail 'partition driver is missing'
cat >"$tmp/suite" <<'SUITE'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  --list-cases)
    case "${FAULT:-}" in
      empty) exit 0 ;;
      duplicate-list) printf 't_a\nt_a\n'; exit 0 ;;
      bad-list) printf 't_a;exit\n'; exit 0 ;;
      list-failure) exit 1 ;;
    esac
    printf 't_a\nt_b\nt_c\nt_d\nt_MixedCase\n'; exit 0 ;;
  --run-cases) manifest=$2 receipt=$3 ;;
  *) exit 2 ;;
esac
: >"$receipt"
failed=0
while IFS= read -r name; do
  printf 'start %s\n' "$name" >>"$STATE/activity"
  : >"$STATE/active.$name"
  : >"$STATE/started.$name"
  if [ "${BARRIER:-0}" = 1 ] && [ "$name" != t_MixedCase ]; then
    tries=0
    until [ -f "$STATE/started.t_a" ] && [ -f "$STATE/started.t_b" ] &&
      [ -f "$STATE/started.t_c" ] && [ -f "$STATE/started.t_d" ]; do
      tries=$((tries + 1)); [ "$tries" -lt 200 ] || exit 1
      sleep 0.01
    done
  fi
  sleep "${DELAY:-0.01}"
  rm -f "$STATE/active.$name"
  printf 'done %s\n' "$name" >>"$STATE/activity"
  if [ "$name" = t_a ]; then
    case "${FAULT:-}" in
      child-failure) exit 1 ;;
      completed-failure) failed=1 ;;
      silent-exit) exit 0 ;;
      missing-receipt) rm "$receipt"; exit 0 ;;
      wrong-receipt) printf 't_wrong\n' >>"$receipt" ;;
      duplicate-receipt) printf '%s\n' "$name" >>"$receipt" ;;
      source-changed) printf '\n# changed while running\n' >>"$0" ;;
    esac
  fi
  printf 'CASE %s\n' "$name"
  printf '%s\n' "$name" >>"$receipt"
done <"$manifest"
exit "$failed"
SUITE
run() {
  rm -rf "$tmp/state"
  mkdir -p "$tmp/state/temp"
  cp "$tmp/suite" "$tmp/running-suite"
  rc=0
  STATE="$tmp/state" TMPDIR="$tmp/state/temp" bash "$driver" --suite "$tmp/running-suite" "$@" \
    >"$tmp/out" 2>"$tmp/err" || rc=$?
}
run --jobs 1
if [ "$rc" -ne 0 ] || [ "$(grep -c '^CASE ' "$tmp/out")" -ne 5 ]; then
  cat "$tmp/err" >&2
  fail 'serial control lost cases'
fi
grep -q 'cases=5 completed=5 jobs=1' "$tmp/out" || fail 'serial coverage receipt missing'
BARRIER=1 run --jobs 4
[ "$rc" -eq 0 ] || { cat "$tmp/err" >&2; fail 'parallel positive control failed'; }
grep -q 'cases=5 completed=5 jobs=4' "$tmp/out" || fail 'parallel coverage receipt missing'
awk '$1=="start" { if (++n > max) max=n } $1=="done" { n-- }
  END { exit !(max==4 && n==0) }' "$tmp/state/activity" || fail 'actual concurrency was not four'
[ -z "$(find "$tmp/state" -name 'active.*')" ] || fail 'returned with a live writer'
for fault in empty duplicate-list bad-list list-failure child-failure completed-failure silent-exit missing-receipt wrong-receipt duplicate-receipt source-changed; do
  FAULT="$fault" run --jobs 4
  [ "$rc" -ne 0 ] || fail "$fault passed"
  if [ "$fault" = completed-failure ]; then
    [ "$rc" -eq 1 ] || fail 'a completely executed failed suite lost its finding status'
  fi
  grep -q 'TEST-PARTITIONS COMPLETE' "$tmp/out" && fail "$fault published complete coverage"
  [ -z "$(find "$tmp/state" -name 'active.*')" ] || fail "$fault did not join its writers"
  [ -z "$(find "$tmp/state/temp" -mindepth 1 -maxdepth 1)" ] || fail "$fault leaked driver scratch"
done
for jobs in 0 5 -1 nope; do
  run --jobs "$jobs"
  [ "$rc" -eq 2 ] || fail "invalid jobs=$jobs was not UNKNOWN"
  [ ! -e "$tmp/state/activity" ] || fail 'invalid worker bound executed the suite'
done

# Interrupt the parent after four writers start. Cleanup must wait for all four.
rm -rf "$tmp/state"; mkdir -p "$tmp/state/temp"
STATE="$tmp/state" DELAY=0.2 TMPDIR="$tmp/state/temp" \
  bash "$driver" --suite "$tmp/suite" >"$tmp/out" 2>"$tmp/err" &
parent=$!
tries=0
until [ -f "$tmp/state/started.t_a" ] && [ -f "$tmp/state/started.t_d" ]; do
  tries=$((tries + 1))
  if [ "$tries" -gt 200 ]; then kill -TERM "$parent"; wait "$parent" || true; fail 'interrupt fixture did not start'; fi
  sleep 0.01
done
kill -TERM "$parent"
rc=0; wait "$parent" || rc=$?
[ "$rc" -eq 2 ] || fail 'interrupted driver was not UNKNOWN'
[ -z "$(find "$tmp/state" -name 'active.*')" ] || fail 'interrupted driver left a writer'
[ -z "$(find "$tmp/state/temp" -mindepth 1 -maxdepth 1)" ] || fail 'interrupted driver leaked scratch'

# The actual safety suite must enumerate every declared case before any fixture
# runs; omitted, repeated and invented registry entries all fail closed.
safety="$here/worktree-cleanup.test.sh"
bash "$safety" --list-cases >"$tmp/native-cases" || fail 'native registry failed'
grep -qx 't_keeps_untracked_when_showUntrackedFiles_is_no' "$tmp/native-cases" || fail 'mixed-case native case was lost'
# The first member of a large registry must not be rejected by a producer's
# SIGPIPE when grep finishes early. Exercise the actual worker and real fixture.
printf 't_reaps_spent\n' >"$tmp/one-case"
rc=0
"$BASH" "$safety" --run-cases "$tmp/one-case" "$tmp/one-receipt" >"$tmp/out" 2>"$tmp/err" || rc=$?
if [ "$rc" -ne 0 ] || ! cmp -s "$tmp/one-case" "$tmp/one-receipt"; then
  cat "$tmp/err" >&2
  fail 'a real assigned case was rejected or not completed'
fi
for fault in missing duplicate unknown; do
  awk -v fault="$fault" '
    /^t_reaps_spent$/ && fault == "missing" { next }
    { print }
    /^t_reaps_spent$/ && fault == "duplicate" { print }
    /^t_reaps_spent$/ && fault == "unknown" { print "t_not_declared_anywhere" }
  ' "$safety" >"$tmp/altered-suite"
  rc=0
  bash "$tmp/altered-suite" --list-cases >"$tmp/out" 2>"$tmp/err" || rc=$?
  if [ "$rc" -ne 2 ] || ! grep -q 'registry differs from declared' "$tmp/err"; then
    fail "$fault native registry did not fail for completeness"
  fi
done

# The orchestrator is an independent four-minute serial tail on macOS. Its
# actual entrypoint must enumerate all groups without executing the fixtures.
orchestrator="$here/worktree-cleanup-all.test.sh"
"$BASH" "$orchestrator" --list-cases >"$tmp/orchestrator-cases" || fail 'orchestrator registry failed'
if [ "$(wc -l <"$tmp/orchestrator-cases" | tr -d ' ')" -ne 42 ] ||
  grep -Ev '^t_[a-zA-Z0-9_]+$' "$tmp/orchestrator-cases" >/dev/null; then
  fail 'orchestrator registry executed fixtures or lost case groups'
fi
for fault in missing-variant duplicate-variant unknown-variant; do
  awk -v fault="$fault" '
    /^t_excluded_nested_submodule_retains_parent missing$/ {
      if (fault == "missing-variant") next
      if (fault == "duplicate-variant") print
      if (fault == "unknown-variant") { print "t_excluded_nested_submodule_retains_parent unknown-variant"; next }
    }
    { print }
  ' "$orchestrator" >"$tmp/altered-orchestrator"
  rc=0
  "$BASH" "$tmp/altered-orchestrator" --list-cases >"$tmp/out" 2>"$tmp/err" || rc=$?
  if [ "$rc" -ne 2 ] || ! grep -q 'case invocation registry' "$tmp/err"; then
    fail "$fault orchestrator registry did not fail for complete parameter coverage"
  fi
done
printf 't_rejects_a_bad_lane_or_extra_argument\n' >"$tmp/orchestrator-one"
rc=0
"$BASH" "$orchestrator" --run-cases "$tmp/orchestrator-one" "$tmp/orchestrator-receipt" \
  >"$tmp/out" 2>"$tmp/err" || rc=$?
if [ "$rc" -ne 0 ] || ! cmp -s "$tmp/orchestrator-one" "$tmp/orchestrator-receipt"; then
  cat "$tmp/err" >&2
  fail 'actual orchestrator assignment was rejected or incomplete'
fi

partition_test_finished=1
echo 'test-partitions: OK'
