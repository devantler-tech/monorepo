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
# A second sweep must never start beside a live one (#3823), and the records cannot promise that
# on their own: a record can be unreadable, and a sweeper outlives a supervisor that was killed
# with `kill -9`. So the records decide what is REPORTED, and the process table decides whether a
# sweep may START: none does while any supervisor or sweeper of the lane is running, whatever the
# records say. The one supervisor left out is the one whose sweep the records show finished: it
# has written its last record and is on its way out.
# A process is known by its command line, which is read the way the script it runs reads its own
# arguments, so every spelling that script accepts is the same sweep: `apply 24`, `apply 24 336
# --lane claude` and `--lane=claude apply` all sweep the claude lane. And a supervisor shows the
# launcher's command line until it has replaced it with its own, so the launcher keeps its lock
# until the supervisor has said it is running, and the supervisor sweeps only once it has said so.
#
# Usage: worktree-lane-sweep.sh start|status --lane claude|codex
#   start   report the previous sweep, then start a new one detached
#           (worktree-cleanup-all.sh apply 24 --lane <lane>) and return at once. While the
#           previous sweep is still running, report that and start no second one. A supervisor
#           still present after six hours is reported as stuck with a recovery command, and also
#           blocks a second sweep. An unreadable record is reported and replaced unless something
#           of the lane is still sweeping; an unreadable process table is UNKNOWN and starts
#           nothing because running versus gone is unproven.
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
launch_lock_owner=""
lock_held=0
# A reporter that exits 0 without having looked is worse than one that errors. Bash 3.2 reports
# $? as 0 to an EXIT trap after a `set -u` abort, so completion is recorded explicitly: reaching
# a deliberate exit is the only way a verdict leaves this script (the ci-job-wiring.sh pattern).
# shellcheck disable=SC2329  # invoked by the EXIT trap below
on_exit() {
  local rc=$? grave
  if [ "$lock_held" = 1 ]; then
    # One rename frees the lock, whatever owner records it holds: removing them one at a time
    # would show a waiting launcher the dead owner this one took over from, still on record.
    grave="$launch_lock.released.$$"
    rm -rf -- "$grave" 2>/dev/null || true
    if mv -- "$launch_lock" "$grave" 2>/dev/null; then
      rm -rf -- "$grave" 2>/dev/null || true
    else
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
sweeper_name=${sweeper##*/}
# The per-repository cleanup the sweeper runs for each repository of the lane.
cleanup_name=worktree-cleanup.sh
dir="$HOME/.claude/worktree-cleanup-manifests"
log="$dir/cleanup-$lane.log"
started="$dir/cleanup-$lane.started"
finished="$dir/cleanup-$lane.finished"
launch_lock="$dir/cleanup-$lane.launch.lock"
launch_lock_owner="$launch_lock/owner"
stuck_after_seconds=21600
stale_lock_after_seconds=300

id_re='[0-9]{8}T[0-9]{6}Z-[0-9]+'
at_re='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
started_re="^id=($id_re) pid=([0-9]+) at=($at_re)$"
finished_re="^id=($id_re) rc=([0-9]+) at=($at_re)$"
lock_owner_re="^pid=([0-9]+) at=($at_re)$"

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

# record_is_safe <path> — only a small, ordinary file can be read as runtime state. A FIFO,
# device, symlink or unbounded file must not hold a pre-flight open while its launcher lock is held.
record_is_safe() {
  local bytes
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  bytes=$(wc -c <"$1" 2>/dev/null) || return 1
  [ "$bytes" -le 512 ]
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
  SUPERVISOR_AGE_SECONDS=$((10#$days * 86400 + 10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))
}

# supervisor_runs <pid> <id> — 0 when <pid> is this script supervising sweep <id>, 1 when the
# process is absent or different, and 2 when one unfiltered process-table read cannot prove either.
# Matching the command line, not just the pid, keeps a recycled pid from reading as running. The
# launcher is matched by its file name, not by this copy's path: every run starts it from its own
# checkout, so the run that asks is rarely the one that started the sweep. The
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
        *"/$self_name __supervise --lane $lane --id $2")
          target_seen=1; target_elapsed=$elapsed
          ;;
        # A supervisor that has only just been started still shows the command line of the launcher
        # it was forked from. It is about to be the supervisor, so it is running, not gone.
        *"/$self_name start --lane $lane")
          [ "$listed_pid" = "$$" ] || { target_seen=1; target_elapsed=$elapsed; }
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

# launcher_runs <pid> — the same complete process-table proof for a lock owner. A recycled pid is
# not a launcher, and an incomplete listing never permits recovery.
launcher_runs() {
  local process_table listed_pid elapsed command self_seen=0 target_seen=0
  process_table=$(ps -A -ww -o pid= -o etime= -o command= 2>/dev/null) || return 2
  [ -n "$process_table" ] || return 2
  while read -r listed_pid elapsed command; do
    [ -n "${listed_pid:-}" ] || continue
    if [ "$listed_pid" = "$$" ]; then
      case "$command" in *"$self_name"*) self_seen=1 ;; esac
    fi
    if [ "$listed_pid" = "$1" ]; then
      case "$command" in *"$self_name start --lane $lane"*) target_seen=1 ;; esac
    fi
  done <<<"$process_table"
  [ "$self_seen" = 1 ] || return 2
  [ "$target_seen" = 1 ] && return 0
  return 1
}

