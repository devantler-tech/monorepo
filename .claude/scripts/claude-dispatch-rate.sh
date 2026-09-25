#!/usr/bin/env bash
# claude-dispatch-rate.sh — how many of a Claude task's scheduled slots actually dispatched?
#
# AGENTS.md#Cadence & focus says the Claude scheduler refuses a dispatch that would overlap the
# previous run of the same task, so "scheduled every hour" is not "ran every hour". It also says the
# drop rate may be re-derived ONLY by comparing actual dispatches to scheduled slots -- never by
# counting `per_task_limit` skip records, which the scheduler re-writes every minute a run stays open.
# Counting those records produced five mutually inconsistent readings. Every reading so far was a
# one-off hand measurement, so none could be repeated (monorepo#2716). This helper is that comparison.
#
# THE RULE
#   Slots come from the task's `cronExpression`, evaluated in host local time. A slot is DISPATCHED
#   when an attributable session for that task starts in [slot, next slot). A delayed dispatch that
#   starts after its own slot but before the next one therefore still counts. That is the
#   "delayed into the next hour is not dropped" correction the contract records.
#   A slot is SETTLED only once its successor is at or before --until. An open slot has had no chance
#   to dispatch yet and is never counted as dropped.
#
# WHAT IT CANNOT SEE
#   The store keeps only the CURRENT cron, with no edit history. A window is always judged against
#   it, and the output says so (`cron_source=current`). A schedule edited during the window is
#   invisible here, so measure only windows you know the schedule held for. Windows starting before
#   the task's `createdAt` are refused.
#   A dispatch that dies before the run's first user message carries no task marker, so it cannot
#   be attributed and counts as dropped. That is the honest reading: such a run did no work. It is
#   also why `claude-lane-liveness.sh` answers whether the NEWEST dispatch produced work, while this
#   reports a RATE over a window. The two answer different questions.
#
# READ-ONLY, and as narrow as claude-lane-liveness.sh: from each transcript it reads only the
# first line's task marker and timestamp. It never reads run content.
#
# Usage: claude-dispatch-rate.sh --task ID --since ISO [--until ISO] [--store PATH] [--projects PATH]
#                               [--now-epoch S] [--slots]
#   --since/--until  UTC instants, YYYY-MM-DDTHH:MM:SSZ. --until defaults to now and may not be later.
#   --slots          also print one line per settled slot: `<slot-utc> dispatched|dropped`.
#
# Exit 0  measured; prints `DISPATCH-RATE task=<id> scheduled=<n> dispatched=<d> dropped=<n-d> ...`
#      2  UNKNOWN -- bad arguments, no jq, absent/ambiguous store, unsupported cron, an unreadable
#         transcript, or no settled slot in the window. Never a rate computed from a partial read.

set -Eeuo pipefail
trap 'exit 2' ERR

STORE="${CLAUDE_SCHEDULE_STORE_PATH:-}"
STORE_ROOT="${CLAUDE_SCHEDULE_STORE_ROOT:-$HOME/Library/Application Support/Claude/claude-code-sessions}"
PROJECTS="${CLAUDE_PROJECTS_ROOT:-$HOME/.claude/projects}"
TASK=""; SINCE=""; UNTIL=""; NOW_EPOCH=""; SLOTS=0

usage() { sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; }
die_unknown() { printf 'claude-dispatch-rate: UNKNOWN -- %s\n' "$1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --task) [ "$#" -ge 2 ] || die_unknown "--task needs a value"; TASK="$2"; shift 2 ;;
    --since) [ "$#" -ge 2 ] || die_unknown "--since needs a value"; SINCE="$2"; shift 2 ;;
    --until) [ "$#" -ge 2 ] || die_unknown "--until needs a value"; UNTIL="$2"; shift 2 ;;
    --store) [ "$#" -ge 2 ] || die_unknown "--store needs a value"; STORE="$2"; shift 2 ;;
    --projects) [ "$#" -ge 2 ] || die_unknown "--projects needs a value"; PROJECTS="$2"; shift 2 ;;
    --now-epoch) [ "$#" -ge 2 ] || die_unknown "--now-epoch needs a value"; NOW_EPOCH="$2"; shift 2 ;;
    --slots) SLOTS=1; shift ;;
    *) die_unknown "unrecognised argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die_unknown "jq is not available"
