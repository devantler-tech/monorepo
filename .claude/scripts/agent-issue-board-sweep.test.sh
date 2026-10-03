#!/usr/bin/env bash
#
# Self-test for agent-issue-board-sweep.sh.
#
# BEHAVIOURAL, not textual: `gh` is stubbed on PATH to emit a chosen result set and to RECORD its
# own argv, and `board-add.sh` is stubbed to LOG every URL it is handed. The central assertion is
# a set comparison — every discovered issue reached the helper — and it is ABLATED at the end
# against a copy of the script that drops one issue, so a check that could never fail is not
# mistaken for a passing one.
#
# The stub also answers the two reads the sweep makes before it hands anything to the helper
# (monorepo#3340): the board's id, and the bulk membership read. What the bulk read reports for each
# issue comes from a table the cases fill in, so every shape that must NOT count as "already on the
# board" has a case, and the helper log proves whether the issue was still checked on its own.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sweep="$here/agent-issue-board-sweep.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
report() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = yes ]; then echo "PASS: $name"; else echo "FAIL: $name${detail:+ — $detail}"; fail=1; fi
}

# A `gh` stub that answers the three calls the sweep makes and records its argv.
#   search issues       prints $GH_RESULTS (rows `<node id><TAB><url>`); GH_EXIT fails it
#   api graphql         without --input: the board id ($GH_PROJECT_ID); GH_PROJECT_EXIT fails it
#   api graphql --input the bulk membership read. Each requested id is looked up in $GH_MEMBERSHIP
#                       (rows `<id><TAB><url><TAB><kind>`) and answered by kind:
#                         present   on the board with a Status      absent   on no project
#                         nostatus  on the board, no Status         other    on another project
#                         private   present, repository private    many     nothing on the first
#                         null      the node came back null                  page, more pages exist
#                         wrongid / wrongurl   a present node that answers for another issue
#                       GH_BULK_EXIT fails the call; GH_BULK_MODE is errors (no data), short (one
#                       node missing), or partial (an errors entry beside complete data).
mkstub_gh() {
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_ARGV_LOG}"
printf '%s\n' "$@" >> "${GH_ARGS_LOG}"
case "$1 ${2:-}" in
  "search issues")
    printf 'search\n' >> "${GH_CALL_LOG}"
    if [ -n "${GH_STDERR:-}" ]; then printf '%s\n' "${GH_STDERR}" >&2; fi
    if [ "${GH_EXIT:-0}" != 0 ]; then echo "stub: simulated search failure" >&2; exit "${GH_EXIT}"; fi
    [ -s "${GH_RESULTS}" ] && cat "${GH_RESULTS}"
    exit 0
    ;;
  "api graphql")
    case " $* " in
      *" --input - "*)
        printf 'bulk\n' >> "${GH_CALL_LOG}"
        body="$(cat)"
        jq -r '.variables.ids[]' <<<"$body" >> "${GH_BULK_IDS}"
        jq -r '.variables.ids | length' <<<"$body" >> "${GH_BULK_SIZES}"
        if [ "${GH_BULK_EXIT:-0}" != 0 ]; then echo "stub: simulated bulk failure" >&2; exit "${GH_BULK_EXIT}"; fi
        jq -c --rawfile table "${GH_MEMBERSHIP}" --arg mode "${GH_BULK_MODE:-ok}" '
          ($table | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: {url: .[1], kind: .[2]}})
            | from_entries) as $t
          | def item($project; $status):
              {id: "PVTI_item", project: {id: $project},
               fieldValueByName: (if $status == null then null else {name: $status} end)};
            def node($id):
              ($t[$id] // {url: null, kind: "absent"}) as $row
              | if $row.kind == "null" then null
                else {
                  id: (if $row.kind == "wrongid" then "I_someone_else" else $id end),
                  url: (if $row.kind == "wrongurl" then "https://github.com/devantler-tech/x/issues/999" else $row.url end),
                  repository: {isPrivate: ($row.kind == "private")},
                  projectItems: {
                    nodes: (if ($row.kind | IN("present", "private", "wrongid", "wrongurl")) then [item("PVT_board"; "📥 Backlog")]
                            elif $row.kind == "nostatus" then [item("PVT_board"; null)]
                            elif $row.kind == "other" then [item("PVT_other"; "📥 Backlog")]
                            else [] end),
                    pageInfo: {hasNextPage: ($row.kind == "many")}
                  }
                } end;
            [.variables.ids[] | node(.)] as $nodes
          | if $mode == "errors" then {errors: [{type: "RATE_LIMITED", message: "stub"}]}
            elif $mode == "short" then {data: {nodes: $nodes[:-1]}}
            elif $mode == "partial" then {errors: [{message: "stub: one node could not be resolved"}], data: {nodes: $nodes}}
            else {data: {nodes: $nodes}} end' <<<"$body"
        # Like the real CLI (measured 2026-10-04): a response carrying `errors` is printed in full
        # and the call still exits 1, even when the data beside it is complete.
        case "${GH_BULK_MODE:-ok}" in errors | partial) echo "gh: stub: the response carried errors" >&2; exit 1 ;; esac
        exit 0
        ;;
      *)
        printf 'project\n' >> "${GH_CALL_LOG}"
        if [ "${GH_PROJECT_EXIT:-0}" != 0 ]; then echo "stub: simulated project lookup failure" >&2; exit "${GH_PROJECT_EXIT}"; fi
        printf '%s\n' "${GH_PROJECT_ID-PVT_board}"
        exit 0
        ;;
    esac
    ;;
esac
echo "stub: unexpected gh call: $*" >&2
exit 64
STUB
  chmod +x "$tmp/bin/gh"
}

