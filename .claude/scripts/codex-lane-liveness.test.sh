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

# A green exit that ran no assertions is the very anti-pattern the script under test exists to fix,
# so CI may not take it. A developer machine can opt in explicitly; CI cannot opt in by accident.
if ! command -v sqlite3 >/dev/null 2>&1; then
  if [ "${ALLOW_SKIP:-0}" = "1" ]; then
    echo "SKIP: sqlite3 unavailable (ALLOW_SKIP=1)" >&2; exit 0
  fi
  echo "FAIL: sqlite3 is required to run this suite (set ALLOW_SKIP=1 to skip locally)" >&2; exit 1
fi

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

# `thread_id` is the PRIMARY KEY, so its uniqueness has to be guaranteed rather than likely. A
# `$RANDOM` component can repeat, which would make two runs sharing an automation/ago/duration
# collide and abort the whole fixture under `set -e` — a flake with no relation to what is being
# tested. A monotonic counter also keeps every id reproducible, which the header's "no assertion
# depends on a non-pinned input" property requires.
run_seq=0

# add_run <db> <automation> <ended_ms_ago> <duration_s> <inbox:yes|no>
add_run() {
  local db=$1 auto=$2 ago=$3 dur=$4 inbox=$5 status=${6:-PENDING_REVIEW}
  add_run_ms "$db" "$auto" "$ago" "$(( dur * 1000 ))" "$inbox" "$status"
}

# add_run_ms <db> <automation> <ended_ms_ago> <duration_MS> <inbox:yes|no> [status]
# Millisecond-precision variant, so a fixture can sit just above a whole-second stub threshold.
add_run_ms() {
  local db=$1 auto=$2 ago=$3 dur_ms=$4 inbox=$5 status=${6:-PENDING_REVIEW}
  local ended=$(( NOW_MS - ago )) created
  created=$(( ended - dur_ms ))
  run_seq=$(( run_seq + 1 ))
  local title
  case "$inbox" in
    yes)   title="'an inbox item'" ;;
    empty) title="''" ;;            # present but blank — the trim() branch
    blank) title="'   '" ;;         # spaces only — also the trim() branch
    *)     title=NULL ;;
  esac
  sqlite3 "$db" "INSERT INTO automation_runs
    (thread_id,automation_id,status,thread_title,inbox_title,inbox_summary,last_error,created_at,updated_at)
    VALUES ('t-$auto-$run_seq-$ago-$dur_ms','$auto','$status','Run',$title,'sum','PRIVATE-ERROR-PAYLOAD',$created,$ended);"
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

# The negative counterpart. An exit code says which verdict was reached but not which one was
# AVOIDED, and the two failure directions here are not interchangeable: reporting an unproven run as
# a proven dead lane is a different defect from reporting it as healthy.
expect_out_not() {
  asserts=$(( asserts + 1 ))
  case "$OUT" in
    *"$1"*) note_fail "$2 (expected output NOT to contain: $1)
--- output ---
$OUT" ;;
    *) : ;;
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

# --- 3b. stale updated_at does not make an active run terminal ----------------------------------
# `updated_at` is not a heartbeat. A long-running turn can retain a timestamp older than the grace
# boundary while its row remains IN_PROGRESS. If that active row enters the two-run window beside a
# real terminal stub, both look short and inbox-less even though the older terminal run was healthy.
db=$TMP/stale-active.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  3 no IN_PROGRESS
add_run "$db" lane-a $(( GRACE_MS + 120000 )) 4 no
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 900 yes
run_check "$db"
expect_rc 0 "an IN_PROGRESS row must not be classified after its updated_at ages past grace"
expect_out "OK" "terminal history containing a healthy run must remain OK"

# --- 4. duration alone is not enough -----------------------------------------------------------
db=$TMP/fastok.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  4 yes           # fast BUT wrote an inbox item
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 5 yes
run_check "$db"
expect_rc 0 "a fast run that wrote an inbox item is not a stub"

