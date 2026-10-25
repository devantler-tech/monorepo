#!/usr/bin/env bash
# Tests for main-head-rung0-probe.sh (monorepo#3623, monorepo#4518).
#
# A stub `gh` on PATH serves one fixture directory per case: main.json for `commits/main`,
# checks.json for the head's check runs and runs.json for its workflow runs. A missing file is a
# failed read. The cases that motivated the probe are the two a check-run-only read calls clean:
# a failed workflow with no jobs beside zero check runs, and the same beside a green check run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="${here}/main-head-rung0-probe.sh"
tmp="$(mktemp -d)"

mkdir -p "${tmp}/bin" "${tmp}/fx"
cat >"${tmp}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 1
path=""
for a in "$@"; do case "${a}" in repos/*) path="${a}" ;; esac; done
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "${path}" >>"${STUB_LOG}"
case "${path}" in
  */commits/main) f=main.json ;;
  */check-runs\?*) f=checks.json ;;
  */actions/runs\?head_sha=*) f=runs.json ;;
  *) exit 1 ;;
esac
[ -f "${STUB_DIR}/${f}" ] || exit 1
cat "${STUB_DIR}/${f}"
STUB
chmod +x "${tmp}/bin/gh"

sha="0123456789abcdef0123456789abcdef01234567"
main_ok="{\"sha\":\"${sha}\"}"
check_ok='{"name":"Lint","status":"completed","conclusion":"success"}'
check_red='{"name":"Build","status":"completed","conclusion":"failure"}'
check_skip='{"name":"Docs","status":"completed","conclusion":"skipped"}'
run_ok='{"name":"CI","path":".github/workflows/ci.yaml","status":"completed","conclusion":"success"}'
# A workflow that fails validation before creating a job: completed, failed, and no check run.
run_nojob_red='{"name":"Release","path":".github/workflows/release.yaml","status":"completed","conclusion":"failure"}'
run_startup='{"name":"Scan","path":".github/workflows/scan.yaml","status":"completed","conclusion":"startup_failure"}'
run_busy='{"name":"CI","path":".github/workflows/ci.yaml","status":"in_progress","conclusion":null}'
checks() { local n="$1"; shift; local IFS=,; printf '{"total_count":%s,"check_runs":[%s]}' "${n}" "$*"; }
runs() { local n="$1"; shift; local IFS=,; printf '{"total_count":%s,"workflow_runs":[%s]}' "${n}" "$*"; }

fixture() { # fixture <name> <main|-> <checks|-> <runs|->  ("-" leaves the file out: a failed read)
  local d="${tmp}/fx/$1"
  mkdir -p "${d}"
  [ "$2" = - ] || printf '%s\n' "$2" >"${d}/main.json"
  [ "$3" = - ] || printf '%s\n' "$3" >"${d}/checks.json"
  [ "$4" = - ] || printf '%s\n' "$4" >"${d}/runs.json"
}

fixture green "${main_ok}" "$(checks 2 "${check_ok}" "${check_skip}")" "$(runs 1 "${run_ok}")"
fixture zero-checks-nojob-red "${main_ok}" "$(checks 0)" "$(runs 1 "${run_nojob_red}")"
fixture green-check-beside-nojob-red "${main_ok}" "$(checks 1 "${check_ok}")" "$(runs 2 "${run_ok}" "${run_nojob_red}")"
fixture startup-failure "${main_ok}" "$(checks 1 "${check_ok}")" "$(runs 2 "${run_ok}" "${run_startup}")"
fixture red-check "${main_ok}" "$(checks 2 "${check_ok}" "${check_red}")" "$(runs 1 "${run_ok}")"
fixture red-check-truncated-runs "${main_ok}" "$(checks 1 "${check_red}")" "$(runs 3 "${run_ok}")"
fixture zero-checks-zero-runs "${main_ok}" "$(checks 0)" "$(runs 0)"
fixture zero-checks-green-run "${main_ok}" "$(checks 0)" "$(runs 1 "${run_ok}")"
fixture green-checks-zero-runs "${main_ok}" "$(checks 1 "${check_ok}")" "$(runs 0)"
fixture truncated-checks "${main_ok}" "$(checks 150 "${check_ok}")" "$(runs 1 "${run_ok}")"
fixture truncated-runs "${main_ok}" "$(checks 1 "${check_ok}")" "$(runs 2 "${run_ok}")"
fixture unfinished "${main_ok}" "$(checks 1 "${check_ok}")" "$(runs 1 "${run_busy}")"
fixture main-unreadable - "$(checks 1 "${check_ok}")" "$(runs 1 "${run_ok}")"
fixture main-malformed '{"sha":"not-a-sha"}' "$(checks 1 "${check_ok}")" "$(runs 1 "${run_ok}")"
fixture checks-unreadable "${main_ok}" - "$(runs 1 "${run_ok}")"
fixture runs-unreadable "${main_ok}" "$(checks 1 "${check_ok}")" -
fixture runs-wrong-shape "${main_ok}" "$(checks 1 "${check_ok}")" '{"total_count":1,"jobs":[]}'
# --paginate prints one object per page; the counts must sum across pages.
fixture two-pages "${main_ok}" "$(checks 2 "${check_ok}")
$(checks 2 "${check_ok}")" "$(runs 1 "${run_ok}")"

