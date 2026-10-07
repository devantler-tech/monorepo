#!/usr/bin/env bash
# required-gate-completeness.test.sh — hermetic proof for required-gate-completeness.sh
# (monorepo#2730). A stub `gh` on PATH serves one canned response per endpoint, so no token or
# network is needed. Key properties are paired with an ablated copy that must FAIL the same case.
# shellcheck disable=SC2016 # perl substitutions and Markdown clauses are literal text on purpose
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tool="${here}/required-gate-completeness.sh"
head_sha="0123456789abcdef0123456789abcdef01234567"

tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -e abort inside an EXIT trap as exit 0, so require completion.
on_exit() {
  local status=$?
  rm -rf "${tmp}"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then exit 1; fi
}
trap on_exit EXIT
failures=0
checks=0

mkdir -p "${tmp}/bin"
# The stub maps the endpoint to a file in $STUB_DIR; a missing file is a failed read.
cat >"${tmp}/bin/gh" <<'STUB'
#!/usr/bin/env bash
dir="${STUB_DIR:?}"
# EVERY call is logged with all its arguments, before anything can reject it, so a case can prove
# which repository was read, that nothing was read, and that no call carried a method or a body.
[ -z "${STUB_LOG:-}" ] || printf '%s\n' "$*" >>"${STUB_LOG}"
path=""
for a in "$@"; do case "$a" in api|--paginate) ;; *) path="$a" ;; esac; done
case "$path" in
  */rules/branches/*) key=rules ;;
  */code-quality/setup) key=cq ;;
  */branches/*) key=branch ;;
  */check-runs*) key=check-runs ;;
  */statuses*) key=statuses ;;
  */actions/runs*) key=runs ;;
  *) exit 1 ;;
esac
[ -e "${dir}/${key}" ] || exit 1
cat "${dir}/${key}"
STUB
chmod +x "${tmp}/bin/gh"

rules_check_and_workflow='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Build"}]}},{"type":"workflows","parameters":{"workflows":[{"repository_id":1,"path":".github/workflows/scan.yaml","ref":"refs/heads/main"}]}}]'
branch_off='{"name":"main","protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}'
build_ok='{"id":10,"name":"Build","status":"completed","conclusion":"success","app":{"id":15368}}'
req_url='"workflow_url":"https://api.github.com/repos/devantler-tech/monorepo/actions/required_workflows/7"'
local_url='"workflow_url":"https://api.github.com/repos/devantler-tech/monorepo/actions/workflows/8"'
scan_ok='{"id":100,"path":".github/workflows/scan.yaml",'"${req_url}"',"status":"completed","conclusion":"success","created_at":"2026-09-22T10:00:00Z"}'

# fixture <name> <rules> <branch> <check-runs-page> <statuses> <runs-page> [cq]
fixture() {
  local d="${tmp}/fx/$1"
  mkdir -p "${d}"
  printf '%s\n' "$2" >"${d}/rules"
  printf '%s\n' "$3" >"${d}/branch"
  printf '%s\n' "$4" >"${d}/check-runs"
  printf '%s\n' "$5" >"${d}/statuses"
  printf '%s\n' "$6" >"${d}/runs"
  [ -z "${7:-}" ] || printf '%s\n' "$7" >"${d}/cq"
}

fixture complete "${rules_check_and_workflow}" "${branch_off}" \
  "{\"total_count\":1,\"check_runs\":[${build_ok}]}" '[]' \
  "{\"total_count\":1,\"workflow_runs\":[${scan_ok}]}"
# platform#2704: a required check that never ran at this head.
fixture missing-check "${rules_check_and_workflow}" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' \
  "{\"total_count\":1,\"workflow_runs\":[${scan_ok}]}"
# ksail#6645: the required workflow failed before creating a job, so no check-run exists.
fixture zero-job-failure "${rules_check_and_workflow}" "${branch_off}" \
  "{\"total_count\":1,\"check_runs\":[${build_ok}]}" '[]' \
  "{\"total_count\":1,\"workflow_runs\":[{\"id\":101,\"path\":\".github/workflows/scan.yaml\",${req_url},\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-09-22T10:00:00Z\"}]}"
fixture superseded-cancel "${rules_check_and_workflow}" "${branch_off}" \
  "{\"total_count\":1,\"check_runs\":[${build_ok}]}" '[]' \
  "{\"total_count\":2,\"workflow_runs\":[{\"id\":99,\"path\":\".github/workflows/scan.yaml\",${req_url},\"status\":\"completed\",\"conclusion\":\"cancelled\",\"created_at\":\"2026-09-22T09:00:00Z\"},${scan_ok}]}"
fixture pending "${rules_check_and_workflow}" "${branch_off}" \
  '{"total_count":1,"check_runs":[{"id":10,"name":"Build","status":"in_progress","conclusion":null,"app":{"id":15368}}]}' '[]' \
  "{\"total_count\":1,\"workflow_runs\":[${scan_ok}]}"
fixture status-context '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CodeRabbit"}]}}]' \
  "${branch_off}" '{"total_count":0,"check_runs":[]}' '[{"id":5,"context":"CodeRabbit","state":"success"}]' \
  '{"total_count":0,"workflow_runs":[]}'
fixture wrong-app '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Build","integration_id":999}]}}]' \
  "${branch_off}" "{\"total_count\":1,\"check_runs\":[${build_ok}]}" '[]' '{"total_count":0,"workflow_runs":[]}'