# --- 5. missing inbox alone is not a STUB, but it is not health either --------------------------
# A long run without an inbox item is not the dispatch-time death the NOT-PRODUCING verdict names,
# so it is still not a stub. It is not evidence of production either: this store cannot separate a
# run that died part way from one that worked and never wrote an inbox item. Reporting OK here is
# what let a lane whose newest settled run had died to an account-scoped cause read healthy
# (monorepo#3287), so the verdict is UNKNOWN -- which is never read as producing.
db=$TMP/longnoinbox.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  900 no          # long BUT no inbox item
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 800 no
run_check "$db"
expect_rc 2 "a long run with no inbox item is unproven, not healthy"
expect_out "production is unproven" "the unproven verdict must name why it could not judge"
expect_out_not "NOT-PRODUCING" "an unproven run must not be reported as a proven dead lane"

# --- 5b. THE LIVE SHAPE (monorepo#3287): newest run died part way, older one produced ------------
# Measured on 2026-09-08: the newest settled run of a twice-daily automation ran 46 minutes, wrote no
# inbox item and died to an account-scoped cause, while the run before it was healthy. The old
# conjunctive test scored this window OK, and the lane was only caught because a SECOND automation on
# the same account happened to show the stub signature. A lane must not depend on a sibling's cadence
# to be diagnosed, so this window is UNKNOWN on its own evidence.
db=$TMP/newestdied.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  2764 no         # newest: long, produced nothing
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 997  yes        # older:  healthy
run_check "$db"
expect_rc 2 "a healthy older run must not certify a newest run that produced nothing"
expect_out "1 of 2" "the verdict must say how many runs were unproven"

# --- 5c. the OK path is untouched: an inbox item is still proof of production --------------------
db=$TMP/stillok.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  2764 yes
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 4    yes
run_check "$db"
expect_rc 0 "runs that wrote inbox items remain OK regardless of duration"

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

# The run status is what separates active rows from terminal history. A schema without that column
# cannot safely classify anything, even when every other field still permits the old query to run.
db=$TMP/status-schema.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  900 yes
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 800 yes
sqlite3 "$db" "ALTER TABLE automation_runs RENAME COLUMN status TO run_state;"
run_check "$db"
expect_rc 2 "a missing run status must be UNKNOWN, not a classification without terminality"
expect_out "automation_runs.status is missing" "run-status schema drift must name the missing dependency"

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
# A quote is the input that could actually escape a single-quoted SQL literal; the semicolon form
# above could not, so on its own it never exercised the case it is named for.
run_check "$db" --automation "x' OR '1'='1"
expect_rc 2 "a quote-bearing automation id must be rejected"
asserts=$(( asserts + 1 ))
sqlite3 "$db" "SELECT count(*) FROM automations;" >/dev/null 2>&1 \
  || note_fail "the automations table did not survive the injection attempts"

# --- 13b. a blank automation id is recorded, never silently skipped -----------------------------
# Paired with a VALID automation on purpose: a blank id on its own makes the whole enumeration empty
# and is caught by the earlier "no ACTIVE automations" guard, so it never reaches the loop branch
# this case exists to exercise.
db=$TMP/blankid.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  900 yes
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 800 yes
sqlite3 "$db" "INSERT INTO automations (id,status) VALUES ('','ACTIVE');"
run_check "$db"
expect_rc 2 "a blank automation id must be UNKNOWN, not an unexamined pass"
# Assert the CAUSE. A blank id also falls through to a zero-row query and thin-history UNKNOWN, so an
# exit-code-only assertion passes with the blank-id branch removed entirely.
expect_out "blank automation id" "a blank id must be reported as such, not as thin history"

# --- 13c. floors: a zero window would defeat the invariant it exists to hold --------------------
db=$TMP/healthy.db
run_check "$db" --grace-seconds 0
expect_rc 2 "--grace-seconds 0 must be rejected (it would classify in-flight runs)"
run_check "$db" --stub-seconds 0
expect_rc 2 "--stub-seconds 0 must be rejected (the stub window would be unreachable)"

# --- 13d. a blank-but-present inbox title still counts as no inbox item -------------------------
# Without this, deleting the `trim(inbox_title) = ''` branch leaves the whole suite green.
for variant in empty blank; do
  db=$TMP/inbox-$variant.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
  add_run "$db" lane-a $(( GRACE_MS + 60000 ))  4 "$variant"
  add_run "$db" lane-a $(( GRACE_MS + 900000 )) 5 "$variant"
  run_check "$db"
  expect_rc 1 "a '$variant' inbox title must count as no inbox item"