[ -n "$TASK" ] || die_unknown "--task is required"
case "$TASK" in *[!A-Za-z0-9._-]*) die_unknown "unusable task id: $TASK" ;; esac
[ -n "$SINCE" ] || die_unknown "--since is required"

if [ -n "$NOW_EPOCH" ]; then
  case "$NOW_EPOCH" in *[!0-9]*) die_unknown "--now-epoch must be a non-negative integer" ;; esac
else
  NOW_EPOCH=$(date +%s)
fi

# Strict UTC instants only. BSD and GNU date parse differently, so both are tried and validated;
# an unparsable instant returns empty and every caller treats that as UNKNOWN.
iso_to_epoch() {
  local raw=$1 base out frac
  # The whole value is validated, including the trailing Z, before anything is stripped. Stripping
  # first would turn `...00.000+02:00` into a UTC instant two hours off and still report a rate.
  case "$raw" in *Z) : ;; *) return 0 ;; esac
  base=${raw%Z}
  case "$base" in
    *.*) frac=${base#*.}; base=${base%%.*}
         case "$frac" in ''|*[!0-9]*) return 0 ;; esac ;;
  esac
  case "$base" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) : ;;
    *) return 0 ;;
  esac
  out=$(date -u -d "${base}Z" +%s 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null) || out=""
  case "$out" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$out"
}
epoch_to_iso() {
  local out
  out=$(date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || out=""
  printf '%s\n' "$out"
}
# Local wall clock as "HH MM SS"; cron expressions use the host timezone.
local_clock() {
  local out
  out=$(date -r "$1" '+%H %M %S' 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -d "@$1" '+%H %M %S' 2>/dev/null) || out=""
  case "$out" in [0-2][0-9]' '[0-5][0-9]' '[0-5][0-9]) printf '%s\n' "$out" ;; *) return 0 ;; esac
}
# Local "YYYYMMDDHH", used to count a fixed wall-clock hour once per day.
local_hour_key() {
  local out
  out=$(date -r "$1" +%Y%m%d%H 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -d "@$1" +%Y%m%d%H 2>/dev/null) || out=""
  case "$out" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) printf '%s\n' "$out" ;; *) return 0 ;; esac
}
epoch_to_touch() {
  local out
  out=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null) || out=""
  printf '%s\n' "$out"
}

SINCE_E=$(iso_to_epoch "$SINCE"); [ -n "$SINCE_E" ] || die_unknown "--since is not a UTC instant: $SINCE"
if [ -n "$UNTIL" ]; then
  UNTIL_E=$(iso_to_epoch "$UNTIL"); [ -n "$UNTIL_E" ] || die_unknown "--until is not a UTC instant: $UNTIL"
else
  UNTIL_E=$NOW_EPOCH
fi
# A window reaching past now would settle slots whose dispatch window has not closed yet.
[ "$UNTIL_E" -le "$NOW_EPOCH" ] || die_unknown "--until is later than now"
[ "$SINCE_E" -lt "$UNTIL_E" ] || die_unknown "--since must be earlier than --until"

# Store discovery matches claude-lane-liveness.sh: EXACTLY one enabled store, or UNKNOWN.
if [ -z "$STORE" ]; then
  matches=0; selected=""
  for candidate in "$STORE_ROOT"/*/*/scheduled-tasks.json; do
    [ -f "$candidate" ] || continue
    # An unreadable candidate could be the current store. Skipping it would let a stale sibling win.
    jq -e . "$candidate" >/dev/null 2>&1 || die_unknown "candidate store is not readable JSON: $candidate"
    jq -e '[.scheduledTasks[]? | select(.enabled == true) | .id] | length > 0' "$candidate" >/dev/null 2>&1 || continue
    selected="$candidate"; matches=$((matches + 1))
  done
  [ "$matches" -eq 1 ] || die_unknown "expected exactly one Claude scheduled-tasks store under $STORE_ROOT, found $matches"
  STORE="$selected"
