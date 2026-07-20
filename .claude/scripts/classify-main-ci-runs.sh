#!/usr/bin/env bash
# Classify whether main is red from a GitHub Actions runs payload already scoped
# to one repo's current main head (head_sha=<full-sha>&branch=main).
#
# Stdin: JSON array of run objects (or GitHub list envelope { "workflow_runs": [...] }).
# Stdout: one line per currently-red workflow —
#   <workflow_id>\t<conclusion>\t<html_url>\t<name>
# Exit 0 always when input parses; exit 2 on malformed input / missing jq.
#
# Rules (must stay in lockstep with .claude/agents/portfolio-surveyor.md § CI red on main):
#   - keep only main-branch events: push, schedule, merge_group, workflow_dispatch, dynamic
#   - take the latest run per workflow_id (greatest created_at; id, never display name)
#   - report red only when that latest conclusion is failure or timed_out
#   - skipped / neutral / success / cancelled / in_progress are not red

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "classify-main-ci-runs: jq is required" >&2
  exit 2
fi

input="$(cat)"

if ! jq -e '
  if type == "object" and has("workflow_runs") then .workflow_runs
  elif type == "array" then .
  else empty end
  | type == "array"
' <<<"${input}" >/dev/null 2>&1; then
  echo "classify-main-ci-runs: expected a runs array or {workflow_runs:[…]}" >&2
  exit 2
fi

jq -r '
  (if type == "object" and has("workflow_runs") then .workflow_runs else . end) as $runs
  | (
      ["push", "schedule", "merge_group", "workflow_dispatch", "dynamic"]
    ) as $main_events
  | ($runs
      | map(select(
          ((.event as $e | $main_events | index($e)) != null)
          and (.workflow_id | type == "number")
          and ((.created_at // "") | length) > 0
        ))
      | group_by(.workflow_id)
      | map(sort_by(.created_at) | last)
      | map(select(.conclusion == "failure" or .conclusion == "timed_out"))
      | sort_by(.workflow_id)
    )[]
  | [.workflow_id, .conclusion, (.html_url // ""), (.name // "")]
  | @tsv
' <<<"${input}"
