#!/usr/bin/env bash
# Report whether the volume holding this checkout has room for a run's heavy work.
#
# Why this exists (#3676): on 2026-09-29 the agent host's disk reached 99% and new sessions
# could not start, because nothing looked at free space before a run began building, testing
# or starting clusters. A nearly full disk was only found when something failed. Every run
# now checks here first, and does no heavy work while this is not a clean 0.
#
# Usage: disk-preflight.sh [min_free_gb] [path]
#   min_free_gb  whole GB (GiB) that must be free; default $DISK_PREFLIGHT_MIN_FREE_GB, else 20
#   path         a directory on the volume to measure; default the checkout holding this script
#
# Exit codes: 0 enough space · 1 below the threshold · 2 UNKNOWN (usage error, or the free
# space could not be measured). 2 is never "enough": a failed or unparseable read is not a
# disk with room on it.
set -euo pipefail

prog=disk-preflight
disk_preflight_finished=0
# A guard that exits 0 without having run is worse than one that errors. Bash 3.2 reports $?
# as 0 to an EXIT trap after a `set -u` abort, so completion is recorded explicitly: reaching
# the end is the only way a verdict leaves this script (the ci-job-wiring.sh pattern). Any
# other exit is UNKNOWN, including an errexit abort whose own status is 1, which would
# otherwise read as a LOW verdict nobody measured.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
on_exit() {
  local rc=$?
  if [ "$disk_preflight_finished" != 1 ] && [ "$rc" -ne 2 ]; then
    printf '%s: aborted before finishing — UNKNOWN\n' "$prog" >&2
    rc=2
  fi
  exit "$rc"
}
trap on_exit EXIT

unknown() { printf '%s: UNKNOWN — %s\n' "$prog" "$1" >&2; exit 2; }

[ "$#" -le 2 ] || unknown "usage: disk-preflight.sh [min_free_gb] [path]"
threshold=${1:-${DISK_PREFLIGHT_MIN_FREE_GB:-20}}
case "$threshold" in
  '' | *[!0-9]*) unknown "min_free_gb must be a whole number of GB, got '$threshold'" ;;
esac
# Bound the digits before any arithmetic, and read them as decimal: `08` is otherwise an
# octal parse error, and a value past int64 wraps silently (build-cache-reclaim.sh).
[ "${#threshold}" -le 7 ] || unknown "min_free_gb is too large (max 7 digits)"
threshold=$((10#$threshold))

if [ "$#" -ge 2 ]; then
  target=$2
else
  script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) \
    || unknown "cannot resolve the script directory"
  target="$script_dir/../.."
fi
[ -d "$target" ] || unknown "not a directory: $target"
target=$(CDPATH='' cd -- "$target" && pwd -P) || unknown "cannot resolve $target"

# POSIX output (-P) in 1024-byte blocks (-k): one header line, then one data line whose
# numeric run is total, used, available and capacity%, followed by the mount point. It is
# matched as that run rather than by field number, so a filesystem name holding spaces
# cannot shift the columns. A line with more than one such run (a filesystem or mount name
# that itself looks like the columns) cannot be attributed, so it is UNKNOWN, never a guess.
if ! out=$(LC_ALL=C df -Pk -- "$target" 2>&1); then
  unknown "df failed for $target: $(printf '%s' "$out" | head -n 1)"
fi
lines=$(printf '%s\n' "$out" | grep -c .) || lines=0
[ "$lines" -eq 2 ] || unknown "unexpected df output ($lines lines) for $target"
data=$(printf '%s\n' "$out" | sed -n '2p')
numeric='[[:space:]]([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)%[[:space:]]+/'
runs=$(printf '%s\n' "$data" | grep -oE "$numeric" | grep -c .) || runs=0
[ "$runs" -le 1 ] || unknown "ambiguous df output for $target ($runs column runs): $data"
[[ "$data" =~ $numeric ]] || unknown "cannot parse df output for $target: $data"
avail_kb=${BASH_REMATCH[3]}
# Same digit bound as the threshold: a wrapped value must not read as plenty of room.
[ "${#avail_kb}" -le 15 ] || unknown "implausible free space reported for $target"
avail_kb=$((10#$avail_kb))

kb_per_gb=1048576
free_gb=$((avail_kb / kb_per_gb))
if [ "$avail_kb" -ge $((threshold * kb_per_gb)) ]; then
  verdict=OK rc=0
else
  verdict=LOW rc=1
fi
printf '%s: %s — %s GB free on the volume holding %s (threshold %s GB)\n' \
  "$prog" "$verdict" "$free_gb" "$target" "$threshold"
disk_preflight_finished=1
exit "$rc"