fi
[ -r "$STORE" ] || die_unknown "scheduled-tasks store is not readable: $STORE"
[ -d "$PROJECTS" ] || die_unknown "projects root not found: $PROJECTS"

n=$(jq -r --arg t "$TASK" '[.scheduledTasks[]? | select(.id == $t and .enabled == true)] | length' "$STORE" 2>/dev/null) \
  || die_unknown "scheduled-tasks store is not valid JSON: $STORE"
[ "$n" = "1" ] || die_unknown "task $TASK is not a single enabled task in $STORE"
CRON=$(jq -r --arg t "$TASK" 'first(.scheduledTasks[] | select(.id == $t and .enabled == true)) | .cronExpression | strings
  | select(test("\\A[0-9]{1,2} (\\*|[0-9]{1,2}(,[0-9]{1,2})*) \\* \\* \\*\\z"))' "$STORE") || CRON=""
# Whitelisted in jq, on the raw value, before command substitution can strip a trailing newline.
[ -n "$CRON" ] || die_unknown "task $TASK has no cronExpression in a supported shape (M * * * * or M H1,H2 * * *)"
# The store keeps no schedule history, so a window can only be judged against the task's CURRENT
# cron. Before the task existed there is nothing to judge at all: those slots would all read dropped.
CREATED_MS=$(jq -r --arg t "$TASK" 'first(.scheduledTasks[] | select(.id == $t and .enabled == true)) | .createdAt | numbers' "$STORE") || CREATED_MS=""
case "$CREATED_MS" in ''|*[!0-9]*) die_unknown "task $TASK has no numeric createdAt, so the window cannot be bounded" ;; esac
[ "$SINCE_E" -ge $(( CREATED_MS / 1000 )) ] \
  || die_unknown "--since predates task $TASK's creation at $(epoch_to_iso $(( CREATED_MS / 1000 )))"

# Supported shapes are the two the deployment uses: `M * * * *` and `M H1,H2,... * * *`.
# Anything else is UNKNOWN rather than a guessed schedule.
# `read` consumes one physical line, so a multi-line value would be judged by its first line alone.
case "$CRON" in *$'\n'*|*$'\r'*) die_unknown "cron expression spans more than one line" ;; esac
read -r C_MIN C_HOUR C_DOM C_MON C_DOW C_EXTRA <<EOF
$CRON
EOF
{ [ -z "${C_EXTRA:-}" ] && [ "$C_DOM" = "*" ] && [ "$C_MON" = "*" ] && [ "$C_DOW" = "*" ]; } \
  || die_unknown "unsupported cron expression: $CRON"
case "$C_MIN" in ''|*[!0-9]*) die_unknown "unsupported cron minute: $CRON" ;; esac
[ "$((10#$C_MIN))" -le 59 ] || die_unknown "unsupported cron minute: $CRON"
if [ "$C_HOUR" != "*" ]; then
  case "$C_HOUR" in ''|,*|*,|*,,*|*[!0-9,]*) die_unknown "unsupported cron hour list: $CRON" ;; esac
  # Every value is checked up front. Checking lazily would let `3,25` pass as `3`, because the
  # match loop returns on the first hit before it reaches the invalid value.
  IFS=, read -r -a C_HOURS <<EOF
$C_HOUR
EOF
  for v in "${C_HOURS[@]}"; do
    { [ "${#v}" -le 2 ] && [ "$((10#$v))" -le 23 ]; } || die_unknown "unsupported cron hour list: $CRON"
  done
