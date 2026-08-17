#!/usr/bin/env bash
# codex-lane-liveness.sh — did the Codex lane's dispatched runs actually RUN?
#
# *Agent definition locations* resolves Codex cadence and its dispatch marker from an automation's
# `rrule` and `last_run_at`. Neither observes the turn. When every dispatched run dies seconds after
# starting, the scheduler still dispatches on time, so `last_run_at` advances and `next_run_at` stays
# correct — and the prescribed check reports a healthy lane while that lane produces nothing at all.
#
# Measured 2026-08-17 on the local scheduler store: 32 consecutive dead dispatches over ~29h across
# BOTH Codex automations (3 `agent-improver`, 29 `daily-ai-engineer`), entirely undetected. The prior
# fortnight's healthy `agent-improver` runs ran 768-24,428s and each wrote an inbox item, against
# 4-second stubs that wrote none. See monorepo#2885.
#
# Two pre-existing signals independently fail to catch this, which is why a third is needed:
#   - `notification_policy = "failed_runs_only"` never fires: the scheduler records these runs
#     PENDING_REVIEW, the SAME status healthy runs carry. Status cannot discriminate.
#   - `last_run_at` records that a dispatch STARTED, never that it ran.
#
# READ-ONLY, and deliberately NARROW in what it reads. It selects run timings and a computed
# inbox-presence FLAG only — never `last_error`, `inbox_summary`, `thread_title`, or any archived
# message. The cause of a stall is frequently private runtime state (billing, credentials, account
# posture); this check is about the deployment being BLIND, so it must stay generic across causes and
# must not be able to carry such state into a repository artifact or a run report.
#
# Usage: codex-lane-liveness.sh [--store PATH] [--automation ID] [--grace-seconds N]
#                              [--stub-seconds N] [--consecutive N] [--now-ms MS] [--quiet]
#
# Exit 0  every ACTIVE automation checked has a healthy run among its newest settled runs
#      1  NOT PRODUCING — some automation's newest settled runs are ALL stubs
#      2  UNKNOWN — could not determine (no sqlite3, unreadable/absent store, unexpected schema,
#         an unusable automation id, or too little settled history to judge)
#
# Any OTHER non-zero status is an unexpected internal failure under `set -e` and also means UNKNOWN.
# Only 0 and 1 are verdicts. Exit 2 is deliberately NOT exit 0: "I could not check" and "the lane is
# alive" are different answers, and collapsing them is how a liveness check becomes decoration —
# which is precisely the failure this script exists to correct.
#
# Exit 1 requires BOTH discriminators on EVERY run in the window. Duration alone fires on a
# legitimately fast run; inbox-presence alone fires on a run that wrote nothing for a benign reason.
# Requiring both, on consecutive runs, is what keeps a real verdict rare enough to act on.

set -Eeuo pipefail

# Exit 1 is a VERDICT ("this lane is not producing"), so no internal failure may reach it. Under
# `set -e` the abort status is the failing command's, and 1 is the commonest — a failing `date` or a
# closed stdout would otherwise page an operator for a dead lane. Any unhandled error becomes 2.
trap 'ec=$?; [ "$ec" -eq 0 ] || exit 2' ERR

STORE="${CODEX_HOME:-$HOME/.codex}/sqlite/codex-dev.db"
AUTOMATION=""
GRACE_SECONDS=300
STUB_SECONDS=60
CONSECUTIVE=2
NOW_MS=""
QUIET=0

RECOVERY="
  To resolve: confirm the lane's runs are reaching the model at all. A stub run is a dispatch whose
  turn ended immediately, so look at the runtime's own run record rather than the scheduler's — the
  scheduler's view is healthy by construction here. Re-run this check once a run has settled."

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

die_unknown() {
  printf 'codex-lane-liveness: UNKNOWN — %s\n' "$1" >&2
  printf '%s\n' "$RECOVERY" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --store) [ "$#" -ge 2 ] || die_unknown "--store needs a value"; STORE="$2"; shift 2 ;;
    --automation) [ "$#" -ge 2 ] || die_unknown "--automation needs a value"; AUTOMATION="$2"; shift 2 ;;
    --grace-seconds) [ "$#" -ge 2 ] || die_unknown "--grace-seconds needs a value"; GRACE_SECONDS="$2"; shift 2 ;;
    --stub-seconds) [ "$#" -ge 2 ] || die_unknown "--stub-seconds needs a value"; STUB_SECONDS="$2"; shift 2 ;;
    --consecutive) [ "$#" -ge 2 ] || die_unknown "--consecutive needs a value"; CONSECUTIVE="$2"; shift 2 ;;
    --now-ms) [ "$#" -ge 2 ] || die_unknown "--now-ms needs a value"; NOW_MS="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) die_unknown "unrecognised argument: $1" ;;
  esac
