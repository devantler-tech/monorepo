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
#   required-gate-completeness.sh --input -
#
#   `--input -` is the SURVEY form (monorepo#3506). It reads one pull request on stdin, exactly as
#   `gh pr view <n> --repo devantler-tech/<repo> --json url,baseRefName,headRefOid` prints it, and
#   judges that head. It takes no other argument, so argv can never aim it at another target, and
#   the repository in `url` must belong to devantler-tech.
#
# OUTPUT
#   One `GATE <kind> <name> <state>` line per required gate, where <kind> is check | workflow |
#   code_quality and <state> is PASS | PENDING | FAILED | MISSING | UNVERIFIED.
#   A required check with no run is PENDING while a workflow run or an Actions job at the head is
#   unfinished, and MISSING once all have finished: a job publishes its check-run only when it
#   starts (monorepo#3506). Another app's unfinished check-run does not delay MISSING.
#   An active `code_quality` rule is always UNVERIFIED: no readable surface reports its analysis
#   for a head. Its line is `GATE code_quality setup=<state|unreadable> UNVERIFIED`, and the setup
#   state is the lead when a merge is refused.
#   Then one verdict line:
#     COMPLETE required=<n>
#     INCOMPLETE missing=<n> failed=<n> pending=<n>
#     UNKNOWN <reason>
#   The survey form then prints one LAST line, the value the survey copies into its check field:
#     required=complete
#     required=missing:<gate>[,<gate>…][+failing:<gate>…][+pending:<gate>…]
#     required=unverified:<kind>[,<kind>…]   every readable gate passed; these have no readable surface
#     required=unknown:<reason>
#   It always ends with that line: an abort nothing above describes prints `required=unknown:aborted`.
#
# EXIT CODES
#   0  every required gate passed at the head
#   1  at least one required gate is missing, failed or pending
#   2  UNKNOWN: a read failed, was truncated, or a gate cannot be verified — never read as 0
set -euo pipefail

usage() {
  # The header ends where the code starts, so its length is never a number to keep in step.
  sed -n '/^# USAGE$/,/^set -euo pipefail$/p' "$0" | sed '$d' >&2
  exit 2
}

repo="" base="" head="" input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || usage; base="$2"; shift 2 ;;
    --head) [ "$#" -ge 2 ] || usage; head="$2"; shift 2 ;;
    --input) [ "$#" -ge 2 ] || usage; input="$2"; shift 2 ;;
    *) usage ;;
  esac
done

survey=0
survey_said=0
# survey_line <value> — the survey form's last line; the argv form prints nothing extra.
survey_line() {
  [ "${survey}" = 1 ] || return 0
  survey_said=1
  printf 'required=%s\n' "$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]')"
}
# The survey copies the LAST line, so the survey form must end with one whatever happens. An abort
# no branch below foresaw prints `required=unknown:aborted` and exits 2 instead of printing nothing.
# Installed for the survey form only: the argv form keeps the shell's own exit status untouched.
survey_backstop() {
  [ "${survey_said}" = 1 ] || {
    echo "required=unknown:aborted"
    exit 2
  }
}

unknown() {
  local reason="$*"
  echo "UNKNOWN ${reason}"
  survey_line "unknown:${reason// /-}"
  exit 2
}

