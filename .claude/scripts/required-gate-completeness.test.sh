#!/usr/bin/env bash
# required-gate-completeness.test.sh — hermetic proof for required-gate-completeness.sh
# (monorepo#2730). A stub `gh` on PATH serves one canned response per endpoint, so no token or
# network is needed. Key properties are paired with an ablated copy that must FAIL the same case.
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
# Every forge read is logged, so a case can prove which repository was read, or that none was.
[ -z "${STUB_LOG:-}" ] || printf '%s\n' "${path}" >>"${STUB_LOG}"
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
  '{"total_count":1,"check_runs":[{"id":11,"name":"Lint","status":"queued","conclusion":null,"app":{"id":15368}}]}' '[]' \
  '{"total_count":0,"workflow_runs":[]}'
fixture absent-after-runs-finished "${rules_build_only}" "${branch_off}" \
  '{"total_count":1,"check_runs":[{"id":11,"name":"Lint","status":"completed","conclusion":"success","app":{"id":15368}}]}' '[]' \
  "{\"total_count\":1,\"workflow_runs\":[${finished_ci}]}"
# monorepo#3506: the survey line must name every gate in every blocking state, not only the first.
fixture two-missing '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Build"},{"context":"CI - Required Checks"}]}}]' \
  "${branch_off}" '{"total_count":0,"check_runs":[]}' '[]' '{"total_count":0,"workflow_runs":[]}'
fixture missing-and-failed "${rules_check_and_workflow}" "${branch_off}" \
  '{"total_count":0,"check_runs":[]}' '[]' \
  "{\"total_count\":1,\"workflow_runs\":[{\"id\":101,\"path\":\".github/workflows/scan.yaml\",${req_url},\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-09-22T10:00:00Z\"}]}"

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
expect "an absent check is PENDING while another job is queued" "${tool}" absent-while-job-queued 1 \
  "GATE check Build PENDING"
expect "an absent check is MISSING once every run has finished" "${tool}" absent-after-runs-finished 1 \
  "GATE check Build MISSING"

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
if grep -Fxq 'repos/devantler-tech/monorepo/rules/branches/main' "${stub_log}" &&
  grep -Fxq "repos/devantler-tech/monorepo/commits/${head_sha}/check-runs?per_page=100" "${stub_log}"; then
  echo "ok   survey: the repository, base and head come from the piped pull request"
else
  echo "FAIL survey: the piped pull request did not select the reads:" >&2
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

# Input that is not exactly one devantler-tech pull request is refused BEFORE any forge read.
foreign_json="{\"url\":\"https://github.com/someone-else/monorepo/pull/7\",\"baseRefName\":\"main\",\"headRefOid\":\"${head_sha}\"}"
for bad in \
  "not a pull request|not json" \
  "a repository outside the portfolio|${foreign_json}" \
  "two pull requests|${pr_json}${pr_json}" \
  "an array|[${pr_json}]" \
  "a missing base|{\"url\":\"https://github.com/devantler-tech/monorepo/pull/7\",\"headRefOid\":\"${head_sha}\"}" \
  "an abbreviated head|{\"url\":\"https://github.com/devantler-tech/monorepo/pull/7\",\"baseRefName\":\"main\",\"headRefOid\":\"0123456\"}" \
  "a base that climbs out of its path|{\"url\":\"https://github.com/devantler-tech/monorepo/pull/7\",\"baseRefName\":\"../../x\",\"headRefOid\":\"${head_sha}\"}" \
  "a repository name that climbs out of its path|{\"url\":\"https://github.com/devantler-tech/../pull/7\",\"baseRefName\":\"main\",\"headRefOid\":\"${head_sha}\"}" \
  "a url that is not a pull request|{\"url\":\"https://github.com/devantler-tech/monorepo/issues/7\",\"baseRefName\":\"main\",\"headRefOid\":\"${head_sha}\"}" \
  "a tab that would shift the fields|{\"url\":\"https://github.com/devantler-tech/monorepo/pull/7\\tmain\\t${head_sha}\",\"baseRefName\":\"x\",\"headRefOid\":\"y\"}"; do
  expect_survey "survey: ${bad%%|*} is refused" "${tool}" complete "${bad#*|}" 2 "required=unknown:malformed-input"
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
no_unfinished="$(ablate no-unfinished 's/if \$seen == "MISSING" and \$unfinished then "PENDING" else \$seen end/\$seen/')"
only_workflow_runs="$(ablate only-workflow-runs 's/ or any\(\$runs\[\]; \.status != "completed"\)//')"
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
# Both arms exit 1, so these two compare the gate line rather than the status.
expect_ablation_line() { # <label> <ablated tool> <fixture> <line the real tool prints>
  local got
  checks=$((checks + 1))
  set +e
  got="$(run "$2" "$3")"
  set -e
  if [[ "${got}" != *"$4"* ]]; then echo "ok   ablation caught: $1"; else
    echo "FAIL ablation not caught: $1" >&2
    failures=$((failures + 1))
  fi
}
expect_ablation_line "without the unfinished-run rule a job that has not started reads MISSING" \
  "${no_unfinished}" absent-while-run-unfinished "GATE check Build PENDING"
expect_ablation_line "without the check-run arm a queued sibling job is not seen" \
  "${only_workflow_runs}" absent-while-job-queued "GATE check Build PENDING"

expect_survey_ablation_fails() { # <label> <ablated tool> <payload> <rc the real tool gives> [extra args…]
  local label="$1" t="$2" payload="$3" real="$4" rc
  shift 4
  checks=$((checks + 1))
  set +e
  run_survey "${t}" complete "${payload}" "$@" >/dev/null
  rc=$?
  set -e
  if [ "${rc}" != "${real}" ]; then echo "ok   ablation caught: ${label}"; else
    echo "FAIL ablation not caught: ${label} (rc=${rc})" >&2
    failures=$((failures + 1))
  fi
}
expect_survey_ablation_fails "without the owner pin another organisation's pull request is judged" \
  "${no_org_pin}" "${foreign_json}" 2
expect_survey_ablation_fails "without the single-document guard a second pull request is ignored" \
  "${no_single}" "${pr_json}${pr_json}" 2
expect_survey_ablation_fails "without the mix guard argv aims the survey form" \
  "${no_mix_guard}" "${pr_json}" 2 --repo devantler-tech/monorepo
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