fixture classic-protection '[]' \
  '{"name":"main","protection":{"enabled":true,"required_status_checks":{"enforcement_level":"everyone","contexts":["Lint"],"checks":[{"context":"Lint","app_id":null}]}}}' \
  "{\"total_count\":1,\"check_runs\":[${build_ok}]}" '[]' '{"total_count":0,"workflow_runs":[]}'
# monorepo#3404: an active code_quality rule is never proven by any readable surface.
fixture code-quality "[{\"type\":\"code_quality\",\"parameters\":{\"severity\":\"all\"}}]" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}' '{"state":"not-configured"}'
fixture code-quality-unreadable "[{\"type\":\"code_quality\",\"parameters\":{\"severity\":\"all\"}}]" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}'
# A setup read that answers with something other than JSON used to abort the script with no
# verdict at all; it is an unreadable setup state like any other.
fixture code-quality-not-json "[{\"type\":\"code_quality\",\"parameters\":{\"severity\":\"all\"}}]" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}' '<html>oops</html>'
fixture code-quality-not-object "[{\"type\":\"code_quality\",\"parameters\":{\"severity\":\"all\"}}]" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}' '["configured"]'
# A second page was never fetched: the required check may sit on it.
fixture truncated "${rules_check_and_workflow}" "${branch_off}" \
  '{"total_count":150,"check_runs":[]}' '[]' \
  "{\"total_count\":1,\"workflow_runs\":[${scan_ok}]}"
fixture read-failed "${rules_check_and_workflow}" "${branch_off}" \
  "{\"total_count\":1,\"check_runs\":[${build_ok}]}" '[]' \
  "{\"total_count\":1,\"workflow_runs\":[${scan_ok}]}"
rm "${tmp}/fx/read-failed/check-runs"
fixture no-gates '[]' "${branch_off}" '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}'
# A local workflow at the required path, e.g. one the PR adds, must not stand in for the required run.
fixture local-shadow "${rules_check_and_workflow}" "${branch_off}" \
  "{\"total_count\":1,\"check_runs\":[${build_ok}]}" '[]' \
  "{\"total_count\":2,\"workflow_runs\":[{\"id\":101,\"path\":\".github/workflows/scan.yaml\",${req_url},\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-09-22T10:00:00Z\"},{\"id\":102,\"path\":\".github/workflows/scan.yaml\",${local_url},\"status\":\"completed\",\"conclusion\":\"success\",\"created_at\":\"2026-09-22T11:00:00Z\"}]}"
fixture local-only "${rules_check_and_workflow}" "${branch_off}" \
  "{\"total_count\":1,\"check_runs\":[${build_ok}]}" '[]' \
  "{\"total_count\":1,\"workflow_runs\":[{\"id\":102,\"path\":\".github/workflows/scan.yaml\",${local_url},\"status\":\"completed\",\"conclusion\":\"success\",\"created_at\":\"2026-09-22T11:00:00Z\"}]}"
# monorepo#3506: a job publishes its check-run only when it starts, so the aggregate job that waits
# on every other job has none while CI runs. Measured on a live draft: its required check read
# MISSING beside 40 queued jobs. Absent is PENDING until every run at the head has finished.
running_ci='{"id":200,"path":".github/workflows/ci.yaml","workflow_url":"https://api.github.com/repos/devantler-tech/monorepo/actions/workflows/8","status":"in_progress","conclusion":null,"created_at":"2026-09-22T10:00:00Z"}'
finished_ci='{"id":200,"path":".github/workflows/ci.yaml","workflow_url":"https://api.github.com/repos/devantler-tech/monorepo/actions/workflows/8","status":"completed","conclusion":"success","created_at":"2026-09-22T10:00:00Z"}'
rules_build_only='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Build"}]}}]'
fixture absent-while-run-unfinished "${rules_build_only}" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' "{\"total_count\":1,\"workflow_runs\":[${running_ci}]}"
fixture absent-while-job-queued "${rules_build_only}" "${branch_off}" \
  '{"total_count":1,"check_runs":[{"id":11,"name":"Lint","status":"queued","conclusion":null,"app":{"id":15368,"slug":"github-actions"}}]}' '[]' \
  '{"total_count":0,"workflow_runs":[]}'
# A run waiting on an approval holds its jobs back, so their checks are still on the way.
fixture absent-while-run-waiting "${rules_build_only}" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' \
  '{"total_count":1,"workflow_runs":[{"id":201,"path":".github/workflows/ci.yaml","workflow_url":"https://api.github.com/repos/devantler-tech/monorepo/actions/workflows/8","status":"waiting","conclusion":null,"created_at":"2026-09-22T10:00:00Z"}]}'
# Another app's check-run left unfinished says nothing about an Actions job: with every workflow
# run finished, the required check is MISSING, not waiting on a stranger that may never report.
fixture absent-while-other-app-queued "${rules_build_only}" "${branch_off}" \
  '{"total_count":1,"check_runs":[{"id":11,"name":"Some App","status":"queued","conclusion":null,"app":{"id":999,"slug":"some-app"}}]}' '[]' \
  '{"total_count":0,"workflow_runs":[]}'
fixture absent-while-appless-check-queued "${rules_build_only}" "${branch_off}" \
  '{"total_count":1,"check_runs":[{"id":11,"name":"Some App","status":"queued","conclusion":null}]}' '[]' \
  '{"total_count":0,"workflow_runs":[]}'