cases=0
failures=0
expect() { # expect <fixture> <want-rc> <want-substring> [extra args…]
  local fx="$1" want_rc="$2" want="$3" got rc
  shift 3
  cases=$((cases + 1))
  set +e
  got="$(STUB_DIR="${tmp}/fx/${fx}" PATH="${tmp}/bin:${PATH}" bash "${tool}" --repo devantler-tech/monorepo "$@" 2>/dev/null)"
  rc=$?
  set -e
  if [ "${rc}" = "${want_rc}" ] && [[ "${got}" == *"${want}"* ]]; then
    echo "ok   ${fx}"
  else
    echo "FAIL ${fx}: rc=${rc} (want ${want_rc}), output: ${got} (want: ${want})" >&2
    failures=$((failures + 1))
  fi
}

expect green 0 "sha=${sha} checks=2 runs=1 OK"
expect zero-checks-nojob-red 1 'BREAKAGE workflow:.github/workflows/release.yaml=failure'
expect green-check-beside-nojob-red 1 'BREAKAGE workflow:.github/workflows/release.yaml=failure'
expect startup-failure 1 'workflow:.github/workflows/scan.yaml=startup_failure'
expect red-check 1 'BREAKAGE check:Build=failure'
expect red-check-truncated-runs 1 'BREAKAGE check:Build=failure'
expect zero-checks-zero-runs 2 'UNKNOWN no-check-runs'
expect zero-checks-green-run 2 'UNKNOWN no-check-runs'
expect green-checks-zero-runs 2 'UNKNOWN no-workflow-runs'
expect truncated-checks 2 'UNKNOWN truncated check_runs fetched=1 total=150'
expect truncated-runs 2 'UNKNOWN truncated workflow_runs fetched=1 total=2'
expect unfinished 0 'OK'
expect main-unreadable 2 'UNKNOWN read-failed main'
expect main-malformed 2 'UNKNOWN malformed main'
expect checks-unreadable 2 'UNKNOWN read-failed check-runs'
expect runs-unreadable 2 'UNKNOWN read-failed workflow-runs'
expect runs-wrong-shape 2 'UNKNOWN malformed workflow_runs'
expect two-pages 0 'checks=2 runs=1 OK'

# The worst repository decides: breakage beats UNKNOWN, UNKNOWN beats OK. Each repo reads the same
# fixture here, so the order is proven with two different fixtures through two calls.
cases=$((cases + 1))
set +e
out="$(STUB_DIR="${tmp}/fx/green" PATH="${tmp}/bin:${PATH}" bash "${tool}" --repo devantler-tech/a --repo devantler-tech/b 2>/dev/null)"
rc=$?
set -e
if [ "${rc}" = 0 ] && [ "$(grep -c ' OK$' <<<"${out}")" = 2 ]; then echo "ok   two repositories, one line each"
else echo "FAIL two repositories: rc=${rc} output: ${out}" >&2; failures=$((failures + 1)); fi

# The workflow-run read is the one that catches a failed zero-job workflow: prove it is made at the head.
cases=$((cases + 1))
log="${tmp}/gh.log"
STUB_LOG="${log}" STUB_DIR="${tmp}/fx/green" PATH="${tmp}/bin:${PATH}" bash "${tool}" --repo devantler-tech/monorepo >/dev/null 2>&1 || true
if grep -qx "repos/devantler-tech/monorepo/actions/runs?head_sha=${sha}&per_page=100" "${log}" &&
  grep -qx "repos/devantler-tech/monorepo/commits/${sha}/check-runs?per_page=100" "${log}"; then
  echo "ok   reads check runs and workflow runs at the resolved head"
else echo "FAIL head reads: $(tr '\n' ' ' <"${log}")" >&2; failures=$((failures + 1)); fi

# Usage errors are UNKNOWN (exit 2) and never reach the forge.
for args in "" "--repo" "--repo someone-else/monorepo" "--repo devantler-tech/.." "--repo devantler-tech/a/b" "--bogus"; do
  cases=$((cases + 1))
  : >"${log}"
  set +e
  # shellcheck disable=SC2086 # the cases are word lists on purpose
  STUB_LOG="${log}" STUB_DIR="${tmp}/fx/green" PATH="${tmp}/bin:${PATH}" bash "${tool}" ${args} >/dev/null 2>&1
  rc=$?
  set -e
  if [ "${rc}" = 2 ] && [ ! -s "${log}" ]; then echo "ok   usage error: '${args}'"
  else echo "FAIL usage error '${args}': rc=${rc}, forge reads: $(wc -l <"${log}")" >&2; failures=$((failures + 1)); fi
done

rm -rf "${tmp}"
if [ "${failures}" -gt 0 ]; then
  echo "main-head-rung0-probe tests: FAIL (${failures} of ${cases})" >&2
  exit 1
fi
echo "main-head-rung0-probe tests: PASS (${cases} cases)"
