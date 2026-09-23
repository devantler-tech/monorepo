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
no_unverified="$(ablate no-unverified 's/\[ "\$\{unverified\}" -eq 0 \] \|\| unknown/true || unknown/')"
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
merge_policy="$(awk '/^### Merge policy/ { inside = 1 } inside && /^### / && !/Merge policy/ { exit } inside' \
  "${here}/../../AGENTS.md")"
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
update_branch_lines="$(grep -E 'pulls/[^ `]*/update-branch' "${here}/../../AGENTS.md" || true)"
if [ -n "${update_branch_lines}" ] && grep -vq 'expected_head_sha=' <<<"${update_branch_lines}"; then
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
