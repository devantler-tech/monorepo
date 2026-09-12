#!/usr/bin/env bash
# claude-lane-liveness.sh — did the Claude lane's dispatched runs actually RUN?
#
# The Claude counterpart to codex-lane-liveness.sh, and it exists for the same reason: *Agent
# definition locations* resolves Claude cadence from a `scheduled-tasks.json` record with `lastRunAt`
# as its marker, and that marker records only that a dispatch STARTED. When a dispatched run dies
# immediately, `lastRunAt` advances exactly as it does on a healthy run, so every prescribed check
# reports a healthy lane while that lane produces nothing.
#
# monorepo#3268 made an Improver prove its sibling lane is producing before treating that sibling's
# ledger as evidence, and named codex-lane-liveness.sh as the check. That is correct for the Claude
# Improver, whose sibling is Codex. It is unsatisfiable for the CODEX Improver, whose sibling is
# Claude: no Claude-lane check existed, so that direction was `2 UNKNOWN` by construction and could
# never reach a positive verdict. This closes that half. See monorepo#3269.
#
# WHY THIS CANNOT MIRROR THE CODEX CHECK
# Codex records every run in a scheduler table with a duration and an inbox flag, so a stub is visible as
# a row. Claude's store keeps NO run history at all -- one `lastRunAt` per task -- and a dispatch that
# dies does not necessarily leave an attributable transcript: the `<scheduled-task ...>` marker that
# identifies which task a session belongs to is written with the run's first user message, and a
# transcript that never got that far carries no marker (verified on a real 7-line stub transcript:
# zero markers, zero assistant turns). Classifying transcripts alone therefore cannot see a dead
# dispatch, because the dead one is exactly the transcript that cannot be attributed.
#
# So the anchor is the DISPATCH, not the transcript: `lastRunAt` is authoritative for "a dispatch
# happened", and a healthy dispatch's session starts within about a second of it (measured ~1.0s on
# both tasks). ABSENCE of a session at that anchor is itself the signal, and it needs no marker on
# the failed run.
#
# READ-ONLY, and deliberately NARROW. Session transcripts contain the entire content of every run --
# code, credentials in tool output, private operator reasoning. This check reads ONLY:
#   - the `<scheduled-task name=...>` marker on the transcript's first line, to attribute it, and
#   - `.timestamp` and `.type` values, to time it and count assistant turns.
# It never reads message content, and never emits anything from a transcript into its own output.
#
# Usage: claude-lane-liveness.sh [--store PATH] [--projects PATH] [--task ID]
#                               [--grace-seconds N] [--skew-seconds N]
#                               [--lookback-hours N] [--now-epoch S] [--quiet]
#
# Exit 0  every enabled task checked produced work on its most recent settled dispatch
#      1  NOT PRODUCING -- a dispatch happened and produced no work
#      2  UNKNOWN -- could not determine (no jq, absent/ambiguous store, absent projects root,
#         unparsable record, or the newest dispatch still in flight)
#
# Any OTHER non-zero status is an unexpected internal failure under `set -e` and also means UNKNOWN.
# Only 0 and 1 are verdicts. Exit 2 is deliberately NOT exit 0: "I could not check" and "the lane is
# alive" are different answers, and collapsing them is how a liveness check becomes decoration.

set -Eeuo pipefail

# Exit 1 is a VERDICT, so no internal failure may reach it. Under `set -e` the abort status is the
# failing command's, and 1 is the commonest -- a failing `date` or a closed stdout would otherwise
# report a dead lane. Any unhandled error becomes 2.
trap 'ec=$?; [ "$ec" -eq 0 ] || exit 2' ERR

STORE="${CLAUDE_SCHEDULE_STORE_PATH:-}"
STORE_ROOT="${CLAUDE_SCHEDULE_STORE_ROOT:-$HOME/Library/Application Support/Claude/claude-code-sessions}"
PROJECTS="${CLAUDE_PROJECTS_ROOT:-$HOME/.claude/projects}"
TASK=""
TASK_SET=0
GRACE_SECONDS=900
SKEW_SECONDS=120
LOOKBACK_HOURS=72
NOW_EPOCH=""
QUIET=0

RECOVERY="
  To resolve: confirm the lane's dispatched runs are reaching the model at all. A dead dispatch still
  advances lastRunAt, so look at whether a session exists for that dispatch rather than at the
  scheduler's own view. Re-run this check once the newest dispatch has had time to settle."

