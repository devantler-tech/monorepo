#!/usr/bin/env bash
# Run every case of a fixture suite in at most four separate Bash processes (#4394).
# The suite supplies a complete registry and writes one receipt after each case.
# A child exit status alone cannot establish complete, non-overlapping coverage.
set -euo pipefail
unknown() { echo "test-partitions: UNKNOWN — $*" >&2; exit 2; }
suite='' jobs=4
while [ "$#" -gt 0 ]; do
  case "$1" in
    --suite) [ "$#" -ge 2 ] || unknown 'missing suite'; suite=$2; shift 2 ;;
    --jobs) [ "$#" -ge 2 ] || unknown 'missing jobs'; jobs=$2; shift 2 ;;
    *) unknown "unexpected argument: $1" ;;
  esac
done
case "$jobs" in 1|2|3|4) ;; *) unknown 'jobs must be 1..4' ;; esac
[ -f "$suite" ] && [ -r "$suite" ] || unknown 'suite is not a readable file'
tmp="$(mktemp -d)" || unknown 'cannot allocate scratch'
partition_finished=0 partition_interrupted=0 child_failed=0 pids=''
join_children() {
  local pid rc
  for pid in $pids; do
    # A trapped signal can interrupt wait while the child is still running.
    # Reap it before deleting scratch; never signal a possibly recycled PID.
    while :; do
      rc=0; wait "$pid" || rc=$?
      [ "$rc" -eq 0 ] || child_failed=1
      if ! kill -0 "$pid" 2>/dev/null || [ "$rc" -eq 127 ]; then break; fi
    done
  done
}
cleanup() {
  local rc=$?
  join_children
  rm -rf "$tmp"
  if [ "$partition_finished" != 1 ] || [ "$partition_interrupted" != 0 ]; then rc=2; fi
  exit "$rc"
}
trap cleanup EXIT
# Defer exit until the just-launched child's PID is recorded and all children join.
trap 'partition_interrupted=1' HUP INT TERM
before="$(cksum <"$suite")" || unknown 'cannot bind suite source'
"$BASH" "$suite" --list-cases >"$tmp/all" || unknown 'suite registry failed'
[ -s "$tmp/all" ] || unknown 'empty case registry'
if grep -Ev '^t_[a-zA-Z0-9_]+$' "$tmp/all" >/dev/null; then unknown 'invalid case identifier'; fi
LC_ALL=C sort "$tmp/all" >"$tmp/sorted"
[ -z "$(uniq -d "$tmp/sorted")" ] || unknown 'duplicate case registry'
count=$(wc -l <"$tmp/all" | tr -d ' ')
[ "$count" -gt 0 ] || unknown 'empty case registry'
[ "$jobs" -le "$count" ] || jobs=$count
index=1
while [ "$index" -le "$jobs" ]; do
  [ "$partition_interrupted" = 0 ] || unknown 'interrupted before launch'
  awk -v part="$index" -v jobs="$jobs" '(NR - 1) % jobs + 1 == part' "$tmp/all" >"$tmp/expected-$index"
  "$BASH" "$suite" --run-cases "$tmp/expected-$index" "$tmp/actual-$index" >"$tmp/log-$index" 2>&1 &
  pids="$pids $!"
  index=$((index + 1))
done
join_children
pids=''
[ "$partition_interrupted" = 0 ] || unknown 'interrupted while running'
[ "$(cksum <"$suite")" = "$before" ] || unknown 'suite source changed while running'
: >"$tmp/completed"
index=1
while [ "$index" -le "$jobs" ]; do
  cat "$tmp/log-$index"
  if [ ! -f "$tmp/actual-$index" ] || ! cmp -s "$tmp/expected-$index" "$tmp/actual-$index"; then
    unknown "partition $index completion receipt differs from its assignment"
  fi
  cat "$tmp/actual-$index" >>"$tmp/completed"
  index=$((index + 1))
done
LC_ALL=C sort "$tmp/completed" >"$tmp/completed-sorted"
cmp -s "$tmp/sorted" "$tmp/completed-sorted" || unknown 'whole-suite coverage differs from the registry'
if [ "$child_failed" != 0 ]; then
  echo "TEST-PARTITIONS FAILED cases=$count jobs=$jobs" >&2
  partition_finished=1
  exit 1
fi
echo "TEST-PARTITIONS COMPLETE cases=$count completed=$count jobs=$jobs bash=$BASH_VERSION"
partition_finished=1
