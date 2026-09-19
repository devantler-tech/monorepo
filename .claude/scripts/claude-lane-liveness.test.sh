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
export TZ=UTC

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
epoch_utc() {
  local raw=$1 base=${1%Z} out
  out=$(date -u -d "$raw" +%s 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null) || out=""
  [ -n "$out" ] || { echo "FAIL: cannot parse UTC instant $raw" >&2; exit 1; }
  printf '%s\n' "$out"
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
  local scheduled
  scheduled=$(iso_at $(( NOW - NOW % 3600 )))
  printf '{"scheduledTasks":[' > "$file"
  local first=1
  while [ "$#" -gt 0 ]; do
    [ "$first" -eq 1 ] || printf ',' >> "$file"
    first=0
    printf '{"id":"%s","enabled":%s,"lastRunAt":%s,"lastScheduledFor":"%s","cronExpression":"0 * * * *","filePath":"/x","cwd":"/y"}' \
      "$1" "$2" "$3" "$scheduled" >> "$file"
    shift 3
  done
  printf ']}\n' >> "$file"
}

mkstore_scheduled() {
  local file=$1 id=$2 enabled=$3 last_run=$4 last_scheduled=$5 cron=$6
  printf '{"scheduledTasks":[{"id":"%s","enabled":%s,"lastRunAt":%s,"lastScheduledFor":%s,"cronExpression":"%s","filePath":"/x","cwd":"/y"}]}\n' \
    "$id" "$enabled" "$last_run" "$last_scheduled" "$cron" > "$file"
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

# Two different empty reads must stay DISTINGUISHABLE. Both exit 2, so an exit-code assertion
# alone leaves whichever guard runs second unpinned -- a later change could delete it and no
# test would notice. Pinning the diagnostic is what keeps both alive.
expect_msg() {
  local want=$1 needle=$2 label=$3; shift 3
  local got=0 out
  out=$("$SCRIPT" --store "$STORE" --projects "$PROJECTS" --now-epoch "$NOW" "$@" 2>&1) || got=$?
  asserts=$(( asserts + 1 ))
  [ "$got" = "$want" ] || note_fail "$label: expected exit $want, got $got"
  case "$out" in *"$needle"*) : ;; *) note_fail "$label: output did not mention '$needle'" ;; esac
}

# --- GREEN: a healthy lane must NOT fire -------------------------------------------------------
mkcase healthy
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect 0 "healthy dispatch with a producing session exits 0"