fi
hour_matches() {
  local h=$1 v
  [ "$C_HOUR" = "*" ] && return 0
  local IFS=,
  for v in $C_HOUR; do
    [ "$((10#$v))" -le 23 ] || return 1
    [ "$((10#$v))" -eq "$((10#$h))" ] && return 0
  done
  return 1
}

# Enumerate slots. Find the first minute boundary at or after --since whose local minute is the
# cron minute, then walk absolute hours: every local hour boundary falls on one of them, including
# across a DST change, because offsets here move in whole hours.
start=$(( SINCE_E + (60 - SINCE_E % 60) % 60 ))
i=0; first=""
while [ "$i" -lt 60 ]; do
  clk=$(local_clock $(( start + i * 60 ))); [ -n "$clk" ] || die_unknown "could not render local time"
  read -r _ mm _ <<EOF
$clk
EOF
  if [ "$((10#$mm))" -eq "$((10#$C_MIN))" ]; then first=$(( start + i * 60 )); break; fi
  i=$(( i + 1 ))
done
[ -n "$first" ] || die_unknown "no local minute matched the cron minute; the timezone offset is not whole-minute"

SLOT_LIST=""; SEEN_KEYS=""
# The walk starts a day early so a fixed hour that already fired before --since (the first half of a
# DST fallback) is remembered. Only slots at or after --since are measured.
e=$(( first - 25 * 3600 ))
while [ "$e" -le "$UNTIL_E" ]; do
  clk=$(local_clock "$e"); [ -n "$clk" ] || die_unknown "could not render local time"
  read -r hh _ _ <<EOF
$clk
EOF
  if hour_matches "$hh"; then
    # A fixed-hour schedule fires once per wall-clock hour. During a DST fallback the same local
    # hour occurs twice in absolute time; counting both would invent a dropped slot. An hourly
    # schedule fires every absolute hour, so it is not deduplicated.
    key=""
    if [ "$C_HOUR" != "*" ]; then
      key=$(local_hour_key "$e"); [ -n "$key" ] || die_unknown "could not render local time"
      case " $SEEN_KEYS " in *" $key "*) e=$(( e + 3600 )); continue ;; esac
      SEEN_KEYS="$SEEN_KEYS $key"
    fi
    [ "$e" -lt "$SINCE_E" ] || SLOT_LIST="$SLOT_LIST $e"
  fi
  e=$(( e + 3600 ))
done
# One more matching slot beyond --until bounds the last settled interval. It is capped at 24 hours
# ahead, since a supported cron always fires at least once a day.
end_bound=""
limit=$(( e + 25 * 3600 ))
while [ "$e" -le "$limit" ]; do
  clk=$(local_clock "$e"); [ -n "$clk" ] || die_unknown "could not render local time"
  read -r hh _ _ <<EOF
$clk
EOF
  if hour_matches "$hh"; then end_bound=$e; break; fi
  e=$(( e + 3600 ))
done
[ -n "$end_bound" ] || die_unknown "could not find the slot after --until for $CRON"

