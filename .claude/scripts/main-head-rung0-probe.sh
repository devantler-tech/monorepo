#!/usr/bin/env bash
# main-head-rung0-probe.sh — is every live devantler-tech repository's default-branch head free of red CI?
# (monorepo#3623, monorepo#4518)
#
# WHY THIS EXISTS
#   A weekly-paced `agentic-engineer-2` run ends after rung 0, so its rung-0 read must never call a
#   broken head clean. Reading check runs alone misses a workflow that fails before it creates a
#   job: such a run publishes no check run at all (the shape required-gate-completeness.sh already
#   documents, ksail#6645). It can leave zero check runs at the head, or only green check runs from
#   another workflow. So this probe reads the head's workflow runs as well as its check runs, and
#   treats missing evidence of either kind as UNKNOWN rather than clean. The rung-0 census is the
#   live organization, not the Portfolio map (work-selection guide), so `--org` enumerates it and an
#   incomplete enumeration is UNKNOWN too.
#
# USAGE
#   main-head-rung0-probe.sh --org devantler-tech
#   main-head-rung0-probe.sh --repo devantler-tech/<name> [--repo devantler-tech/<name> …]
#   `--org` probes every non-archived repository on its default branch; `--repo` probes `main`.
#   The owner is pinned to devantler-tech; any other target is a usage error.
#
# OUTPUT
#   With `--org`, first one line: `RUNG0-ORG devantler-tech repos=<n> live=<n>`, or
#   `RUNG0-ORG devantler-tech UNKNOWN <reason>` when the list cannot be proven complete.
#   Then one line per repository:
#   RUNG0 <owner>/<repo> sha=<sha> checks=<n> runs=<n> OK
#   RUNG0 <owner>/<repo> sha=<sha> checks=<n> runs=<n> BREAKAGE <kind>:<name>=<conclusion>[,…]
#   RUNG0 <owner>/<repo> EMPTY          the repository has no branch, so no head can be red
#   RUNG0 <owner>/<repo> UNKNOWN <reason>
#   A failed check run or workflow run is BREAKAGE even when the other kind is missing or truncated.
#   Only the latest run of each workflow and event counts, so a failure a later run of the same
#   workflow superseded at the same head is not breakage; another workflow's run never supersedes
#   it. A cancelled run has no verdict, so a later successful run of the same workflow at the head
#   replaces it whatever that run's event (monorepo#4527: a dispatch cancelled the push run it
#   re-ran, and the stale cancel kept weekly pacing off). The latest MEANINGFUL run decides: runs
#   without a verdict (pending, skipped, neutral) and replaced cancellations are dropped before the
#   latest run is chosen, so they never hide an earlier failure (monorepo#4529). Without breakage, UNKNOWN reasons are: read-failed <what>, malformed <what>,
#   truncated <what>, no-check-runs and no-workflow-runs. An unfinished run is not a failure; the
#   next run re-reads it.
#
# EXIT CODES
#   0  every repository read OK or EMPTY
#   1  at least one repository has a failed check run or workflow run at its head
#   2  no breakage was found, but the organization list or a repository is UNKNOWN (or a usage error)
set -euo pipefail

usage() {
  sed -n '/^# USAGE$/,/^# OUTPUT$/p' "$0" | sed '$d' >&2
  exit 2
}

org=""
repos=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || usage
      [[ "$2" =~ ^devantler-tech/[A-Za-z0-9_.-]+$ ]] || usage
      case "${2#*/}" in . | ..) usage ;; esac
      repos+=("$2 main")
      shift 2
      ;;
    --org)
      [ "$#" -ge 2 ] && [ "$2" = devantler-tech ] && [ -z "${org}" ] || usage
      org="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
# Exactly one form: an org census, or an explicit repository list.
if [ -n "${org}" ]; then [ "${#repos[@]}" = 0 ] || usage; else [ "${#repos[@]}" -gt 0 ] || usage; fi

# A conclusion that means the head is red. `startup_failure` exists only on workflow runs.
failed='["failure","timed_out","cancelled","action_required","startup_failure"]'

# read_json <gh api args…> — capture first; a failed or empty read fails, never yields empty data.
read_json() {
  local out
  out="$(gh api "$@" 2>/dev/null)" && [ -n "${out}" ] && printf '%s\n' "${out}"
}

worst=0
note() { # note <rc> — keep the worst outcome: breakage beats UNKNOWN beats OK
  case "$1" in
    0) ;;
    1) worst=1 ;;
    *) [ "${worst}" = 1 ] || worst=2 ;;
  esac
}

