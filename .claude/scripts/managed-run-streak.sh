#!/usr/bin/env bash
# managed-run-streak.sh — decide whether a red GitHub-managed run on main is the FIRST failure of
# its streak (exempt) or a REPEATED one (actionable) (monorepo#2768).
#
# WHY THIS EXISTS
#   A GitHub-managed run (`event: dynamic`, path under `dynamic/`) has no workflow file to fix, so a
#   single red one is reported NO-ACTION. A red that persists across consecutive runs on main is
#   ours to repair, and must escalate to `(REPEATED — ACTIONABLE)`. Until this helper, that rule
#   lived only in the surveyor overlay's prose, where a wrong rule passes every text pin. The
#   measured traps it encodes:
#     - one managed workflow id aggregates independent jobs, so the unit is the run NAME with its
#       per-run id stripped (`… - Update #123`, `… #123`); an exact name caps every streak at 1
#       (48 runs, 48 distinct names, ksail 2026-08-07), and a workflow-id-wide walk merges
#       unrelated dependencies;
#     - a NULL name exists in the live corpus and must not abort the walk;
#     - red is `failure`, `timed_out` OR `startup_failure` — a config that will not parse concludes
#       `startup_failure` on every attempt and must still accumulate a streak;
#     - only runs on `main` count: a pull-request scan must neither extend nor break a streak;
#     - the streak's age comes from walking back to the first non-red run, never a two-run peek.
#   An unfinished run has no verdict yet, so it neither extends nor breaks a streak; order comes
#   from `created_at` (then `id`), never from the order the API happened to return.
#
# USAGE
#   managed-run-streak.sh --input -
#   stdin: ONE JSON object {"run": <id>, "runs": [<run>, ...]}, where `run` is the numeric id of
#          the red run being judged and `runs` is that workflow's run history on main, e.g. every
#          `.workflow_runs[]` from
#          `gh api --paginate "repos/<o>/<r>/actions/workflows/<id>/runs?branch=main&per_page=100"`.
#          Each run needs `id` (number), `name` (string or null), `status` (string),
#          `conclusion` (string or null), `created_at` (string) and `head_branch` (string or null).
#          The run name is read only from this data; it never enters a command line.
#
# OUTPUT (one line on stdout)
#   CLEAR                          the newest finished run of this unit on main is not red
#   FIRST since=<YYYY-MM-DD>       exactly one red run: exempt, report NO-ACTION
#   REPEATED runs=<n> since=<YYYY-MM-DD>
#                                  <n> >= 2 consecutive red runs: actionable, counts as a fire
#
# EXIT CODES
#   0  CLEAR or FIRST
#   1  REPEATED
#   2  usage error, malformed input, or the judged run is absent or not red on main
set -euo pipefail

usage() {
  sed -n '23,42p' "$0" >&2
  exit 2
}

[ "$#" -eq 2 ] && [ "$1" = "--input" ] && [ "$2" = "-" ] || usage
command -v jq >/dev/null 2>&1 || {
  echo "managed-run-streak: jq is required" >&2
  exit 2
}

payload="$(cat)" || exit 2
jq -se 'length == 1 and (.[0] | type == "object"
    and (keys == ["run", "runs"])
    and (.run | type == "number")
    and (.runs | type == "array")
    and (.runs | all(type == "object"
      and (.id | type == "number")
      and ((.name | type) as $t | $t == "string" or $t == "null")
      and (.status | type == "string")
      and ((.conclusion | type) as $t | $t == "string" or $t == "null")
      and (.created_at | type == "string")
      and ((.head_branch | type) as $t | $t == "string" or $t == "null"))))' \
  <<<"$payload" >/dev/null 2>&1 || {
  echo "managed-run-streak: stdin must be one JSON object {run: <id>, runs: [...]} whose runs carry id, name, status, conclusion, created_at and head_branch" >&2
  exit 2
}

result="$(jq -r '
  def unit: (.name // "") | sub("( - Update)? #[0-9]+$"; "");
  def red: .status == "completed" and (.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure");

  .run as $id
  | ([.runs[] | select(.id == $id)] | first) as $target
  | if $target == null then "UNKNOWN judged run not in input"
    elif ($target.head_branch != "main") then "UNKNOWN judged run is not on main"
    elif ($target | red | not) then "UNKNOWN judged run is not red"
    else
      ($target | unit) as $u
      | [.runs[] | select(.head_branch == "main" and .status == "completed" and (unit == $u))]
      | sort_by(.created_at, .id) | reverse
      | (map(red) | index(false) // length) as $n
      | if $n == 0 then "CLEAR"
        elif $n == 1 then "FIRST since=\(.[0].created_at[0:10])"
        else "REPEATED runs=\($n) since=\(.[$n - 1].created_at[0:10])" end
    end
' <<<"$payload")" || exit 2

case "$result" in
UNKNOWN*)
  echo "managed-run-streak: ${result#UNKNOWN }" >&2
  exit 2
  ;;
esac
printf '%s\n' "$result"
case "$result" in
REPEATED*) exit 1 ;;
*) exit 0 ;;
esac