# sweep_command <command line> — what a process is to a lane's sweep. The command line is read the
# way the script it names reads its own arguments, so every spelling that script accepts counts
# (#3823): matching the one spelling this launcher uses let `apply 24` (the claude lane, by
# default) or `--lane=claude apply` run beside a sweep it had started. Sets CMD_KIND to
#   supervisor  this script supervising a sweep; CMD_LANE and CMD_ID are what it was given
#   sweeper     worktree-cleanup-all.sh removing worktrees; CMD_LANE is the lane it resolves to
#   cleanup     worktree-cleanup.sh removing one repository's worktrees, as a sweeper runs it
# or to nothing: any other process, a dry run, and the launcher's own `start` and `status`.
CMD_KIND=""; CMD_LANE=""; CMD_ID=""
sweep_command() {
  local -a words
  local i=0 n word script="" positional=0 mode=""
  CMD_KIND=""; CMD_LANE=""; CMD_ID=""
  read -r -a words <<<"$1" || return 0
  n=${#words[@]}
  while [ "$i" -lt "$n" ] && [ -z "$script" ]; do
    word=${words[$i]}; i=$((i + 1))
    case "$word" in
      "$self_name"|*/"$self_name") script=launcher ;;
      "$sweeper_name"|*/"$sweeper_name") script=sweeper ;;
      "$cleanup_name"|*/"$cleanup_name") script=cleanup ;;
    esac
  done
  case "$script" in
    launcher)
      if [ "$i" -ge "$n" ] || [ "${words[$i]}" != __supervise ]; then return 0; fi
      i=$((i + 1))
      while [ "$i" -lt "$n" ]; do
        word=${words[$i]}; i=$((i + 1))
        [ "$i" -lt "$n" ] || break
        case "$word" in
          --lane) CMD_LANE=${words[$i]}; i=$((i + 1)) ;;
          --id) CMD_ID=${words[$i]}; i=$((i + 1)) ;;
        esac
      done
      CMD_KIND=supervisor
      ;;
    sweeper)
      # --lane may stand anywhere, in either form, and is claude when absent. The first other
      # argument is the mode, a dry run when absent, and only `apply` removes anything.
      CMD_LANE=claude
      while [ "$i" -lt "$n" ]; do
        word=${words[$i]}; i=$((i + 1))
        case "$word" in
          --lane)
            if [ "$i" -lt "$n" ]; then CMD_LANE=${words[$i]}; i=$((i + 1)); else CMD_LANE=""; fi
            ;;
          --lane=*) CMD_LANE=${word#--lane=} ;;
          *) positional=$((positional + 1)); [ "$positional" -ne 1 ] || mode=$word ;;
        esac
      done
      [ "$mode" != apply ] || CMD_KIND=sweeper
      ;;
    cleanup)
      while [ "$i" -lt "$n" ]; do
        [ "${words[$i]}" != apply ] || CMD_KIND=cleanup
        i=$((i + 1))
      done
      ;;
  esac
  return 0
}

# other_lane <lane> — succeeds when it names the lane this launcher was not asked about. A lane that
# cannot be read from a command line is not known to be the other one, so its process counts.
other_lane() {
  case "$1" in
    claude|codex) [ "$1" != "$lane" ] ;;
    *) return 1 ;;
  esac
}

