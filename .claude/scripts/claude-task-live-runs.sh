#!/usr/bin/env bash
# claude-task-live-runs.sh — is another run of this Claude scheduled task live right now?
#
# The Claude scheduler is meant to drop a dispatch that overlaps a live run of the same task, and
# nothing downstream fences same-task concurrency because of that. It does not always hold: a
# runtime restart on 2026-09-23 dispatched each task three times inside 100 seconds (monorepo#3536),
# and on 2026-10-06 three consecutive hourly Engineer runs each overlapped the previous one by 15 to
# 75 minutes, so two runs evaluated and promoted the same pull request a minute apart.
#
# The scheduler's own record cannot answer the question: `lastRunAt` names only the NEWEST dispatch,
# so the runs it superseded are invisible there. The process table can. Every Claude Code session is
# one process of the runtime's `claude` binary whose working directory is the session's worktree, and
# the session's transcript -- kept under the projects root in a directory named after that working
# directory -- opens with the `<scheduled-task name=...>` marker that names its task.
#
# So: list the live session processes, drop the caller's own session, and attribute each remaining
# one through its working directory to its newest transcript's opening marker.
#
# READ-ONLY, and deliberately NARROW. A transcript holds everything a run saw. This check reads only
# the FIRST line of a transcript, and from it only the opening task marker. It never prints message
# content, and it prints no process arguments.
#
# Usage: claude-task-live-runs.sh --task ID [--projects PATH] [--self-pid PID]
#                                 [--ps-file FILE] [--cwd-file FILE] [--now-epoch S] [--quiet]
#
#   --task       the scheduled task id to look for (the name in its `<scheduled-task name=...>`).
#   --projects   the Claude projects root (default: ~/.claude/projects).
#   --self-pid   a process inside the caller's own session (default: this script's own pid). The
#                session that process descends from is the caller's and is never reported.
#   --ps-file    TEST SEAM: read the process snapshot from FILE instead of running `ps`. One process
#                per line: pid, parent pid, elapsed time, then the command with its arguments.
#   --cwd-file   TEST SEAM: read working directories from FILE (pid, a tab, the directory) instead
#                of asking `lsof`.
#   --now-epoch  TEST SEAM: the current time in seconds, instead of the clock.
#
# Output: one `LIVE task=<id> pid=<pid> elapsed=<etime> session=<transcript name>` line per other
# live run of the task, then one `CHECKED sessions=<n> other=<n> own=<pid|unresolved> task=<id> live=<n>` line. `own` is
# the caller's session; `unresolved` means none was found, so the caller's own run, if it is one of
# the sessions, is reported as another.
#
# Exit 0  no other run of the task is live
#      1  at least one other run of the task is live
#      2  UNKNOWN -- a usage error, a failed or empty process read, or a live session that could not
#         be attributed to a task: no readable working directory, a directory two live sessions
#         share, no transcript or only one older than the session, or no opening message. A session
#         seconds old is exactly the overlap this check exists to see, so it is never read as absent

set -euo pipefail

die_unknown() { printf 'claude-task-live-runs: UNKNOWN -- %s\n' "$1" >&2; exit 2; }

TASK=""
PROJECTS="${HOME}/.claude/projects"
SELF_PID="$$"
PS_FILE=""
CWD_FILE=""
QUIET=0
NOW=""
SKEW_SECONDS=5
OPENING_RECORDS=20

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task|--projects|--self-pid|--ps-file|--cwd-file|--now-epoch)
      [ "$#" -ge 2 ] || die_unknown "$1 needs a value"
      case "$1" in
        --task) TASK="$2" ;;
        --projects) PROJECTS="$2" ;;
        --self-pid) SELF_PID="$2" ;;
        --ps-file) PS_FILE="$2" ;;
        --cwd-file) CWD_FILE="$2" ;;
        --now-epoch) NOW="$2" ;;
      esac
      shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --help|-h) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die_unknown "unknown argument: $1" ;;
  esac
done

case "$TASK" in
  "") die_unknown "--task is required" ;;
  *[!A-Za-z0-9._-]*) die_unknown "--task must be a task id (letters, digits, '.', '_' or '-')" ;;