# Attributable sessions for this task that started in the window. `-newer` keeps BSD find working;
# a transcript's mtime is at or after its start, so this never drops an in-window session.
ANY_ATTRIBUTED=0
TIMEREF=$(mktemp); FILELIST=$(mktemp); STARTS=$(mktemp)
trap 'rm -f "$TIMEREF" "$FILELIST" "$STARTS"' EXIT
stamp=$(epoch_to_touch "$SINCE_E"); [ -n "$stamp" ] || die_unknown "could not render --since as a touch stamp"
touch -t "$stamp" "$TIMEREF" || die_unknown "could not stamp the window reference file"
find "$PROJECTS" -maxdepth 2 -name '*.jsonl' -type f -newer "$TIMEREF" > "$FILELIST" 2>/dev/null \
  || die_unknown "could not enumerate transcripts under $PROJECTS"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  line1=$(head -n 1 "$f" 2>/dev/null) || die_unknown "could not read a transcript header"
  case "$line1" in *'<scheduled-task name='*) : ;; *) continue ;; esac
  # A header that carries the marker but is not valid JSON may be a dispatch in this window.
  # Skipping it would count its slot as dropped and still report a rate, so it is UNKNOWN.
  # Exactly ONE object: two objects on one line would each yield a task name.
  printf '%s' "$line1" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
    || die_unknown "a task-marker transcript header is not valid JSON: $f"
  # Same anchored attribution as claude-lane-liveness.sh: the marker must OPEN the first user
  # message (after complete leading system reminders), so a quoted marker attributes nothing.
  nm=$(printf '%s' "$line1" | jq -er '
    select(type == "object")
    | if .type == "queue-operation" and .operation == "enqueue" then .content
      elif .type == "user" and .message.role == "user" then .message.content
      else empty end
    | select(type == "string")
    | sub("^(<system-reminder>[\\s\\S]*?</system-reminder>[[:space:]]*)+"; "")
    | capture("^<scheduled-task name=\"(?<id>[A-Za-z0-9._-]+)\"([[:space:]]|>)").id
  ' 2>/dev/null) || nm=""
  [ -z "$nm" ] || ANY_ATTRIBUTED=$(( ANY_ATTRIBUTED + 1 ))
  [ "$nm" = "$TASK" ] || continue
  ts=$(printf '%s' "$line1" | jq -r '.timestamp // empty' 2>/dev/null) || ts=""
  se=$(iso_to_epoch "$ts")
  # Attributed to THIS task but untimed: dropping it would count its slot as dropped on evidence
  # that was malformed rather than absent.
  [ -n "$se" ] || die_unknown "a $TASK transcript has no readable start timestamp: $f"
  # A start later than the observer clock is corrupted evidence. It would match no settled interval
  # and silently read as a dropped slot.
  [ "$se" -le $(( NOW_EPOCH + 120 )) ] || die_unknown "a $TASK transcript starts after now: $f"
  printf '%s\n' "$se" >> "$STARTS"
done < "$FILELIST"

# No attributable transcript for ANY task means the projects root or its layout is wrong, not that
# every slot was dropped. A total outage lasting the whole window reads UNKNOWN too, which is the
# same trade claude-lane-liveness.sh makes: neither case is ever reported as a measured rate.
[ "$ANY_ATTRIBUTED" -gt 0 ] || die_unknown "no transcript under $PROJECTS in the window is attributable to any scheduled task"

scheduled=0; dispatched=0; slot_lines=""
prev=""
for s in $SLOT_LIST $end_bound; do
  if [ -n "$prev" ] && [ "$s" -le "$UNTIL_E" ]; then
    hit=$(awk -v a="$prev" -v b="$s" '$1 >= a && $1 < b { print "y"; exit }' "$STARTS")
    scheduled=$(( scheduled + 1 ))
    if [ "$hit" = "y" ]; then dispatched=$(( dispatched + 1 )); st=dispatched; else st=dropped; fi
    slot_lines="$slot_lines$(epoch_to_iso "$prev") $st
"
  fi
  prev=$s
done

[ "$scheduled" -gt 0 ] || die_unknown "no settled slot between --since and --until for $CRON"

dropped=$(( scheduled - dispatched ))
rate=$(awk -v d="$dropped" -v n="$scheduled" 'BEGIN { printf "%.1f", 100 * d / n }')
printf 'DISPATCH-RATE task=%s cron="%s" cron_source=current window=%s..%s scheduled=%d dispatched=%d dropped=%d drop_rate=%s%%\n' \
  "$TASK" "$CRON" "$(epoch_to_iso "$SINCE_E")" "$(epoch_to_iso "$UNTIL_E")" "$scheduled" "$dispatched" "$dropped" "$rate"
[ "$SLOTS" -eq 0 ] || printf '%s' "$slot_lines"
