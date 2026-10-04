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
# It never sends anything itself. Exit 1 tells the caller to send the DM through the Slack connector
# and then record that with --mark-notified.
#
# WHAT IT DELIBERATELY DOES NOT PAGE ON
#   - A lane that recovers inside the threshold. One or two bad slots are ordinary.
#   - An outage whose every NOT-PRODUCING line carries cause=quota/billing. A usage limit has a known
#     reset and the maintainer cannot shorten it (monorepo#3623), so it is reported as KNOWN-RESET and
#     neither counts toward the threshold nor clears a count already running.
#   - An UNKNOWN liveness verdict. "Could not check" is never "down", and it is never "alive" either:
#     it leaves the count where it was and exits 2.
#
# READ-ONLY toward both runtimes. The only file it writes is its own state file, which holds a lane
# name, a count, three timestamps and a bounded cause class — nothing from a transcript or a store.
# It prints only that same summary, never the liveness report itself, so its output is safe to quote
# in a run report.
#
# Usage: sibling-lane-watch.sh --lane <claude|codex> [--state-file PATH] [--threshold N]
#                              [--min-gap-seconds S] [--now-epoch S]
#        sibling-lane-watch.sh --lane <claude|codex> [--state-file PATH] --mark-notified
#
# --lane is the lane being WATCHED, which is never the caller's own: a Claude run passes `codex`, a
# Codex run passes `claude`. The default state file lives in the CALLER's private runtime directory
# (`~/.claude/lane-watch/codex.json` when watching codex, `~/.codex/lane-watch/claude.json` when
# watching claude), outside every checkout.
#
# SIBLING_LANE_LIVENESS_CMD replaces the liveness check, for the test suite only.
#
# Exit 0  nothing to send — verdict OK, WATCHING, KNOWN-RESET or ALREADY-NOTIFIED
#      1  ESCALATE — the lane has been NOT-PRODUCING for the threshold and nobody has been told
#      2  UNKNOWN — usage error, liveness could not judge, or the state file is unreadable,
#         malformed or unwritable
#
# Any OTHER non-zero status is an unexpected internal failure and also means UNKNOWN.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LANE=""
STATE_FILE=""
THRESHOLD=3
MIN_GAP_SECONDS=2700
NOW_EPOCH=""
MARK_NOTIFIED=0

unknown() {
  echo "sibling-lane-watch: UNKNOWN -- $*" >&2
  echo "verdict=UNKNOWN lane=${LANE:-unset}"
  exit 2
}

is_uint() {
  case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane | --state-file | --threshold | --min-gap-seconds | --now-epoch)
      [ "$#" -ge 2 ] || unknown "$1 needs a value"
      case "$1" in
        --lane) LANE="$2" ;;
        --state-file) STATE_FILE="$2" ;;
        --threshold) THRESHOLD="$2" ;;
        --min-gap-seconds) MIN_GAP_SECONDS="$2" ;;
        --now-epoch) NOW_EPOCH="$2" ;;
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

case "$LANE" in
  claude) default_state="$HOME/.codex/lane-watch/claude.json" ;;
  codex) default_state="$HOME/.claude/lane-watch/codex.json" ;;
  *)
    LANE="unset"
    unknown "--lane must be claude or codex (the lane being watched, never the caller's own)"
    ;;
esac
[ -n "$STATE_FILE" ] || STATE_FILE="$default_state"

is_uint "$THRESHOLD" && [ "$THRESHOLD" -ge 1 ] || unknown "--threshold must be a positive integer"
is_uint "$MIN_GAP_SECONDS" || unknown "--min-gap-seconds must be a non-negative integer"
[ -n "$NOW_EPOCH" ] || NOW_EPOCH="$(date +%s)"
is_uint "$NOW_EPOCH" || unknown "--now-epoch must be a non-negative integer"
command -v jq >/dev/null 2>&1 || unknown "jq is not installed"