usage() { sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; }

die_unknown() {
  printf 'claude-lane-liveness: UNKNOWN -- %s\n' "$1" >&2
  printf '%s\n' "$RECOVERY" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --store) [ "$#" -ge 2 ] || die_unknown "--store needs a value"; STORE="$2"; shift 2 ;;
    --projects) [ "$#" -ge 2 ] || die_unknown "--projects needs a value"; PROJECTS="$2"; shift 2 ;;
    --task) [ "$#" -ge 2 ] || die_unknown "--task needs a value"; TASK="$2"; TASK_SET=1; shift 2 ;;
    --grace-seconds) [ "$#" -ge 2 ] || die_unknown "--grace-seconds needs a value"; GRACE_SECONDS="$2"; shift 2 ;;
    --skew-seconds) [ "$#" -ge 2 ] || die_unknown "--skew-seconds needs a value"; SKEW_SECONDS="$2"; shift 2 ;;
    --lookback-hours) [ "$#" -ge 2 ] || die_unknown "--lookback-hours needs a value"; LOOKBACK_HOURS="$2"; shift 2 ;;
    --now-epoch) [ "$#" -ge 2 ] || die_unknown "--now-epoch needs a value"; NOW_EPOCH="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) die_unknown "unrecognised argument: $1" ;;
  esac
done

# Every numeric knob is validated before use. An unvalidated value would otherwise reach arithmetic
# and either abort under `set -e` or silently widen a window until the check cannot fire.
for pair in "GRACE_SECONDS:$GRACE_SECONDS" \
            "SKEW_SECONDS:$SKEW_SECONDS" "LOOKBACK_HOURS:$LOOKBACK_HOURS"; do
  name=${pair%%:*}; val=${pair#*:}
  case "$val" in ''|*[!0-9]*) die_unknown "$name must be a non-negative integer, got: $val" ;; esac
done
# Each carries a floor of 1, because 0 defeats the invariant it exists to hold:
# --grace-seconds 0 classifies a dispatch that is still in flight -- the trap the settled window
# closes; --skew-seconds 0 requires a session to start in the same second as its dispatch,
# which no real dispatch does (~1.0s measured), so every healthy lane would read NOT PRODUCING;
# --lookback-hours 0 enumerates nothing, so every task reads as having no session.
[ "$GRACE_SECONDS" -ge 1 ] || die_unknown "--grace-seconds must be at least 1"
[ "$SKEW_SECONDS" -ge 1 ] || die_unknown "--skew-seconds must be at least 1"
[ "$LOOKBACK_HOURS" -ge 1 ] || die_unknown "--lookback-hours must be at least 1"

if [ -n "$NOW_EPOCH" ]; then
  case "$NOW_EPOCH" in ''|*[!0-9]*) die_unknown "--now-epoch must be a non-negative integer, got: $NOW_EPOCH" ;; esac
else
  NOW_EPOCH=$(date +%s)
fi

command -v jq >/dev/null 2>&1 || die_unknown "jq is not available"

# BSD and GNU `date` spell absolute-time parsing differently and neither accepts the other's form, so
# the conversion is attempted both ways and validated. An unparsable timestamp must never fall
# through to a verdict: it returns empty and every caller treats that as UNKNOWN.
iso_to_epoch() {
  local raw=$1 base out
  base=${raw%%.*}          # drop fractional seconds
  base=${base%Z}           # drop the zone marker; the record is always UTC
  case "$base" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) : ;;
    *) return 0 ;;
  esac
  out=$(date -u -d "${base}Z" +%s 2>/dev/null) || out=""
  if [ -z "$out" ]; then
    out=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null) || out=""
  fi
  case "$out" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$out"
}

# The store is discovered the same way agent-telemetry.sh discovers it, and requires EXACTLY ONE
# match. Two candidate stores mean two plausible answers about the same lane, and picking either is
# a guess; that fails closed rather than reporting a lane's health from an arbitrary file.
if [ -z "$STORE" ]; then
  matches=0; selected=""
  for candidate in "$STORE_ROOT"/*/*/scheduled-tasks.json; do
    [ -f "$candidate" ] || continue
    jq -e '[.scheduledTasks[]? | select(.enabled == true) | .id] | length > 0' "$candidate" >/dev/null 2>&1 || continue
    selected="$candidate"; matches=$((matches + 1))
  done
  [ "$matches" -eq 1 ] || die_unknown "expected exactly one Claude scheduled-tasks store under $STORE_ROOT, found $matches"
  STORE="$selected"