done

# --- 13e. the sqlite3 wire format is pinned, and the rc file refused ----------------------------
# Asserted structurally because the failure needs a hostile ~/.sqliterc, which a test must not write
# into the invoking user's home. `.headers on` or a non-list mode would make every row mis-parse as
# a non-stub — a dead lane reported healthy — so silent removal of these flags must fail the suite.
for flag in '-init /dev/null' '-noheader' '-list' "-separator '|'"; do
  asserts=$(( asserts + 1 ))
  grep -qF -- "$flag" "$SCRIPT" || note_fail "sqlite3 invocation must pin $flag"
done
asserts=$(( asserts + 1 ))
grep -qF "want '1|2'" "$SCRIPT" || note_fail "the script must probe the actual sqlite3 output format"

# --- 13f. an internal failure must not be able to reach exit 1 ----------------------------------
# Exit 1 is a verdict. Under `set -e` the abort status is the failing command's, and 1 is the
# commonest, so without the ERR trap a failing `date` would be indistinguishable from a dead lane.
asserts=$(( asserts + 1 ))
grep -qE 'trap .*(exit 2).* ERR' "$SCRIPT" || note_fail "an ERR trap must map internal failures to UNKNOWN"
asserts=$(( asserts + 1 ))
grep -qE '^set -[A-Za-z]*E' "$SCRIPT" || note_fail "set -E is required for the ERR trap to propagate"

# --- 13g. the row parser must fail closed on an unparsable field --------------------------------
# Structural, and deliberately so: with the wire format pinned above, the SQL CASE can only ever
# yield 0 or 1, so no fixture can drive this branch. It is defence-in-depth for the case where the
# format pin itself fails — the direction that matters, because an unvalidated `no_inbox` defaults to
# "has an inbox item" and therefore to the healthy verdict. Asserting its presence is what stops it
# being removed as dead code, which is exactly how a fail-open gets reintroduced.
asserts=$(( asserts + 1 ))
grep -qF 'malformed=1; break' "$SCRIPT" || note_fail "an unparsable run row must fail closed, not default to healthy"
asserts=$(( asserts + 1 ))
grep -qF 'unparsable run row' "$SCRIPT" || note_fail "a malformed window must be reported UNKNOWN"

# --- 14. PRIVACY: the check must never read a run's payload ------------------------------------
# The stall's cause is frequently private runtime state. This check is about the deployment being
# blind, so it must stay generic across causes and must not be able to carry such state outward.
# Asserted structurally against the script's own source, not against one run's output.
# Comment LINES are stripped first — the script's own header names these columns precisely to say it
# does not read them, and matching that prose would fail the check on the documentation of the
# property it is verifying. Whole lines are dropped rather than truncating at the first '#', because
# parameter expansions like ${pair#*:} would otherwise mangle real code into a false PASS.
# NOT a pipeline: `grep -Eq` exits at the first match, the upstream grep dies of SIGPIPE, and under
# `set -o pipefail` the pipeline reports THAT — so the assertion would report "clean" precisely when
# it matched. Reproduced 3/3 on a large input with an early match, which is the shape a growing
# script eventually reaches. A fail-open in the privacy assertion is the exact class this check exists
# to prevent, so it is written without a pipe.
# `\b` is a GNU extension, NOT POSIX ERE. On a grep without it the escape degrades to a literal 'b',
# the alternation stops matching anything, and this assertion passes unconditionally — a vacuous
# guard over a privacy property, on a suite that must run on both BSD and GNU. An explicit delimiter
# class is portable, and the positive control below is what proves the matcher is alive at all.
PAYLOAD_RE='(^|[^A-Za-z0-9_])(last_error|inbox_summary|thread_title|archived_[a-z_]*)([^A-Za-z0-9_]|$)'

asserts=$(( asserts + 1 ))
if ! grep -Eq "$PAYLOAD_RE" <<<'SELECT last_error FROM automation_runs;'; then
  note_fail "the privacy matcher is broken — it does not match a known payload reference"