# A `board-add.sh` stub logging each URL. BOARD_ADD_FAIL_ON / BOARD_ADD_PRIVATE_ON select
# an operational failure or a private-repo refusal for one URL. BOARD_ADD_SLEEP makes each call
# take that many seconds, so a deadline has something to cut off.
mkstub_board_add() {
  cat > "$tmp/board-add-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${BOARD_LOG}"
[ -z "${BOARD_ADD_SLEEP:-}" ] || sleep "${BOARD_ADD_SLEEP}"
if [ -n "${BOARD_ADD_PRIVATE_ON:-}" ] && grep -qxF "$1" <<<"${BOARD_ADD_PRIVATE_ON}"; then
  echo "board-add: devantler-tech/x is PRIVATE; project 5 is public — adding it is a maintainer decision, not an agent default"; exit 2
fi
if [ -n "${BOARD_ADD_FAIL_ON:-}" ] && grep -qxF "$1" <<<"${BOARD_ADD_FAIL_ON}"; then
  echo "board-add: set failed"; exit 2
fi
if [ -n "${BOARD_ADD_NOOP_ON:-}" ] && grep -qxF "$1" <<<"${BOARD_ADD_NOOP_ON}"; then
  echo "board-add: $1 already-present (status untouched) (item X) [verified]"; exit 0
fi
if [ -n "${BOARD_ADD_STATUS_SET_ON:-}" ] && grep -qxF "$1" <<<"${BOARD_ADD_STATUS_SET_ON}"; then
  echo "board-add: $1 already-present (status set) → 📥 Backlog (item X) [verified]"; exit 0
fi
echo "board-add: $1 added → 📥 Backlog (item X) [verified]"
STUB
  chmod +x "$tmp/board-add-stub.sh"
}

mkstub_gh
mkstub_board_add
export GH_ARGV_LOG="$tmp/gh-argv" GH_ARGS_LOG="$tmp/gh-args" GH_RESULTS="$tmp/results" BOARD_LOG="$tmp/board-log"
export GH_CALL_LOG="$tmp/gh-calls" GH_BULK_IDS="$tmp/bulk-ids" GH_BULK_SIZES="$tmp/bulk-sizes" GH_MEMBERSHIP="$tmp/membership"
: > "$GH_MEMBERSHIP"

U1=https://github.com/devantler-tech/monorepo/issues/1
U2=https://github.com/devantler-tech/platform/issues/2
U3=https://github.com/devantler-tech/ksail/issues/3

# The node id discovery returns beside a URL: unique per repository and number.
id_of() {
  local repo="${1%/issues/*}"
  printf 'I_%s_%s' "${repo##*/}" "${1##*/}"
}
# results <url>... — the discovery result set, oldest first. Every issue starts absent from the
# board, so a case that says nothing about membership exercises the per-issue path as before.
results() {
  local u
  : > "$GH_RESULTS"; : > "$GH_MEMBERSHIP"
  for u in "$@"; do
    printf '%s\t%s\n' "$(id_of "$u")" "$u" >> "$GH_RESULTS"
    printf '%s\t%s\tabsent\n' "$(id_of "$u")" "$u" >> "$GH_MEMBERSHIP"
  done
}
# membership <kind> <url>... — what the bulk read reports for those issues (kinds: see the gh stub).
membership() {
  local kind="$1" u
  shift
  for u in "$@"; do
    awk -F'\t' -v id="$(id_of "$u")" -v kind="$kind" 'BEGIN { OFS = "\t" } $1 == id { $3 = kind } { print }' \
      "$GH_MEMBERSHIP" > "$GH_MEMBERSHIP.new"
    cat "$GH_MEMBERSHIP.new" > "$GH_MEMBERSHIP"
  done
}
count_calls() { grep -c -x -- "$1" "$GH_CALL_LOG" || true; }

# Run the sweep (arg $1 = script under test) with a fresh log; sets $rc and $out.
run_sweep_without_author() {
  local script="$1"; shift
  : > "$BOARD_LOG"; : > "$GH_ARGV_LOG"; : > "$GH_ARGS_LOG"
  : > "$GH_CALL_LOG"; : > "$GH_BULK_IDS"; : > "$GH_BULK_SIZES"
  rc=0
  out="$(PATH="$tmp/bin:$PATH" "$script" --board-add "$tmp/board-add-stub.sh" --pace-seconds 0 "$@" 2>&1)" || rc=$?
}

run_sweep() {
  local script="$1"; shift
  run_sweep_without_author "$script" --author app/agent-fixture "$@"
}

# An omitted author must never trigger discovery or boarding under an implicit identity.
results "$U1"
run_sweep_without_author "$sweep"
report "an omitted --author fails before any external call" \
  "$([ "$rc" -eq 1 ] && [ ! -s "$GH_ARGV_LOG" ] && [ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "rc=$rc $out"
report "an omitted --author reports the required input" \
  "$(grep -qF -- '--author is required' <<<"$out" && echo yes || echo no)" "$out"
run_sweep_without_author "$sweep" --dry-run
report "dry-run also requires an explicit author before discovery" \
  "$([ "$rc" -eq 1 ] && [ ! -s "$GH_ARGV_LOG" ] && [ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "rc=$rc $out"
for invalid_author in '' ' ' '--dry-run'; do
  run_sweep_without_author "$sweep" --author "$invalid_author"
  report "an empty, blank or option-shaped author fails before any external call [$invalid_author]" \
    "$([ "$rc" -eq 1 ] && [ ! -s "$GH_ARGV_LOG" ] && [ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "rc=$rc $out"
done
run_sweep_without_author "$sweep" --author
report "--author without a value is a usage error with no external call" \
  "$([ "$rc" -eq 1 ] && [ ! -s "$GH_ARGV_LOG" ] && [ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "rc=$rc $out"