# A check bound to another app cannot be published by an Actions job, so an unfinished Actions run
# says nothing about it: absent is MISSING at once. Bound to Actions itself, it still waits.
rules_build_other_app='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Build","integration_id":999}]}}]'
rules_build_actions_app='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Build","integration_id":15368}]}}]'
fixture other-app-absent-while-run-unfinished "${rules_build_other_app}" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' "{\"total_count\":1,\"workflow_runs\":[${running_ci}]}"
fixture actions-app-absent-while-run-unfinished "${rules_build_actions_app}" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' "{\"total_count\":1,\"workflow_runs\":[${running_ci}]}"
# A commit status names no app, so it cannot stand in for the check-run of the app a gate is bound
# to. Passing, it used to read the gate PASS while the forge still held it missing.
fixture app-bound-status-only "${rules_build_actions_app}" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[{"id":5,"context":"Build","state":"success"}]' \
  '{"total_count":0,"workflow_runs":[]}'
fixture app-bound-failed-status-only "${rules_build_actions_app}" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[{"id":5,"context":"Build","state":"failure"}]' \
  '{"total_count":0,"workflow_runs":[]}'
fixture app-bound-check-run-decides "${rules_build_actions_app}" "${branch_off}" \
  "{\"total_count\":1,\"check_runs\":[${build_ok}]}" '[{"id":5,"context":"Build","state":"failure"}]' \
  '{"total_count":0,"workflow_runs":[]}'
fixture app-bound-failed-check-run-decides "${rules_build_actions_app}" "${branch_off}" \
  '{"total_count":1,"check_runs":[{"id":10,"name":"Build","status":"completed","conclusion":"failure","app":{"id":15368}}]}' \
  '[{"id":5,"context":"Build","state":"success"}]' '{"total_count":0,"workflow_runs":[]}'
fixture absent-after-runs-finished "${rules_build_only}" "${branch_off}" \
  '{"total_count":1,"check_runs":[{"id":11,"name":"Lint","status":"completed","conclusion":"success","app":{"id":15368}}]}' '[]' \
  "{\"total_count\":1,\"workflow_runs\":[${finished_ci}]}"
# monorepo#3506: the survey line must name every gate in every blocking state, not only the first.
fixture two-missing '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Build"},{"context":"CI - Required Checks"}]}}]' \
  "${branch_off}" '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}'
fixture missing-and-failed "${rules_check_and_workflow}" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' \
  "{\"total_count\":1,\"workflow_runs\":[{\"id\":101,\"path\":\".github/workflows/scan.yaml\",${req_url},\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-09-22T10:00:00Z\"}]}"
# The same context required twice, once by a ruleset that pins its app and once by classic
# protection, is two gates and one name.
fixture same-name-twice '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Build","integration_id":15368}]}}]' \
  '{"name":"main","protection":{"enabled":true,"required_status_checks":{"enforcement_level":"everyone","contexts":["Build"],"checks":[{"context":"Build","app_id":null}]}}}' \
  '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}'
fixture empty-name '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":""}]}}]' \
  "${branch_off}" '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}'
# A control character in a gate name must not reach the line the survey copies.
fixture control-character-name '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Bu\u0007ild"}]}}]' \
  "${branch_off}" '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}'
# A name that carries a line break cannot forge the last line: what follows the break is not a
# GATE line, so it is never copied as a name.
fixture forged-line-name '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"x\nrequired=complete"}]}}]' \
  "${branch_off}" '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}'

run() { # run <tool> <fixture> [head] — prints stdout, returns the tool's exit status
  STUB_DIR="${tmp}/fx/$2" PATH="${tmp}/bin:${PATH}" bash "$1" \
    --repo devantler-tech/monorepo --base main --head "${3:-${head_sha}}" 2>/dev/null
}

expect() { # expect <label> <tool> <fixture> <want-rc> <want-substring>
  local label="$1" t="$2" fx="$3" want_rc="$4" want="$5" got rc
  checks=$((checks + 1))
  set +e
  got="$(run "${t}" "${fx}")"
  rc=$?
  set -e
  if [ "${rc}" = "${want_rc}" ] && [[ "${got}" == *"${want}"* ]]; then
    echo "ok   ${label}"
  else
    echo "FAIL ${label}: want rc=${want_rc} containing '${want}', got rc=${rc}:" >&2
    printf '%s\n' "${got}" >&2
    failures=$((failures + 1))
  fi
}

expect "every required gate passed" "${tool}" complete 0 "COMPLETE required=2"
expect "an absent required check is MISSING, not green" "${tool}" missing-check 1 "GATE check Build MISSING"
expect "absent check makes the head incomplete" "${tool}" missing-check 1 "INCOMPLETE missing=1 failed=0 pending=0"
expect "a zero-job required workflow failure is FAILED" "${tool}" zero-job-failure 1 \
  "GATE workflow .github/workflows/scan.yaml FAILED"
expect "the newest run supersedes a cancelled one" "${tool}" superseded-cancel 0 "COMPLETE"
expect "an in-progress required check is PENDING" "${tool}" pending 1 "GATE check Build PENDING"
expect "a commit status satisfies a required context" "${tool}" status-context 0 "COMPLETE required=1"
expect "a check from the wrong app does not satisfy it" "${tool}" wrong-app 1 "GATE check Build MISSING"
expect "classic branch protection contributes required checks" "${tool}" classic-protection 1 "GATE check Lint MISSING"
expect "a code_quality rule is UNVERIFIED and names its setup" "${tool}" code-quality 2 \
  "GATE code_quality setup=not-configured UNVERIFIED"
