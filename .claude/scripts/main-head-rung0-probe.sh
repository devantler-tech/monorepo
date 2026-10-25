#!/usr/bin/env bash
# main-head-rung0-probe.sh — is a portfolio repository's current `main` head free of red CI?
# (monorepo#3623, monorepo#4518)
#
# WHY THIS EXISTS
#   A weekly-paced `agentic-engineer-2` run ends after rung 0, so its rung-0 read must never call a
#   broken `main` clean. Reading check runs alone misses a workflow that fails before it creates a
#   job: such a run publishes no check run at all (the shape required-gate-completeness.sh already
#   documents, ksail#6645). It can leave zero check runs at the head, or only green check runs from
#   another workflow. So this probe reads the head's workflow runs as well as its check runs, and
#   treats missing evidence of either kind as UNKNOWN rather than clean.
#
# USAGE
#   main-head-rung0-probe.sh --repo devantler-tech/<name> [--repo devantler-tech/<name> …]
#   The owner is pinned to devantler-tech; any other target is a usage error.
#
# OUTPUT (one line per repository, in argument order)
#   RUNG0 <owner>/<repo> sha=<sha> checks=<n> runs=<n> OK
#   RUNG0 <owner>/<repo> sha=<sha> checks=<n> runs=<n> BREAKAGE <kind>:<name>=<conclusion>[,…]
#   RUNG0 <owner>/<repo> UNKNOWN <reason>
#   A failed check run or workflow run is BREAKAGE even when the other kind is missing or truncated.
#   Without one, UNKNOWN reasons are: read-failed <what>, malformed <what>, truncated <what>,
#   no-check-runs and no-workflow-runs. An unfinished run is not a failure; the next run re-reads it.
#
# EXIT CODES
#   0  every repository read OK
#   1  at least one repository has a failed check run or workflow run at its `main` head
#   2  no breakage was found, but at least one repository is UNKNOWN (or a usage error)
set -euo pipefail

usage() {
  sed -n '/^# USAGE$/,/^# OUTPUT/p' "$0" | sed '$d' >&2
  exit 2
}

repos=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || usage
      [[ "$2" =~ ^devantler-tech/[A-Za-z0-9_.-]+$ ]] || usage
      case "${2#*/}" in . | ..) usage ;; esac
      repos+=("$2")
      shift 2
      ;;
    *) usage ;;
  esac
done
[ "${#repos[@]}" -gt 0 ] || usage

# A conclusion that means the head is red. `startup_failure` exists only on workflow runs.
failed='["failure","timed_out","cancelled","action_required","startup_failure"]'

# read_json <gh api args…> — capture first; a failed or empty read fails, never yields empty data.
read_json() {
  local out
  out="$(gh api "$@" 2>/dev/null)" && [ -n "${out}" ] && printf '%s\n' "${out}"
}

# probe <owner/repo> — prints one RUNG0 line and returns 0 (OK), 1 (BREAKAGE) or 2 (UNKNOWN).
probe() {
  local repo="$1" commit sha check_pages run_pages pages checks_seen runs_seen counts bad gap=""
  commit="$(read_json "repos/${repo}/commits/main")" || { echo "RUNG0 ${repo} UNKNOWN read-failed main"; return 2; }
  sha="$(jq -r '.sha // empty' <<<"${commit}" 2>/dev/null)" || sha=""
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "RUNG0 ${repo} UNKNOWN malformed main"; return 2; }

  check_pages="$(read_json --paginate "repos/${repo}/commits/${sha}/check-runs?per_page=100")" ||
    { echo "RUNG0 ${repo} UNKNOWN read-failed check-runs"; return 2; }
  run_pages="$(read_json --paginate "repos/${repo}/actions/runs?head_sha=${sha}&per_page=100")" ||
    { echo "RUNG0 ${repo} UNKNOWN read-failed workflow-runs"; return 2; }

  # Every list must be complete before an absence of failures means anything.
  for key in check_runs workflow_runs; do
    if [ "${key}" = check_runs ]; then pages="${check_pages}"; else pages="${run_pages}"; fi
    counts="$(jq -s -r --arg k "${key}" \
      'if all(.[]; (.[$k] | type) == "array") and ((.[0].total_count | type) == "number")
       then "\([.[][$k][]] | length) \(.[0].total_count)" else error("shape") end' \
      <<<"${pages}" 2>/dev/null)" || { echo "RUNG0 ${repo} UNKNOWN malformed ${key}"; return 2; }
    if [ "${counts% *}" != "${counts#* }" ]; then
      gap="${gap:-truncated ${key} fetched=${counts% *} total=${counts#* }}"
    fi
    if [ "${key}" = check_runs ]; then checks_seen="${counts% *}"; else runs_seen="${counts% *}"; fi
  done

  bad="$(jq -n -r --argjson f "${failed}" \
    --slurpfile c <(printf '%s\n' "${check_pages}") --slurpfile r <(printf '%s\n' "${run_pages}") '
    [ ($c[].check_runs[] | select(.conclusion as $x | $f | index($x)) | "check:\(.name)=\(.conclusion)"),
      ($r[].workflow_runs[] | select(.conclusion as $x | $f | index($x)) | "workflow:\(.path // .name)=\(.conclusion)") ]
    | map(gsub("[^A-Za-z0-9_./:=@+-]"; "_")) | join(",")')" ||
    { echo "RUNG0 ${repo} UNKNOWN malformed conclusions"; return 2; }

  local head="RUNG0 ${repo} sha=${sha} checks=${checks_seen} runs=${runs_seen}"
  if [ -n "${bad}" ]; then echo "${head} BREAKAGE ${bad}"; return 1; fi
  if [ -n "${gap}" ]; then echo "RUNG0 ${repo} UNKNOWN ${gap}"; return 2; fi
  [ "${checks_seen}" -gt 0 ] || { echo "RUNG0 ${repo} UNKNOWN no-check-runs"; return 2; }
  [ "${runs_seen}" -gt 0 ] || { echo "RUNG0 ${repo} UNKNOWN no-workflow-runs"; return 2; }
  echo "${head} OK"
}

worst=0
for repo in "${repos[@]}"; do
  rc=0
  probe "${repo}" || rc=$?
  case "${rc}" in
    0) ;;
    1) worst=1 ;;
    *) [ "${worst}" = 1 ] || worst=2 ;;
  esac
done
exit "${worst}"
