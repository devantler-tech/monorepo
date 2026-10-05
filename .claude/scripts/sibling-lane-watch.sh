#!/usr/bin/env bash
# sibling-lane-watch.sh — has the OTHER runtime's lane been down long enough to tell the maintainer?
#
# claude-lane-liveness.sh and codex-lane-liveness.sh already answer "is that lane producing right
# now?", and both answered correctly during the outage that motivated this script. What was missing
# is a caller: the only runs that would have run the Claude check were Claude runs, and those are
# exactly the runs that could not start. Measured 2026-10-03: a stale desktop sign-in dropped 17
# hourly Engineer dispatches and 1 Improver dispatch before any session existed, and for 16.9 hours
# nothing reached the maintainer, who was the only one able to fix it. See monorepo#3801.
#
# So each runtime watches its SIBLING on every run, and this script turns a sequence of single
# liveness verdicts into one decision: send the last-resort Slack DM now, or not. It keeps a small
# private state file between runs because neither liveness check reports how long a lane has been
# down, and because "once per outage" needs a memory of having sent.
#
# It never sends anything itself. Exit 1 together with `verdict=ESCALATE` on stdout tells the caller
# to send the DM through the Slack connector and then record that with --mark-notified.
#
# WHAT IT COUNTS
#   Slots of the sibling's HOURLY task in which that task was not producing. Two runs inside one
#   slot are one observation; runs in different slots are separate ones, however close together. A
#   count survives one slot the watch did not observe and starts again after two, so old bad slots
#   cannot combine with a new one into a page. A producing look always clears it.
#   Two known imprecisions, both absorbed by the threshold and cleared by the next producing look:
#   a look between `:55` and a late Claude dispatch reads that dispatch as overdue, and a look just
#   after a slot boundary can count the previous slot's dead dispatch again.
#
# WHAT IT DELIBERATELY DOES NOT PAGE ON
#   - A lane that recovers inside the threshold. One or two bad slots are ordinary.
#   - An outage whose every NOT-PRODUCING line carries cause=quota/billing. A usage limit has a known
#     reset and the maintainer cannot shorten it (monorepo#3623), so it is reported as KNOWN-RESET and
#     never counts toward the threshold. It ends a count nobody was paged for, so bad slots before
#     and after a usage limit are never added together.
#   - An UNKNOWN liveness verdict. "Could not check" is never "down", and it is never "alive" either:
#     it leaves the count where it was and exits 2.
#   - The sibling's twice-daily task. Its verdict stands for twelve hours, which says nothing about
#     three hourly slots.
#
# READ-ONLY toward both runtimes. Everything it writes sits beside its own state file: the file, its
# `.lock` and `.reap` directories, and a `.corrupt` copy of a state file it had to set aside. The
# state holds a lane name, a count, a slot number and three timestamps — nothing from a transcript
# or a store. It prints only that same summary, never the liveness report itself,
# so its output is safe to quote in a run report.
#
# Usage: sibling-lane-watch.sh --lane <claude|codex> [--state-file PATH] [--threshold N]
#                              [--now-epoch S]
#        sibling-lane-watch.sh --lane <claude|codex> [--state-file PATH] --mark-notified
#
# --lane is the lane being WATCHED, which is never the caller's own: a Claude run passes `codex`, a
# Codex run passes `claude`. The default state file lives in the CALLER's private runtime directory
# (`~/.claude/lane-watch/codex.json` when watching codex, `~/.codex/lane-watch/claude.json` when
# watching claude), outside every checkout.
#
# The liveness check is always the one beside this script. --now-epoch is for the test suite and is
# passed on to it.
#
# Exit 0  nothing to send — verdict OK, WATCHING, KNOWN-RESET, ESCALATION-CLAIMED or ALREADY-NOTIFIED
#      1  ESCALATE — the lane has been NOT-PRODUCING for the threshold and nobody has been told
#      2  UNKNOWN — usage error, liveness could not judge, or the state file is unreadable,
#         malformed, locked or unwritable
#
# Any OTHER non-zero status is an unexpected internal failure and also means UNKNOWN.

set -Eeuo pipefail

# Exit 1 is a VERDICT that asks for a page, so no internal failure may reach it. Under `set -e` the
# abort status is the failing command's, and 1 is the commonest (a closed stdout is enough). Any
# unhandled error becomes 2, as in the two liveness checks.
trap 'exit 2' ERR

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LANE=""
STATE_FILE=""
THRESHOLD=3
NOW_EPOCH=""
NOW_SET=0
MARK_NOTIFIED=0