# ---------------------------------------------------------------------------
# 1. THE CENTRAL ASSERTION — every discovered issue reaches the helper.
results "$U1" "$U2" "$U3"
run_sweep "$sweep"
got="$(sort "$BOARD_LOG")"
want="$(printf '%s\n%s\n%s\n' "$U1" "$U2" "$U3" | sort)"
report "every discovered issue is passed to board-add" \
  "$([ "$got" = "$want" ] && [ "$rc" -eq 0 ] && echo yes || echo no)" "rc=$rc got=[$(echo "$got" | tr '\n' ' ')]"
report "summary counts the sweep" \
  "$(grep -q 'discovered=3 verified=0 boarded=3 wrote=3 skipped=0 failed=0' <<<"$out" && echo yes || echo no)" "$out"

# 2. Discovery flags are pinned (the AC names each one).
argv="$(cat "$GH_ARGV_LOG")"
for flag in "--archived=false" "--owner devantler-tech" "--state open" "--author app/agent-fixture" "--limit 300" "--sort created" "--order asc"; do
  report "discovery pins ${flag}" "$(grep -qF -- "$flag" <<<"$argv" && echo yes || echo no)" "$argv"
done
report "discovery passes the explicit author as an exact argument" \
  "$([ "$(awk 'previous == "--author" { print; exit } { previous=$0 }' "$GH_ARGS_LOG")" = app/agent-fixture ] && echo yes || echo no)" "$argv"

# A different explicit identity must select the caller's author without a provider default.
run_sweep_without_author "$sweep" --author fixture-maintainer
report "an explicit user author is preserved and every issue reaches board-add" \
  "$([ "$rc" -eq 0 ] && [ "$(sort "$BOARD_LOG")" = "$want" ] && [ "$(awk 'previous == "--author" { print; exit } { previous=$0 }' "$GH_ARGS_LOG")" = fixture-maintainer ] && echo yes || echo no)" "rc=$rc $out"

# 3. An EMPTY but SUCCESSFUL sweep is believed: exit 0, nothing handed to the helper.
: > "$GH_RESULTS"
run_sweep "$sweep"
report "empty successful sweep exits 0 with no board-add call" \
  "$([ "$rc" -eq 0 ] && [ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "rc=$rc log=[$(cat "$BOARD_LOG")]"
report "empty sweep reports discovered=0" \
  "$(grep -q 'discovered=0 verified=0 boarded=0' <<<"$out" && echo yes || echo no)" "$out"

# 4. FAIL-CLOSED: a failed discovery is not an empty one. This is the control for case 3 —
#    both produce no output from `gh`, and only the exit status separates them.
results "$U1"
GH_EXIT=1 run_sweep "$sweep"
report "a FAILED discovery exits 2 and boards nothing" \
  "$([ "$rc" -eq 2 ] && [ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "rc=$rc"
unset GH_EXIT

# 5. One helper failure does not abort the sweep, and is not absorbed either.
results "$U1" "$U2" "$U3"
BOARD_ADD_FAIL_ON="$U2" run_sweep "$sweep"
report "a board-add failure still boards the others" \
  "$([ "$(wc -l < "$BOARD_LOG" | tr -d ' ')" = 3 ] && echo yes || echo no)" "log=[$(cat "$BOARD_LOG")]"
report "a board-add failure makes the sweep exit 2" "$([ "$rc" -eq 2 ] && echo yes || echo no)" "rc=$rc"

# 6. A private repository's issue is SKIPPED, not a failure — it is a maintainer decision.
BOARD_ADD_PRIVATE_ON="$U2" run_sweep "$sweep"
report "a private-repo refusal is skipped, not failed" \
  "$([ "$rc" -eq 0 ] && grep -q 'skipped=1 failed=0' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 7. Usage errors fail closed rather than sweeping with a wrong bound.
run_sweep "$sweep" --limit not-a-number
report "a non-numeric --limit is a usage error" "$([ "$rc" -eq 1 ] && echo yes || echo no)" "rc=$rc"

# Reject out-of-range or ambiguous integer spellings before discovery, rather than blaming an outage.
for invalid_limit in 0 1001 0001 999999999999999999999999999999; do
  run_sweep "$sweep" --limit "$invalid_limit"
  report "invalid --limit $invalid_limit fails before any external call" \
    "$([ "$rc" -eq 1 ] && [ ! -s "$GH_ARGV_LOG" ] && [ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "rc=$rc $out"
done
# Empty successful discovery separates acceptance of both endpoints from saturation handling.
: > "$GH_RESULTS"
for valid_limit in 1 1000; do
  run_sweep "$sweep" --limit "$valid_limit"
  report "valid --limit $valid_limit reaches discovery" \
    "$([ "$rc" -eq 0 ] && [ -s "$GH_ARGV_LOG" ] && echo yes || echo no)" "rc=$rc $out"
done

# ---------------------------------------------------------------------------
# 7c. SATURATION — a result set at the cap may be truncated, so success would hide unboarded issues.
results "$U1" "$U2"
run_sweep "$sweep" --limit 2
report "a result set AT the --limit cap fails closed" \
  "$([ "$rc" -eq 2 ] && grep -q 'TRUNCATED' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
report "a saturated discovery boards nothing" "$([ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "log=[$(cat "$BOARD_LOG")]"
# Control: one BELOW the cap is a complete census and sweeps normally.
run_sweep "$sweep" --limit 3
report "control: one result below the cap sweeps normally" \
  "$([ "$rc" -eq 0 ] && [ "$(wc -l < "$BOARD_LOG" | tr -d ' ')" = 2 ] && echo yes || echo no)" "rc=$rc"

# 7d. A SUCCESSFUL search that writes to stderr must not fold that text into the URL list.
#     The CLI prints an upgrade notice on stderr about once a day, so this is routine, not exotic.
results "$U1" "$U2" "$U3"
GH_STDERR="A new release of gh is available: 2.0.0 -> 2.1.0" run_sweep "$sweep"
got_stderr="$(sort "$BOARD_LOG")"
report "a stderr notice is not passed to board-add as an issue" \
  "$([ "$got_stderr" = "$want" ] && [ "$rc" -eq 0 ] && echo yes || echo no)" "rc=$rc got=[$(echo "$got_stderr" | tr '\n' ' ')]"