# lane_processes <finished-id> — the same complete process-table proof for everything that may
# still be sweeping this lane, asked before any sweep starts. Sets LIVE_SUPERVISORS, LIVE_SWEEPERS
# and LIVE_CLEANUPS to their pids. Processes are known by what they run, never by a pid a record
# names: a record can be unreadable or missing, and a sweeper outlives a killed supervisor. So any
# copy of these scripts counts, whichever checkout or home directory started it. A refused start
# costs one sweep; a second sweep beside a live one is what this exists to prevent.
# The supervisor of sweep <finished-id> is left out: the records show that sweep finished, so it
# has written its last record and is exiting.
# A sweeper that has only just been forked still runs the supervisor's own command line, and is
# counted as a supervisor until it is the sweeper.
# A cleanup goes on after a sweeper that was stopped alone, and its arguments name no lane. The
# manifest it writes does, by where it lies: the claude lane's in this launcher's records
# directory, another lane's in a directory of the lane's name below it. Only a cleanup writing
# there counts, so one started for another home directory, as the tests do, blocks nothing.
LIVE_SUPERVISORS=""; LIVE_SWEEPERS=""; LIVE_CLEANUPS=""
lane_processes() {
  local process_table listed_pid elapsed command self_seen=0
  LIVE_SUPERVISORS=""; LIVE_SWEEPERS=""; LIVE_CLEANUPS=""
  process_table=$(ps -A -ww -o pid= -o etime= -o command= 2>/dev/null) || return 2
  [ -n "$process_table" ] || return 2
  while read -r listed_pid elapsed command; do
    [ -n "${listed_pid:-}" ] || continue
    if [ "$listed_pid" = "$$" ]; then
      case "$command" in *"$self_name"*) self_seen=1 ;; esac
      continue
    fi
    sweep_command "$command"
    case "$CMD_KIND" in
      supervisor)
        if other_lane "$CMD_LANE"; then continue; fi
        if [ -n "$1" ] && [ "$CMD_LANE" = "$lane" ] && [ "$CMD_ID" = "$1" ]; then continue; fi
        LIVE_SUPERVISORS="$LIVE_SUPERVISORS $listed_pid"
        ;;
      sweeper)
        if other_lane "$CMD_LANE"; then continue; fi
        LIVE_SWEEPERS="$LIVE_SWEEPERS $listed_pid"
        ;;
      cleanup)
        case "$lane" in
          claude)
            case "$command" in
              *" $dir/codex/"*) continue ;;
              *" $dir/"*) ;;
              *) continue ;;
            esac
            ;;
          *)
            case "$command" in
              *" $dir/$lane/"*) ;;
              *) continue ;;
            esac
            ;;
        esac
        LIVE_CLEANUPS="$LIVE_CLEANUPS $listed_pid"
        ;;
    esac
  done <<<"$process_table"
  [ "$self_seen" = 1 ] || return 2
}