expect "an unreadable code_quality setup is named" "${tool}" code-quality-unreadable 2 "setup=unreadable"
expect "a truncated check list is UNKNOWN, never MISSING" "${tool}" truncated 2 \
  "UNKNOWN truncated check_runs fetched=0 total=150"
expect "a failed read is UNKNOWN on stdout" "${tool}" read-failed 2 "UNKNOWN read-failed check-runs"
expect "no required gates reads complete" "${tool}" no-gates 0 "COMPLETE required=0"
expect "a local run never satisfies a failed required workflow" "${tool}" local-shadow 1 \
  "GATE workflow .github/workflows/scan.yaml FAILED"
expect "a local run alone leaves the required workflow MISSING" "${tool}" local-only 1 \
  "GATE workflow .github/workflows/scan.yaml MISSING"
expect "an absent check is PENDING while a workflow run is unfinished" "${tool}" absent-while-run-unfinished 1 \
  "GATE check Build PENDING"
expect "an unfinished run leaves nothing MISSING" "${tool}" absent-while-run-unfinished 1 \
  "INCOMPLETE missing=0 failed=0 pending=1"
expect "an absent check is PENDING while another Actions job is queued" "${tool}" absent-while-job-queued 1 \
  "GATE check Build PENDING"
expect "an absent check is PENDING while a run waits on an approval" "${tool}" absent-while-run-waiting 1 \
  "GATE check Build PENDING"
expect "an absent check is MISSING once every run has finished" "${tool}" absent-after-runs-finished 1 \
  "GATE check Build MISSING"
expect "another app's unfinished check-run does not delay MISSING" "${tool}" absent-while-other-app-queued 1 \
  "GATE check Build MISSING"
expect "a check-run with no app does not delay MISSING" "${tool}" absent-while-appless-check-queued 1 \
  "GATE check Build MISSING"
expect "an Actions run does not delay a check bound to another app" "${tool}" other-app-absent-while-run-unfinished 1 \
  "GATE check Build MISSING"
expect "an Actions run still delays a check bound to Actions" "${tool}" actions-app-absent-while-run-unfinished 1 \
  "GATE check Build PENDING"
expect "a passing status does not pass a check bound to an app" "${tool}" app-bound-status-only 2 \
  "GATE check Build UNVERIFIED"
expect "a status beside no app check-run never reads complete" "${tool}" app-bound-status-only 2 \
  "UNKNOWN unverified=1"
expect "a failing status does not fail a check bound to an app either" "${tool}" app-bound-failed-status-only 2 \
  "GATE check Build UNVERIFIED"
expect "the bound app's passing check-run decides beside a failing status" "${tool}" app-bound-check-run-decides 0 \
  "COMPLETE required=1"
expect "the bound app's failed check-run decides beside a passing status" "${tool}" app-bound-failed-check-run-decides 1 \
  "GATE check Build FAILED"
expect "a setup read that is not JSON is unreadable, not an abort" "${tool}" code-quality-not-json 2 \
  "GATE code_quality setup=unreadable UNVERIFIED"
expect "a setup read that is not an object is unreadable" "${tool}" code-quality-not-object 2 \
  "GATE code_quality setup=unreadable UNVERIFIED"
expect "a setup read that is not JSON still ends in a verdict" "${tool}" code-quality-not-json 2 \
  "UNKNOWN unverified=1"

checks=$((checks + 1))
set +e
got="$(run "${tool}" complete 0123456 2>&1)"
rc=$?
set -e
if [ "${rc}" = 2 ]; then echo "ok   an abbreviated head is refused"; else
  echo "FAIL an abbreviated head is refused: rc=${rc}" >&2
  failures=$((failures + 1))
fi

missing_value() { # missing_value <tool> — a flag given without its value, as the last argument
  STUB_DIR="${tmp}/fx/complete" PATH="${tmp}/bin:${PATH}" bash "$1" \
    --repo devantler-tech/monorepo --head "${head_sha}" --base >/dev/null 2>&1
}
checks=$((checks + 1))
set +e
missing_value "${tool}"
rc=$?
set -e
if [ "${rc}" = 2 ]; then echo "ok   a flag without its value is a usage error"; else
  echo "FAIL a flag without its value is a usage error: rc=${rc}" >&2
  failures=$((failures + 1))
fi

# ── The survey form (monorepo#3506): one pull request on stdin, one `required=` line last ──────────
pr_json="{\"url\":\"https://github.com/devantler-tech/monorepo/pull/7\",\"baseRefName\":\"main\",\"headRefOid\":\"${head_sha}\"}"
stub_log="${tmp}/gh-calls.log"

run_survey() { # run_survey <tool> <fixture> <stdin payload> [extra args…] — prints stdout, returns the status
  local t="$1" fx="$2" payload="$3"
  shift 3
  : >"${stub_log}"
  printf '%s\n' "${payload}" |
    STUB_LOG="${stub_log}" STUB_DIR="${tmp}/fx/${fx}" PATH="${tmp}/bin:${PATH}" bash "${t}" --input - "$@" 2>/dev/null
}

