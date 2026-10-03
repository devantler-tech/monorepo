#!/usr/bin/env bash
# Start a run's detached lane worktree sweep, and report how the previous one ended.
#
# Why this exists (#3714): every run starts its lane's sweep (worktree-cleanup-all.sh apply) in
# the background at pre-flight and never waits on it (#3681). Its exit status went only to a log
# nothing reads, so a sweep that aborted on every run — an unreadable process listing,
# repository metadata or manifest — looked exactly like one that worked, and worktrees piled up
# unnoticed until the disk threshold stopped heavy work.
#
# The sweep now runs under a small supervisor that records how it ended, next to its log, and
# every start first reports the record the previous sweep left:
#
#   ~/.claude/worktree-cleanup-manifests/cleanup-<lane>.log       the sweep's output, appended
#   ~/.claude/worktree-cleanup-manifests/cleanup-<lane>.started   id, supervisor pid, start time
#   ~/.claude/worktree-cleanup-manifests/cleanup-<lane>.finished  id, exit code, end time
#
# The launcher writes .started and the supervisor writes .finished, so neither can overwrite the
# other's record, whichever finishes first. A sweep has finished only when both name the same id.
# A supervisor that dies before recording (killed, host restarted) leaves .started alone, and
# its pid then no longer runs this script with that id: that is a sweep that never finished.
#
# Usage: worktree-lane-sweep.sh start|status --lane claude|codex
#   start   report the previous sweep, then start a new one detached
#           (worktree-cleanup-all.sh apply 24 --lane <lane>) and return at once. While the
#           previous sweep is still running, report that and start no second one. A supervisor
#           still present after six hours is reported as stuck with a recovery command, and also
#           blocks a second sweep. An unreadable record is reported and replaced; an unreadable
#           process table is UNKNOWN and starts nothing because running versus gone is unproven.
#   status  report the previous sweep only.
#
# Exit codes: 0 the previous sweep finished cleanly · 1 it did not: it failed, never finished,
# is still running, or no sweep is on record · 2 UNKNOWN (a usage error, an unreadable or
# malformed record, an unreadable process table, or the new sweep could not be started or recorded).
# Only 0 is a clean sweep.
set -euo pipefail

prog=worktree-lane-sweep
lane_sweep_finished=0
launch_lock=""
lock_held=0
# A reporter that exits 0 without having looked is worse than one that errors. Bash 3.2 reports
# $? as 0 to an EXIT trap after a `set -u` abort, so completion is recorded explicitly: reaching
# a deliberate exit is the only way a verdict leaves this script (the ci-job-wiring.sh pattern).
# shellcheck disable=SC2329  # invoked by the EXIT trap below
on_exit() {
  local rc=$?
  if [ "$lock_held" = 1 ]; then
    if ! rmdir -- "$launch_lock" 2>/dev/null; then
      printf '%s: UNKNOWN — cannot release launcher lock %s\n' "$prog" "$launch_lock" >&2
      rc=2
    fi
    lock_held=0
  fi
  if [ "$lane_sweep_finished" != 1 ] && [ "$rc" -ne 2 ]; then
    printf '%s: aborted before finishing — UNKNOWN\n' "$prog" >&2
    rc=2
  fi
  exit "$rc"
}
trap on_exit EXIT

unknown() { printf '%s: UNKNOWN — %s\n' "$prog" "$1" >&2; exit 2; }
finish() { lane_sweep_finished=1; exit "$1"; }
usage() { unknown "usage: worktree-lane-sweep.sh start|status --lane claude|codex"; }

[ "$#" -ge 1 ] || usage
cmd=$1; shift
lane=""; id=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane) [ "$#" -ge 2 ] || usage; lane=$2; shift 2 ;;
    --id) [ "$cmd" = __supervise ] && [ "$#" -ge 2 ] || usage; id=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$cmd" in start|status|__supervise) ;; *) usage ;; esac
# No default lane: a run sweeps only its own lane's worktrees and must say which that is.
case "$lane" in
  claude|codex) ;;
  *) unknown "--lane must be claude or codex, got '$lane'" ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) \
  || unknown "cannot resolve the script directory"