# leads_group <pid> — succeeds when <pid> leads its own process group, as a sweeper its supervisor
# started does. One signal to that group then reaches the sweeper and the cleanup it is running;
# a signal to the sweeper alone leaves that cleanup going on without it.
leads_group() {
  local group
  group=$(ps -o pgid= -p "$1" 2>/dev/null) || return 1
  group=${group//[[:space:]]/}
  [ "$group" = "$1" ]
}

lock_is_stale() {
  local modified now_epoch
  if modified=$(stat -f %m "$launch_lock" 2>/dev/null); then :
  elif modified=$(stat -c %Y "$launch_lock" 2>/dev/null); then :
  else return 2
  fi
  now_epoch=$(date +%s) || return 2
  [ $((now_epoch - modified)) -ge "$stale_lock_after_seconds" ]
}

# The launcher lock is a directory holding a chain of owner records. `owner` names the launcher
# that made the directory. A launcher that finds the last owner dead takes the lock over by adding
# the next record, and the chain's last record is the owner.
#
# Taking over used to remove the dead owner's directory and make a new one. Two launchers recovering
# the same dead lock could then each remove the other's fresh lock, and both went on (#3823): a
# removal cannot be told which lock it may remove. So recovery removes nothing. Every record is
# created by one hard link, which fails when the name exists and shows the record only once it is
# complete, and the name of a takeover record is fixed by the record it replaces. Two launchers that
# judged the same owner dead therefore ask for the same name and exactly one gets it. The directory
# goes away only when its live owner renames it aside on exit.
#
# lock_owner — follow the chain. OWNER_STATE is `none` (no record), `valid`, `malformed` (the last
# record cannot be read as one) or `unknown` (too long to follow); OWNER_PID is a valid owner's pid
# and OWNER_NEXT the one name the record after the last would carry.
OWNER_STATE=""; OWNER_FILE=""; OWNER_PID=""; OWNER_NEXT=""
lock_owner() {
  local file=$launch_lock_owner record hops=0
  OWNER_STATE=none; OWNER_FILE=""; OWNER_PID=""; OWNER_NEXT=$file
  while [ -e "$file" ] || [ -L "$file" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 64 ]; then OWNER_STATE=unknown; return 0; fi
    OWNER_FILE=$file
    if record_is_safe "$file" && record=$(cat -- "$file" 2>/dev/null) \
      && [[ "$record" =~ $lock_owner_re ]]; then
      OWNER_STATE=valid; OWNER_PID=${BASH_REMATCH[1]}
      OWNER_NEXT="$launch_lock/takeover.${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    else
      OWNER_STATE=malformed; OWNER_PID=""
      OWNER_NEXT="$file.next"
    fi
    file=$OWNER_NEXT
  done
}

acquire_launch_lock() {
  local made=0 refusal="" state target tmp="$dir/cleanup-$lane.launch.owner.tmp.$$"
  if mkdir -- "$launch_lock" 2>/dev/null; then
    made=1; target=$launch_lock_owner
  else
    lock_owner
    target=$OWNER_NEXT
    case "$OWNER_STATE" in
      valid)
        if launcher_runs "$OWNER_PID"; then state=0; else state=$?; fi
        case "$state" in
          0) unknown "another $lane sweep launcher (pid $OWNER_PID) holds $launch_lock" ;;
          1) ;;
          *) unknown "cannot read the process table completely to verify launcher pid $OWNER_PID" ;;
        esac
        ;;
      none|malformed)
        # No owner to ask the process table about, so only age shows the lock was abandoned: a
        # launcher that has just made the directory has not written its record yet.
        lock_is_stale \
          || unknown "launcher lock $launch_lock has no readable owner record and is not old enough to recover"
        ;;
      *) unknown "launcher lock $launch_lock holds more owner records than can be followed" ;;
    esac
  fi

  if ! printf 'pid=%s at=%s\n' "$$" "$(now)" >"$tmp" 2>/dev/null; then
    refusal="cannot write a launcher owner record in $dir"
  elif ! ln -- "$tmp" "$target" 2>/dev/null; then
    refusal="another $lane sweep launcher took $launch_lock first"
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  if [ -n "$refusal" ]; then
    # An empty directory this launcher made itself is nobody's lock yet.
    [ "$made" = 0 ] || rmdir -- "$launch_lock" 2>/dev/null || true
    unknown "$refusal"
  fi
  # The directory read above may have been released and made again by another launcher since. A
  # record added to a chain that is no longer there owns nothing, so read the chain once more.
  lock_owner
  if [ "$OWNER_FILE" != "$target" ] || [ "$OWNER_STATE" != valid ] || [ "$OWNER_PID" != "$$" ]; then
    unknown "another $lane sweep launcher holds $launch_lock"
  fi
  lock_held=1
}