# A count continues across at most ONE slot the watch did not observe. It cannot be zero: the
# caller's scheduler drops a dispatch that overlaps a long run, and a watcher that looks every second
# hour would then restart at 1 forever and never page (reproduced over 12 such looks). It is not
# more than one, so that old bad slots cannot combine with a new one. The price is stated in the
# guide: the three bad slots may have one unobserved slot between each pair.
MAX_SLOT_GAP=2
# How long an ESCALATE verdict reserves the page for the run that received it. A run that dies
# before sending must not silence the outage for good, so the claim expires.
CLAIM_TTL_SECONDS=3600
# A healthy Claude dispatch starts its session about a second after `lastRunAt`, and the liveness
# check already allows 120 s of skew. Its default 900 s grace is longer than the gap between a Claude
# dispatch (`:50` plus a measured 3 to 13 minutes of scheduler jitter) and the Codex run at `:10`
# that watches it, so with the default most Codex runs read UNKNOWN. One early misread is absorbed by
# the threshold; a watch that cannot judge is not.
CLAUDE_GRACE_SECONDS=300
LOCK_STALE_MINUTES=2

sibling_lane_watch_finished=0
lock_dir=""
lock_held=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
sibling_lane_watch_cleanup() {
  local rc=$?
  if [ "$lock_held" -eq 1 ]; then rmdir "$lock_dir" 2>/dev/null || true; fi
  # Bash 3.2 reports a `set -u` abort to an EXIT trap as status 0 (monorepo#3414), and bash 5
  # reports it as 1, which here would read as a page. Only `finish` may choose the status.
  if [ "$sibling_lane_watch_finished" != 1 ] && [ "$rc" -ne 2 ]; then
    echo "sibling-lane-watch: aborted before finishing; reporting UNKNOWN rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
trap sibling_lane_watch_cleanup EXIT

finish() {
  sibling_lane_watch_finished=1
  exit "$1"
}

unknown() {
  echo "sibling-lane-watch: UNKNOWN -- $*" >&2
  echo "verdict=UNKNOWN lane=${LANE:-unset}"
  finish 2
}

is_uint() {
  case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane | --state-file | --threshold | --now-epoch)
      [ "$#" -ge 2 ] || unknown "$1 needs a value"
      case "$1" in
        --lane) LANE="$2" ;;
        --state-file) STATE_FILE="$2" ;;
        --threshold) THRESHOLD="$2" ;;
        --now-epoch)
          NOW_EPOCH="$2"
          NOW_SET=1
          ;;
      esac
      shift 2
      ;;
    --mark-notified)
      MARK_NOTIFIED=1
      shift
      ;;
    *) unknown "unrecognised argument: $1" ;;
  esac
done

# Only the HOURLY task is judged (see the header). `sibling_minute` is the minute that task is
# scheduled at (AGENTS.md, Cadence & focus); it turns the caller's clock into the sibling slot whose
# dispatch this run can judge.
case "$LANE" in
  claude)
    default_state="$HOME/.codex/lane-watch/claude.json"
    sibling_minute=50
    liveness_args=(--task daily-ai-assistant --grace-seconds "$CLAUDE_GRACE_SECONDS")
    ;;
  codex)
    default_state="$HOME/.claude/lane-watch/codex.json"
    sibling_minute=10
    liveness_args=(--automation daily-ai-engineer)
    ;;
  *)
    LANE="unset"
    unknown "--lane must be claude or codex (the lane being watched, never the caller's own)"
    ;;
esac
[ -n "$STATE_FILE" ] || STATE_FILE="$default_state"

is_uint "$THRESHOLD" && [ "${#THRESHOLD}" -le 4 ] && [ "$((10#$THRESHOLD))" -ge 1 ] ||
  unknown "--threshold must be a positive integer of at most four digits"
