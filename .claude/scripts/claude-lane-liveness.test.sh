#!/usr/bin/env bash
# claude-lane-liveness.test.sh — RED/GREEN coverage for the Claude lane liveness check.
#
# The check exists because a dead lane looked healthy, so the assertions that matter most are the
# ones proving it does NOT fire on a healthy lane: a guard that always fires is indistinguishable
# from decoration and gets ignored exactly as the signals it replaces were.
#
# Two cases here are REGRESSION guards for fail-opens the first working version actually had, both
# caught by running it against the real host rather than by reading the diff:
#   - `find -newermt @<epoch>` is GNU-only. BSD find rejects it, and with stderr suppressed that read
#     as "no transcripts matched", producing a fabricated NOT-PRODUCING on a healthy lane.
#   - the `<scheduled-task name=...>` marker is embedded in JSON, so its quotes arrive
#     backslash-escaped; matching only the unescaped spelling attributed nothing at all.
#
# Fixtures are synthetic. Every case pins `--now-epoch`, so no assertion depends on wall-clock time.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/claude-lane-liveness.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  if [ "${ALLOW_SKIP:-0}" = "1" ]; then
    echo "SKIP: jq unavailable (ALLOW_SKIP=1)" >&2; exit 0
  fi
  echo "FAIL: jq is required to run this suite (set ALLOW_SKIP=1 to skip locally)" >&2; exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

NOW=1788000000            # fixed "now" for every case
fails=0
asserts=0
note_fail() { echo "FAIL: $1" >&2; fails=$(( fails + 1 )); }

# Both helpers accept either date dialect, for the same reason the script does.
iso_at() {
  local e=$1 out
  out=$(date -u -r "$e" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || out=""
  [ -n "$out" ] || { echo "FAIL: cannot render epoch $e as ISO" >&2; exit 1; }
  printf '%s.000Z\n' "$out"
}
touch_at() {
  local e=$1 out
  out=$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -d "@$e" +%Y%m%d%H%M.%S 2>/dev/null) || out=""
  [ -n "$out" ] || { echo "FAIL: cannot render epoch $e as touch stamp" >&2; exit 1; }
  printf '%s\n' "$out"
}

# One store per case, so a fixture can never leak into the next.
mkcase() {
  local name=$1; CASE="$TMP/$name"
  mkdir -p "$CASE/projects/proj-a"
  STORE="$CASE/store.json"; PROJECTS="$CASE/projects"
}

# `enabled` and `lastRunAt` are written exactly as the real store writes them.
mkstore() {
  local file=$1; shift
  printf '{"scheduledTasks":[' > "$file"
  local first=1
  while [ "$#" -gt 0 ]; do
    [ "$first" -eq 1 ] || printf ',' >> "$file"
    first=0
    printf '{"id":"%s","enabled":%s,"lastRunAt":%s,"cronExpression":"0 * * * *","filePath":"/x","cwd":"/y"}' \
      "$1" "$2" "$3" >> "$file"
    shift 3
  done
  printf ']}\n' >> "$file"
}

# A transcript whose FIRST line carries the marker plus the session's start timestamp, followed by
# `turns` assistant records spread across `span` seconds. `esc` selects the escaped spelling (which
# is what the real runtime writes) or the bare one.
mksession() {
  local dir=$1 id=$2 start=$3 turns=$4 span=$5 esc=${6:-escaped} f n
  mkdir -p "$dir"
  f="$dir/$(printf 'sess-%s-%s' "$id" "$start").jsonl"
  # The runtime writes the marker inside a JSON string, so its quotes carry exactly ONE backslash
  # (`name=\"daily-ai-assistant\"`, verified against a real transcript). Building that through
  # printf's own escapes is where this fixture first went wrong -- it emitted three backslashes and
  # the GREEN cases silently failed to attribute. Carrying the two characters as DATA is unambiguous.
  local bsq='\"'
  if [ "$esc" = "late" ]; then
    # Line 1 carries NO marker; the marker appears further down. Inside JSON the marker's quotes are
    # always escaped, so an "unescaped marker" transcript cannot exist -- an unescaped quote would
    # break the JSON. What CAN exist is a session that merely mentions the marker later in its own
    # content, and attributing that would credit an unrelated session to a dispatch.
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hello"}}\n' \
      "$(iso_at "$start")" > "$f"
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<scheduled-task name=%s%s%s>"}}\n' \
      "$(iso_at "$start")" "$bsq" "$id" "$bsq" >> "$f"
  else
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<scheduled-task name=%s%s%s file=%s/x%s>go</scheduled-task>"}}\n' \
      "$(iso_at "$start")" "$bsq" "$id" "$bsq" "$bsq" "$bsq" > "$f"
  fi
  n=0
  while [ "$n" -lt "$turns" ]; do
    printf '{"type":"assistant","timestamp":"%s"}\n' "$(iso_at "$(( start + 1 ))")" >> "$f"
    n=$(( n + 1 ))
  done
  # The closing record fixes the session span regardless of turn count, so span and turn count stay
  # independent -- which is what lets the two discriminators be tested one at a time.
  printf '{"type":"system","timestamp":"%s"}\n' "$(iso_at "$(( start + span ))")" >> "$f"
  touch -t "$(touch_at "$(( start + span ))")" "$f"
  printf '%s\n' "$f"
}