fi

[ -f "$STORE" ] || die_unknown "scheduled-tasks store not found: $STORE"
[ -r "$STORE" ] || die_unknown "scheduled-tasks store is not readable: $STORE"
jq -e . "$STORE" >/dev/null 2>&1 || die_unknown "scheduled-tasks store is not valid JSON: $STORE"
[ -d "$PROJECTS" ] || die_unknown "projects root not found: $PROJECTS"
[ -r "$PROJECTS" ] || die_unknown "projects root is not readable: $PROJECTS"

# Schema is asserted, never assumed. A renamed field would otherwise make every lookup below return
# empty, and empty reads exactly like "nothing to report" -- a silent pass in the case this exists for.
jq -e 'has("scheduledTasks") and (.scheduledTasks | type == "array")' "$STORE" >/dev/null 2>&1 \
  || die_unknown "unexpected store schema: .scheduledTasks is missing or not an array"
for field in id enabled lastRunAt; do
  jq -e --arg f "$field" 'all(.scheduledTasks[]?; has($f))' "$STORE" >/dev/null 2>&1 \
    || die_unknown "unexpected store schema: a scheduled task is missing .$field"
done

# Field PRESENCE is not field VALIDITY. Two malformed-store shapes reach a verdict otherwise,
# and both fail OPEN in the direction that matters:
#   - a non-string or unsupported id (null, a number, a value with characters the marker parser
#     cannot produce) can never match a session, so the task reports NOT-PRODUCING;
#   - a DUPLICATE enabled id is evaluated once per occurrence while the lastRunAt lookup below
#     returns the FIRST record every time, so a second, dead dispatch is masked by an earlier
#     healthy one and the check exits 0.
# Both are unprovable stores rather than lanes, so both are UNKNOWN. The two conditions are
# asserted SEPARATELY rather than joined, so neither depends on jq's short-circuit behaviour:
# `test` on a non-string raises, which would abort the run instead of reporting UNKNOWN.
jq -e '[.scheduledTasks[]? | select(.enabled == true) | .id] | all(type == "string")' "$STORE" >/dev/null 2>&1 \
  || die_unknown "unexpected store schema: an enabled task id is not a string"
jq -e '[.scheduledTasks[]? | select(.enabled == true) | .id] | all(test("^[A-Za-z0-9._-]+$"))' "$STORE" >/dev/null 2>&1 \
  || die_unknown "unusable enabled task id in $STORE (only A-Za-z0-9._- are supported)"
jq -e '[.scheduledTasks[]? | select(.enabled == true) | .id] | length == (unique | length)' "$STORE" >/dev/null 2>&1 \
  || die_unknown "duplicate enabled task id in $STORE -- a later dispatch would be masked by an earlier record"

if [ "$TASK_SET" -eq 1 ]; then
  [ -n "$TASK" ] || die_unknown "--task must not be empty"
  case "$TASK" in *[!A-Za-z0-9._-]*) die_unknown "unusable task id: $TASK" ;; esac
  # A named task is held to the SAME enabled filter the unfiltered branch applies. A disabled task
  # does not dispatch, so judging it would report NOT PRODUCING for something not meant to produce --
  # a false positive on the one verdict this check makes, so it fails closed.
  ok=$(jq -r --arg t "$TASK" '[.scheduledTasks[]? | select(.id == $t and .enabled == true)] | length' "$STORE") \
    || die_unknown "could not look up task $TASK"
  [ "$ok" = "1" ] || die_unknown "task $TASK is not a single enabled task in $STORE"
  ids=$TASK
else
  ids=$(jq -r '[.scheduledTasks[]? | select(.enabled == true) | .id] | sort | .[]' "$STORE") \
    || die_unknown "could not enumerate scheduled tasks"
fi
[ -n "$ids" ] || die_unknown "no enabled scheduled tasks found in $STORE"