self="$script_dir/worktree-lane-sweep.sh"
self_name=${self##*/}
sweeper="$script_dir/worktree-cleanup-all.sh"
dir="$HOME/.claude/worktree-cleanup-manifests"
log="$dir/cleanup-$lane.log"
started="$dir/cleanup-$lane.started"
finished="$dir/cleanup-$lane.finished"
launch_lock="$dir/cleanup-$lane.launch.lock"
stuck_after_seconds=21600

id_re='[0-9]{8}T[0-9]{6}Z-[0-9]+'
at_re='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
started_re="^id=($id_re) pid=([0-9]+) at=($at_re)$"
finished_re="^id=($id_re) rc=([0-9]+) at=($at_re)$"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# write_record <file> <line> — replace the record atomically, so a reader never sees half of one.
# A directory in the record's place would swallow the file (`mv` moves into it), so it fails.
write_record() {
  local tmp="$1.tmp.$$"
  [ ! -d "$1" ] || return 1
  printf '%s\n' "$2" >"$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# elapsed_seconds <etime> — parse ps' portable [[dd-]hh:]mm:ss elapsed form.
SUPERVISOR_AGE_SECONDS=""
elapsed_seconds() {
  local value=$1 days=0 hours=0 minutes=0 seconds=0 first second third
  case "$value" in
    *-*) days=${value%%-*}; value=${value#*-} ;;
  esac
  IFS=: read -r first second third <<<"$value"
  if [ -n "${third:-}" ]; then
    hours=$first; minutes=$second; seconds=$third
  else
    minutes=$first; seconds=$second
  fi
  case "$days:$hours:$minutes:$seconds" in
    *[!0-9:]*) return 1 ;;
  esac
  SUPERVISOR_AGE_SECONDS=$((days * 86400 + hours * 3600 + minutes * 60 + seconds))
}

# supervisor_runs <pid> <id> — 0 when <pid> is this script supervising sweep <id>, 1 when the
# process is absent or different, and 2 when one unfiltered process-table read cannot prove either.
# Matching the command line, not just the pid, keeps a recycled pid from reading as running. The
# same listing must contain this reporter with readable arguments, so a filtered or partial read
# never becomes a "gone" verdict.
supervisor_runs() {
  local process_table listed_pid elapsed command self_seen=0 target_seen=0 target_elapsed=""
  process_table=$(ps -A -ww -o pid= -o etime= -o command= 2>/dev/null) || return 2
  [ -n "$process_table" ] || return 2
  while read -r listed_pid elapsed command; do
    [ -n "${listed_pid:-}" ] || continue
    if [ "$listed_pid" = "$$" ]; then
      case "$command" in *"$self_name"*) self_seen=1 ;; esac
    fi
    if [ "$listed_pid" = "$1" ]; then
      case "$command" in
        *"$self __supervise --lane $lane --id $2")
          target_seen=1; target_elapsed=$elapsed
          ;;
      esac
    fi
  done <<<"$process_table"
  [ "$self_seen" = 1 ] || return 2
  if [ "$target_seen" = 1 ]; then
    elapsed_seconds "$target_elapsed" || return 2
    return 0
  fi
  return 1
}

if [ "$cmd" = __supervise ]; then
  # Detached, with stdout and stderr appended to the lane's log by the launcher.
  [[ "$id" =~ ^$id_re$ ]] || unknown "--id is malformed: '$id'"
  printf '=== lane sweep %s started %s (lane %s) ===\n' "$id" "$(now)" "$lane"
  rc=0
  "$sweeper" apply 24 --lane "$lane" </dev/null || rc=$?
  printf '=== lane sweep %s finished %s: exit %s ===\n' "$id" "$(now)" "$rc"
  write_record "$finished" "id=$id rc=$rc at=$(now)" \
    || unknown "cannot record the end of sweep $id in $finished"
  finish "$rc"
fi