THRESHOLD=$((10#$THRESHOLD))
[ -n "$NOW_EPOCH" ] || NOW_EPOCH="$(date +%s)"
is_uint "$NOW_EPOCH" && [ "${#NOW_EPOCH}" -le 11 ] ||
  unknown "--now-epoch must be a non-negative integer of at most eleven digits"
NOW_EPOCH=$((10#$NOW_EPOCH))
[ "$NOW_EPOCH" -ge 3600 ] || unknown "--now-epoch is before the first slot"
command -v jq >/dev/null 2>&1 || unknown "jq is not installed"

slot=$(((NOW_EPOCH - sibling_minute * 60) / 3600))

# --- state -------------------------------------------------------------------------------------
# Every read-modify-write happens under one lock, taken AFTER the liveness call. That call takes
# seconds, and a run holding state it read before the call would overwrite another run's
# --mark-notified and page the same outage twice.
is_stale() {
  [ -n "$(find "$1" -maxdepth 0 -mmin "+${LOCK_STALE_MINUTES}" 2>/dev/null || true)" ]
}

lock_state() {
  local dir reap_dir tries=0
  dir="$(dirname "$STATE_FILE")"
  mkdir -p "$dir" 2>/dev/null || unknown "cannot create the state directory: $dir"
  [ -w "$dir" ] || unknown "the state directory is not writable: $dir"
  lock_dir="${STATE_FILE}.lock"
  reap_dir="${STATE_FILE}.reap"
  until mkdir "$lock_dir" 2>/dev/null; do
    # A lock older than any run of this script was left by one that died. Testing its age and then
    # removing it are two steps, and between them another waiter can have removed it and a third
    # run taken a live lock in its place. So only ONE waiter at a time may reap: the age test and the
    # removal both happen under a second, short mutex, and nothing but a reaper ever removes a
    # lock it does not hold. A reaper mutex left by a killed run ages out the same way.
    if is_stale "$lock_dir"; then
      if mkdir "$reap_dir" 2>/dev/null; then
        if is_stale "$lock_dir"; then rmdir "$lock_dir" 2>/dev/null || true; fi
        rmdir "$reap_dir" 2>/dev/null || true
      elif is_stale "$reap_dir"; then
        rmdir "$reap_dir" 2>/dev/null || true
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || unknown "the state file is locked by another run; the count is unchanged"
    sleep 0.1
  done
  lock_held=1
}

# A file that cannot be used is set aside, so one bad write cannot blind the watch for a whole
# outage: this run is UNKNOWN and the next starts afresh. The cost is at worst one repeated DM.
quarantine_state() {
  mv -f "$STATE_FILE" "${STATE_FILE}.corrupt" 2>/dev/null ||
    unknown "$1, and it could not be set aside: $STATE_FILE"
  unknown "$1; it was set aside and the next run starts afresh: $STATE_FILE"
}

observations=0
first_seen=0
last_slot=0
claimed=0
notified=0
read_state() {
  local state_line state_lane
  [ -e "$STATE_FILE" ] || return 0
  state_line="$(jq -r '
    select(type == "object" and (.lane == "claude" or .lane == "codex"))
    | [.observations, .first_seen_epoch, .last_slot, .claimed_epoch, .notified_epoch] as $n
    | select($n | all(.[]; type == "number" and (tostring | test("^[0-9]{1,11}$"))))
    | [.lane] + ($n | map(tostring)) | join(" ")' "$STATE_FILE" 2>/dev/null)" || state_line=""
  [ -n "$state_line" ] || quarantine_state "the state file is unreadable or malformed"
  read -r state_lane observations first_seen last_slot claimed notified <<EOF
$state_line
EOF
  [ "$state_lane" = "$LANE" ] || unknown "the state file tracks another lane: $STATE_FILE"
  [ "$last_slot" -le "$slot" ] || quarantine_state "the state file's last observation is in the future"
}

write_state() {
  local tmp
  tmp="${STATE_FILE}.tmp.$$"
  jq -n --arg lane "$LANE" --argjson o "$observations" --argjson f "$first_seen" \
    --argjson s "$last_slot" --argjson c "$claimed" --argjson n "$notified" \
    '{lane: $lane, observations: $o, first_seen_epoch: $f, last_slot: $s, claimed_epoch: $c, notified_epoch: $n}' \
    >"$tmp" 2>/dev/null || {
    rm -f "$tmp"
    unknown "cannot write the state file: $STATE_FILE"
  }
  mv -f "$tmp" "$STATE_FILE" 2>/dev/null || {
    rm -f "$tmp"
    unknown "cannot replace the state file: $STATE_FILE"
  }
}

summary() {
  echo "verdict=$1 lane=${LANE} observations=${observations}/${THRESHOLD} first_seen_epoch=${first_seen} notified_epoch=${notified} cause=$2"
}

if [ "$MARK_NOTIFIED" -eq 1 ]; then
  lock_state
  read_state
  # Recording a send nobody was asked for would suppress the real DM later.
  [ "$claimed" -gt 0 ] || unknown "--mark-notified without an ESCALATE verdict for lane ${LANE}"
  notified="$NOW_EPOCH"
  write_state
  summary ALREADY-NOTIFIED recorded
  finish 0
fi

# --- liveness ----------------------------------------------------------------------------------
liveness_cmd="${script_dir}/${LANE}-lane-liveness.sh"
[ -x "$liveness_cmd" ] || unknown "liveness check is missing or not executable: $liveness_cmd"
if [ "$NOW_SET" -eq 1 ]; then
  case "$LANE" in
    claude) liveness_args+=(--now-epoch "$NOW_EPOCH") ;;
    codex) liveness_args+=(--now-ms "${NOW_EPOCH}000") ;;
  esac
fi

# The healthy branch clears the state, but only the state this run saw before it looked: a run that
# counted a bad slot or recorded a send while this one was still checking wrote something newer,
# and that must survive.
state_signature() {
  if [ -e "$STATE_FILE" ]; then cksum <"$STATE_FILE" 2>/dev/null || echo unreadable; else echo absent; fi
}
signature_before="$(state_signature)"

liveness_rc=0
# bash 3.2 runs the inherited ERR trap inside this substitution even though the status is handled
# here, which would turn the check's exit 1 into 2. The trap is dropped for the subshell only.
liveness_out="$(trap - ERR; "$liveness_cmd" "${liveness_args[@]}" 2>/dev/null)" || liveness_rc=$?

case "$liveness_rc" in
  0)
    # Producing again: the outage, if any, is over, so the next one may page afresh.
    lock_state
    if [ -e "$STATE_FILE" ] && [ "$(state_signature)" = "$signature_before" ]; then
      rm -f "$STATE_FILE" 2>/dev/null || unknown "cannot clear the state file: $STATE_FILE"
    fi
    summary OK none
    finish 0
    ;;
  1) ;;
  *)
    # Usually a dispatch still in flight, which a later look in the same run can judge.
    unknown "the ${LANE} liveness check could not judge (exit ${liveness_rc}); the count is unchanged -- run this once more before the run report"
    ;;