# Enumerated once, not per task. `find` over the projects root is the expensive step here (the
# per-session worktree layout leaves hundreds of project directories behind), and the marker read is
# bounded to the transcript's FIRST LINE -- measured to be where the marker always sits, and the only
# line that can be read without touching run content.
SESSION_INDEX=$(mktemp) || die_unknown "could not create a temporary file"
FILELIST=$(mktemp) || die_unknown "could not create a temporary file"
TIMEREF=$(mktemp) || die_unknown "could not create a temporary file"
UNPARSABLE=$(mktemp) || die_unknown "could not create a temporary file"

trap 'rm -f "$SESSION_INDEX" "$FILELIST" "$TIMEREF" "$UNPARSABLE"' EXIT

# `find -newermt @<epoch>` is GNU-only syntax. BSD find -- which is what /usr/bin/find is on the
# deployment host -- rejects it outright with "Can't parse date/time", and with stderr suppressed
# that failure is INDISTINGUISHABLE from "no transcripts matched". The enumeration then comes back
# empty, every task reads as having no session for its dispatch, and the check reports a fabricated
# NOT-PRODUCING for a completely healthy lane. Measured exactly that way on first run.
# A reference file plus `-newer` is portable to both finds, and `touch -t` takes LOCAL time, which is
# what `date` without -u prints -- so the two agree without a timezone correction.
epoch_to_touch() {
  local e=$1 out
  out=$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null) || out=""
  if [ -z "$out" ]; then out=$(date -d "@$e" +%Y%m%d%H%M.%S 2>/dev/null) || out=""; fi
  case "$out" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9]) printf '%s\n' "$out" ;;
    *) return 0 ;;
  esac
}
cutoff_stamp=$(epoch_to_touch "$(( NOW_EPOCH - LOOKBACK_HOURS * 3600 ))")
[ -n "$cutoff_stamp" ] || die_unknown "could not render the lookback cutoff as a touch timestamp"
touch -t "$cutoff_stamp" "$TIMEREF" 2>/dev/null \
  || die_unknown "could not stamp the lookback reference file"

# The exit status is CHECKED rather than assigned inside a command substitution: an assignment there
# runs in a subshell and can never propagate, which is how the first version of this reported a
# broken enumeration as a successful empty one.
find "$PROJECTS" -maxdepth 2 -name '*.jsonl' -type f -newer "$TIMEREF" > "$FILELIST" 2>/dev/null \
  || die_unknown "could not enumerate transcripts under $PROJECTS"

