#!/usr/bin/env bash
# The ablation phrases below are literal jq source, so nothing in them is meant to expand.
# shellcheck disable=SC2016
# managed-run-streak.test.sh — behavioural proof for managed-run-streak.sh (monorepo#2768).
# Each rule the helper encodes has a case that fails when that rule is removed, and the ablations
# at the end remove one rule at a time to prove it.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tool="${here}/managed-run-streak.sh"
live_fixture="${here}/fixtures/managed-run-streak-ksail-code-quality-2768.json"

tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -e abort inside an EXIT trap as exit 0, so require completion.
on_exit() {
  local status=$?
  rm -rf "${tmp}"
  if [ "${completed}" != 1 ]; then
    echo "managed-run-streak.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT
failures=0
checks=0

[ -s "${live_fixture}" ] || { echo "FAIL fixture missing or empty: ${live_fixture}" >&2; exit 1; }

# r <id> <name|null> <conclusion|null> <created_at> [branch] [status]  -> one run object
r() {
  jq -nc --argjson id "$1" --arg name "$2" --arg c "$3" --arg t "$4" \
    --arg b "${5:-main}" --arg s "${6:-completed}" '{
      id: $id,
      name: (if $name == "null" then null else $name end),
      status: $s,
      conclusion: (if $c == "null" then null else $c end),
      created_at: $t,
      head_branch: $b
    }'
}

# payload <judged-id> <run>...  -> the helper's stdin: one run object per line, the judged one marked.
# Each run carries the page's total_count, which defaults to the number of distinct runs given (a
# complete read); a run that already carries one keeps it.
payload() {
  local id="$1"
  shift
  printf '%s\n' "$@" |
    jq -sc --argjson id "${id}" '(map(.id) | unique | length) as $n
      | .[] | {total_count: $n} + . + {judged: (.id == $id)}'
}

# window <count> <total_count>  -> <count> runs, oldest green and the rest red, the newest judged
window() {
  jq -nc --argjson n "$1" --argjson total "$2" 'range(1; $n + 1) as $i | {
      id: $i, name: "Code Quality: Push on main", status: "completed",
      conclusion: (if $i == 1 then "success" else "failure" end),
      created_at: ("2026-09-01T00:00:00Z" | fromdate | . + $i * 60 | todate),
      head_branch: "main", total_count: $total, judged: ($i == $n)
    }'
}

run() { # run <tool> <payload> [args...] -> sets got, rc
  local t="$1" p="$2"
  shift 2
  [ "$#" -gt 0 ] || set -- --input -
  set +e
  got="$(printf '%s' "${p}" | bash "${t}" "$@" 2>"${tmp}/stderr")"
  rc=$?
  set -e
}

expect() { # expect <name> <want-rc> <want-line> <payload> [args...]
  local name="$1" want_rc="$2" want="$3" p="$4"
  shift 4
  checks=$((checks + 1))
  run "${tool}" "${p}" "$@"
  if [ "${rc}" != "${want_rc}" ] || [ "${got}" != "${want}" ]; then
    echo "FAIL ${name}: want rc=${want_rc} '${want}', got rc=${rc} '${got}' ($(cat "${tmp}/stderr"))" >&2
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

# lone <older-run-of-unit:yes|no>  -> a capped listing (total_count 2500) of 1000 runs: the newest is
# the judged red run of one dependency, and every other run belongs to another dependency, except,
# with `yes`, the oldest, which is an earlier green of the judged one.
lone() {
  jq -nc --arg older "$1" 'range(1; 1001) as $i | {
      id: $i,
      name: (if $i == 1000 or ($i == 1 and $older == "yes") then "helm in /a - Update #\($i)"
             else "docker in /b - Update #\($i)" end),
      status: "completed", conclusion: (if $i == 1000 then "failure" else "success" end),
      created_at: ("2026-09-01T00:00:00Z" | fromdate | . + $i * 60 | todate),
      head_branch: "main", total_count: 2500, judged: ($i == 1000)
    }'
}