esac
case "$SELF_PID" in ""|*[!0-9]*) die_unknown "--self-pid must be a process id" ;; esac
[ -d "$PROJECTS" ] || die_unknown "projects root not found: $PROJECTS"
command -v jq >/dev/null 2>&1 || die_unknown "jq is required"
[ -n "$NOW" ] || NOW=$(date +%s) || die_unknown "could not read the clock"
case "$NOW" in ""|*[!0-9]*) die_unknown "--now-epoch must be a number of seconds" ;; esac

if [ -n "$PS_FILE" ]; then
  [ -r "$PS_FILE" ] || die_unknown "process snapshot is not readable: $PS_FILE"
  snapshot=$(cat "$PS_FILE") || die_unknown "could not read the process snapshot"
else
  snapshot=$(ps -axo pid=,ppid=,etime=,command=) || die_unknown "could not list processes"
fi
[ -n "$snapshot" ] || die_unknown "the process list is empty"

# A session is the runtime's own `claude` binary, launched directly. The desktop app also starts a
# wrapper whose arguments repeat that path; it is the session's parent, not a second session.
# Emit `<pid> <etime> <self|other>` per session: `self` is the session --self-pid descends from, and
# any session started from inside it.
sessions=$(printf '%s\n' "$snapshot" | awk -v self="$SELF_PID" '
  {
    pid = $1; parent[pid] = $2; elapsed[pid] = $3
    command = $0
    sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", command)
    # The path holds spaces, so "starts with it" is tested as: nothing before it begins another path.
    prefix = substr(command, 1, index(command, "/claude-code/"))
    if (command ~ /^\/.*\/claude-code\/[^\/]+\/[^\/]+\/claude\.app\/Contents\/MacOS\/claude([[:space:]]|$)/ && prefix !~ /[[:space:]]\//) {
      session[pid] = 1; order[++count] = pid
    }
  }
  END {
    own = ""
    for (cursor = self; cursor != "" && cursor != "0" && cursor != "1" && !(cursor in seen); cursor = parent[cursor]) {
      seen[cursor] = 1
      if (cursor in session) { own = cursor; break }
    }
    for (index_ = 1; index_ <= count; index_++) {
      pid = order[index_]; kind = "other"
      split("", walked)
      for (cursor = pid; cursor != "" && cursor != "0" && cursor != "1" && !(cursor in walked); cursor = parent[cursor]) {
        walked[cursor] = 1
        if (own != "" && cursor == own) { kind = "self"; break }
      }
      print pid, elapsed[pid], kind
    }
  }
') || die_unknown "could not read the process snapshot"

# The caller normally runs inside a session, so a snapshot with no session at all means the
# recognition is wrong (a changed install path), not that nothing is running.
[ -n "$sessions" ] || die_unknown "no Claude Code session process recognised -- cannot judge"

working_directory() {
  if [ -n "$CWD_FILE" ]; then
    awk -F '\t' -v pid="$1" '$1 == pid { print $2; found = 1; exit } END { exit found ? 0 : 1 }' "$CWD_FILE"
  else
    lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
  fi
}

# `ps` prints elapsed time as [[dd-]hh:]mm:ss.
elapsed_seconds() {
  case "$1" in
    ""|*[!0-9:-]*) return 1 ;;
  esac
  awk -v elapsed="$1" 'BEGIN {
    days = 0
    if (split(elapsed, dayparts, "-") == 2) { days = dayparts[1]; elapsed = dayparts[2] }
    count = split(elapsed, parts, ":"); seconds = 0
    for (position = 1; position <= count; position++) seconds = seconds * 60 + parts[position]
    print days * 86400 + seconds
  }'
}

# GNU first: BSD `stat` rejects -c without printing, while GNU `stat -f` would print something else.
modified_epoch() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

unattributed() {
  printf 'UNATTRIBUTED pid=%s elapsed=%s reason=%s\n' "$1" "$2" "$3"
  unknown=$((unknown + 1))
}

total=0
others=0
live=0
unknown=0
own_session="unresolved"
TAB=$(printf '\t')