# 7d2. BOUNDED BATCH — a backfill larger than the batch defers the remainder instead of exceeding
#      the hourly request budget. Deferral is reported and is NOT a failure: board-add is
#      idempotent, so the next run continues from where this one stopped.
results "$U1" "$U2" "$U3"
run_sweep "$sweep" --max-mutations 2
report "a batch bound stops after max-mutations issues" \
  "$([ "$(wc -l < "$BOARD_LOG" | tr -d ' ')" = 2 ] && echo yes || echo no)" "log=[$(cat "$BOARD_LOG" | tr '\n' ' ')]"
report "the deferred remainder is reported, not failed" \
  "$([ "$rc" -eq 0 ] && grep -q 'deferred=1' <<<"$out" && grep -q 'failed=0' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
report "a deferral says the next run continues" \
  "$(grep -q 'next sweep continues where this one stopped' <<<"$out" && echo yes || echo no)" "$out"
# Control: a batch at least as large as the set defers nothing, so the bound cannot fire vacuously.
run_sweep "$sweep" --max-mutations 3
report "control: a batch covering the whole set defers nothing" \
  "$([ "$rc" -eq 0 ] && [ "$(wc -l < "$BOARD_LOG" | tr -d ' ')" = 3 ] && grep -q 'deferred=0' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

run_sweep "$sweep" --max-mutations 0
report "a zero --max-mutations is a usage error" "$([ "$rc" -eq 1 ] && echo yes || echo no)" "rc=$rc"
run_sweep "$sweep" --max-mutations nope
report "a non-numeric --max-mutations is a usage error" "$([ "$rc" -eq 1 ] && echo yes || echo no)" "rc=$rc"

# 7d3. THE BATCH COUNTS WRITES, NOT ISSUES EXAMINED. Discovery is oldest-first and returns the same
#      prefix every run, so charging an already-boarded issue to the budget would spend the batch on
#      the oldest no-ops and defer everything after them FOREVER — the exact opposite of "the next
#      run continues". Two already-boarded issues plus one needing a write, with a batch of 1:
results "$U1" "$U2" "$U3"
BOARD_ADD_NOOP_ON="$(printf '%s\n%s' "$U1" "$U2")" run_sweep "$sweep" --max-mutations 1
report "already-boarded issues do not consume the write budget" \
  "$([ "$rc" -eq 0 ] && grep -q 'wrote=1' <<<"$out" && grep -q 'deferred=0' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
report "the issue needing a write is still reached past the no-ops" \
  "$(grep -q "boarded ${U3}" <<<"$out" && echo yes || echo no)" "$out"
# Control: charge the same three to the budget as ISSUES and the third would be deferred — this is
# the regression the fix exists to prevent, so prove the counter is the thing that changed.
BOARD_ADD_NOOP_ON="" run_sweep "$sweep" --max-mutations 1
report "control: with three real writes and a batch of 1, two ARE deferred" \
  "$([ "$rc" -eq 0 ] && grep -q 'wrote=1' <<<"$out" && grep -q 'deferred=2' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 7d4. `already-present (status set)` is a REAL write, not a no-op. board-add.sh emits it when it
#      item-edits a card that was on the board without a Status — and a backlog of status-less
#      cards is exactly what this sweep exists to repair, so a bare `already-present` substring
#      match would let the one case that matters bypass the batch and the pacing entirely.
results "$U1" "$U2" "$U3"
BOARD_ADD_STATUS_SET_ON="$(printf '%s\n%s\n%s' "$U1" "$U2" "$U3")" run_sweep "$sweep"
report "a status-set outcome counts as a write" \
  "$([ "$rc" -eq 0 ] && grep -q 'wrote=3' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
# Control: the same three as genuine no-ops must count zero, so the check is not matching everything.
BOARD_ADD_NOOP_ON="$(printf '%s\n%s\n%s' "$U1" "$U2" "$U3")" run_sweep "$sweep"
report "control: status-untouched no-ops count zero writes" \
  "$([ "$rc" -eq 0 ] && grep -q 'wrote=0' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
report "a status-set backlog is still bounded by the batch" \
  "$(BOARD_ADD_STATUS_SET_ON="$(printf '%s\n%s\n%s' "$U1" "$U2" "$U3")" run_sweep "$sweep" --max-mutations 2; grep -q 'wrote=2' <<<"$out" && grep -q 'deferred=1' <<<"$out" && echo yes || echo no)" "$out"

# 7d5. A FAILURE is charged to the budget: board-add.sh can fail after a successful item-add or
#      item-edit (a read-back that does not confirm), so treating failures as costless would let
#      repeated partial writes bypass both safeguards exactly when GitHub is already refusing.
BOARD_ADD_FAIL_ON="$(printf '%s\n%s\n%s' "$U1" "$U2" "$U3")" run_sweep "$sweep"
report "a possibly-partial failure is charged to the write budget" \
  "$([ "$rc" -eq 2 ] && grep -q 'wrote=3' <<<"$out" && grep -q 'failed=3' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
report "repeated failures are bounded by the batch rather than hammering" \
  "$(BOARD_ADD_FAIL_ON="$(printf '%s\n%s\n%s' "$U1" "$U2" "$U3")" run_sweep "$sweep" --max-mutations 1; grep -q 'failed=1' <<<"$out" && grep -q 'deferred=2' <<<"$out" && echo yes || echo no)" "$out"

# 7e. Pacing is validated like every other numeric option.
run_sweep "$sweep" --pace-seconds nope
report "a non-numeric --pace-seconds is a usage error" "$([ "$rc" -eq 1 ] && echo yes || echo no)" "rc=$rc"