refused() { # refused <name> <stderr-substring> <payload>  -> exit 2, no stdout, and the right reason
  local name="$1" reason="$2" p="$3"
  checks=$((checks + 1))
  run "${tool}" "${p}"
  if [ "${rc}" != 2 ] || [ -n "${got}" ] || ! grep -qF -- "${reason}" "${tmp}/stderr"; then
    echo "FAIL ${name}: want rc=2, no output and '${reason}', got rc=${rc} '${got}' ($(cat "${tmp}/stderr"))" >&2
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

d="Code Quality: Push on main"
dep_a="helm in /pkg/svc/installer/awslbcontroller"
dep_b="docker in /pkg/svc/installer/kyverno"

# --- the rules --------------------------------------------------------------------------------

# Live corpus, ksail 2026-09-24: four consecutive red CodeQL runs on main after a green.
live="$(jq -c '.[0].id as $id | length as $n | .[] | . + {total_count: $n, judged: (.id == $id)}' "${live_fixture}")"
expect "live ksail streak is REPEATED" 1 "REPEATED runs=4 since=2026-09-24" "${live}"

expect "a single red after a green is the exempt FIRST failure" 0 "FIRST since=2026-09-10" \
  "$(payload 2 "$(r 1 "$d" success 2026-09-09T05:00:00Z)" "$(r 2 "$d" failure 2026-09-10T05:00:00Z)")"

expect "a red that a newer green already recovered is CLEAR" 0 "CLEAR" \
  "$(payload 1 "$(r 1 "$d" failure 2026-09-09T05:00:00Z)" "$(r 2 "$d" success 2026-09-10T05:00:00Z)")"

expect "a recovered red stays CLEAR when a newer streak has since started" 0 "CLEAR" \
  "$(payload 1 "$(r 1 "$d" failure 2026-09-09T05:00:00Z)" "$(r 2 "$d" success 2026-09-10T05:00:00Z)" \
    "$(r 3 "$d" failure 2026-09-11T05:00:00Z)")"

expect "since is the OLDEST red of the streak, not the previous run" 1 "REPEATED runs=3 since=2026-09-01" \
  "$(payload 4 "$(r 0 "$d" success 2026-08-31T05:00:00Z)" "$(r 1 "$d" failure 2026-09-01T05:00:00Z)" \
    "$(r 3 "$d" failure 2026-09-05T05:00:00Z)" "$(r 4 "$d" failure 2026-09-09T05:00:00Z)")"

expect "a history with no green behind the streak counts every red" 1 "REPEATED runs=2 since=2026-09-01" \
  "$(payload 2 "$(r 1 "$d" failure 2026-09-01T05:00:00Z)" "$(r 2 "$d" failure 2026-09-02T05:00:00Z)")"

# The per-run id is stripped: two runs of one dependency are one unit.
expect "per-run Update ids are stripped, so one dependency forms a streak" 1 "REPEATED runs=2 since=2026-09-01" \
  "$(payload 2 "$(r 1 "${dep_a} - Update #1510869626" failure 2026-09-01T05:00:00Z)" \
    "$(r 2 "${dep_a} - Update #1510870001" failure 2026-09-02T05:00:00Z)")"

expect "a bare trailing #id is stripped too" 1 "REPEATED runs=2 since=2026-09-01" \
  "$(payload 2 "$(r 1 "${dep_a} #11" failure 2026-09-01T05:00:00Z)" "$(r 2 "${dep_a} #12" failure 2026-09-02T05:00:00Z)")"

# One workflow id, two dependencies: first failures of each must not merge into a streak.
expect "first failures of two different dependencies stay FIRST" 0 "FIRST since=2026-09-02" \
  "$(payload 2 "$(r 1 "${dep_a} - Update #1" failure 2026-09-01T05:00:00Z)" \
    "$(r 2 "${dep_b} - Update #2" failure 2026-09-02T05:00:00Z)")"

expect "an unrelated dependency's green does not break a real streak" 1 "REPEATED runs=2 since=2026-09-01" \
  "$(payload 3 "$(r 1 "${dep_a} - Update #1" failure 2026-09-01T05:00:00Z)" \
    "$(r 2 "${dep_b} - Update #2" success 2026-09-02T05:00:00Z)" \
    "$(r 3 "${dep_a} - Update #3" failure 2026-09-03T05:00:00Z)")"

expect "a null run name does not abort the walk" 1 "REPEATED runs=2 since=2026-09-01" \
  "$(payload 2 "$(r 1 null failure 2026-09-01T05:00:00Z)" "$(r 2 null failure 2026-09-02T05:00:00Z)" \
    "$(r 3 "$d" success 2026-09-03T05:00:00Z)")"

expect "timed_out and startup_failure are red" 1 "REPEATED runs=3 since=2026-09-01" \
  "$(payload 3 "$(r 1 "$d" startup_failure 2026-09-01T05:00:00Z)" "$(r 2 "$d" timed_out 2026-09-02T05:00:00Z)" \
    "$(r 3 "$d" startup_failure 2026-09-03T05:00:00Z)")"

expect "cancelled is not red and breaks the streak" 0 "FIRST since=2026-09-03" \
  "$(payload 3 "$(r 1 "$d" failure 2026-09-01T05:00:00Z)" "$(r 2 "$d" cancelled 2026-09-02T05:00:00Z)" \
    "$(r 3 "$d" failure 2026-09-03T05:00:00Z)")"

expect "a pull-request green between two main reds does not break the streak" 1 "REPEATED runs=2 since=2026-09-01" \
  "$(payload 3 "$(r 1 "$d" failure 2026-09-01T05:00:00Z)" "$(r 2 "$d" success 2026-09-02T05:00:00Z feature)" \
    "$(r 3 "$d" failure 2026-09-03T05:00:00Z)")"

expect "a pull-request red does not extend a main streak" 0 "FIRST since=2026-09-03" \
  "$(payload 3 "$(r 1 "$d" success 2026-09-01T05:00:00Z)" "$(r 2 "$d" failure 2026-09-02T05:00:00Z feature)" \
    "$(r 3 "$d" failure 2026-09-03T05:00:00Z)")"

expect "an unfinished run neither extends nor breaks the streak" 1 "REPEATED runs=2 since=2026-09-01" \
  "$(payload 2 "$(r 1 "$d" failure 2026-09-01T05:00:00Z)" "$(r 2 "$d" failure 2026-09-02T05:00:00Z)" \
    "$(r 3 "$d" null 2026-09-03T05:00:00Z main in_progress)")"

expect "order comes from created_at, not from input order" 0 "CLEAR" \
  "$(payload 1 "$(r 3 "$d" success 2026-09-03T05:00:00Z)" "$(r 1 "$d" failure 2026-09-01T05:00:00Z)" \
    "$(r 2 "$d" failure 2026-09-02T05:00:00Z)")"

# Completeness (monorepo#3586): the surveyor pipes gh straight into the helper, so a read that died
# after some pages reaches it as a shorter history. The page's own total_count catches that.
expect "a run two pages both returned is counted once" 1 "REPEATED runs=2 since=2026-09-02" \
  "$(payload 3 "$(r 1 "$d" success 2026-09-01T05:00:00Z)" "$(r 2 "$d" failure 2026-09-02T05:00:00Z)" \
    "$(r 2 "$d" failure 2026-09-02T05:00:00Z)" "$(r 3 "$d" failure 2026-09-03T05:00:00Z)")"

refused "a history shorter than its total_count is refused" "history incomplete: read 2 of 3 runs" \
  "$(payload 2 "$(r 1 "$d" success 2026-09-01T05:00:00Z | jq -c '. + {total_count: 3}')" \
    "$(r 2 "$d" failure 2026-09-02T05:00:00Z | jq -c '. + {total_count: 3}')")"

refused "a run that arrives mid-read makes the history incomplete" "history incomplete: read 2 of 3 runs" \
  "$(payload 2 "$(r 1 "$d" success 2026-09-01T05:00:00Z | jq -c '. + {total_count: 2}')" \
    "$(r 2 "$d" failure 2026-09-02T05:00:00Z | jq -c '. + {total_count: 3}')")"

expect "the newest 1000 runs are complete when GitHub caps the listing" 1 "REPEATED runs=999 since=2026-09-01" \
  "$(window 1000 2500)"

refused "fewer than 1000 runs of a capped listing are refused" "history incomplete: read 999 of 1000 runs" \
  "$(window 999 2500)"

refused "a lone red at the edge of a capped listing cannot be proven FIRST" \
  "streak start lies outside the newest 1000 runs" "$(lone no)"

expect "a lone red with an earlier green of its unit in a capped listing is FIRST" 0 "FIRST since=2026-09-01" \
  "$(lone yes)"

# --- refusals ---------------------------------------------------------------------------------

expect "a judged run absent from the input is refused" 2 "" \
  "$(payload 9 "$(r 1 "$d" failure 2026-09-01T05:00:00Z)")"
expect "a judged run that is not red is refused" 2 "" \
  "$(payload 1 "$(r 1 "$d" success 2026-09-01T05:00:00Z)")"
expect "a judged run off main is refused" 2 "" \
  "$(payload 1 "$(r 1 "$d" failure 2026-09-01T05:00:00Z feature)")"
expect "a run missing a field is refused" 2 "" '{"id":1,"name":"x","status":"completed","conclusion":"failure","created_at":"2026-09-01T05:00:00Z","total_count":1,"judged":true}'
refused "a run missing total_count is refused as malformed" "stdin must be a stream of run objects" \
  '{"id":1,"name":"x","status":"completed","conclusion":"failure","created_at":"2026-09-01T05:00:00Z","head_branch":"main","judged":true}'
expect "two judged runs are refused" 2 "" "$(payload 1 "$(r 1 "$d" failure 2026-09-01T05:00:00Z)") $(payload 1 "$(r 1 "$d" failure 2026-09-02T05:00:00Z)")"
expect "a non-object value is refused" 2 "" "$(payload 1 "$(r 1 "$d" failure 2026-09-01T05:00:00Z)") [1]"
expect "an array instead of a stream is refused" 2 "" "[$(payload 1 "$(r 1 "$d" failure 2026-09-01T05:00:00Z)")]"
expect "an empty stdin is refused" 2 "" ''
expect "a missing --input is refused" 2 "" "${live}" --run 1

# --- ablations: remove one rule at a time; the suite must notice each ---------------------------

ablate() { # ablate <label> <phrase> <replacement>
  local label="$1" phrase="$2" replacement="$3" copy="${tmp}/ablated.sh" n
  n="$(grep -cF -- "${phrase}" "${tool}" || true)"
  if [ "${n}" != 1 ]; then
    echo "FAIL ablation '${label}': phrase must occur exactly once, found ${n}" >&2
    failures=$((failures + 1))
    return
  fi
  PHRASE="${phrase}" REPLACEMENT="${replacement}" perl -0pe 's/\Q$ENV{PHRASE}\E/$ENV{REPLACEMENT}/' "${tool}" >"${copy}"
  if cmp -s "${tool}" "${copy}"; then
    echo "FAIL ablation '${label}': substitution changed nothing" >&2
    failures=$((failures + 1))
    return
  fi
  local saved_tool="${tool}" saved_failures="${failures}" saved_checks="${checks}"
  tool="${copy}"
  run_rules >/dev/null 2>&1 || true
  local caught=$((failures - saved_failures))
  tool="${saved_tool}"
  failures="${saved_failures}"
  checks="${saved_checks}"
  checks=$((checks + 1))
  if [ "${caught}" -gt 0 ]; then
    echo "ok   ablation caught: ${label} (${caught} case(s) failed)"
  else
    echo "FAIL ablation not caught: ${label}" >&2
    failures=$((failures + 1))
  fi
}

# run_rules re-runs every rule case above against ${tool}; it is the body the ablations reuse.
run_rules() {
  sed -n '/^# --- the rules/,/^# --- ablations/p' "${BASH_SOURCE[0]}" >"${tmp}/rules.sh"
  # shellcheck disable=SC1091
  source "${tmp}/rules.sh"
}

ablate "per-run id strip" 'sub("( - Update)? #[0-9]+$"; "")' 'sub("^$"; "")'
ablate "null name guard" '(.name // "")' '(.name)'
ablate "timed_out is red" '.conclusion == "timed_out" or ' ''
ablate "startup_failure is red" ' or .conclusion == "startup_failure"' ''
ablate "main-only history" 'select(.head_branch == "main" and ' 'select('
ablate "finished runs only" '.status == "completed" and (unit == $u)' '(unit == $u)'
ablate "sort by created_at" 'sort_by(.created_at, .id) | reverse' '.'
ablate "walk to the first non-red run" '"REPEATED runs=\($n) since=\(.[$n - 1].created_at[0:10])"' '"REPEATED runs=\($n) since=\(.[1].created_at[0:10])"'
ablate "completeness check" 'if $read < $expected then' 'if false then'
ablate "largest total_count" '(map(.total_count) | max) as $total' '(map(.total_count) | min) as $total'
ablate "1000-run listing cap" '([$total, 1000] | min) as $expected' '$total as $expected'
ablate "one count per run" '(unique_by(.id)) as $runs' '. as $runs'
ablate "unprovable FIRST at a capped edge" 'elif $n == 1 and $capped and length == 1 then' 'elif false then'

completed=1
echo "managed-run-streak: ${checks} checks, ${failures} failure(s)"
[ "${failures}" = 0 ]