# First pass: every session's working directory, the caller's included. Two live sessions in one
# directory share one transcript directory, so neither can be attributed from "the newest file".
rows=""
while read -r pid elapsed kind; do
  [ -n "$pid" ] || continue
  total=$((total + 1))
  [ "$kind" = "other" ] || own_session="$pid"
  cwd=$(working_directory "$pid") || cwd=""
  rows="${rows}${pid}${TAB}${elapsed}${TAB}${kind}${TAB}${cwd}
"
done <<EOF2
$sessions
EOF2

while IFS="$TAB" read -r pid elapsed kind cwd; do
  [ -n "$pid" ] || continue
  [ "$kind" = "other" ] || continue
  others=$((others + 1))

  if [ -z "$cwd" ]; then unattributed "$pid" "$elapsed" no-working-directory; continue; fi

  sharing=$(printf '%s' "$rows" | awk -F '\t' -v cwd="$cwd" '$4 == cwd { count++ } END { print count + 0 }')
  if [ "$sharing" -ne 1 ]; then unattributed "$pid" "$elapsed" shared-working-directory; continue; fi

  # The runtime names a session's transcript directory after its working directory, with every
  # character that is not a letter or a digit replaced by a dash.
  slug=$(printf '%s' "$cwd" | tr -c 'A-Za-z0-9' '-')
  newest=""
  for candidate in "$PROJECTS/$slug"/*.jsonl; do
    [ -f "$candidate" ] || continue
    if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then newest="$candidate"; fi
  done
  if [ -z "$newest" ]; then unattributed "$pid" "$elapsed" no-transcript; continue; fi

  # A session that has not written its transcript yet must not be read from the one an earlier
  # session left in the same directory: the live session's own transcript is never older than it.
  age=$(elapsed_seconds "$elapsed") || age=""
  modified=$(modified_epoch "$newest") || modified=""
  case "$age:$modified" in
    :*|*:|*[!0-9:]*) unattributed "$pid" "$elapsed" unreadable-age; continue ;;
  esac
  if [ "$modified" -lt $((NOW - age - SKEW_SECONDS)) ]; then
    unattributed "$pid" "$elapsed" stale-transcript; continue
  fi

  # The same anchored recognition claude-lane-liveness.sh uses: only the opening of the session's
  # first message, after complete leading system-reminder blocks. A marker quoted anywhere else
  # names no task; a session whose first message has none is an interactive session. The first
  # message is not always the first record (a title or bridge record can precede it), so the first
  # few records are read and the first one that IS a message decides. `null` means none was found.
  # Every record read is consumed: a reader that stopped at the first match would end the pipe
  # early, and under pipefail that reads as a failure on exactly the transcripts that matched.
  name=$(head -n "$OPENING_RECORDS" "$newest" 2>/dev/null | jq -Rrn '
    [
      inputs | (try fromjson catch null)
      | select(type == "object")
      | if .type == "queue-operation" and .operation == "enqueue" then .content
        elif .type == "user" and .message.role == "user" then .message.content
        else empty end
      | select(type == "string")
    ] | (.[0] // null)
    | if . == null then "null"
      else "message " + (sub("^(<system-reminder>[\\s\\S]*?</system-reminder>[[:space:]]*)+"; "")
        | (capture("^<scheduled-task name=\"(?<id>[A-Za-z0-9._-]+)\"([[:space:]]|>)").id // ""))
      end
  ' 2>/dev/null) || name="null"
  case "$name" in
    "message "*) name=${name#message } ;;
    *) unattributed "$pid" "$elapsed" no-opening-message; continue ;;
  esac

  if [ "$name" = "$TASK" ]; then
    live=$((live + 1))
    session_name=${newest##*/}
    printf 'LIVE task=%s pid=%s elapsed=%s session=%s\n' "$TASK" "$pid" "$elapsed" "${session_name%.jsonl}"
  fi
done <<EOF2
$rows
EOF2

[ "$QUIET" -eq 1 ] || printf 'CHECKED sessions=%s other=%s own=%s task=%s live=%s\n' \
  "$total" "$others" "$own_session" "$TASK" "$live"

if [ "$live" -gt 0 ]; then exit 1; fi
if [ "$unknown" -gt 0 ]; then
  die_unknown "$unknown live session(s) could not be attributed to a task"
fi
exit 0