# report_previous — print how the last recorded sweep ended and set VERDICT: ok, or one of
# failed · unfinished · running · none (exit 1), or unknown for a record it cannot read (exit 2).
VERDICT=""
bad_record() {
  printf '%s: UNKNOWN — %s; the last %s sweep cannot be judged\n' "$prog" "$1" "$lane" >&2
  VERDICT=unknown
}
bad_process_read() {
  printf '%s: UNKNOWN — cannot read the process table completely; the last %s sweep cannot be judged\n' \
    "$prog" "$lane" >&2
  VERDICT=process-unknown
}
report_previous() {
  local s f s_id s_pid s_at f_id f_rc f_at supervisor_state finish_record_bad=0
  if [ ! -e "$started" ]; then
    printf '%s: no %s sweep on record — nothing shows the lane was ever swept\n' "$prog" "$lane"
    VERDICT=none; return 0
  fi
  s=$(cat -- "$started" 2>/dev/null) || { bad_record "cannot read $started"; return 0; }
  [[ "$s" =~ $started_re ]] || { bad_record "malformed sweep record in $started"; return 0; }
  s_id=${BASH_REMATCH[1]}; s_pid=${BASH_REMATCH[2]}; s_at=${BASH_REMATCH[3]}
  if [ -e "$finished" ]; then
    if ! f=$(cat -- "$finished" 2>/dev/null); then
      bad_record "cannot read $finished"
      finish_record_bad=1
    elif [[ ! "$f" =~ $finished_re ]]; then
      bad_record "malformed sweep record in $finished"
      finish_record_bad=1
    else
      f_id=${BASH_REMATCH[1]}; f_rc=${BASH_REMATCH[2]}; f_at=${BASH_REMATCH[3]}
      if [ "$f_id" = "$s_id" ]; then
        if [ "$f_rc" = 0 ]; then
          printf '%s: the last %s sweep (%s) finished cleanly at %s\n' "$prog" "$lane" "$s_id" "$f_at"
          VERDICT=ok
        else
          printf '%s: the last %s sweep (%s) FAILED with exit %s at %s — see the end of %s\n' \
            "$prog" "$lane" "$s_id" "$f_rc" "$f_at" "$log"
          VERDICT=failed
        fi
        return 0
      fi
    fi
  fi
  if supervisor_runs "$s_pid" "$s_id"; then supervisor_state=0
  else supervisor_state=$?; fi
  case "$supervisor_state" in
    0)
      if [ "$finish_record_bad" = 1 ]; then
        printf '%s: not replacing the unreadable %s finish record while supervisor pid %s still runs\n' \
          "$prog" "$lane" "$s_pid"
        VERDICT=record-running
      elif (( SUPERVISOR_AGE_SECONDS >= stuck_after_seconds )); then
        printf '%s: the last %s sweep (%s, pid %s) is STUCK — its supervisor has run for six hours or more since %s; inspect %s, then if it is not making progress run `kill %s` and start again\n' \
          "$prog" "$lane" "$s_id" "$s_pid" "$s_at" "$log" "$s_pid"
        VERDICT=stuck
      else
        printf '%s: the last %s sweep (%s, pid %s) has been running since %s and has not finished\n' \
          "$prog" "$lane" "$s_id" "$s_pid" "$s_at"
        VERDICT=running
      fi
      ;;
    1)
      if [ "$finish_record_bad" != 1 ]; then
        printf '%s: the last %s sweep (%s) started at %s and NEVER FINISHED — its supervisor (pid %s) is gone without recording an end; see the end of %s\n' \
          "$prog" "$lane" "$s_id" "$s_at" "$s_pid" "$log"
        VERDICT=unfinished
      fi
      ;;
    *) bad_process_read ;;
  esac
}

# Serialize a launcher's read/start/record transaction. A racing launcher either loses this
# atomic mkdir or enters after the first releases it and observes the recorded supervisor.
if [ "$cmd" = start ]; then
  mkdir -p -- "$dir" 2>/dev/null || unknown "cannot create $dir"
  if ! mkdir -- "$launch_lock" 2>/dev/null; then
    unknown "another $lane sweep launcher holds $launch_lock; retry after it finishes"
  fi
  lock_held=1
fi

report_previous
case "$VERDICT" in ok) rc=0 ;; unknown|process-unknown|record-running) rc=2 ;; *) rc=1 ;; esac
[ "$cmd" = start ] || finish "$rc"

if [ "$VERDICT" = process-unknown ]; then
  printf '%s: not starting a %s sweep while its prior supervisor state is unknown\n' "$prog" "$lane"
  finish "$rc"
fi
if [ "$VERDICT" = running ] || [ "$VERDICT" = stuck ] || [ "$VERDICT" = record-running ]; then
  printf '%s: not starting a second %s sweep while that one runs\n' "$prog" "$lane"
  finish "$rc"
fi
# An unreadable record still starts a sweep, which replaces it: refusing would leave the lane
# unswept on every run until someone repaired one file, and the disk would fill again.
[ -x "$sweeper" ] || unknown "missing $sweeper"
new_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
nohup bash "$self" __supervise --lane "$lane" --id "$new_id" >>"$log" 2>&1 </dev/null &
pid=$!
write_record "$started" "id=$new_id pid=$pid at=$(now)" \
  || unknown "started sweep $new_id (pid $pid) but cannot record it in $started"
printf '%s: started the %s sweep %s (pid %s) detached — its output appends to %s\n' \
  "$prog" "$lane" "$new_id" "$pid" "$log"
finish "$rc"