expect_survey() { # expect_survey <label> <tool> <fixture> <payload> <want-rc> <want-last-line>
  local label="$1" t="$2" fx="$3" payload="$4" want_rc="$5" want="$6" got rc last
  checks=$((checks + 1))
  set +e
  got="$(run_survey "${t}" "${fx}" "${payload}")"
  rc=$?
  set -e
  last="$(printf '%s\n' "${got}" | tail -n 1)"
  if [ "${rc}" = "${want_rc}" ] && [ "${last}" = "${want}" ]; then
    echo "ok   ${label}"
  else
    echo "FAIL ${label}: want rc=${want_rc} ending '${want}', got rc=${rc}:" >&2
    printf '%s\n' "${got}" >&2
    failures=$((failures + 1))
  fi
}

expect_no_read() { # expect_no_read <label> — the previous survey call must not have reached the forge
  checks=$((checks + 1))
  if [ ! -s "${stub_log}" ]; then echo "ok   $1"; else
    echo "FAIL $1: the forge was read:" >&2
    cat "${stub_log}" >&2
    failures=$((failures + 1))
  fi
}

expect_survey "survey: every required gate passed reads complete" "${tool}" complete "${pr_json}" 0 "required=complete"
checks=$((checks + 1))
if grep -Fxq 'api --paginate repos/devantler-tech/monorepo/rules/branches/main' "${stub_log}" &&
  grep -Fxq "api --paginate repos/devantler-tech/monorepo/commits/${head_sha}/check-runs?per_page=100" "${stub_log}"; then
  echo "ok   survey: the repository, base and head come from the piped pull request"
else
  echo "FAIL survey: the piped pull request did not select the reads:" >&2
  cat "${stub_log}" >&2
  failures=$((failures + 1))
fi
# The form is declared to a read-only guard as a READ. Every call it makes must be a plain GET of
# this one repository: `api`, optionally `--paginate`, one path, and no method, field or body flag.
checks=$((checks + 1))
calls="$(grep -c . "${stub_log}" || true)"
others="$(grep -Evc '^api( --paginate)? repos/devantler-tech/monorepo/[^ ]+$' "${stub_log}" || true)"
if [ "${calls}" -ge 5 ] && [ "${others}" = 0 ]; then
  echo "ok   survey: all ${calls} forge calls are plain reads of the piped repository"
else
  echo "FAIL survey: ${others} of ${calls} forge calls are not plain reads of the piped repository:" >&2
  cat "${stub_log}" >&2
  failures=$((failures + 1))
fi
expect_survey "survey: an absent required check reads missing, not complete" "${tool}" missing-check "${pr_json}" 1 \
  "required=missing:Build"
expect_survey "survey: every missing gate is named, spaces kept" "${tool}" two-missing "${pr_json}" 1 \
  "required=missing:Build,CI - Required Checks"
expect_survey "survey: a failed required workflow reads failing" "${tool}" zero-job-failure "${pr_json}" 1 \
  "required=failing:.github/workflows/scan.yaml"
expect_survey "survey: missing and failing gates are both named" "${tool}" missing-and-failed "${pr_json}" 1 \
  "required=missing:Build+failing:.github/workflows/scan.yaml"
expect_survey "survey: an in-progress required check reads pending" "${tool}" pending "${pr_json}" 1 \
  "required=pending:Build"
expect_survey "survey: a check whose job has not started reads pending, not missing" "${tool}" \
  absent-while-run-unfinished "${pr_json}" 1 "required=pending:Build"
expect_survey "survey: the same check reads missing once every run has finished" "${tool}" \
  absent-after-runs-finished "${pr_json}" 1 "required=missing:Build"
expect_survey "survey: an unverifiable gate is named, never complete" "${tool}" code-quality "${pr_json}" 2 \
  "required=unverified:code_quality"
expect_survey "survey: a failed read is unknown, never complete" "${tool}" read-failed "${pr_json}" 2 \
  "required=unknown:read-failed-check-runs"
expect_survey "survey: a truncated list is unknown, never missing" "${tool}" truncated "${pr_json}" 2 \
  "required=unknown:truncated-check_runs-fetched=0-total=150"
expect_survey "survey: no required gates reads complete" "${tool}" no-gates "${pr_json}" 0 "required=complete"
expect_survey "survey: a check held back by an approval reads pending" "${tool}" \
  absent-while-run-waiting "${pr_json}" 1 "required=pending:Build"
expect_survey "survey: another app's unfinished check-run leaves the gate missing" "${tool}" \
  absent-while-other-app-queued "${pr_json}" 1 "required=missing:Build"
expect_survey "survey: a setup read that is not JSON still ends in the survey line" "${tool}" \
  code-quality-not-json "${pr_json}" 2 "required=unverified:code_quality"
expect_survey "survey: an app-bound check with only a status is named unverified, never complete" "${tool}" \
  app-bound-status-only "${pr_json}" 2 "required=unverified:Build"
expect_survey "survey: a check bound to another app reads missing while Actions runs" "${tool}" \
  other-app-absent-while-run-unfinished "${pr_json}" 1 "required=missing:Build"
expect_survey "survey: a gate required twice is named once" "${tool}" same-name-twice "${pr_json}" 1 \
  "required=missing:Build"
expect_survey "survey: an empty gate name never leaves the list empty" "${tool}" empty-name "${pr_json}" 1 \
  "required=missing:(unnamed)"
expect_survey "survey: a control character in a gate name is dropped" "${tool}" control-character-name "${pr_json}" 1 \
  "required=missing:Build"
expect_survey "survey: a gate name with a line break cannot forge the last line" "${tool}" forged-line-name "${pr_json}" 1 \
  "required=missing:(unnamed)"