# 7f. THE DEFAULTS MUST FIT THE RUNTIME'S CALL BUDGET. A batch large enough to outlast the Bash
#     tool's 120 s default would be killed mid-run, losing the summary and the exit status while
#     leaving the writes it had already made applied — so the defaults are asserted here rather
#     than left to a comment that a later raise could contradict silently.
def_pace="$(awk -F= '/^pace=[0-9]+$/{print $2; exit}' "$sweep")"
def_batch="$(awk -F= '/^max_mutations=[0-9]+$/{print $2; exit}' "$sweep")"
report "the script declares numeric pace and batch defaults" \
  "$([ -n "$def_pace" ] && [ -n "$def_batch" ] && echo yes || echo no)" "pace=[$def_pace] batch=[$def_batch]"
sleep_budget=$(( def_pace * (def_batch - 1) ))
report "a full batch's sleeping fits the 120 s call budget with margin" \
  "$([ "$sleep_budget" -le 90 ] && echo yes || echo no)" "${def_pace}s x ($def_batch - 1) = ${sleep_budget}s"
# The ~500/hour budget is shared across BOTH machine-local lanes, each running this hourly, and
# every write costs two requests.
fleet_hourly=$(( 2 * def_batch * 2 ))
report "two lanes' hourly writes stay well inside the shared ~500 request budget" \
  "$([ "$fleet_hourly" -le 250 ] && echo yes || echo no)" "2 lanes x $def_batch writes x 2 requests = $fleet_hourly"

# ---------------------------------------------------------------------------
# 9. BULK MEMBERSHIP (monorepo#3340). The sweep used to ask board-add.sh about every issue, three
#    remote reads each, so an all-no-op pass over ~780 issues outlived the 120 s call budget. It now
#    reads membership for up to 100 issues per request and hands only the rest to the helper.
results "$U1" "$U2" "$U3"
membership present "$U1" "$U2"
run_sweep "$sweep"
report "an issue the bulk read proves is on the board is not handed to board-add" \
  "$([ "$rc" -eq 0 ] && [ "$(cat "$BOARD_LOG")" = "$U3" ] && echo yes || echo no)" "rc=$rc log=[$(tr '\n' ' ' < "$BOARD_LOG")]"
report "it is reported as already on the board" \
  "$(grep -qF "already on the board ${U1}" <<<"$out" && grep -qF "already on the board ${U2}" <<<"$out" && echo yes || echo no)" "$out"
report "the issue that is missing still goes through board-add" \
  "$(grep -qF "boarded ${U3}" <<<"$out" && echo yes || echo no)" "$out"
report "the summary separates verified from boarded" \
  "$(grep -q 'discovered=3 verified=2 boarded=1 wrote=1 skipped=0 failed=0 deferred=0' <<<"$out" && echo yes || echo no)" "$out"
report "one bulk read covers the three issues" \
  "$([ "$(count_calls bulk)" = 1 ] && [ "$(count_calls project)" = 1 ] && [ "$(count_calls search)" = 1 ] && echo yes || echo no)" "calls=[$(tr '\n' ' ' < "$GH_CALL_LOG")]"

# 9b. PRESENCE IS THE ONLY THING THE BULK READ PROVES. Every other answer leaves the issue to
#     board-add.sh, which does the complete, paginated, verified read. None may read as "on the
#     board": each case asserts the helper WAS consulted for that issue.
for kind in nostatus other private many null wrongid wrongurl absent; do
  results "$U1" "$U2" "$U3"
  membership present "$U1" "$U3"
  membership "$kind" "$U2"
  run_sweep "$sweep"
  report "a '${kind}' answer is not proof of membership: the issue is still checked on its own" \
    "$([ "$rc" -eq 0 ] && [ "$(cat "$BOARD_LOG")" = "$U2" ] && grep -q 'verified=2 boarded=1' <<<"$out" && echo yes || echo no)" \
    "rc=$rc log=[$(tr '\n' ' ' < "$BOARD_LOG")] $out"
done
# A private repository's issue that sits on the board is still the maintainer's decision: it is
# reported SKIPPED by the helper, exactly as before, never counted as verified.
results "$U1" "$U2"
membership private "$U2"
BOARD_ADD_PRIVATE_ON="$U2" run_sweep "$sweep"
report "a private repository's boarded issue is still SKIPPED, not verified" \
  "$([ "$rc" -eq 0 ] && grep -q 'verified=0 boarded=1 wrote=1 skipped=1' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 9c. A FAILED OR INCOMPLETE BULK READ PROVES NOTHING. Each failure mode must send every issue of
#     that read through board-add.sh and say so, never report it as already on the board.
bulk_failure() { # bulk_failure <name> <VAR=value> — run the sweep with that failure injected in the stub
  local name="$1" injected="$2"
  results "$U1" "$U2" "$U3"
  membership present "$U1" "$U2" "$U3"
  rc=0
  : > "$BOARD_LOG"; : > "$GH_ARGV_LOG"; : > "$GH_ARGS_LOG"; : > "$GH_CALL_LOG"; : > "$GH_BULK_IDS"; : > "$GH_BULK_SIZES"
  out="$(env "$injected" PATH="$tmp/bin:$PATH" "$sweep" --author app/agent-fixture --board-add "$tmp/board-add-stub.sh" --pace-seconds 0 2>&1)" || rc=$?
  report "${name}: every issue is checked on its own instead" \
    "$([ "$rc" -eq 0 ] && [ "$(sort "$BOARD_LOG")" = "$want" ] && grep -q 'verified=0 boarded=3' <<<"$out" && echo yes || echo no)" \
    "rc=$rc log=[$(tr '\n' ' ' < "$BOARD_LOG")] $out"
  report "${name}: the sweep says the bulk read did not hold" \
    "$(grep -q 'bulk membership read' <<<"$out" && echo yes || echo no)" "$out"
}
bulk_failure "a bulk read that fails" GH_BULK_EXIT=1
bulk_failure "a bulk read that returns errors and no data" GH_BULK_MODE=errors
bulk_failure "a bulk read that returns fewer nodes than it was asked for" GH_BULK_MODE=short
bulk_failure "a board id that cannot be resolved" GH_PROJECT_EXIT=1
bulk_failure "a board id that comes back empty" GH_PROJECT_ID=
# An errors entry beside COMPLETE data voids nothing by itself: each node is still validated on its
# own, and the one that came back null is the one that falls through.
results "$U1" "$U2" "$U3"
membership present "$U1" "$U3"
membership null "$U2"
GH_BULK_MODE=partial run_sweep "$sweep"
report "a partial error keeps the nodes that validate and checks the null one on its own" \
  "$([ "$rc" -eq 0 ] && [ "$(cat "$BOARD_LOG")" = "$U2" ] && grep -q 'verified=2 boarded=1' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 9d. NO SILENT TRUNCATION. 250 issues take three reads of at most 100, and every discovered id is
