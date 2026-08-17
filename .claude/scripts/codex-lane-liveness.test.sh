#!/usr/bin/env bash
# codex-lane-liveness.test.sh — RED/GREEN coverage for the Codex lane liveness check.
#
# The check exists because a dead lane looked healthy. So the assertions that matter most are the
# ones proving it does NOT fire on a healthy lane: a guard that always fires is indistinguishable
# from decoration, and gets ignored exactly as the signals it replaces were.
#
# Fixtures are synthetic stores built to the real schema. Every case pins `--now-ms`, so no assertion
# depends on wall-clock time.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/codex-lane-liveness.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 unavailable" >&2; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

NOW_MS=1000000000000        # fixed "now" for every case
GRACE_MS=300000            # default --grace-seconds 300

fails=0
asserts=0

note_fail() { echo "FAIL: $1" >&2; fails=$(( fails + 1 )); }

# Build a store with the real schema. Only the columns the script reads are required to match; the
# extras are present so a fixture cannot accidentally pass by being simpler than reality.
mkstore() {
  local db=$1
  sqlite3 "$db" "
    CREATE TABLE automations (
      id TEXT PRIMARY KEY, status TEXT NOT NULL, rrule TEXT,
      last_run_at INTEGER, updated_at INTEGER);
    CREATE TABLE automation_runs (
      thread_id TEXT PRIMARY KEY, automation_id TEXT NOT NULL, status TEXT NOT NULL,
      thread_title TEXT, inbox_title TEXT, inbox_summary TEXT, last_error TEXT,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
  "
}

add_automation() {
  sqlite3 "$1" "INSERT INTO automations (id,status,rrule,last_run_at,updated_at)
                VALUES ('$2','$3','RRULE:FREQ=DAILY',$NOW_MS,$NOW_MS);"
}

# add_run <db> <automation> <ended_ms_ago> <duration_s> <inbox:yes|no>
add_run() {
  local db=$1 auto=$2 ago=$3 dur=$4 inbox=$5
  local ended=$(( NOW_MS - ago )) created
  created=$(( ended - dur * 1000 ))
  local title="'an inbox item'"
  [ "$inbox" = "yes" ] || title=NULL
  sqlite3 "$db" "INSERT INTO automation_runs
    (thread_id,automation_id,status,thread_title,inbox_title,inbox_summary,last_error,created_at,updated_at)
    VALUES ('t-$auto-$RANDOM-$ago-$dur','$auto','PENDING_REVIEW','Run',$title,'sum','PRIVATE-ERROR-PAYLOAD',$created,$ended);"
}

run_check() {
  set +e
  OUT=$(bash "$SCRIPT" --store "$1" --now-ms "$NOW_MS" "${@:2}" 2>&1)
  RC=$?
  set -e
}

expect_rc() {
  asserts=$(( asserts + 1 ))
  if [ "$RC" != "$1" ]; then
    note_fail "$2 (expected exit $1, got $RC)
--- output ---
$OUT"
  fi
}

expect_out() {
  asserts=$(( asserts + 1 ))
  case "$OUT" in
    *"$1"*) : ;;
    *) note_fail "$2 (expected output to contain: $1)
--- output ---
$OUT" ;;
  esac
}

# --- 1. a healthy lane must NOT fire -----------------------------------------------------------
db=$TMP/healthy.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  900 yes
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 800 yes
run_check "$db"
expect_rc 0 "healthy lane must exit 0"
expect_out "OK" "healthy lane must report OK"

# --- 2. an all-stub lane must fire -------------------------------------------------------------
db=$TMP/dead.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  4 no
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 5 no
run_check "$db"
expect_rc 1 "all-stub lane must exit 1"
expect_out "NOT-PRODUCING" "all-stub lane must report NOT-PRODUCING"

# --- 3. THE fail-open trap: an in-flight run must not be classified -----------------------------
# The newest run is short because it is still running — the case where a run inspects its own row.
# Classifying it would fire on a healthy lane on every single invocation.
# The window must be filled ENTIRELY with unsettled runs, or the fixture cannot flip: one in-flight
# stub paired with a settled healthy run yields "not all stubs" whether or not the filter exists, so
# the assertion would pass vacuously. Two unsettled stubs make the filter the only thing deciding.
db=$TMP/inflight.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a 0     3 no                               # in flight, ends "now"
add_run "$db" lane-a 60000 4 no                               # ended 60s ago, still inside the grace
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  900 yes
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 800 yes
run_check "$db"
expect_rc 0 "an in-flight short run must not be classified as a stub"

# --- 4. duration alone is not enough -----------------------------------------------------------
db=$TMP/fastok.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  4 yes           # fast BUT wrote an inbox item
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 5 yes
run_check "$db"
expect_rc 0 "a fast run that wrote an inbox item is not a stub"