esac

# A `1` must name at least one NOT-PRODUCING task. An exit 1 with none is not a verdict this script
# understands, and treating it as "down" would page on a failure of the check itself.
down_lines="$(printf '%s\n' "$liveness_out" | grep -E '^[[:space:]]*NOT-PRODUCING[[:space:]]' || true)"
[ -n "$down_lines" ] || unknown "the ${LANE} liveness check exited 1 without a NOT-PRODUCING line"

lock_state
read_state

other_lines="$(printf '%s\n' "$down_lines" | grep -vF 'cause=quota/billing' || true)"
if [ -z "$other_lines" ]; then
  # The lane is down for a reason that is not this watch's business, so what follows is a different
  # outage: a count nobody was paged for ends here. An outage he WAS told about stays recorded, and
  # so does one whose page has been handed to a run that still has to record the send.
  if [ "$observations" -gt 0 ] && [ "$notified" -eq 0 ] && [ "$claimed" -eq 0 ]; then
    rm -f "$STATE_FILE" 2>/dev/null || unknown "cannot clear the state file: $STATE_FILE"
    observations=0
    first_seen=0
  fi
  summary KNOWN-RESET quota/billing
  finish 0
fi
cause="unknown"
case "$other_lines" in *cause=credentials/auth*) cause="credentials/auth" ;; esac

# An outage the maintainer was told about stays that outage until the lane is seen producing, however
# long this watch went without looking; only a count nobody was paged for can go stale.
if [ "$observations" -eq 0 ] ||
  { [ "$notified" -eq 0 ] && [ $((slot - last_slot)) -gt "$MAX_SLOT_GAP" ]; }; then
  observations=1
  first_seen="$NOW_EPOCH"
  last_slot="$slot"
  claimed=0
  notified=0
  write_state
elif [ "$slot" -gt "$last_slot" ]; then
  observations=$((observations + 1))
  last_slot="$slot"
  write_state
fi

if [ "$notified" -gt 0 ]; then
  summary ALREADY-NOTIFIED "$cause"
  finish 0
fi
if [ "$observations" -lt "$THRESHOLD" ]; then
  summary WATCHING "$cause"
  finish 0
fi
if [ "$claimed" -gt 0 ] && [ $((NOW_EPOCH - claimed)) -lt "$CLAIM_TTL_SECONDS" ]; then
  # Another run was handed this page. If it never records the send, the claim expires.
  summary ESCALATION-CLAIMED "$cause"
  finish 0
fi
# The verdict is printed BEFORE the claim is written: if the write fails this exits 2, and the caller
# pages only on exit 1 together with verdict=ESCALATE.
summary ESCALATE "$cause"
claimed="$NOW_EPOCH"
write_state
# The every-run bullet in AGENTS.md has no room for the procedure, so the verdict carries it.
echo "sibling-lane-watch: send the lane-outage Slack DM, then re-run with --mark-notified -- see 'Sibling lane outage' in .claude/guides/maintainer-channels.md" >&2 || true
finish 1