#     asked about exactly once.
many_issues() { # many_issues <count> <kind> — a discovery set of <count> issues, all of one kind
  local i
  : > "$GH_RESULTS"; : > "$GH_MEMBERSHIP"
  for ((i = 1; i <= $1; i++)); do
    printf 'I_bulk_%s\thttps://github.com/devantler-tech/bulk/issues/%s\n' "$i" "$i" >> "$GH_RESULTS"
    printf 'I_bulk_%s\thttps://github.com/devantler-tech/bulk/issues/%s\t%s\n' "$i" "$i" "$2" >> "$GH_MEMBERSHIP"
  done
}
many_issues 250 present
run_sweep "$sweep" --limit 1000
report "250 issues are read in three requests of at most 100" \
  "$([ "$(tr '\n' ' ' < "$GH_BULK_SIZES")" = "100 100 50 " ] && echo yes || echo no)" "sizes=[$(tr '\n' ' ' < "$GH_BULK_SIZES")]"
report "every discovered id is asked about exactly once" \
  "$([ "$(sort "$GH_BULK_IDS")" = "$(cut -f1 "$GH_RESULTS" | sort)" ] && echo yes || echo no)" "asked=$(wc -l < "$GH_BULK_IDS" | tr -d ' ')"
report "all 250 are verified without one board-add call" \
  "$([ "$rc" -eq 0 ] && [ ! -s "$BOARD_LOG" ] && grep -q 'discovered=250 verified=250 boarded=0 wrote=0' <<<"$out" && echo yes || echo no)" "rc=$rc $(tail -n 1 <<<"$out")"
# The issue in the LAST position of a full read and the FIRST of the next are where an off-by-one
# would drop or double-count one.
many_issues 201 present
membership absent https://github.com/devantler-tech/bulk/issues/100 https://github.com/devantler-tech/bulk/issues/101 https://github.com/devantler-tech/bulk/issues/201
run_sweep "$sweep" --limit 1000
report "the issues at a read boundary are neither dropped nor counted twice" \
  "$([ "$rc" -eq 0 ] && [ "$(tr '\n' ' ' < "$BOARD_LOG")" = "https://github.com/devantler-tech/bulk/issues/100 https://github.com/devantler-tech/bulk/issues/101 https://github.com/devantler-tech/bulk/issues/201 " ] && grep -q 'discovered=201 verified=198 boarded=3' <<<"$out" && echo yes || echo no)" \
  "rc=$rc log=[$(tr '\n' ' ' < "$BOARD_LOG")] $(tail -n 1 <<<"$out")"

# 9e. THE MEASURED CASE: 778 issues, all already on the board. Before, that was 778 board-add calls
#     of three remote reads each. Now it is one search, one board id and eight bulk reads.
many_issues 778 present
SECONDS=0
run_sweep "$sweep" --limit 1000
fixture_seconds="$SECONDS"
report "a 778-issue all-no-op pass makes ten remote calls and no board-add call" \
  "$([ "$rc" -eq 0 ] && [ ! -s "$BOARD_LOG" ] && [ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" = 10 ] && [ "$(count_calls bulk)" = 8 ] && echo yes || echo no)" \
  "rc=$rc calls=$(wc -l < "$GH_CALL_LOG" | tr -d ' ') bulk=$(count_calls bulk) helper=$(wc -l < "$BOARD_LOG" | tr -d ' ')"
report "it ends with the terminal summary" \
  "$(grep -q 'discovered=778 verified=778 boarded=0 wrote=0 skipped=0 failed=0 deferred=0' <<<"$out" && echo yes || echo no)" "$(tail -n 1 <<<"$out")"
report "its local work fits the 120 s call budget many times over" \
  "$([ "$fixture_seconds" -le 60 ] && echo yes || echo no)" "${fixture_seconds}s"

# 9e2. A discovery row the script cannot read stops the sweep: it never guesses which half is the URL.
printf '%s\n' "$U1" > "$GH_RESULTS"
run_sweep "$sweep"
report "a discovery row with no node id fails closed and boards nothing" \
  "$([ "$rc" -eq 2 ] && [ ! -s "$BOARD_LOG" ] && grep -q 'nothing swept' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
printf 'I_x\t%s\n' "https://github.com/devantler-tech/monorepo/pull/1" > "$GH_RESULTS"
run_sweep "$sweep"
report "a discovery row whose second field is not an issue URL fails closed" \
  "$([ "$rc" -eq 2 ] && [ ! -s "$BOARD_LOG" ] && [ "$(count_calls bulk)" = 0 ] && echo yes || echo no)" "rc=$rc $out"