fi

asserts=$(( asserts + 1 ))
noncomment=$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)
if grep -Eq "$PAYLOAD_RE" <<<"$noncomment"; then
  note_fail "the script must not read a run's payload columns"
fi

# A column allow-list is defeated by a wildcard: `SELECT *` pulls every payload column into the row
# buffer without any forbidden name appearing in the source, so the assertion above would pass.
asserts=$(( asserts + 1 ))
if grep -Eq 'SELECT[[:space:]]+\*' <<<"$noncomment"; then
  note_fail "the script must not SELECT * — it would pull payload columns in unnamed"
fi

# The fixtures deliberately carry a payload, so a leak would surface in output.
asserts=$(( asserts + 1 ))
db=$TMP/dead.db
run_check "$db"
case "$OUT" in
  *PRIVATE-ERROR-PAYLOAD*) note_fail "a run's error payload reached the check's output" ;;
esac

# --- an explicitly EMPTY --automation must not widen to every automation ------------------------
# The failure this pins is silent: the request was for one automation, and testing the value rather
# than the flag turned it into a sweep of all of them, reporting on lanes nobody asked about.
db=$TMP/emptyauto.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run "$db" lane-a $(( GRACE_MS + 60000 ))  4 no
add_run "$db" lane-a $(( GRACE_MS + 900000 )) 5 no
run_check "$db" --automation ""
expect_rc 2 "an empty --automation must be UNKNOWN, never a silent sweep of every automation"
expect_out "must not be empty" "the empty --automation refusal must say so"

# --- a NAMED but INACTIVE automation must not be judged ------------------------------------------
# An inactive lane does not dispatch, so its newest settled runs are old by construction and would
# classify as a dead lane. That is a false NOT-PRODUCING on the one verdict this check exists to make.
db=$TMP/inactive.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_automation "$db" lane-b INACTIVE
add_run "$db" lane-b $(( GRACE_MS + 60000 ))  4 no
add_run "$db" lane-b $(( GRACE_MS + 900000 )) 5 no
run_check "$db" --automation lane-b
expect_rc 2 "an inactive automation must be UNKNOWN, never NOT-PRODUCING"
expect_out "not an ACTIVE automation" "the inactive refusal must name the reason"

# --- a run just OVER the stub threshold is not a stub --------------------------------------------
# Whole-second truncation classified `STUB_SECONDS*1000 + 999` ms as exactly STUB_SECONDS, so a run
# genuinely over the threshold counted as under it. Both runs sit 999 ms over, so the comparison
# precision is the only thing deciding the verdict.
db=$TMP/justover.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run_ms "$db" lane-a $(( GRACE_MS + 60000 ))  60999 no
add_run_ms "$db" lane-a $(( GRACE_MS + 900000 )) 60999 no
run_check "$db"
expect_rc 2 "a run 999ms over the stub threshold must not be counted a stub"
expect_out "60999ms" "the verdict must report the millisecond duration it actually compared"
expect_out_not "NOT-PRODUCING" "999ms over the threshold must not reach the dead-lane verdict"

# --- a NEGATIVE duration is corrupt timing data, not a long run ----------------------------------
# updated_at before created_at cannot describe a real run. Treating it as a large duration made it a
# non-stub, which fed the healthy verdict — the same fall-through the field validation exists to stop.
db=$TMP/negdur.db; mkstore "$db"; add_automation "$db" lane-a ACTIVE
add_run_ms "$db" lane-a $(( GRACE_MS + 60000 ))  -5000 no
add_run_ms "$db" lane-a $(( GRACE_MS + 900000 )) -5000 no
run_check "$db"
expect_rc 2 "a negative run duration must be UNKNOWN, never a silent non-stub"
expect_out "unparsable run row" "a negative duration must report as an unparsable row"

echo "codex-lane-liveness.test.sh: $asserts assertions, $fails failure(s)"
# A floor on the count, so deleting a whole section cannot leave the suite green and silent.
if [ "$asserts" -lt 52 ]; then
  echo "FAIL: only $asserts assertions ran — a section is missing" >&2
  exit 1
fi
[ "$fails" -eq 0 ] || exit 1
echo "OK"