if [ -n "${input}" ]; then
  # Stdin is the only source of the target, so a caller cannot mix the two forms.
  [ "${input}" = "-" ] && [ -z "${repo}${base}${head}" ] || usage
  survey=1
  trap survey_backstop EXIT
  payload="$(cat)" || unknown "malformed-input"
  # Exactly one JSON object with three string fields; anything else is not a pull request read.
  # `@tsv` escapes a tab or newline inside a value, so the line always holds exactly three fields.
  target="$(jq -s -r 'if length == 1 and (.[0] | type) == "object"
      and ([.[0].url, .[0].baseRefName, .[0].headRefOid] | all(type == "string"))
    then [.[0].url, .[0].baseRefName, .[0].headRefOid] | @tsv else error("shape") end' \
    <<<"${payload}" 2>/dev/null)" || unknown "malformed-input"
  pr_url=""
  IFS=$'\t' read -r pr_url base head <<<"${target}" || true
  # The owner is pinned: this form is declared to the surveyor's read-only guard, so whatever the
  # forge printed must not be able to steer it to a repository outside the portfolio.
  [[ "${pr_url}" =~ ^https://github\.com/devantler-tech/([A-Za-z0-9_.-]+)/pull/[1-9][0-9]*$ ]] ||
    unknown "malformed-input"
  repo_name="${BASH_REMATCH[1]}"
  case "${repo_name}" in . | ..) unknown "malformed-input" ;; esac
  repo="devantler-tech/${repo_name}"
  [[ "${head}" =~ ^[0-9a-f]{40}$ ]] || unknown "malformed-input"
  # A legal branch name may hold characters this allowlist leaves out (`@`, `+`); it is refused by
  # name rather than placed unescaped into a request path.
  [[ "${base}" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "${base}" != *..* ]] || unknown "unsupported-base"
fi
grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' <<<"${repo}" || usage
grep -Eq '^[A-Za-z0-9._/-]+$' <<<"${base}" || usage
grep -Eq '^[0-9a-f]{40}$' <<<"${head}" || usage

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
  # Only the setup state is wanted. A failed read, or one that is not a JSON object, leaves it
  # empty, which prints as `unreadable`; it must never abort the verdict.
  if cq="$(gh api "repos/${repo}/code-quality/setup" 2>/dev/null)"; then
    cq_state="$(jq -r 'if type == "object" and (.state | type) == "string" then .state else "" end' \
      <<<"${cq}" 2>/dev/null)" || cq_state=""
  fi
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
  | (any($wf[]; .status != "completed")
     or any($runs[]; .status != "completed" and (.app.slug // "") == "github-actions")) as $unfinished
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
       | (if ($cr | rank) >= ($st | rank) then $cr else $st end) as $seen
       # A job publishes its check-run only when it starts, so a job that waits on other jobs has
       # none while they run. An absent check is therefore PENDING, not MISSING, until every
       # workflow run and every Actions job at this head has finished. Both states block, but only
       # MISSING means the check will never report. Another app with a check-run left unfinished
       # says nothing about an Actions job, so it does not turn MISSING into PENDING.
       | if $seen == "MISSING" and $unfinished then "PENDING" else $seen end
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
# names <STATE> — the comma-joined gate names in that state, for the survey line. A name is copied
# as the ruleset wrote it; one required twice (by a ruleset and by classic protection) is named
# once. A name that is empty, or that no GATE line yields (one holding a line break), is named
# `(unnamed)`, so a counted gate never leaves the list empty.
names() {
  sed -n "s/^GATE [a-z_]* \(.*\) $1\$/\1/p" <<<"${gates}" |
    awk '!seen[$0]++ { n++; print ($0 == "" ? "(unnamed)" : $0) } END { if (!n) print "(unnamed)" }' |
    paste -s -d , -
}
# A definite blocker is more useful than UNKNOWN, so it wins; UNVERIFIED alone never reads COMPLETE.
if [ $((missing + failed + pending)) -gt 0 ]; then
  echo "INCOMPLETE missing=${missing} failed=${failed} pending=${pending}"
  parts=""
  [ "${missing}" -eq 0 ] || parts="missing:$(names MISSING)"
  [ "${failed}" -eq 0 ] || parts="${parts:+${parts}+}failing:$(names FAILED)"
  [ "${pending}" -eq 0 ] || parts="${parts:+${parts}+}pending:$(names PENDING)"
  survey_line "${parts}"
  exit 1
fi
if [ "${unverified}" -ne 0 ]; then
  echo "UNKNOWN unverified=${unverified}"
  # An unverifiable gate is named by its kind: its GATE line carries a setup state, not a name.
  survey_line "unverified:$(sed -n 's/^GATE \([a-z_]*\) .* UNVERIFIED$/\1/p' <<<"${gates}" | sort -u | paste -s -d , -)"
  exit 2
fi
echo "COMPLETE required=$(jq 'length' <<<"${required}")"
survey_line complete