# 9f. DRY-RUN is the read-only path: it performs the bulk read, and still never calls the helper.
results "$U1" "$U2" "$U3"
membership present "$U1"
run_sweep "$sweep" --dry-run
report "dry-run reports what the bulk read proved and what it would board, with no helper call" \
  "$([ "$rc" -eq 0 ] && [ ! -s "$BOARD_LOG" ] && grep -qF "already on the board ${U1}" <<<"$out" && grep -qF "DRY-RUN would board ${U2}" <<<"$out" && grep -qF "DRY-RUN would board ${U3}" <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 9g. The board the bulk read matches on must be the board board-add.sh writes to.
for constant in PROJECT_NUMBER PROJECT_OWNER; do
  sweep_value="$(sed -n "s/^readonly ${constant}=//p" "$sweep")"
  helper_value="$(sed -n "s/^readonly ${constant}=//p" "$here/board-add.sh")"
  report "the sweep and board-add.sh agree on ${constant}" \
    "$([ -n "$sweep_value" ] && [ "$sweep_value" = "$helper_value" ] && echo yes || echo no)" "sweep=[$sweep_value] helper=[$helper_value]"
done

# ---------------------------------------------------------------------------
# 10. DEADLINE AND CHECKPOINT. A pass that still has per-issue work when the deadline arrives stops
#     calling the helper, says where it stopped, and prints the terminal summary — instead of being
#     killed by the call timeout with neither.
#     The margins are wide on purpose: the three stubbed reads before the first helper call must
#     finish inside the deadline even on a loaded runner, and the helper call must outlast it.
results "$U1" "$U2" "$U3"
BOARD_ADD_SLEEP=9 run_sweep "$sweep" --deadline-seconds 8
report "a deadline stops the per-issue work after the call in flight" \
  "$([ "$rc" -eq 0 ] && [ "$(cat "$BOARD_LOG")" = "$U1" ] && echo yes || echo no)" "rc=$rc log=[$(tr '\n' ' ' < "$BOARD_LOG")]"
report "the unexamined issues are deferred and the summary is still printed" \
  "$(grep -q 'discovered=3 verified=0 boarded=1 wrote=1 skipped=0 failed=0 deferred=2' <<<"$out" && echo yes || echo no)" "$out"
report "the checkpoint names the first issue not examined" \
  "$(grep -qF "checkpoint=${U2}" <<<"$out" && grep -qF -- "--resume-from ${U2}" <<<"$out" && echo yes || echo no)" "$out"
# Verified issues cost nothing, so they are still counted after the deadline has passed.
results "$U1" "$U2" "$U3"
membership present "$U3"
run_sweep "$sweep" --deadline-seconds 0
report "a zero deadline examines nothing, yet still counts what the bulk read proved" \
  "$([ "$rc" -eq 0 ] && [ ! -s "$BOARD_LOG" ] && grep -q 'discovered=3 verified=1 boarded=0 wrote=0 skipped=0 failed=0 deferred=2' <<<"$out" && grep -qF "checkpoint=${U1}" <<<"$out" && echo yes || echo no)" "rc=$rc $out"
# Control: with time to spare nothing is deferred and no checkpoint is printed.
results "$U1" "$U2" "$U3"
run_sweep "$sweep" --deadline-seconds 60
report "control: a pass inside its deadline defers nothing and prints no checkpoint" \
  "$([ "$rc" -eq 0 ] && grep -q 'deferred=0' <<<"$out" && ! grep -q 'checkpoint=' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 10b. RESUME. The checkpoint is usable: the next call starts its per-issue work there.
results "$U1" "$U2" "$U3"
run_sweep "$sweep" --resume-from "$U2"
report "--resume-from starts the per-issue work at the checkpoint" \
  "$([ "$rc" -eq 0 ] && [ "$(tr '\n' ' ' < "$BOARD_LOG")" = "$U2 $U3 " ] && echo yes || echo no)" "rc=$rc log=[$(tr '\n' ' ' < "$BOARD_LOG")]"
report "the issues before the checkpoint are reported deferred, not dropped" \
  "$(grep -q 'discovered=3 verified=0 boarded=2 wrote=2 skipped=0 failed=0 deferred=1' <<<"$out" && echo yes || echo no)" "$out"
# A checkpoint that discovery no longer returns cannot place the resume point, so nothing is assumed.
run_sweep "$sweep" --resume-from https://github.com/devantler-tech/monorepo/issues/999
report "a checkpoint that is no longer discovered fails closed and boards nothing" \
  "$([ "$rc" -eq 2 ] && [ ! -s "$BOARD_LOG" ] && grep -q 'not among the discovered issues' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
run_sweep "$sweep" --resume-from not-a-url
report "a --resume-from that is not an issue URL is a usage error with no external call" \
  "$([ "$rc" -eq 1 ] && [ ! -s "$GH_ARGV_LOG" ] && [ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "rc=$rc $out"
run_sweep "$sweep" --deadline-seconds soon
report "a non-numeric --deadline-seconds is a usage error" "$([ "$rc" -eq 1 ] && echo yes || echo no)" "rc=$rc"

# 10c. AN INTERRUPTED RUN STILL REPORTS. A TERM delivered while the helper is working lets that call
#      finish, then stops with the checkpoint and the summary, and exits 2: its coverage is unknown.
results "$U1" "$U2" "$U3"
: > "$BOARD_LOG"; : > "$GH_CALL_LOG"; : > "$GH_BULK_IDS"; : > "$GH_BULK_SIZES"
BOARD_ADD_SLEEP=3 PATH="$tmp/bin:$PATH" "$sweep" --author app/agent-fixture --board-add "$tmp/board-add-stub.sh" \
  --pace-seconds 0 > "$tmp/interrupted.out" 2>&1 &
sweep_pid=$!
# Signal only once the helper is running, so the signal lands in the per-issue work.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$BOARD_LOG" ] && break
  sleep 0.5