run() { "$SCRIPT" --store "$STORE" --projects "$PROJECTS" --now-epoch "$NOW" --quiet "$@" >/dev/null 2>&1; }

expect() {
  local want=$1 label=$2; shift 2
  local got=0
  run "$@" || got=$?
  asserts=$(( asserts + 1 ))
  [ "$got" = "$want" ] || note_fail "$label: expected exit $want, got $got"
}

# --- GREEN: a healthy lane must NOT fire -------------------------------------------------------
mkcase healthy
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect 0 "healthy dispatch with a producing session exits 0"

# --- RED: dispatched, but nothing ran ----------------------------------------------------------
mkcase nosession
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
# A session exists, but for a DIFFERENT dispatch far outside the skew window, so the newest
# dispatch has none of its own. Without this the case would also pass on an empty projects dir,
# which the empty-enumeration guard turns into UNKNOWN rather than a verdict.
mksession "$PROJECTS/proj-a" alpha $(( NOW - 40000 )) 40 1200 >/dev/null
expect 1 "dispatch with no session inside the skew window exits 1"

# --- RED: dispatched, session ran but produced nothing ------------------------------------------
mkcase stub
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 0 5 >/dev/null
expect 1 "dispatch whose session produced 0 turns in 5s exits 1"

# --- Both discriminators are required, one at a time --------------------------------------------
mkcase turns_only
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 0 1200 >/dev/null
expect 0 "0 turns but a long span is NOT a stub (span discriminator required)"

mkcase span_only
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 3 5 >/dev/null
expect 0 "a short span with real turns is NOT a stub (turn discriminator required)"

# --- REGRESSION: the escaped marker is what the runtime actually writes --------------------------
mkcase escaped_marker
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 escaped >/dev/null
expect 0 "a backslash-escaped marker is attributed (regression: unescaped-only matched nothing)"

mkcase late_marker
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 late >/dev/null
expect 1 "a marker on a later line is NOT attributed (the first-line read is deliberate)"

# --- REGRESSION: a broken/empty enumeration is UNKNOWN, never a verdict --------------------------
mkcase empty_projects
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
expect 2 "no transcripts at all is UNKNOWN, not NOT-PRODUCING (regression: BSD find fail-open)"

# --- UNKNOWN: an in-flight dispatch must not be classified ---------------------------------------
mkcase inflight
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 10 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 9 )) 0 2 >/dev/null
expect 2 "a dispatch inside the grace window is UNKNOWN, not a stub"

# --- Exit 1 outranks exit 2 ----------------------------------------------------------------------
mkcase dead_outranks
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\"" beta true "\"$(iso_at $(( NOW - 10 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 0 5 >/dev/null
mksession "$PROJECTS/proj-a" beta $(( NOW - 9 )) 30 5 >/dev/null
expect 1 "a detected dead task outranks an unjudgeable one"

# --- Disabled tasks ------------------------------------------------------------------------------
mkcase disabled_excluded
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\"" beta false "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect 0 "a disabled task is not judged (it does not dispatch)"
expect 2 "--task on a disabled task is UNKNOWN, not a verdict" --task beta

# --- Malformed inputs all fail closed ------------------------------------------------------------
mkcase badstore
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
printf 'not json' > "$CASE/broken.json"
asserts=$(( asserts + 1 ))
rc=0; "$SCRIPT" --store "$CASE/broken.json" --projects "$PROJECTS" --now-epoch "$NOW" --quiet >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] || note_fail "a non-JSON store is UNKNOWN, got $rc"
asserts=$(( asserts + 1 ))
rc=0; "$SCRIPT" --store "$STORE" --projects "$CASE/absent" --now-epoch "$NOW" --quiet >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] || note_fail "an absent projects root is UNKNOWN, got $rc"
asserts=$(( asserts + 1 ))
printf '{"scheduledTasks":[{"id":"alpha","enabled":true}]}\n' > "$CASE/noschema.json"
rc=0; "$SCRIPT" --store "$CASE/noschema.json" --projects "$PROJECTS" --now-epoch "$NOW" --quiet >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] || note_fail "a task missing .lastRunAt is UNKNOWN, got $rc"

mkcase unparsable_lastrun
mkstore "$STORE" alpha true '"not-a-timestamp"'
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect 2 "an unparsable lastRunAt is UNKNOWN"

# --- A dispatch older than the lookback window is UNKNOWN, not a verdict --------------------------
# Its session cannot be enumerated, so NOT-PRODUCING there would be a statement about the filter
# rather than about the lane -- the same class as the empty-enumeration guard above.
mkcase stale_dispatch
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 80 * 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect 2 "a dispatch predating the lookback window is UNKNOWN, not NOT-PRODUCING"

# --- Knob validation: a zero window must never disable the guard ---------------------------------
mkcase knobs
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect 2 "--grace-seconds 0 is refused" --grace-seconds 0
expect 2 "--stub-seconds 0 is refused" --stub-seconds 0
expect 2 "--skew-seconds 0 is refused" --skew-seconds 0
expect 2 "--lookback-hours 0 is refused" --lookback-hours 0
expect 2 "a non-numeric knob is refused" --stub-seconds abc
expect 2 "an unrecognised argument is refused" --nope
expect 2 "an unusable task id is refused" --task 'a;b'

echo "claude-lane-liveness.test.sh: $asserts assertion(s), $fails failure(s)"
[ "$fails" -eq 0 ] || exit 1