await_start_record() {
  local attempt=0 record
  while [ "$attempt" -lt 100 ]; do
    if record_is_safe "$started"; then
      record=$(cat -- "$started" 2>/dev/null) || record=""
      if [[ "$record" =~ $started_re ]] \
        && [ "${BASH_REMATCH[1]}" = "$id" ] && [ "${BASH_REMATCH[2]}" = "$$" ]; then
        return 0
      fi
    fi
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

# A supervisor is forked from its launcher, and until it has replaced that command line with its
# own the process table shows a second launcher where the record names a supervisor. A launcher
# arriving then would read the recorded supervisor as gone and start a second sweep (#3823). So the
# supervisor says it is running, by a file in the launcher's lock, before it sweeps anything, and
# the launcher keeps the lock until it has. A supervisor that cannot say so has no launcher holding
# the lock for it, and sweeps nothing.
#
# await_supervisor <pid> <id> — 0 once the supervisor has said it is running, 1 when it ended
# without saying so, 2 when it has said nothing for ten seconds.
await_supervisor() {
  local attempt=0 said="$launch_lock/supervisor.$2"
  while [ "$attempt" -lt 200 ]; do
    [ ! -e "$said" ] || return 0
    if ! kill -0 "$1" 2>/dev/null; then
      # It may have said so, swept and ended between the two looks above.
      [ ! -e "$said" ] || return 0
      return 1
    fi
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 2
}

sweep_pid=""
# shellcheck disable=SC2329  # invoked by the signal handler below
stop_sweep_group() {
  local attempt=0
  [ -n "$sweep_pid" ] || return 0
  if kill -0 "$sweep_pid" 2>/dev/null; then
    kill -TERM -- "-$sweep_pid" 2>/dev/null || kill -TERM "$sweep_pid" 2>/dev/null || true
    while kill -0 "$sweep_pid" 2>/dev/null && [ "$attempt" -lt 50 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$sweep_pid" 2>/dev/null; then
      kill -KILL -- "-$sweep_pid" 2>/dev/null || kill -KILL "$sweep_pid" 2>/dev/null || true
    fi
  fi
  wait "$sweep_pid" 2>/dev/null || true
}

# shellcheck disable=SC2329  # invoked by the TERM/INT/HUP trap below
stop_supervised_sweep() {
  trap - TERM INT HUP
  stop_sweep_group
  printf '=== lane sweep %s stopped %s: exit 143 ===\n' "$id" "$(now)"
  write_record "$finished" "id=$id rc=143 at=$(now)" \
    || unknown "cannot record the stopped sweep $id in $finished"
  finish 143
}

if [ "$cmd" = __supervise ]; then
  # Detached, with stdout and stderr appended to the lane's log by the launcher.
  [[ "$id" =~ ^$id_re$ ]] || unknown "--id is malformed: '$id'"
  await_start_record || unknown "start record handshake for sweep $id was not completed"
  touch -- "$launch_lock/supervisor.$id" 2>/dev/null \
    || unknown "the launcher that started sweep $id no longer holds $launch_lock, so nothing was swept"
  printf '=== lane sweep %s started %s (lane %s) ===\n' "$id" "$(now)" "$lane"
  trap stop_supervised_sweep TERM INT HUP
  set -m
  "$sweeper" apply 24 --lane "$lane" </dev/null &
  sweep_pid=$!
  set +m
  if wait "$sweep_pid"; then rc=0; else rc=$?; fi
  trap - TERM INT HUP
  printf '=== lane sweep %s finished %s: exit %s ===\n' "$id" "$(now)" "$rc"
  write_record "$finished" "id=$id rc=$rc at=$(now)" \
    || unknown "cannot record the end of sweep $id in $finished"
  finish "$rc"
fi

# report_previous — print how the last recorded sweep ended and set VERDICT: ok, or one of
# failed · unfinished · running · none (exit 1), or unknown for a record it cannot read (exit 2).
VERDICT=""
FINISHED_ID=""   # the sweep the records show finished, cleanly or not
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
  record_is_safe "$started" \
    || { bad_record "non-regular or oversized sweep record in $started"; return 0; }
  s=$(cat -- "$started" 2>/dev/null) || { bad_record "cannot read $started"; return 0; }
  [[ "$s" =~ $started_re ]] || { bad_record "malformed sweep record in $started"; return 0; }
  s_id=${BASH_REMATCH[1]}; s_pid=${BASH_REMATCH[2]}; s_at=${BASH_REMATCH[3]}
  if [ -e "$finished" ]; then
    if ! record_is_safe "$finished"; then
      bad_record "non-regular or oversized sweep record in $finished"
      finish_record_bad=1
    elif ! f=$(cat -- "$finished" 2>/dev/null); then
      bad_record "cannot read $finished"
      finish_record_bad=1
    elif [[ ! "$f" =~ $finished_re ]]; then
      bad_record "malformed sweep record in $finished"
      finish_record_bad=1
    else
      f_id=${BASH_REMATCH[1]}; f_rc=${BASH_REMATCH[2]}; f_at=${BASH_REMATCH[3]}
      if [ "$f_id" = "$s_id" ]; then
        FINISHED_ID=$s_id
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
        VERDICT="record-running"
      elif (( SUPERVISOR_AGE_SECONDS >= stuck_after_seconds )); then
        # shellcheck disable=SC2016  # the backticks are literal: they mark the command to run
        printf '%s: the last %s sweep (%s, pid %s) is STUCK — its supervisor has run for six hours or more since %s; inspect %s, then if it is not making progress run `kill %s` and start again (a plain kill: the supervisor then stops its sweeper, which `kill -9` would leave running)\n' \
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
  acquire_launch_lock
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
# The verdict above is what the records say. Whether a sweep may start is asked of the process
# table, every time and whatever the verdict: the records cannot name a sweeper whose supervisor
# was killed, and an unreadable record names nothing at all.
if ! lane_processes "$FINISHED_ID"; then
  printf '%s: UNKNOWN — cannot read the process table completely; not starting a %s sweep while what still runs is unknown\n' \
    "$prog" "$lane" >&2
  finish 2
fi
if [ -n "$LIVE_SUPERVISORS" ]; then
  printf '%s: not starting a second %s sweep while supervisor pid%s still runs\n' \
    "$prog" "$lane" "$LIVE_SUPERVISORS"
  [ "$rc" -ne 0 ] || rc=1
  finish "$rc"
fi
if [ -n "$LIVE_SWEEPERS" ]; then
  # The advice stops a sweeper with the cleanup it is running, or not at all: stopped alone, it
  # leaves that cleanup going on with nothing by the sweeper's name left to see.
  stop_groups=""
  for sweeper_pid in $LIVE_SWEEPERS; do
    if leads_group "$sweeper_pid"; then
      stop_groups="$stop_groups -$sweeper_pid"
    else
      stop_groups=""
      break
    fi
  done
  if [ -n "$stop_groups" ]; then
    # shellcheck disable=SC2016  # the backticks are literal: they mark the command to run
    printf '%s: not starting a second %s sweep: sweeper pid%s is still running without its supervisor — let it finish, or stop it and the cleanup it is running with `kill --%s`, then start again\n' \
      "$prog" "$lane" "$LIVE_SWEEPERS" "$stop_groups"
  else
    printf '%s: not starting a second %s sweep: sweeper pid%s is still running without its supervisor — let it finish, then start again (stopping it alone would leave the cleanup it is running)\n' \
      "$prog" "$lane" "$LIVE_SWEEPERS"
  fi
  [ "$rc" -ne 0 ] || rc=1
  finish "$rc"
fi
if [ -n "$LIVE_CLEANUPS" ]; then
  printf '%s: not starting a second %s sweep: cleanup pid%s, which a sweep of the lane started, is still running after its sweeper ended — let it finish, then start again\n' \
    "$prog" "$lane" "$LIVE_CLEANUPS"
  [ "$rc" -ne 0 ] || rc=1
  finish "$rc"
fi
# An unreadable record still starts a sweep once nothing of the lane is running, and that sweep
# replaces it: refusing would leave the lane unswept on every run until someone repaired one file,
# and the disk would fill again.
[ -x "$sweeper" ] || unknown "missing $sweeper"
new_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
# nohup ignores HUP but still inherits the caller's process group. Give the supervisor its
# own group so a scheduled command's teardown cannot kill it before it records the result.
set -m
nohup bash "$self" __supervise --lane "$lane" --id "$new_id" >>"$log" 2>&1 </dev/null &
pid=$!
set +m
if ! write_record "$started" "id=$new_id pid=$pid at=$(now)"; then
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  unknown "started supervisor $new_id (pid $pid) but cannot record it in $started; it was stopped before cleanup began"
fi
if await_supervisor "$pid" "$new_id"; then supervisor_said=0; else supervisor_said=$?; fi
case "$supervisor_said" in
  0) ;;
  1) unknown "supervisor $new_id (pid $pid) ended before it began the sweep — see the end of $log" ;;
  *)
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    unknown "supervisor $new_id (pid $pid) did not say it was running within ten seconds; it was stopped"
    ;;
esac
printf '%s: started the %s sweep %s (pid %s) detached — its output appends to %s\n' \
  "$prog" "$lane" "$new_id" "$pid" "$log"
finish "$rc"