done
kill -TERM "$sweep_pid"
int_rc=0
wait "$sweep_pid" || int_rc=$?
int_out="$(cat "$tmp/interrupted.out")"
report "an interrupted run exits 2 after the call in flight" \
  "$([ "$int_rc" -eq 2 ] && [ "$(cat "$BOARD_LOG")" = "$U1" ] && echo yes || echo no)" "rc=$int_rc log=[$(tr '\n' ' ' < "$BOARD_LOG")] $int_out"
report "an interrupted run still prints its checkpoint and counts" \
  "$(grep -q 'discovered=3 verified=0 boarded=1 wrote=1 skipped=0 failed=0 deferred=2' <<<"$int_out" && grep -qF "checkpoint=${U2}" <<<"$int_out" && echo yes || echo no)" "$int_out"

# 10d. THE DEFAULT DEADLINE MUST FIT THE CALL BUDGET, like the batch defaults above.
def_deadline="$(awk -F= '/^deadline=[0-9]+$/{print $2; exit}' "$sweep")"
report "the script declares a numeric default deadline inside the 120 s call budget" \
  "$([ -n "$def_deadline" ] && [ "$def_deadline" -gt 0 ] && [ "$def_deadline" -le 100 ] && echo yes || echo no)" "deadline=[$def_deadline]"

# 8. ABLATION — a copy that drops the LAST discovered issue must make assertion 1 FIRE.
#    Without this, a set comparison that can never fail would read as a passing test.
ablated="$tmp/sweep-ablated.sh"
# Drop the LAST discovered issue by teaching the loop to skip that exact URL. `awk` rather than
# `sed` because the inserted guard contains `||`, which collides with every convenient sed delimiter.
awk -v skip="$U3" '
  { print }
  /^  \[ -n "\$url" \] \|\| continue$/ && !done { printf "  [ \"$url\" = \"%s\" ] && continue\n", skip; done=1 }
' "$sweep" > "$ablated"
chmod +x "$ablated"
grep -q "&& continue" "$ablated" || report "ablation edit landed" no "the awk insert did not apply"
results "$U1" "$U2" "$U3"
run_sweep "$ablated"
got_abl="$(sort "$BOARD_LOG")"
if [ "$got_abl" = "$want" ]; then
  report "ablation: dropping an issue makes the set assertion fire" no "the ablated copy still passed — assertion 1 cannot fail"
else
  report "ablation: dropping an issue makes the set assertion fire" yes
fi

# 8b. ABLATION OF THE BULK PROOF. Each condition a node must meet is removed from a copy in turn, and
#     the copy must then WRONGLY treat the matching issue as already on the board — that is, never
#     hand it to board-add. A condition whose removal changes nothing is not protecting anything.
# The literals are jq source, so nothing in them is meant to expand.
# shellcheck disable=SC2016
ablate_proof() { # ablate_proof <name> <literal> <replacement> <kind the condition guards against>
  local name="$1" copy="$tmp/sweep-proof-ablated.sh"
  LITERAL="$2" REPLACEMENT="$3" awk '
    { i = index($0, ENVIRON["LITERAL"]) }
    i { $0 = substr($0, 1, i - 1) ENVIRON["REPLACEMENT"] substr($0, i + length(ENVIRON["LITERAL"])); hits++ }
    { print }
    END { exit hits == 1 ? 0 : 1 }' "$sweep" > "$copy" || {
    report "ablation: ${name}" no "the literal did not match exactly once, so the result proves nothing"
    return 0
  }
  chmod +x "$copy"
  results "$U1" "$U2" "$U3"
  membership present "$U1" "$U3"
  membership "$4" "$U2"
  run_sweep "$copy"
  report "ablation: ${name}" \
    "$([ ! -s "$BOARD_LOG" ] && grep -q 'verified=3' <<<"$out" && echo yes || echo no)" \
    "the ablated copy still checked the issue on its own — rc=$rc log=[$(tr '\n' ' ' < "$BOARD_LOG")] $(tail -n 1 <<<"$out")"
}
# shellcheck disable=SC2016
{
  ablate_proof "without the board-id match, an item on another project counts as boarded" \
    '.project.id == $project and ' '' other
  ablate_proof "without the Status requirement, a status-less card counts as boarded" \
    '((.fieldValueByName.name // "") | type == "string" and length > 0)' 'true' nostatus
  ablate_proof "without the id and url match, a node answering for another issue counts" \
    '| select($node.id == $want.id and $node.url == $want.url)' '' wrongid
  ablate_proof "without the visibility requirement, a private repository's issue counts as verified" \
    '| select($node.repository.isPrivate == false)' '' private
}
# The length rule is what keeps a short answer from being read position by position. Without it the
# two nodes that did arrive are trusted, and only the missing one is checked on its own.
short_copy="$tmp/sweep-short-ablated.sh"
# shellcheck disable=SC2016
LITERAL=' or (.data.nodes | length) != ($asked | length)' awk '
  { i = index($0, ENVIRON["LITERAL"]) }
  i { $0 = substr($0, 1, i - 1) substr($0, i + length(ENVIRON["LITERAL"])); hits++ }
  { print }
  END { exit hits == 1 ? 0 : 1 }' "$sweep" > "$short_copy" || report "ablation: the length rule literal matched once" no
chmod +x "$short_copy"
results "$U1" "$U2" "$U3"
membership present "$U1" "$U2" "$U3"
GH_BULK_MODE=short run_sweep "$short_copy"
report "ablation: without the length rule, a short answer is trusted for the nodes that arrived" \
  "$([ "$(cat "$BOARD_LOG")" = "$U3" ] && grep -q 'verified=2' <<<"$out" && echo yes || echo no)" \
  "log=[$(tr '\n' ' ' < "$BOARD_LOG")] $(tail -n 1 <<<"$out")"

if [ "$fail" -eq 0 ]; then echo "agent-issue-board-sweep self-test: all cases passed"; else echo "agent-issue-board-sweep self-test: FAILED" >&2; exit 1; fi