if [ -n "${org}" ]; then
  # The repository list has no total_count, so its length is proven against the org's own counts.
  census() {
    local meta expected pages listed
    meta="$(read_json "orgs/${org}")" || { echo "RUNG0-ORG ${org} UNKNOWN read-failed org"; return 2; }
    expected="$(jq -r 'if (.public_repos | type) == "number" and (.total_private_repos | type) == "number"
      then .public_repos + .total_private_repos else error("count") end' <<<"${meta}" 2>/dev/null)" ||
      { echo "RUNG0-ORG ${org} UNKNOWN malformed org-count"; return 2; }
    pages="$(read_json --paginate "orgs/${org}/repos?type=all&per_page=100")" ||
      { echo "RUNG0-ORG ${org} UNKNOWN read-failed repos"; return 2; }
    listed="$(jq -s -r 'if all(.[]; type == "array") then [.[][]] else error("shape") end
      | if all(.[]; (.name | type) == "string" and (.archived | type) == "boolean"
          and (.default_branch | type) == "string")
        then .[] | select(.archived | not) | "\(.name) \(.default_branch)" else error("shape") end' \
      <<<"${pages}" 2>/dev/null)" || { echo "RUNG0-ORG ${org} UNKNOWN malformed repos"; return 2; }
    local total
    total="$(jq -s '[.[][]] | length' <<<"${pages}")"
    [ "${total}" = "${expected}" ] ||
      { echo "RUNG0-ORG ${org} UNKNOWN truncated repos fetched=${total} total=${expected}"; return 2; }
    local name branch
    while read -r name branch; do
      [ -n "${name}" ] || continue
      # A forge-supplied name or branch only reaches a request path once it passes the allowlist.
      if [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] && [ "${name}" != . ] && [ "${name}" != .. ] &&
        [[ "${branch}" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "${branch}" != *..* ]]; then
        repos+=("${org}/${name} ${branch}")
      else
        echo "RUNG0-ORG ${org} UNKNOWN unsupported-name"
        return 2
      fi
    done <<<"${listed}"
    echo "RUNG0-ORG ${org} repos=${total} live=${#repos[@]}"
  }
  rc=0
  census || rc=$?
  note "${rc}"
  # An unproven list never probes a partial set as if it were the whole organization.
  [ "${rc}" = 0 ] || exit "${worst}"
fi

# probe <owner/repo> <branch> — prints one RUNG0 line and returns 0 (OK), 1 (BREAKAGE) or 2 (UNKNOWN).
probe() {
  local repo="$1" branch="$2" commit sha check_pages run_pages pages checks_seen runs_seen counts bad gap=""
  if ! commit="$(read_json "repos/${repo}/commits/${branch}")"; then
    # An empty repository has no head to be red; any other failed read stays UNKNOWN.
    if [ "$(read_json "repos/${repo}/branches?per_page=1" | jq -c . 2>/dev/null)" = "[]" ]; then
      echo "RUNG0 ${repo} EMPTY"
      return 0
    fi
    echo "RUNG0 ${repo} UNKNOWN read-failed head"
    return 2
  fi
  sha="$(jq -r '.sha // empty' <<<"${commit}" 2>/dev/null)" || sha=""
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "RUNG0 ${repo} UNKNOWN malformed head"; return 2; }

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

  # Superseding needs to know which runs are the same workflow and event: a run without those
  # fields cannot be grouped, and grouping it with others could hide a failure, so it is malformed.
  bad="$(jq -n -r --argjson f "${failed}" \
    --slurpfile c <(printf '%s\n' "${check_pages}") --slurpfile r <(printf '%s\n' "${run_pages}") '
    [$r[].workflow_runs[]] as $runs
    | if all($runs[]; (.workflow_id | type) == "number" and (.event | type) == "string"
        and (.run_number | type) == "number") then . else error("shape") end
    | [ ($c[].check_runs[] | select(.conclusion as $x | $f | index($x)) | "check:\(.name)=\(.conclusion)"),
        # Filter BEFORE choosing the latest run (monorepo#4529): choosing first let a cancellation, a
        # pending run or a non-deciding conclusion discard an earlier genuine failure.
        ($runs | group_by([.workflow_id, .event]) | .[]
          | map(select(.conclusion as $x | ["success"] + $f | index($x)))
          | map(select(. as $c | $c.conclusion != "cancelled" or ([$runs[] | select(.workflow_id == $c.workflow_id
              and .run_number > $c.run_number and .conclusion == "success")]
              | length) == 0))
          | select(length > 0) | max_by(.run_number)
          | select(.conclusion as $x | $f | index($x))
          | "workflow:\(.path // .name)=\(.conclusion)") ]
    | map(gsub("[^A-Za-z0-9_./:=@+-]"; "_")) | join(",")')" ||
    { echo "RUNG0 ${repo} UNKNOWN malformed conclusions"; return 2; }

  local head="RUNG0 ${repo} sha=${sha} checks=${checks_seen} runs=${runs_seen}"
  if [ -n "${bad}" ]; then echo "${head} BREAKAGE ${bad}"; return 1; fi
  if [ -n "${gap}" ]; then echo "RUNG0 ${repo} UNKNOWN ${gap}"; return 2; fi
  [ "${checks_seen}" -gt 0 ] || { echo "RUNG0 ${repo} UNKNOWN no-check-runs"; return 2; }
  [ "${runs_seen}" -gt 0 ] || { echo "RUNG0 ${repo} UNKNOWN no-workflow-runs"; return 2; }
  echo "${head} OK"
}

for entry in "${repos[@]}"; do
  rc=0
  probe "${entry% *}" "${entry##* }" || rc=$?
  note "${rc}"
done
exit "${worst}"