# Input that is not exactly one devantler-tech pull request is refused BEFORE any forge read.
foreign_json="{\"url\":\"https://github.com/someone-else/monorepo/pull/7\",\"baseRefName\":\"main\",\"headRefOid\":\"${head_sha}\"}"
for bad in \
  "not a pull request|not json" \
  "a repository outside the portfolio|${foreign_json}" \
  "two pull requests|${pr_json}${pr_json}" \
  "an array|[${pr_json}]" \
  "a missing base|{\"url\":\"https://github.com/devantler-tech/monorepo/pull/7\",\"headRefOid\":\"${head_sha}\"}" \
  "an abbreviated head|{\"url\":\"https://github.com/devantler-tech/monorepo/pull/7\",\"baseRefName\":\"main\",\"headRefOid\":\"0123456\"}" \
  "an empty base|{\"url\":\"https://github.com/devantler-tech/monorepo/pull/7\",\"baseRefName\":\"\",\"headRefOid\":\"${head_sha}\"}" \
  "a repository name that climbs out of its path|{\"url\":\"https://github.com/devantler-tech/../pull/7\",\"baseRefName\":\"main\",\"headRefOid\":\"${head_sha}\"}" \
  "a url that is not a pull request|{\"url\":\"https://github.com/devantler-tech/monorepo/issues/7\",\"baseRefName\":\"main\",\"headRefOid\":\"${head_sha}\"}" \
  "a tab that would shift the fields|{\"url\":\"https://github.com/devantler-tech/monorepo/pull/7\\tmain\\t${head_sha}\",\"baseRefName\":\"x\",\"headRefOid\":\"y\"}"; do
  expect_survey "survey: ${bad%%|*} is refused" "${tool}" complete "${bad#*|}" 2 "required=unknown:malformed-input"
  expect_no_read "survey: ${bad%%|*} reads nothing"
done
# A base this form will not place in a request path is refused by name, also before any read: one
# that climbs out of its path, and a legal branch name with a character outside the allowlist.
for bad in \
  "a base that climbs out of its path|../../x" \
  "a base with an at sign|release@1" \
  "a base with a plus sign|release+1"; do
  expect_survey "survey: ${bad%%|*} is refused as unsupported" "${tool}" complete \
    "{\"url\":\"https://github.com/devantler-tech/monorepo/pull/7\",\"baseRefName\":\"${bad#*|}\",\"headRefOid\":\"${head_sha}\"}" \
    2 "required=unknown:unsupported-base"
  expect_no_read "survey: ${bad%%|*} reads nothing"
done

# The two forms never mix: argv cannot aim the survey form, and a path is not the stdin form.
for extra in "--repo devantler-tech/monorepo" "--base main" "--head ${head_sha}"; do
  checks=$((checks + 1))
  set +e
  # shellcheck disable=SC2086  # the pair is split on purpose into a flag and its value
  got="$(run_survey "${tool}" complete "${pr_json}" ${extra})"
  rc=$?
  set -e
  if [ "${rc}" = 2 ] && [ -z "${got}" ] && [ ! -s "${stub_log}" ]; then
    echo "ok   survey: ${extra%% *} beside --input is a usage error"
  else
    echo "FAIL survey: ${extra%% *} beside --input was accepted (rc=${rc}): ${got}" >&2
    failures=$((failures + 1))
  fi
done
checks=$((checks + 1))
set +e
got="$(printf '%s\n' "${pr_json}" | STUB_LOG="${stub_log}" STUB_DIR="${tmp}/fx/complete" PATH="${tmp}/bin:${PATH}" \
  bash "${tool}" --input "${tmp}/fx/complete/rules" 2>/dev/null)"
rc=$?
set -e
if [ "${rc}" = 2 ] && [ -z "${got}" ]; then echo "ok   survey: --input with a path is a usage error"; else
  echo "FAIL survey: --input with a path was accepted (rc=${rc}): ${got}" >&2
  failures=$((failures + 1))
fi

# The argv form is unchanged: the merge preflight reads its verdict line, and gets no survey line.
checks=$((checks + 1))
set +e
got="$(run "${tool}" complete)"
set -e
if [[ "${got}" != *"required="[a-z]* ]] && [ "$(printf '%s\n' "${got}" | tail -n 1)" = "COMPLETE required=2" ]; then
  echo "ok   the argv form prints no survey line"
else
  echo "FAIL the argv form changed its output:" >&2
  printf '%s\n' "${got}" >&2
  failures=$((failures + 1))
fi