# --- state -------------------------------------------------------------------------------------
# A missing file is the ordinary "no outage being tracked" state. A file that exists but cannot be
# parsed, or that tracks another lane, is UNKNOWN: guessing would either page on garbage or forget
# that a DM was already sent.
observations=0
first_seen=0
last_counted=0
notified=0
if [ -e "$STATE_FILE" ]; then
  state_line="$(jq -r --arg lane "$LANE" '
    select(type == "object" and .lane == $lane)
    | [.observations, .first_seen_epoch, .last_counted_epoch, .notified_epoch]
    | select(all(.[]; type == "number" and . >= 0 and . == floor))
    | map(tostring) | join(" ")' "$STATE_FILE" 2>/dev/null)" || unknown "state file is unreadable: $STATE_FILE"
  [ -n "$state_line" ] || unknown "state file is malformed or tracks another lane: $STATE_FILE"
  read -r observations first_seen last_counted notified <<EOF
$state_line
EOF
fi

write_state() {
  local dir tmp
  dir="$(dirname "$STATE_FILE")"
  mkdir -p "$dir" 2>/dev/null || unknown "cannot create the state directory: $dir"
  tmp="${STATE_FILE}.tmp.$$"
  jq -n --arg lane "$LANE" --argjson o "$observations" --argjson f "$first_seen" \
    --argjson l "$last_counted" --argjson n "$notified" \
    '{lane: $lane, observations: $o, first_seen_epoch: $f, last_counted_epoch: $l, notified_epoch: $n}' \
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
  # Recording a send for an outage this script never observed would suppress the real DM later.
  [ "$observations" -ge 1 ] || unknown "--mark-notified without a tracked outage for lane ${LANE}"
  notified="$NOW_EPOCH"
  write_state
  summary ALREADY-NOTIFIED recorded
  exit 0
fi

# --- liveness ----------------------------------------------------------------------------------
liveness_cmd="${SIBLING_LANE_LIVENESS_CMD:-${script_dir}/${LANE}-lane-liveness.sh}"
[ -x "$liveness_cmd" ] || unknown "liveness check is missing or not executable: $liveness_cmd"

liveness_rc=0
liveness_out="$("$liveness_cmd" 2>/dev/null)" || liveness_rc=$?

case "$liveness_rc" in
  0)
    # Producing again: the outage, if any, is over, so the next one may page afresh.
    if [ -e "$STATE_FILE" ]; then
      rm -f "$STATE_FILE" 2>/dev/null || unknown "cannot clear the state file: $STATE_FILE"
    fi
    observations=0 first_seen=0 notified=0
    summary OK none
    exit 0
    ;;
  1) ;;
  *) unknown "the ${LANE} liveness check could not judge (exit ${liveness_rc}); the count is unchanged" ;;
esac

# A `1` must name at least one NOT-PRODUCING task. An exit 1 with none is not a verdict this script
# understands, and treating it as "down" would page on a failure of the check itself.
down_lines="$(printf '%s\n' "$liveness_out" | grep -E '^[[:space:]]*NOT-PRODUCING[[:space:]]' || true)"
[ -n "$down_lines" ] || unknown "the ${LANE} liveness check exited 1 without a NOT-PRODUCING line"

other_lines="$(printf '%s\n' "$down_lines" | grep -vF 'cause=quota/billing' || true)"
if [ -z "$other_lines" ]; then
  summary KNOWN-RESET quota/billing
  exit 0
fi
cause="unknown"
case "$other_lines" in *cause=credentials/auth*) cause="credentials/auth" ;; esac

# Two runs inside one slot are one observation, not two: the threshold counts slots.
if [ "$observations" -eq 0 ]; then
  observations=1
  first_seen="$NOW_EPOCH"
  last_counted="$NOW_EPOCH"
  notified=0
  write_state
elif [ "$NOW_EPOCH" -lt "$last_counted" ]; then
  unknown "the state file's last observation is in the future; the count is unchanged"
elif [ $((NOW_EPOCH - last_counted)) -ge "$MIN_GAP_SECONDS" ]; then
  observations=$((observations + 1))
  last_counted="$NOW_EPOCH"
  write_state
fi

if [ "$notified" -gt 0 ]; then
  summary ALREADY-NOTIFIED "$cause"
  exit 0
fi
if [ "$observations" -ge "$THRESHOLD" ]; then
  summary ESCALATE "$cause"
  exit 1
fi
summary WATCHING "$cause"
exit 0