done

# Every numeric knob is validated before use. An unvalidated value would otherwise reach arithmetic
# and either abort under `set -e` (reported as an internal failure) or, worse, silently widen the
# stub window until the check cannot fire.
for pair in "GRACE_SECONDS:$GRACE_SECONDS" "STUB_SECONDS:$STUB_SECONDS" "CONSECUTIVE:$CONSECUTIVE"; do
  name=${pair%%:*}; val=${pair#*:}
  case "$val" in
    ''|*[!0-9]*) die_unknown "$name must be a non-negative integer, got: $val" ;;
  esac
done
# All three carry a floor of 1, because 0 defeats the invariant each one exists to hold:
# --grace-seconds 0 makes settled_before == now, so an in-flight run is classified — the exact trap
# the settled-window filter exists to close; --stub-seconds 0 makes the stub window unreachable, so
# the check could only ever return 0 or 2 and never its actual verdict.
[ "$CONSECUTIVE" -ge 1 ] || die_unknown "--consecutive must be at least 1"
[ "$GRACE_SECONDS" -ge 1 ] || die_unknown "--grace-seconds must be at least 1"
[ "$STUB_SECONDS" -ge 1 ] || die_unknown "--stub-seconds must be at least 1"

if [ -n "$NOW_MS" ]; then
  case "$NOW_MS" in
    ''|*[!0-9]*) die_unknown "--now-ms must be a non-negative integer, got: $NOW_MS" ;;
  esac
else
  NOW_MS=$(( $(date +%s) * 1000 ))
fi

command -v sqlite3 >/dev/null 2>&1 || die_unknown "sqlite3 is not available"
[ -f "$STORE" ] || die_unknown "scheduler store not found: $STORE"
[ -r "$STORE" ] || die_unknown "scheduler store is not readable: $STORE"

# Open read-only. The sibling lane may be mid-dispatch, and *Obligations* forbids a change that could
# break a sibling in flight; a read-only URI cannot create the -wal/-shm files a plain open would.
#
# Every output-affecting knob is PINNED and `~/.sqliterc` is refused with `-init /dev/null`. The CLI
# reads that file at startup, so a user or CI `.headers on` prepends a header row and `.mode column`
# removes the `|` separator entirely — either one makes the parse below silently mis-read every row
# as a non-stub, which reports a dead lane as healthy. Asserting column NAMES does not assert the
# WIRE FORMAT their values arrive in.
sq() {
  sqlite3 -batch -init /dev/null -noheader -list -separator '|' \
    "file:${STORE}?mode=ro" "$@" 2>/dev/null || return 1
}

sq 'SELECT 1;' >/dev/null || die_unknown "scheduler store could not be opened read-only: $STORE"

# Prove the wire format really is what the parse assumes, rather than trusting the flags took effect.
probe=$(sq "SELECT 1,2;") || die_unknown "scheduler store probe query failed"
[ "$probe" = "1|2" ] || die_unknown "unexpected sqlite3 output format (got '${probe}', want '1|2')"

# Schema is asserted, never assumed. A renamed column would otherwise make every comparison below
# return empty, and an empty result set reads exactly like "no stubs found" — a silent pass in the
# one case the check exists for.
for spec in "automations:id" "automations:status" "automation_runs:automation_id" \
            "automation_runs:created_at" "automation_runs:updated_at" "automation_runs:inbox_title"; do
  tbl=${spec%%:*}; col=${spec#*:}
  have=$(sq "SELECT COUNT(*) FROM pragma_table_info('${tbl}') WHERE name='${col}';") \
    || die_unknown "could not read schema for ${tbl}"
  [ "${have:-0}" = "1" ] || die_unknown "unexpected schema: ${tbl}.${col} is missing"
done

if [ -n "$AUTOMATION" ]; then
  case "$AUTOMATION" in
    *[!A-Za-z0-9._-]*) die_unknown "unusable automation id: $AUTOMATION" ;;
  esac
  ids=$AUTOMATION
else
  ids=$(sq "SELECT id FROM automations WHERE status='ACTIVE' ORDER BY id;") \
    || die_unknown "could not enumerate automations"
fi

[ -n "$ids" ] || die_unknown "no ACTIVE automations found in $STORE"

settled_before=$(( NOW_MS - GRACE_SECONDS * 1000 ))
# Tracked as two independent flags rather than one severity counter. A counter invites the ordering
# bug this had on its first run: a later unjudgeable lane overwrote an already-detected dead lane,
# downgrading a real verdict to UNKNOWN purely because of the order automations were enumerated in.
any_dead=0
any_unknown=0
report=""

