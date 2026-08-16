#!/usr/bin/env bash
# Classify whether main is red from a GitHub Actions runs payload already scoped
# to one repo's current main head (head_sha=<full-sha>&branch=main).
#
# Stdin: a flat run array, one or more GitHub list envelopes { "workflow_runs": [...] }, or a
# `gh api --paginate --slurp` array of those envelopes. Page boundaries never affect classification.
# Stdout: one line per currently-red workflow —
#   <workflow_id>\t<conclusion>\t<html_url>\t<name>\t<event>\t<path>\t<created_at>
# Exit 0 always when input parses; exit 2 on malformed input / missing jq.
#
# Rules (must stay in lockstep with .claude/agents/portfolio-surveyor.md § CI red on main):
#   - keep only main-branch events: push, schedule, merge_group, workflow_dispatch, dynamic
#   - group repository workflows by workflow_id; group GitHub-managed dynamic jobs by workflow_id
#     plus logical run name (strip the changing trailing Dependabot update id)
#   - within each group, only success clears a prior red; pending, cancelled, skipped and neutral
#     retries are not recovery evidence
#   - report red when the latest decisive conclusion is failure, timed_out or startup_failure
#     (startup_failure is a workflow/dependency config that could not even parse, so the run
#     never started — the constitution's rung-0 red set names all three)
#   - a group with no red conclusion is not red

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "classify-main-ci-runs: jq is required" >&2
  exit 2
fi

input="$(cat)"

if ! runs="$(jq -cs '
  map(
    if type == "object" and has("workflow_runs") and (.workflow_runs | type == "array") then
      .workflow_runs
    elif type == "array" then
      if length == 0 then
        .
      elif all(.[]; type == "object"
                       and has("workflow_runs")
                       and (.workflow_runs | type == "array")) then
        [.[] | .workflow_runs[]]
      elif all(.[]; type == "object" and (has("workflow_runs") | not)) then
        .
      else
        error("invalid runs payload")
      end
    else
      error("invalid runs payload")
    end
  )
  | add
' <<<"${input}" 2>/dev/null)"; then
  echo "classify-main-ci-runs: expected a runs array or {workflow_runs:[…]}" >&2
  exit 2
fi

jq -r '
  def run_identity:
    if .event == "dynamic" and ((.path // "") | startswith("dynamic/")) then
      ["managed", .workflow_id, ((.name // "") | sub("( - Update)? #[0-9]+$"; ""))]
    else
      ["workflow", .workflow_id]
    end;

  . as $runs
  | (
      ["push", "schedule", "merge_group", "workflow_dispatch", "dynamic"]
    ) as $main_events
  | ($runs
      | map(select(
          ((.event as $e | $main_events | index($e)) != null)
          and (.workflow_id | type == "number")
          and ((.created_at // "") | length) > 0
        ))
      | group_by(run_identity)
      | map(sort_by(.created_at)
            | map(select(.conclusion == "success"
                         or .conclusion == "failure"
                         or .conclusion == "timed_out"
                         or .conclusion == "startup_failure"))
            | last)
      | map(select(. != null
                   and (.conclusion == "failure"
                   or .conclusion == "timed_out"
                   or .conclusion == "startup_failure")))
      | sort_by(.workflow_id)
    )[]
  | [.workflow_id, .conclusion, (.html_url // ""), (.name // ""),
     (.event // ""), (.path // ""), (.created_at // "")]
  | @tsv
' <<<"${runs}"