# --- 5. missing inbox alone is not enough ------------------------------------------------------
db=$TMP/longnoinbox.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  900 no          # long BUT no inbox item
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 800 no
run_check "$db"
expect_rc 0 "a long run with no inbox item is not a stub"

# --- 6. mixed window does not fire (requires ALL runs to be stubs) ------------------------------
db=$TMP/mixed.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  4 no
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 900 yes
run_check "$db"
expect_rc 0 "a window containing a healthy run must not fire"

# --- 7. too little settled history is UNKNOWN, never OK ----------------------------------------
db=$TMP/thin.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 )) 900 yes
run_check "$db"
expect_rc 2 "too little settled history must be UNKNOWN"
expect_out "UNKNOWN" "thin history must report UNKNOWN"

# --- 8. a paused automation is skipped ---------------------------------------------------------
db=$TMP/paused.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE; add_automation "$db" lane-b PAUSED
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  900 yes
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 800 yes
add_run "$db" lane-b $(( GRACE_MS + 60000 ))  4 no
add_run "$db" lane-b $(( GRACE_MS + 900000 )) 4 no
run_check "$db"
expect_rc 0 "a PAUSED automation must not be judged"

# --- 9. a real verdict outranks UNKNOWN --------------------------------------------------------
db=$TMP/both.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE; add_automation "$db" lane-b ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  4 no
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 4 no
add_run "$db" lane-b $(( GRACE_MS + 60000 ))  900 yes         # only one settled run => UNKNOWN
run_check "$db"
expect_rc 1 "a detected dead lane outranks an unjudgeable one"

# --- 10. absent / unreadable store is UNKNOWN --------------------------------------------------
run_check "$TMP/does-not-exist.db"
expect_rc 2 "absent store must be UNKNOWN"

# --- 11. unexpected schema is UNKNOWN, never a silent pass --------------------------------------
# A renamed column makes every comparison return empty, and an empty result set reads exactly like
# "no stubs found" — so schema drift must be caught explicitly.
db=$TMP/schema.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  4 no
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 4 no
sqlite3 "$db" "ALTER TABLE automation_runs RENAME COLUMN inbox_title TO inbox_heading;"
run_check "$db"
expect_rc 2 "a renamed column must be UNKNOWN, not a pass"
# Assert the CAUSE, not just the exit code. Without the schema check the query fails on the missing
# column and still exits 2, so an exit-code-only assertion cannot tell a diagnosed schema drift from
# an opaque query error — and would pass with the schema check removed entirely.
expect_out "unexpected schema" "schema drift must be diagnosed as such, not as an opaque read failure"

# --- 12. no ACTIVE automations is UNKNOWN ------------------------------------------------------
db=$TMP/none.db; mkstore "$db"; add_automation "$db" lane-b PAUSED
run_check "$db"
expect_rc 2 "a store with no ACTIVE automation must be UNKNOWN"

# --- 13. bad arguments are UNKNOWN -------------------------------------------------------------
db=$TMP/healthy.db
run_check "$db" --consecutive 0
expect_rc 2 "--consecutive 0 must be rejected"
run_check "$db" --stub-seconds abc
expect_rc 2 "a non-numeric --stub-seconds must be rejected"
run_check "$db" --automation 'lane-a; DROP TABLE automations'
expect_rc 2 "an unusable automation id must be rejected"

# --- 14. PRIVACY: the check must never read a run's payload ------------------------------------
# The stall's cause is frequently private runtime state. This check is about the deployment being
# blind, so it must stay generic across causes and must not be able to carry such state outward.
# Asserted structurally against the script's own source, not against one run's output.
# Comment LINES are stripped first — the script's own header names these columns precisely to say it
# does not read them, and matching that prose would fail the check on the documentation of the
# property it is verifying. Whole lines are dropped rather than truncating at the first '#', because
# parameter expansions like ${pair#*:} would otherwise mangle real code into a false PASS.
asserts=$(( asserts + 1 ))
if grep -vE '^[[:space:]]*#' "$SCRIPT" |
     grep -Eq '\b(last_error|inbox_summary|thread_title|archived_[a-z_]*)\b'; then
  note_fail "the script must not read a run's payload columns"
fi

# The fixtures deliberately carry a payload, so a leak would surface in output.
asserts=$(( asserts + 1 ))
db=$TMP/dead.db
run_check "$db"
case "$OUT" in
  *PRIVATE-ERROR-PAYLOAD*) note_fail "a run's error payload reached the check's output" ;;
esac

echo "codex-lane-liveness.test.sh: $asserts assertions, $fails failure(s)"
[ "$fails" -eq 0 ] || exit 1
echo "OK"
