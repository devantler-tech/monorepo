#!/usr/bin/env bash
# required-gate-completeness.sh — compare a PR head against the base branch's REQUIRED gate set
# (monorepo#2730).
#
# WHY THIS EXISTS
#   `statusCheckRollup` reports what ran, never what should have run. Three measured cases read
#   all-green while a required gate blocked the merge: a head that predates a required workflow
#   (platform#2704: 12 required checks absent), a required workflow that failed before creating
#   a job and so published no check-run (ksail#6645), and an active `code_quality` rule on a
#   repository whose analysis is not configured (monorepo#3404). A missing gate is only visible
#   by starting from the required set.
#
# USAGE
#   required-gate-completeness.sh --repo <owner>/<repo> --base <branch> --head <40-char sha>
#
# OUTPUT
#   One `GATE <kind> <name> <state>` line per required gate, where <kind> is check | workflow |
#   code_quality and <state> is PASS | PENDING | FAILED | MISSING | UNVERIFIED.
#   An active `code_quality` rule is always UNVERIFIED: no readable surface reports its analysis
#   for a head. Its line is `GATE code_quality setup=<state|unreadable> UNVERIFIED`, and the setup
#   state is the lead when a merge is refused.
#   Then one verdict line:
#     COMPLETE required=<n>
#     INCOMPLETE missing=<n> failed=<n> pending=<n>
#     UNKNOWN <reason>
#
# EXIT CODES
#   0  every required gate passed at the head
#   1  at least one required gate is missing, failed or pending
#   2  UNKNOWN: a read failed, was truncated, or a gate cannot be verified — never read as 0
set -euo pipefail

usage() {
  sed -n '13,30p' "$0" >&2
  exit 2
}

repo="" base="" head=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || usage; base="$2"; shift 2 ;;
    --head) [ "$#" -ge 2 ] || usage; head="$2"; shift 2 ;;
    *) usage ;;
  esac
done
grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' <<<"${repo}" || usage
grep -Eq '^[A-Za-z0-9._/-]+$' <<<"${base}" || usage
grep -Eq '^[0-9a-f]{40}$' <<<"${head}" || usage

unknown() {
  echo "UNKNOWN $*"
  exit 2
}

# read_json <gh api args…> — capture first; a failed or empty read fails, never yields empty data.
read_json() {
  local out
  out="$(gh api "$@" 2>/dev/null)" && [ -n "${out}" ] && printf "%s\n" "${out}"
}

rules="$(read_json --paginate "repos/${repo}/rules/branches/${base}")" || unknown "read-failed rules"
branch="$(read_json "repos/${repo}/branches/${base}")" || unknown "read-failed branch"
check_pages="$(read_json --paginate "repos/${repo}/commits/${head}/check-runs?per_page=100")" ||
  unknown "read-failed check-runs"
status_pages="$(read_json --paginate "repos/${repo}/commits/${head}/statuses?per_page=100")" ||
  unknown "read-failed statuses"
run_pages="$(read_json --paginate "repos/${repo}/actions/runs?head_sha=${head}&per_page=100")" ||
  unknown "read-failed runs"

# Every paginated list must be complete, or a gate on a later page reads as MISSING.
for pair in "check_runs:${check_pages}" "workflow_runs:${run_pages}"; do
  key="${pair%%:*}"
  counts="$(printf '%s\n' "${pair#*:}" | jq -s -r --arg k "${key}" \
    '"\([.[][$k][]] | length) \(.[0].total_count)"' 2>/dev/null)" || unknown "malformed ${key}"
  [ "${counts% *}" = "${counts#* }" ] || unknown "truncated ${key} fetched=${counts% *} total=${counts#* }"
done

required="$(jq -n -c \
  --slurpfile r <(printf '%s\n' "${rules}") \
  --slurpfile b <(printf '%s\n' "${branch}") '
  ([$r[][]] ) as $rules
  | [ ($rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]
        | {kind: "check", name: .context, app: (.integration_id // null)}),
      ($b[0].protection.required_status_checks | select(. != null and .enforcement_level != "off") | .checks // [] | .[]
        | {kind: "check", name: .context, app: (.app_id // null)}),
      ($rules[] | select(.type == "workflows") | .parameters.workflows[]
        | {kind: "workflow", name: .path, app: null}),
      ($rules[] | select(.type == "code_quality") | {kind: "code_quality", name: "code_quality", app: null})
    ] | unique' 2>/dev/null)" || unknown "malformed rules"

cq_state=""
if jq -e 'any(.[]; .kind == "code_quality")' <<<"${required}" >/dev/null; then
  cq="$(gh api "repos/${repo}/code-quality/setup" 2>/dev/null)" && cq_state="$(jq -r '.state // ""' <<<"${cq}" 2>/dev/null)"
fi

gates="$(jq -n -r \
  --argjson req "${required}" \
  --slurpfile c <(printf '%s\n' "${check_pages}") \
  --slurpfile s <(printf '%s\n' "${status_pages}") \
  --slurpfile w <(printf '%s\n' "${run_pages}") \
  --arg cq "${cq_state}" '
  def ok: . == "success" or . == "neutral" or . == "skipped";
  def rank: if . == "PASS" then 3 elif . == "PENDING" then 2 elif . == "FAILED" then 1 else 0 end;
  [$c[].check_runs[]] as $runs
  | [$s[][]] as $statuses
  | [$w[].workflow_runs[]] as $wf
  | $req[]
  | . as $g
  | (if $g.kind == "check" then
       ([$runs[] | select(.name == $g.name and ($g.app == null or .app.id == $g.app))]
          | max_by(.id)
          | if . == null then "MISSING"
            elif .status != "completed" then "PENDING"
            elif (.conclusion | ok) then "PASS" else "FAILED" end) as $cr
       | ([$statuses[] | select(.context == $g.name)] | max_by(.id)
          | if . == null then "MISSING"
            elif .state == "success" then "PASS"
            elif .state == "pending" then "PENDING" else "FAILED" end) as $st
       | if ($cr | rank) >= ($st | rank) then $cr else $st end
     elif $g.kind == "workflow" then
       # A required workflow runs under /actions/required_workflows/; an ordinary workflow at the same
       # path, including one the PR itself adds, never satisfies it.
       [$wf[] | select(.path == $g.name and (.workflow_url // "" | contains("/actions/required_workflows/")))]
       | max_by([.created_at, .id])
       | if . == null then "MISSING"
         elif .status != "completed" then "PENDING"
         elif (.conclusion | ok) then "PASS" else "FAILED" end
     else "UNVERIFIED" end) as $state
  | if $g.kind == "code_quality" then "GATE code_quality setup=\(if $cq == "" then "unreadable" else $cq end) \($state)"
    else "GATE \($g.kind) \($g.name) \($state)" end
' 2>/dev/null)" || unknown "malformed check or run data"

[ -z "${gates}" ] || printf '%s\n' "${gates}"
count() { grep -c " $1\$" <<<"${gates}" || true; }
missing="$(count MISSING)" failed="$(count FAILED)" pending="$(count PENDING)"
unverified="$(count UNVERIFIED)"
# A definite blocker is more useful than UNKNOWN, so it wins; UNVERIFIED alone never reads COMPLETE.
if [ $((missing + failed + pending)) -gt 0 ]; then
  echo "INCOMPLETE missing=${missing} failed=${failed} pending=${pending}"
  exit 1
fi
[ "${unverified}" -eq 0 ] || unknown "unverified=${unverified}"
echo "COMPLETE required=$(jq 'length' <<<"${required}")"