# Ablations: each guard, removed, must let its case through.
ablate() { # ablate <name> <perl substitution> — writes an ablated copy and checks it changed
  local out="${tmp}/$1.sh"
  perl -0pe "$2" "${tool}" >"${out}"
  if cmp -s "${tool}" "${out}"; then
    echo "FAIL ablation $1 did not change the tool" >&2
    failures=$((failures + 1))
  fi
  printf '%s\n' "${out}"
}
no_trunc="$(ablate no-truncation 's/\[ "\$\{counts% \*\}" = "\$\{counts#\* \}" \] \|\|/true ||/')"
no_missing="$(ablate no-missing 's/if \. == null then "MISSING"\n            elif \.status/if . == null then "PASS"\n            elif .status/')"
no_unverified="$(ablate no-unverified 's/if \[ "\$\{unverified\}" -ne 0 \]; then/if false; then/')"
no_org_pin="$(ablate no-org-pin 's/github\\\.com\/devantler-tech\/\(/github\\.com\/[A-Za-z0-9_.-]+\/(/')"
no_single="$(ablate no-single-document 's/length == 1 and //')"
no_mix_guard="$(ablate no-mix-guard 's/ && \[ -z "\$\{repo\}\$\{base\}\$\{head\}" \]//')"
no_unfinished="$(ablate no-unfinished 's/if \$seen == "MISSING" and \$unfinished and \(\$g\.app == null or \$g\.app == actions_app\)\n         then "PENDING" else \$seen end/\$seen/')"
any_gate_waits="$(ablate any-gate-waits 's/ and \(\$g\.app == null or \$g\.app == actions_app\)\n         then "PENDING"/\n         then "PENDING"/')"
status_passes_bound="$(ablate status-passes-bound 's/if \$g\.app == null then \(if \(\$cr \| rank\) >= \(\$st \| rank\) then \$cr else \$st end\)/if true then (if (\$cr | rank) >= (\$st | rank) then \$cr else \$st end)/')"
only_workflow_runs="$(ablate only-workflow-runs 's/\n     or any\(\$runs\[\]; \.status != "completed" and \(\.app\.slug \/\/ ""\) == "github-actions"\)//')"
any_app="$(ablate any-app 's/ and \(\.app\.slug \/\/ ""\) == "github-actions"//')"
no_control_strip="$(ablate no-control-strip 's/ \| LC_ALL=C tr -d \x27\[:cntrl:\]\x27//')"
no_dedupe="$(ablate no-dedupe 's/!seen\[\$0\]\+\+ \{ n\+\+;/{ n++;/')"
# An abort nothing foresaw, placed after the survey form is set up: `false` under `set -e`.
aborting="$(ablate aborting 's/\nrules="\$\(read_json/\nfalse\nrules="\$(read_json/')"
aborting_no_backstop="${tmp}/aborting-no-backstop.sh"
perl -0pe 's/  trap survey_backstop EXIT\n//' "${aborting}" >"${aborting_no_backstop}"
if cmp -s "${aborting}" "${aborting_no_backstop}"; then
  echo "FAIL ablation aborting-no-backstop did not change the tool" >&2
  failures=$((failures + 1))
fi
no_required_url="$(ablate no-required-url 's/ and \(\.workflow_url \/\/ "" \| contains\("\/actions\/required_workflows\/"\)\)//')"
no_value_guard="$(ablate no-value-guard 's/\[ "\$#" -ge 2 \] \|\| usage; //g')"

expect_ablation_fails() { # <label> <ablated tool> <fixture> <rc the real tool gives>
  local got rc
  checks=$((checks + 1))
  set +e
  got="$(run "$2" "$3")"
  rc=$?
  set -e
  if [ "${rc}" != "$4" ]; then echo "ok   ablation caught: $1"; else
    echo "FAIL ablation not caught: $1 (rc=${rc})" >&2
    failures=$((failures + 1))
  fi
}
expect_ablation_fails "without the truncation guard a partial list is judged" "${no_trunc}" truncated 2
expect_ablation_fails "without MISSING an absent check reads green" "${no_missing}" missing-check 1
expect_ablation_fails "without the UNVERIFIED guard code_quality reads complete" "${no_unverified}" code-quality 2
expect_ablation_fails "without the required-run filter a local run shadows a failure" "${no_required_url}" local-shadow 1
# Both arms exit 1, so these compare the gate line rather than the status. The ablated tool must
# print the OTHER state for that gate: an ablation that merely crashed prints neither line.
expect_ablation_line() { # <label> <ablated tool> <fixture> <line the ablated tool must print instead>
  local got
  checks=$((checks + 1))
  set +e
  got="$(run "$2" "$3")"
  set -e
  if [[ "${got}" == *"$4"* ]]; then echo "ok   ablation caught: $1"; else
    echo "FAIL ablation not caught: $1 — wanted '$4', got:" >&2
    printf '%s\n' "${got}" >&2
    failures=$((failures + 1))
  fi
}
expect_ablation_line "without the unfinished-run rule a job that has not started reads MISSING" \
  "${no_unfinished}" absent-while-run-unfinished "GATE check Build MISSING"
expect_ablation_line "without the check-run arm a queued Actions job is not seen" \
  "${only_workflow_runs}" absent-while-job-queued "GATE check Build MISSING"
expect_ablation_line "without the Actions test another app's check-run delays MISSING" \
  "${any_app}" absent-while-other-app-queued "GATE check Build PENDING"
expect_ablation_line "without the app test an Actions run delays a check bound to another app" \
  "${any_gate_waits}" other-app-absent-while-run-unfinished "GATE check Build PENDING"
expect_ablation_line "without the app-bound rule a passing status passes the gate" \
  "${status_passes_bound}" app-bound-status-only "COMPLETE required=1"

expect_survey_ablation() { # <label> <ablated tool> <fixture> <payload> <last line the ablated tool must print> [extra args…]
  local label="$1" t="$2" fx="$3" payload="$4" want="$5" got last
  shift 5
  checks=$((checks + 1))
  set +e
  got="$(run_survey "${t}" "${fx}" "${payload}" "$@")"
  set -e
  last="$(printf '%s\n' "${got}" | tail -n 1)"
  if [ "${last}" = "${want}" ]; then echo "ok   ablation caught: ${label}"; else
    echo "FAIL ablation not caught: ${label} — wanted last line '${want}', got:" >&2
    printf '%s\n' "${got}" >&2
    failures=$((failures + 1))
  fi
}
# Each of these three ends in `required=complete`, the verdict the removed guard exists to refuse.
expect_survey_ablation "without the owner pin another organisation's pull request is judged as ours" \
  "${no_org_pin}" complete "${foreign_json}" "required=complete"
checks=$((checks + 1))
if [ -s "${stub_log}" ]; then echo "ok   ablation caught: without the owner pin the forge is read"; else
  echo "FAIL ablation not caught: without the owner pin nothing was read" >&2
  failures=$((failures + 1))
fi
expect_survey_ablation "without the single-document guard a second pull request is silently dropped" \
  "${no_single}" complete "${pr_json}${pr_json}" "required=complete"
expect_survey_ablation "without the mix guard a target in argv is silently ignored" \
  "${no_mix_guard}" complete "${pr_json}" "required=complete" --repo devantler-tech/monorepo
expect_survey_ablation "without the control-character strip the name is copied raw" \
  "${no_control_strip}" control-character-name "${pr_json}" "$(printf 'required=missing:Bu\aild')"
expect_survey_ablation "without the de-duplication a gate required twice is named twice" \
  "${no_dedupe}" same-name-twice "${pr_json}" "required=missing:Build,Build"
# The backstop: an abort nothing foresaw still ends the survey form in a `required=` line and
# exit 2. Without it the same abort prints nothing, which only a missing-line rule could catch.
expect_survey "survey: an unforeseen abort still ends in the survey line" "${aborting}" complete "${pr_json}" 2 \
  "required=unknown:aborted"
checks=$((checks + 1))
set +e
got="$(run_survey "${aborting_no_backstop}" complete "${pr_json}")"
rc=$?
set -e
if [ -z "${got}" ] && [ "${rc}" != 0 ]; then
  echo "ok   ablation caught: without the backstop an abort prints no survey line"
else
  echo "FAIL ablation not caught: without the backstop the abort gave rc=${rc}: ${got}" >&2
  failures=$((failures + 1))
fi
# The backstop belongs to the survey form alone: the argv form's abort keeps the shell's status
# and prints no survey line.
checks=$((checks + 1))
set +e
got="$(run "${aborting}" complete)"
rc=$?
set -e
if [ -z "${got}" ] && [ "${rc}" != 0 ] && [ "${rc}" != 2 ]; then
  echo "ok   the argv form's abort is left to the shell"
else
  echo "FAIL the argv form's abort was rewritten (rc=${rc}): ${got}" >&2
  failures=$((failures + 1))
fi
checks=$((checks + 1))
set +e
got="$(run_survey "${no_unverified}" code-quality "${pr_json}")"
set -e
if [ "$(printf '%s\n' "${got}" | tail -n 1)" = "required=complete" ]; then
  echo "ok   ablation caught: without the UNVERIFIED guard the survey line reads complete"
else
  echo "FAIL ablation not caught: the survey line without the UNVERIFIED guard was: ${got}" >&2
  failures=$((failures + 1))
fi
checks=$((checks + 1))
set +e
missing_value "${no_value_guard}"
rc=$?
set -e
if [ "${rc}" != 2 ]; then echo "ok   ablation caught: without the value guard a missing value is not a usage error"; else
  echo "FAIL ablation not caught: without the value guard (rc=${rc})" >&2
  failures=$((failures + 1))
fi

# The contract must route exception (a) through this check, and every prescribed branch update must
# carry its head pin. Scoped to the Merge policy section so a phrase surviving elsewhere does not count.
merge_policy="$(awk '/^## Merge policy/ { inside = 1 } inside && /^## / && !/Merge policy/ { exit } inside' \
  "${here}/../guides/merge-policy.md")"
contract() { # contract <label> <fixed string>
  checks=$((checks + 1))
  if grep -Fq -- "$2" <<<"${merge_policy}"; then echo "ok   contract: $1"; else
    echo "FAIL contract: $1 — Merge policy lacks: $2" >&2
    failures=$((failures + 1))
  fi
}
contract "exception (a) runs the completeness check" \
  '.claude/scripts/required-gate-completeness.sh --repo devantler-tech/<repo> --base <baseRefName> --head <headRefOid>'
contract "only COMPLETE lets (a) apply" '**Exit `0` (`COMPLETE`)** is the only reading under which (a) applies.'
contract "a merge exit 0 is not a merge" "A merge command's exit \`0\` is not a merge."
contract "the branch-update remedy is pinned" \
  'gh api --method PUT repos/devantler-tech/<repo>/pulls/<n>/update-branch -f expected_head_sha=<headRefOid>'
checks=$((checks + 1))
grep_status=0
update_branch_lines="$(grep -E 'pulls/[^ `]*/update-branch' "${here}/../guides/merge-policy.md")" || grep_status=$?
if [ "${grep_status}" -gt 1 ]; then
  echo "FAIL contract: could not read the prescribed update-branch calls (grep exit ${grep_status})" >&2
  failures=$((failures + 1))
elif [ -n "${update_branch_lines}" ] && grep -vq 'expected_head_sha=' <<<"${update_branch_lines}"; then
  echo "FAIL contract: an update-branch call is prescribed without expected_head_sha" >&2
  failures=$((failures + 1))
else
  echo "ok   contract: every prescribed update-branch carries its head pin"
fi

completed=1
if [ "${failures}" -gt 0 ]; then
  echo "required-gate-completeness: ${failures} of ${checks} checks FAILED" >&2
  exit 1
fi
echo "required-gate-completeness: all ${checks} checks passed"