# An EMPTY enumeration is UNKNOWN, never a verdict. Zero transcripts in the whole lookback window
# means the projects root is wrong, unreadable, or the filter broke -- an infrastructure fault. The
# lane cannot be judged dead on the strength of a read that found nothing at all, which is the same
# "an empty filtered read is a claim about the filter" rule the contract applies everywhere else.
[ -s "$FILELIST" ] \
  || die_unknown "no transcripts at all under $PROJECTS in the last ${LOOKBACK_HOURS}h -- cannot judge"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  # An unreadable header cannot establish either task attribution or absence.
  line1=$(head -n 1 "$f" 2>/dev/null) \
    || die_unknown "could not read a transcript header; cannot establish attribution"
  case "$line1" in *'<scheduled-task name='*) : ;; *) continue ;; esac
  # Decode the first enqueue event or user message before recognizing its opening task marker. A
  # quoted example elsewhere in that message, another record type, or a prefix
  # of an unsupported task name must not supply evidence for a scheduled run.
  # The runtime opens a scheduled dispatch with system-reminder blocks (a worktree notice), so only
  # COMPLETE leading reminder blocks and the whitespace after them are skipped before the anchored
  # match (monorepo#3320). Nothing else is skipped: a marker quoted inside a reminder, after ordinary
  # text, or after an unterminated reminder still attributes nothing.
  printf '%s' "$line1" | jq -e 'true' >/dev/null 2>&1 \
    || die_unknown "a task-marker candidate is not valid JSON; cannot establish attribution"
  nm=$(printf '%s' "$line1" | jq -er '
    select(type == "object")
    | if .type == "queue-operation" and .operation == "enqueue" then .content
      elif .type == "user" and .message.role == "user" then .message.content
      else empty end
    | select(type == "string")
    | sub("^(<system-reminder>[\\s\\S]*?</system-reminder>[[:space:]]*)+"; "")
    | capture("^<scheduled-task name=\"(?<id>[A-Za-z0-9._-]+)\"([[:space:]]|>)").id
  ' 2>/dev/null) || nm=""
  [ -n "$nm" ] || continue
  start=$(printf '%s' "$line1" | jq -r 'select(.timestamp) | .timestamp' 2>/dev/null | head -1) || start=""
  if [ -z "$start" ]; then
    start=$(head -n 40 "$f" 2>/dev/null | jq -rs '[.[] | select(.timestamp) | .timestamp] | sort | first // empty' 2>/dev/null) || start=""
  fi
  # ATTRIBUTABLE but unreadable. The marker already told us which task this transcript
  # belongs to, so dropping it silently is not neutral: that task then reaches the match
  # step with nothing, and reports NOT-PRODUCING on evidence that was malformed rather
  # than absent -- a verdict about the parse, not about the lane. Record the task so the
  # verdict loop can answer UNKNOWN instead.
  if [ -z "$start" ]; then printf '%s\n' "$nm" >> "$UNPARSABLE"; continue; fi
  se=$(iso_to_epoch "$start")
  if [ -z "$se" ]; then printf '%s\n' "$nm" >> "$UNPARSABLE"; continue; fi
  printf '%s\t%s\t%s\n' "$nm" "$se" "$f" >> "$SESSION_INDEX"
done < "$FILELIST"

# Transcripts exist but NONE is attributable to any scheduled task. The likeliest cause is not
# a dead lane but a changed marker: the `<scheduled-task ...>` block is undocumented runtime
# internals, so a rename or reformat would leave every task with no session and report the
# WHOLE FLEET as not producing at once. That is the same wrong-verdict class the empty-file-list
# guard above closes, one level in.
# The trade-off is deliberate and costs little: a genuine outage lasting the entire lookback
# window would also empty this index and now reports UNKNOWN rather than NOT-PRODUCING. Both
# fail closed identically for the consumer -- neither is ever read as producing -- so the only
# loss is crispness, against a false accusation that would send a run escalating a healthy lane.
[ -s "$SESSION_INDEX" ] \
  || die_unknown "no transcript in the last ${LOOKBACK_HOURS}h is attributable to a scheduled task -- the task marker may have changed; cannot judge"

any_dead=0
any_unknown=0
report=""

while IFS= read -r id; do
  if [ -z "$id" ]; then
    report="${report}  UNKNOWN  <blank task id> -- cannot judge
"
    any_unknown=1; continue
  fi
  last_run=$(jq -r --arg t "$id" 'first(.scheduledTasks[]? | select(.id == $t and .enabled == true) | .lastRunAt) // empty' "$STORE") || last_run=""
  if [ -z "$last_run" ] || [ "$last_run" = "null" ]; then
    report="${report}  UNKNOWN  ${id} -- no lastRunAt recorded, never dispatched or store incomplete
"
    any_unknown=1; continue
  fi
  lr=$(iso_to_epoch "$last_run")
  if [ -z "$lr" ]; then
    report="${report}  UNKNOWN  ${id} -- unparsable lastRunAt, cannot judge
"
    any_unknown=1; continue
  fi
  # A dispatch OLDER than the lookback window cannot have its session enumerated, because the
  # transcript sweep is bounded by that window. Judging it would report NOT-PRODUCING purely
  # because the evidence was filtered out -- a verdict about the filter, not about the lane. A
  # lane whose newest dispatch is that old has its own problem, but this check cannot see it.
  if [ "$lr" -lt $(( NOW_EPOCH - LOOKBACK_HOURS * 3600 )) ]; then
    report="${report}  UNKNOWN  ${id} -- newest dispatch predates the ${LOOKBACK_HOURS}h lookback window, cannot judge
"
    any_unknown=1; continue
  fi
  # An in-flight dispatch is NOT classified. Its session has barely started, so it has few or no
  # assistant turns and a span of seconds -- indistinguishable from a stub. Most acutely, a run that
  # invokes this check on its OWN lane would classify itself dead every time.
  if [ "$lr" -gt $(( NOW_EPOCH - GRACE_SECONDS )) ]; then
    report="${report}  UNKNOWN  ${id} -- newest dispatch is still within the ${GRACE_SECONDS}s grace window, cannot judge
"
    any_unknown=1; continue
  fi

  match=$(awk -F'\t' -v id="$id" -v lr="$lr" -v skew="$SKEW_SECONDS" '
    $1 == id { d = $2 - lr; if (d < 0) d = -d; if (d <= skew && (best == "" || d < bestd)) { bestd = d; best = $3 } }
    END { if (best != "") print best }' "$SESSION_INDEX") || match=""

  if [ -z "$match" ]; then
    # No session matched. Before calling that NOT-PRODUCING, check whether a transcript that WAS
    # attributable to this task had to be discarded for being unreadable: if so the dispatch is
    # unprovable rather than unproductive, and the honest answer is UNKNOWN.
    if grep -qxF -- "$id" "$UNPARSABLE" 2>/dev/null; then
      report="${report}  UNKNOWN  ${id} -- an attributable transcript could not be parsed, so the dispatch is unprovable
"
      any_unknown=1; continue
    fi
    report="${report}  NOT-PRODUCING  ${id} -- dispatched at ${last_run} and no session started within ${SKEW_SECONDS}s of it
"
    any_dead=1; continue
  fi

  # Read the candidate whole, but for two scalars only: how many assistant turns it produced and how
  # long it spanned. Only the TURN COUNT decides -- see the verdict below. The span is carried for the
  # diagnostic line, so a reader can tell a four-second death from an hour-long one, and it must not
  # be reintroduced as a second required condition: a run that dies part way produces no assistant
  # turn while easily outlasting any stub window, so requiring both reported a dead lane as healthy
  # (monorepo#3287).
  stats=$(jq -rs '
      [.[] | select(type == "object")] as $r
      | ([$r[] | select(.type == "assistant")] | length) as $a
      | ([$r[] | select(.timestamp) | .timestamp] | sort) as $t
      | "\($a)\t\($t | first // "")\t\($t | last // "")"' "$match" 2>/dev/null) || stats=""
  if [ -z "$stats" ]; then
    report="${report}  UNKNOWN  ${id} -- session transcript could not be parsed, cannot judge
"
    any_unknown=1; continue
  fi
  turns=${stats%%$'\t'*}; rest=${stats#*$'\t'}
  t_first=${rest%%$'\t'*}; t_last=${rest##*$'\t'}
  case "$turns" in ''|*[!0-9]*) turns="" ;; esac
  fe=$(iso_to_epoch "$t_first"); le=$(iso_to_epoch "$t_last")
  if [ -z "$turns" ] || [ -z "$fe" ] || [ -z "$le" ] || [ "$le" -lt "$fe" ]; then
    report="${report}  UNKNOWN  ${id} -- unparsable session timings or turn count, cannot judge
"
    any_unknown=1; continue
  fi
  span=$(( le - fe ))

  # ZERO ASSISTANT TURNS IS THE WHOLE TEST -- the span is reported, never required. A session that
  # emitted no assistant turn produced nothing whether it died in four seconds or hung for an hour,
  # and pairing the two as a conjunction meant a dispatch that died PART WAY fell through to OK, which
  # is the one verdict this check exists to prevent (monorepo#3287). Unlike the Codex store's
  # inbox flag -- where a long run really can do work without writing one -- `turns == 0` admits no
  # benign reading, and an in-flight dispatch is already excluded by the grace window above, so
  # nothing here can be a run that simply has not got going yet.
  if [ "$turns" -eq 0 ]; then
    report="${report}  NOT-PRODUCING  ${id} -- dispatched at ${last_run}, session produced 0 assistant turns in ${span}s
"
    any_dead=1
  else
    report="${report}  OK  ${id} -- dispatched at ${last_run}, session produced ${turns} assistant turn(s) over ${span}s
"
  fi
done <<EOF
$ids
EOF

if [ "$QUIET" -eq 0 ]; then
  printf 'claude-lane-liveness: store=%s grace=%ss skew<=%ss lookback=%sh\n' \
    "$STORE" "$GRACE_SECONDS" "$SKEW_SECONDS" "$LOOKBACK_HOURS"
  printf '%s' "$report"
fi

# A detected dead lane OUTRANKS an unjudgeable one: exit 1 is actionable now, and letting an UNKNOWN
# elsewhere mask it would hide the very condition this check exists to surface.
if [ "$any_dead" -eq 1 ]; then
  printf 'claude-lane-liveness: NOT PRODUCING -- a dispatched lane is not doing work.\n' >&2
  printf '%s\n' "$RECOVERY" >&2
  exit 1
fi
if [ "$any_unknown" -eq 1 ]; then
  printf 'claude-lane-liveness: UNKNOWN -- at least one task could not be judged.\n' >&2
  exit 2
fi
exit 0