# --- RED: the scheduler stopped before dispatching another run ---------------------------------
# A healthy historical session is not evidence that the scheduler is still producing. The live
# store exposes the last slot it attempted plus the task's cron expression, so the next expected
# slot can be derived without relying on a new run row that a stopped scheduler will never write.
mkcase stopped_scheduler
last_slot=$(( NOW - NOW % 3600 - 3 * 3600 ))
last_run=$(( last_slot + 600 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$last_slot")\"" "0 * * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 1200 >/dev/null
expect 1 "a healthy old run does not mask an overdue hourly scheduler"

# The real Claude scheduler can delay a dispatch while its prior run is open. A delayed run and a
# next slot that is still inside the grace window remain healthy rather than false-firing.
mkcase delayed_inside_grace
last_slot=$(( NOW - NOW % 3600 - 3600 + 50 * 60 ))
last_run=$(( last_slot + 600 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$last_slot")\"" "50 * * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 1200 >/dev/null
expect 0 "an overlapping-run delay inside the next-slot grace stays healthy"

# Claude suppresses a dispatch when the previous run overlaps its next slot. A session that visibly
# spans that slot proves the scheduler's frozen anchor is an overlap skip, not a stopped scheduler;
# the next slot after the session becomes the first one the checker may require.
mkcase overlap_suppresses_dispatch
last_slot=$(( NOW - NOW % 3600 - 3600 ))
last_run=$(( last_slot + 60 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$last_slot")\"" "0 * * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 3700 >/dev/null
expect 0 "a producing session spanning the next slot defers the stopped-scheduler verdict"

# During a long tool call the transcript can be silent across the due slot. Claude's scheduler keeps
# polling and records per_task_limit samples while the run is open; a fresh sample beyond the slot is
# stronger overlap evidence than the transcript endpoint alone.
mkcase recorded_skip_suppresses_dispatch
last_slot=$(( NOW - NOW % 3600 - 3600 ))
last_run=$(( last_slot + 60 ))
printf '{"recordedSkips":{"alpha":[{"at":%s,"reason":"per_task_limit"}]},"scheduledTasks":[{"id":"alpha","enabled":true,"lastRunAt":"%s","lastScheduledFor":"%s","cronExpression":"0 * * * *","filePath":"/x","cwd":"/y"}]}\n' \
  "$(( (NOW - 60) * 1000 ))" "$(iso_at "$last_run")" "$(iso_at "$last_slot")" > "$STORE"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 1200 >/dev/null
expect 0 "a live per_task_limit sample covers a slot crossed during transcript silence"

# A schedule anchor must name the exact start of a cron minute. Silently accepting nonzero seconds
# shifts every derived deadline and can delay a stopped-scheduler verdict.
mkcase scheduled_seconds
last_slot=$(( NOW - NOW % 3600 ))
last_run=$(( last_slot + 60 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at $(( last_slot + 59 )))\"" "0 * * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 1200 >/dev/null
expect_msg 2 "does not name one of its slots" "a lastScheduledFor value with nonzero seconds is UNKNOWN"

# jq decodes JSON's escaped newline before this value reaches the evaluator. Reading just its first
# physical line would bless malformed schedule evidence as a valid hourly expression.
mkcase multiline_schedule
last_slot=$(( NOW - NOW % 3600 ))
last_run=$(( last_slot + 60 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$last_slot")\"" "0 * * * *\ninvalid"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 1200 >/dev/null
expect_msg 2 "unsupported cron expression" "a multiline cron expression is UNKNOWN"

# A last attempted slot cannot be materially later than the observer's clock. Accepting that value
# lets a healthy historical transcript mask a corrupted scheduler store until wall time catches up.
mkcase future_schedule_anchor
last_slot=$(( NOW - NOW % 3600 + 3600 ))
last_run=$(( NOW - 3600 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$last_slot")\"" "0 * * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 1200 >/dev/null
expect_msg 2 "future lastScheduledFor" "a future schedule anchor is UNKNOWN"

# A future transcript endpoint is not proof that one session covered every intervening scheduler
# slot. Without an observer-clock bound, corrupted transcript time can advance a stopped scheduler's
# required slot into the future and turn a known evidence defect into a false OK.
mkcase future_transcript_endpoint
last_slot=$(( NOW - NOW % 3600 - 3 * 3600 ))
last_run=$(( last_slot + 60 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$last_slot")\"" "0 * * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 \
  $(( NOW + 5 * 3600 - last_run - 1 )) >/dev/null
expect_msg 2 "future session endpoint" "a future transcript endpoint is UNKNOWN"

# Corruption in the same transcript invalidates its apparent turn count. The global dead-over-unknown
# rule applies across tasks; it must not reinterpret a corrupt endpoint and zero turns in one task as
# conclusive proof that this task failed to produce.
mkcase future_transcript_endpoint_zero_turns
last_slot=$(( NOW - NOW % 3600 - 3 * 3600 ))
last_run=$(( last_slot + 60 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$last_slot")\"" "0 * * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 0 \
  $(( NOW + 5 * 3600 - last_run - 1 )) >/dev/null
expect_msg 2 "future session endpoint" "a corrupt future endpoint outranks zero turns in the same transcript"

# Both cron shapes in the live store must be understood. Anything else is unproved scheduler state,
# never permission to fall back to the last healthy transcript.
mkcase daily_schedule
day_start=$(( NOW - NOW % 86400 ))
last_run=$(( day_start + 100 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$day_start")\"" "0 0,12 * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 1200 >/dev/null
expect 0 "the live twice-daily Improver cron shape derives its next slot"

# The Europe/Copenhagen clock falls back between the midnight and noon Improver slots on
# 2026-10-25. Noon is thirteen real hours after midnight that day, so nominal-hour arithmetic would
# false-fire for 45 minutes before the real noon slot plus grace had elapsed.
saved_now=$NOW
saved_tz=$TZ
NOW=$(epoch_utc '2026-10-25T11:05:00Z')
TZ=Europe/Copenhagen
mkcase daily_schedule_dst_fall
last_slot=$(epoch_utc '2026-10-24T22:00:00Z')
last_run=$(( last_slot + 100 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$last_slot")\"" "0 0,12 * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 1200 >/dev/null
expect 0 "the twice-daily schedule remains healthy across the autumn DST fallback"
NOW=$saved_now
TZ=$saved_tz

# Europe/Copenhagen has no 02:30 on the 2026 spring-forward day. The checker must skip that phantom
# slot and derive the next configured 14:30 run instead of reporting an outage after 02:45.
saved_now=$NOW
saved_tz=$TZ
NOW=$(epoch_utc '2026-03-29T03:00:00Z')
TZ=Europe/Copenhagen
mkcase daily_schedule_dst_spring_gap
last_slot=$(epoch_utc '2026-03-28T13:30:00Z')
last_run=$(( last_slot + 100 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$last_slot")\"" "30 2,14 * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 1200 >/dev/null
expect 0 "the daily schedule skips a nonexistent spring-forward slot"
NOW=$saved_now
TZ=$saved_tz

mkcase unsupported_schedule
last_slot=$(( NOW - NOW % 3600 ))
last_run=$(( last_slot + 60 ))
mkstore_scheduled "$STORE" alpha true "\"$(iso_at "$last_run")\"" \
  "\"$(iso_at "$last_slot")\"" "*/5 * * * *"
mksession "$PROJECTS/proj-a" alpha $(( last_run + 1 )) 40 1200 >/dev/null
expect_msg 2 "unsupported cron expression" "an unsupported cron expression is UNKNOWN"

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

# --- Zero turns is decisive on its own; a short span is not ------------------------------------
# This case previously expected 0, on the reasoning that both discriminators should be required. That
# was wrong, and it was the fail-open direction: a dispatch that reaches the model and then dies part
# way emits no assistant turn but easily outlasts the stub window, so requiring BOTH let exactly that
# run report OK (monorepo#3287). Zero assistant turns admits no benign reading -- the session produced
# nothing -- and an in-flight dispatch is already excluded by the grace window, so the span is
# reported for diagnosis rather than required for the verdict.
mkcase turns_only
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 0 1200 >/dev/null
expect 1 "0 turns is not producing however long the session lasted"

mkcase span_only
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 3 5 >/dev/null
expect 0 "a short span with real turns is NOT a stub (turn discriminator required)"

# --- REGRESSION: the escaped marker is what the runtime actually writes --------------------------
mkcase escaped_marker
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 escaped >/dev/null
expect 0 "a backslash-escaped marker is attributed (regression: unescaped-only matched nothing)"

# The deployed runtime starts with an enqueue record, before the user message.
# Exercise its actual envelope as well as the user-message representation.
# The runtime also opens a scheduled dispatch with a system-reminder block before the marker
# (monorepo#3320). Only complete leading reminder blocks may be skipped: a marker quoted inside one,
# following ordinary text after one, or following an unterminated one must still attribute nothing.
for queue_case in enqueue reminder_prefix reminder_quoted reminder_then_text reminder_unterminated \
    queue_example queue_suffix dequeue; do
  mkcase "$queue_case"
  mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\"" beta true "\"$(iso_at $(( NOW - 3600 )))\""
  mksession "$PROJECTS/proj-a" beta $(( NOW - 3599 )) 40 1200 >/dev/null
  candidate=$(mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200)
  jq -c --arg scenario "$queue_case" '
    if .type == "user" then
      {type: "queue-operation", operation: "enqueue", timestamp: .timestamp,
       sessionId: "synthetic", content: .message.content}
      | if $scenario == "queue_example" then .content = ("Explain this: " + .content)
        elif $scenario == "queue_suffix" then .content |= sub("alpha"; "alpha:unrelated")
        elif $scenario == "dequeue" then .operation = "dequeue"
        elif $scenario == "reminder_prefix" then
          .content = ("<system-reminder>\nYou are operating in a git worktree.\n</system-reminder>\n\n" + .content)
        elif $scenario == "reminder_quoted" then
          .content = ("<system-reminder>\nQuoted: " + .content + "\n</system-reminder>\n")
        elif $scenario == "reminder_then_text" then
          .content = ("<system-reminder>\nnotice\n</system-reminder>\nExplain this:\n" + .content)
        elif $scenario == "reminder_unterminated" then
          .content = ("<system-reminder>\nnotice\n" + .content)
        else . end
    else . end' "$candidate" > "$CASE/rewritten.jsonl"
  mv "$CASE/rewritten.jsonl" "$candidate"
  if [ "$queue_case" = "enqueue" ]; then
    expect 0 "a real queue enqueue envelope supplies the scheduled session"
  elif [ "$queue_case" = "reminder_prefix" ]; then
    expect 0 "a leading system-reminder block does not hide the scheduled session (regression: monorepo#3320)"
  else
    expect 1 "$queue_case cannot supply the scheduled session"
  fi
done

mkcase late_marker
# `beta` is healthy purely so the session index is NOT empty -- otherwise the unattributable-index
# guard fires first and this case would stop testing the bounded first-line read at all.
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\"" beta true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 late >/dev/null
mksession "$PROJECTS/proj-a" beta $(( NOW - 3599 )) 40 1200 >/dev/null
expect 1 "a marker on a later line is NOT attributed (the first-line read is deliberate)"

# --- REGRESSION: a broken/empty enumeration is UNKNOWN, never a verdict --------------------------
mkcase empty_projects
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
expect_msg 2 "no transcripts at all under" "no transcripts at all is UNKNOWN (regression: BSD find fail-open)"

# A candidate header that cannot be read is missing evidence, not an absent session.
# Keep beta readable so the nonempty index cannot hide a false NOT-PRODUCING verdict.
mkcase unreadable_header
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\"" beta true "\"$(iso_at $(( NOW - 3600 )))\""
candidate=$(mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200)
mksession "$PROJECTS/proj-a" beta $(( NOW - 3599 )) 40 1200 >/dev/null
real_head=$(command -v head)
mkdir -p "$CASE/bin"
cat > "$CASE/bin/head" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 3 ] && [ "$1" = "-n" ] && [ "$2" = "1" ] && [ "$3" = "$LIVENESS_DENIED_HEADER" ]; then
  exit 1
fi
exec "$LIVENESS_REAL_HEAD" "$@"
SH
chmod +x "$CASE/bin/head"
LIVENESS_REAL_HEAD="$real_head" LIVENESS_DENIED_HEADER="$CASE/absent.jsonl" PATH="$CASE/bin:$PATH" \
  expect 0 "the header-read shim preserves readable healthy transcripts"
LIVENESS_REAL_HEAD="$real_head" LIVENESS_DENIED_HEADER="$candidate" PATH="$CASE/bin:$PATH" \
  expect_msg 2 "claude-lane-liveness: UNKNOWN -- could not read a transcript header; cannot establish attribution" \
    "an unreadable candidate header is UNKNOWN even when another task keeps the index nonempty"

# --- Transcripts exist but none is attributable: UNKNOWN, not a fleet-wide verdict ---------------
# A changed task marker would empty the index while transcripts are plentiful. Reporting every task
# NOT-PRODUCING there accuses a healthy fleet on the strength of a parse that stopped matching.
mkcase unattributable
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"no marker here"}}\n' \
  "$(iso_at $(( NOW - 3599 )))" > "$PROJECTS/proj-a/interactive.jsonl"
touch -t "$(touch_at $(( NOW - 2399 )))" "$PROJECTS/proj-a/interactive.jsonl"
expect_msg 2 "task marker may have changed" "unattributable transcripts is UNKNOWN, with its own diagnostic"

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

# Schedule evidence follows the same precedence rule. One malformed cron must not prevent the
# transcript scan from surfacing another task whose settled dispatch produced zero turns.
mkcase transcript_dead_outranks_schedule_unknown
current_slot=$(( NOW - NOW % 3600 ))
printf '{"scheduledTasks":[{"id":"alpha","enabled":true,"lastRunAt":"%s","lastScheduledFor":"%s","cronExpression":"*/5 * * * *"},{"id":"beta","enabled":true,"lastRunAt":"%s","lastScheduledFor":"%s","cronExpression":"0 * * * *"}]}\n' \
  "$(iso_at $(( NOW - 3600 )))" "$(iso_at "$current_slot")" \
  "$(iso_at $(( NOW - 3600 )))" "$(iso_at "$current_slot")" > "$STORE"
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
mksession "$PROJECTS/proj-a" beta $(( NOW - 3599 )) 0 5 >/dev/null
expect 1 "a dead dispatch outranks an unrelated unsupported schedule"

# --- Disabled tasks ------------------------------------------------------------------------------
mkcase disabled_excluded
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\"" beta false "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect 0 "a disabled task is not judged (it does not dispatch)"
expect 2 "--task on a disabled task is UNKNOWN, not a verdict" --task beta

# A disabled record must never supply an enabled duplicate's dispatch timestamp.
mkcase disabled_duplicate
mkstore "$STORE" alpha false "\"$(iso_at $(( NOW - 40000 )))\"" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 39999 )) 40 1200 >/dev/null
expect 1 "an enabled dispatch cannot inherit a disabled duplicate's healthy session"
expect 1 "scoped lookup also ignores a disabled duplicate" --task alpha

# First-line text is not necessarily a runtime task marker. Keep beta healthy so the
# empty-index guard does not mask a false attribution of alpha's missing dispatch.
for marker_case in example_marker suffix_marker non_user_marker; do
  mkcase "$marker_case"
  mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\"" beta true "\"$(iso_at $(( NOW - 3600 )))\""
  mksession "$PROJECTS/proj-a" beta $(( NOW - 3599 )) 40 1200 >/dev/null
  candidate=$(mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200)
  case "$marker_case" in
    example_marker) filter='if .type == "user" then .message.content = ("Explain this example: " + .message.content) else . end' ;;
    suffix_marker) filter='if .type == "user" then .message.content |= sub("alpha"; "alpha:unrelated") else . end' ;;
    non_user_marker) filter='if .type == "user" then .type = "assistant" | .message.role = "assistant" else . end' ;;
  esac
  jq -c "$filter" "$candidate" > "$CASE/rewritten.jsonl"
  mv "$CASE/rewritten.jsonl" "$candidate"
  expect 1 "$marker_case cannot supply a scheduled session"
done

# Invalid JSON with a task-marker candidate cannot establish either attribution
# or absence. Preserve UNKNOWN instead of treating a failed parse as no session.
mkcase malformed_marker_json
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\"" beta true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" beta $(( NOW - 3599 )) 40 1200 >/dev/null
printf '{broken <scheduled-task name="alpha">\n' > "$PROJECTS/proj-a/broken.jsonl"
expect 2 "a malformed marker-bearing candidate is UNKNOWN"

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

# --- Malformed enabled task IDs are UNKNOWN, never a verdict --------------------------------------
# Field presence is not field validity. Each of these reaches a verdict without the assertions:
# an unmatched id reports NOT-PRODUCING, and a duplicate is masked by the first record's lastRunAt.
mkcase dup_id
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\"" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect_msg 2 "duplicate enabled task id" "a duplicate enabled task id is UNKNOWN (a later dispatch would be masked)"

mkcase null_id
printf '{"scheduledTasks":[{"id":null,"enabled":true,"lastRunAt":"%s","lastScheduledFor":"%s","cronExpression":"0 * * * *"}]}\n' \
  "$(iso_at $(( NOW - 3600 )))" "$(iso_at $(( NOW - NOW % 3600 )))" > "$STORE"
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect_msg 2 "is not a string" "a non-string enabled task id is UNKNOWN"

mkcase weird_id
printf '{"scheduledTasks":[{"id":"a;b","enabled":true,"lastRunAt":"%s","lastScheduledFor":"%s","cronExpression":"0 * * * *"}]}\n' \
  "$(iso_at $(( NOW - 3600 )))" "$(iso_at $(( NOW - NOW % 3600 )))" > "$STORE"
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect_msg 2 "unusable enabled task id" "an unsupported enabled task id is UNKNOWN"

# --- An attributable but unreadable transcript is UNKNOWN for THAT task --------------------------
# `beta` is healthy so the index is non-empty and the run reaches the per-task match. `alpha`'s only
# transcript carries alpha's marker but no readable timestamp, so alpha's dispatch is unprovable --
# NOT-PRODUCING there would be a verdict about the parse rather than about the lane.
mkcase unreadable_attributable
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\"" beta true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" beta $(( NOW - 3599 )) 40 1200 >/dev/null
bsq='\"'
printf '{"type":"user","timestamp":"not-a-timestamp","message":{"role":"user","content":"<scheduled-task name=%s%s%s>"}}\n' \
  "$bsq" alpha "$bsq" > "$PROJECTS/proj-a/alpha-broken.jsonl"
touch -t "$(touch_at $(( NOW - 2399 )))" "$PROJECTS/proj-a/alpha-broken.jsonl"
expect_msg 2 "could not be parsed" "an attributable but unreadable transcript is UNKNOWN for that task"

# --- RED: the runtime's own error message is not an assistant turn --------------------------------
# When the account hits a usage limit, the runtime ends the session by writing ONE record of type
# `assistant` that it synthesised itself: `isApiErrorMessage: true`, an `error` class, and model
# `<synthetic>`. Counted as a turn, it made an account-wide quota outage read OK on every task for a
# day (monorepo#3412). Shape copied from a real 2026-09-19 transcript; message text omitted.
append_synthetic() {
  local f=$1 at=$2 err=$3 mt
  mt=$(iso_at "$at")
  printf '{"type":"assistant","timestamp":"%s","isApiErrorMessage":true,"error":"%s","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"limit"}]}}\n' \
    "$mt" "$err" >> "$f"
  touch -t "$(touch_at "$at")" "$f"
}

mkcase quota_killed
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
f=$(mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 0 1)
append_synthetic "$f" $(( NOW - 3598 )) rate_limit
expect_msg 1 "cause=quota/billing" "a session holding only a synthetic rate_limit message is NOT-PRODUCING, cause quota/billing"

mkcase synthetic_unclassified
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
f=$(mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 0 1)
append_synthetic "$f" $(( NOW - 3598 )) something_new
expect_msg 1 "cause=unknown" "an unrecognised synthetic error class is NOT-PRODUCING with cause unknown"

# GREEN control: a run that did real work and THEN hit the limit produced output. Discounting the
# synthetic record must not discount the work before it.
mkcase worked_then_limited
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
f=$(mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200)
append_synthetic "$f" $(( NOW - 2399 )) rate_limit
expect 0 "real turns followed by a synthetic limit message stay OK"

# --- Knob validation: a zero window must never disable the guard ---------------------------------
mkcase knobs
mkstore "$STORE" alpha true "\"$(iso_at $(( NOW - 3600 )))\""
mksession "$PROJECTS/proj-a" alpha $(( NOW - 3599 )) 40 1200 >/dev/null
expect 2 "--grace-seconds 0 is refused" --grace-seconds 0
expect 2 "--skew-seconds 0 is refused" --skew-seconds 0
expect 2 "--lookback-hours 0 is refused" --lookback-hours 0
expect 2 "a non-numeric knob is refused" --skew-seconds abc
# --stub-seconds was removed with the span conjunct: the verdict is now `turns == 0` alone, so the
# knob decided nothing. It is asserted as an UNRECOGNISED ARGUMENT rather than left in the knob list,
# where it would keep passing on the unknown-option path while its label claimed a window was being
# validated -- a test that passes for a reason other than the one it names.
expect 2 "--stub-seconds is gone and refused as unrecognised" --stub-seconds 60
expect 2 "an unrecognised argument is refused" --nope
expect 2 "an unusable task id is refused" --task 'a;b'

echo "claude-lane-liveness.test.sh: $asserts assertion(s), $fails failure(s)"
[ "$fails" -eq 0 ] || exit 1