while IFS= read -r id; do
  # A blank id is recorded, never silently skipped. SQLite permits NULL in a TEXT PRIMARY KEY, so an
  # ACTIVE automation can enumerate as an empty line — and if that were the dead lane, a bare
  # `continue` would exit 0 having examined nothing about it. This is the only skip in the file that
  # would otherwise leave no trace.
  if [ -z "$id" ]; then
    report="${report}  UNKNOWN  <blank automation id> — cannot judge
"
    any_unknown=1
    continue
  fi
  # The id came out of a local store rather than from this script, so it is validated before being
  # interpolated into SQL — the same discipline the contract applies to any value it did not construct.
  case "$id" in
    *[!A-Za-z0-9._-]*)
      report="${report}  UNKNOWN  ${id} — unusable automation id, skipped
"
      any_unknown=1
      continue ;;
  esac

  # Only SETTLED runs are classified. An in-flight run is short BECAUSE it is still running — most
  # acutely when the checking run inspects its own row — so classifying it would make the guard fire
  # on a healthy lane every time it ran. This is the trap that would have made the check useless.
  rows=$(sq "SELECT ((updated_at - created_at) / 1000) AS dur,
                    CASE WHEN inbox_title IS NULL OR trim(inbox_title) = '' THEN 1 ELSE 0 END AS no_inbox
             FROM automation_runs
             WHERE automation_id = '${id}' AND updated_at <= ${settled_before}
             ORDER BY updated_at DESC
             LIMIT ${CONSECUTIVE};") || die_unknown "could not read runs for ${id}"

  n=0
  stubs=0
  maxdur=-1
  malformed=0
  while IFS='|' read -r dur no_inbox; do
    [ -n "$dur" ] || continue
    n=$(( n + 1 ))
    # BOTH fields are validated. An unparsable value must never fall through to the healthy verdict:
    # `no_inbox` in particular is compared against the literal 1, so without this check every
    # unexpected value (empty, NULL, a header token, a shifted column) would read as "produced an
    # inbox item" and therefore as NOT a stub — making the default for "I could not parse this" the
    # answer that exits 0. Strip at most one leading '-' so forms like `--5` or `1-2` are rejected
    # rather than reaching `[ ]` and erroring into a false non-stub.
    case "${dur#-}" in ''|*[!0-9]*) dur=-1 ;; esac
    case "$no_inbox" in
      0|1) : ;;
      *) malformed=1; break ;;
    esac
    # An `[ ... ] && x=y` here would return non-zero whenever the test is false and abort the loop
    # under `set -e`, so the assignment is written as a full conditional.
    if [ "$dur" -gt "$maxdur" ]; then maxdur=$dur; fi
    if [ "$dur" -ge 0 ] && [ "$dur" -le "$STUB_SECONDS" ] && [ "$no_inbox" = "1" ]; then
      stubs=$(( stubs + 1 ))
    fi
  done <<EOF
$rows
EOF

  if [ "$malformed" -eq 1 ]; then
    report="${report}  UNKNOWN  ${id} — unparsable run row, cannot judge
"
    any_unknown=1
  elif [ "$n" -lt "$CONSECUTIVE" ]; then
    report="${report}  UNKNOWN  ${id} — only ${n} settled run(s), need ${CONSECUTIVE} to judge
"
    any_unknown=1
  elif [ "$stubs" -eq "$n" ]; then
    report="${report}  NOT-PRODUCING  ${id} — newest ${n} settled runs all ended within ${STUB_SECONDS}s with no inbox item
"
    any_dead=1
  else
    report="${report}  OK  ${id} — ${stubs}/${n} newest settled runs are stubs, longest ${maxdur}s
"
  fi
done <<EOF
$ids
EOF

if [ "$QUIET" -eq 0 ]; then
  printf 'codex-lane-liveness: store=%s grace=%ss stub<=%ss window=%s runs\n' \
    "$STORE" "$GRACE_SECONDS" "$STUB_SECONDS" "$CONSECUTIVE"
  printf '%s' "$report"
fi

# A detected dead lane OUTRANKS an unjudgeable one: exit 1 is actionable now, and letting an UNKNOWN
# elsewhere mask it would hide the very condition this check exists to surface.
if [ "$any_dead" -eq 1 ]; then
  printf 'codex-lane-liveness: NOT PRODUCING — a dispatched lane is not doing work.\n' >&2
  printf '%s\n' "$RECOVERY" >&2
  exit 1
fi
if [ "$any_unknown" -eq 1 ]; then
  printf 'codex-lane-liveness: UNKNOWN — at least one lane could not be judged.\n' >&2
  exit 2
fi
exit 0
