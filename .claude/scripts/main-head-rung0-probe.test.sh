#!/usr/bin/env bash
# Tests for main-head-rung0-probe.sh (monorepo#3623, monorepo#4518).
#
# A stub `gh` on PATH serves one fixture directory per case: head.json for `commits/<branch>`,
# checks.json for the head's check runs, runs.json for its workflow runs, branches.json for a
# repository's branch list, and org.json / repos.json for the organization census. A file in a
# `<repo>/` subdirectory overrides the shared one for that repository. A missing file is a failed
# read. The cases that motivated the probe are the two a check-run-only read calls clean: a failed
# workflow with no jobs beside zero check runs, and the same beside a green check run.
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
for a in "$@"; do case "${a}" in repos/* | orgs/*) path="${a}" ;; esac; done
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "${path}" >>"${STUB_LOG}"
repo=""
case "${path}" in repos/*/*) repo="${path#repos/*/}"; repo="${repo%%/*}" ;; esac
case "${path}" in
  orgs/*/repos\?*) f=repos.json ;;
  orgs/*) f=org.json ;;
  */check-runs\?*) f=checks.json ;;
  */actions/runs\?head_sha=*) f=runs.json ;;
  */branches\?per_page=1) f=branches.json ;;
  */commits/*) f=head.json ;;
  *) exit 1 ;;
esac
if [ -n "${repo}" ] && [ -f "${STUB_DIR}/${repo}/${f}" ]; then cat "${STUB_DIR}/${repo}/${f}"; exit 0; fi
[ -n "${repo}" ] && [ -f "${STUB_DIR}/${repo}/${f}.missing" ] && exit 1
[ -f "${STUB_DIR}/${f}" ] || exit 1
cat "${STUB_DIR}/${f}"
STUB
chmod +x "${tmp}/bin/gh"

sha="0123456789abcdef0123456789abcdef01234567"
head_ok="{\"sha\":\"${sha}\"}"
check_ok='{"name":"Lint","status":"completed","conclusion":"success"}'
check_red='{"name":"Build","status":"completed","conclusion":"failure"}'
check_skip='{"name":"Docs","status":"completed","conclusion":"skipped"}'
# run <workflow_id> <path> <event> <run_number> <status> <conclusion|null> [<check_suite_id>]
run() {
  local c="$6" s=""
  [ "${c}" = null ] || c="\"${c}\""
  [ -z "${7:-}" ] || s=",\"check_suite_id\":$7"
  printf '{"workflow_id":%s,"name":"w%s","path":"%s","event":"%s","run_number":%s,"status":"%s","conclusion":%s%s}' \
    "$1" "$1" "$2" "$3" "$4" "$5" "${c}" "${s}"
}
# suite_check <name> <conclusion> <check_suite_id> — a check run an Actions workflow run created
suite_check() { printf '{"name":"%s","status":"completed","conclusion":"%s","check_suite":{"id":%s}}' "$1" "$2" "$3"; }
ci=.github/workflows/ci.yaml
rel=.github/workflows/release.yaml
run_ok="$(run 1 "${ci}" push 7 completed success)"
# A workflow that fails validation before creating a job: completed, failed, and no check run.
run_nojob_red="$(run 2 "${rel}" push 3 completed failure)"
run_startup="$(run 3 .github/workflows/scan.yaml push 1 completed startup_failure)"
run_busy="$(run 1 "${ci}" push 8 in_progress null)"
checks() { local n="$1"; shift; local IFS=,; printf '{"total_count":%s,"check_runs":[%s]}' "${n}" "$*"; }
runs() { local n="$1"; shift; local IFS=,; printf '{"total_count":%s,"workflow_runs":[%s]}' "${n}" "$*"; }

fixture() { # fixture <name> <head|-> <checks|-> <runs|->  ("-" leaves the file out: a failed read)
  local d="${tmp}/fx/$1"
  mkdir -p "${d}"
  [ "$2" = - ] || printf '%s\n' "$2" >"${d}/head.json"
  [ "$3" = - ] || printf '%s\n' "$3" >"${d}/checks.json"
  [ "$4" = - ] || printf '%s\n' "$4" >"${d}/runs.json"
}

fixture green "${head_ok}" "$(checks 2 "${check_ok}" "${check_skip}")" "$(runs 1 "${run_ok}")"
fixture zero-checks-nojob-red "${head_ok}" "$(checks 0)" "$(runs 1 "${run_nojob_red}")"
fixture green-check-beside-nojob-red "${head_ok}" "$(checks 1 "${check_ok}")" "$(runs 2 "${run_ok}" "${run_nojob_red}")"
fixture startup-failure "${head_ok}" "$(checks 1 "${check_ok}")" "$(runs 2 "${run_ok}" "${run_startup}")"
fixture red-check "${head_ok}" "$(checks 2 "${check_ok}" "${check_red}")" "$(runs 1 "${run_ok}")"
fixture red-check-truncated-runs "${head_ok}" "$(checks 1 "${check_red}")" "$(runs 3 "${run_ok}")"
fixture zero-checks-zero-runs "${head_ok}" "$(checks 0)" "$(runs 0)"
fixture zero-checks-green-run "${head_ok}" "$(checks 0)" "$(runs 1 "${run_ok}")"
fixture green-checks-zero-runs "${head_ok}" "$(checks 1 "${check_ok}")" "$(runs 0)"
fixture truncated-checks "${head_ok}" "$(checks 150 "${check_ok}")" "$(runs 1 "${run_ok}")"
fixture truncated-runs "${head_ok}" "$(checks 1 "${check_ok}")" "$(runs 2 "${run_ok}")"
fixture unfinished "${head_ok}" "$(checks 1 "${check_ok}")" "$(runs 2 "${run_ok}" "${run_busy}")"
fixture head-malformed '{"sha":"not-a-sha"}' "$(checks 1 "${check_ok}")" "$(runs 1 "${run_ok}")"
fixture checks-unreadable "${head_ok}" - "$(runs 1 "${run_ok}")"
fixture runs-unreadable "${head_ok}" "$(checks 1 "${check_ok}")" -
fixture runs-wrong-shape "${head_ok}" "$(checks 1 "${check_ok}")" '{"total_count":1,"jobs":[]}'
fixture runs-ungroupable "${head_ok}" "$(checks 1 "${check_ok}")" \
  '{"total_count":1,"workflow_runs":[{"name":"CI","status":"completed","conclusion":"failure"}]}'
# --paginate prints one object per page; the counts must sum across pages.
fixture two-pages "${head_ok}" "$(checks 2 "${check_ok}")
$(checks 2 "${check_ok}")" "$(runs 1 "${run_ok}")"
# Superseding (Codex on #4518): only a later run of the SAME workflow and event clears a failure.
fixture superseded-failure "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "$(run 4 digest.yaml schedule 10 completed failure)" "$(run 4 digest.yaml schedule 11 completed success)")"
fixture later-failure "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "$(run 4 digest.yaml schedule 11 completed failure)" "$(run 4 digest.yaml schedule 10 completed success)")"
fixture other-event-does-not-supersede "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "$(run 4 digest.yaml schedule 10 completed failure)" "$(run 4 digest.yaml workflow_dispatch 11 completed success)")"
fixture other-workflow-does-not-supersede "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "$(run 4 digest.yaml push 10 completed failure)" "$(run 5 other.yaml push 11 completed success)")"
# A cancelled run has no verdict (monorepo#4527, the unifi head): a LATER successful run of the same
# workflow at the head replaces it whatever its event. Nothing else clears a cancelled run.
cancelled_push="$(run 1 "${ci}" push 9 completed cancelled)"
fixture cancelled-then-green-other-event "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "${cancelled_push}" "$(run 1 "${ci}" workflow_dispatch 10 completed success)")"
fixture cancelled-alone "${head_ok}" "$(checks 1 "${check_ok}")" "$(runs 1 "${cancelled_push}")"
fixture cancelled-then-red-other-event "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "${cancelled_push}" "$(run 1 "${ci}" workflow_dispatch 10 completed failure)")"
fixture cancelled-then-unfinished-other-event "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "${cancelled_push}" "$(run 1 "${ci}" workflow_dispatch 10 in_progress null)")"
fixture cancelled-after-green-other-event "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "${cancelled_push}" "$(run 1 "${ci}" workflow_dispatch 8 completed success)")"
fixture cancelled-then-green-other-workflow "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "${cancelled_push}" "$(run 5 other.yaml workflow_dispatch 10 completed success)")"
# monorepo#4529: an earlier genuine failure survives anything that is not a later qualifying
# success of the same workflow and event. Filtering happens BEFORE the latest run is chosen, so a
# cancellation, a pending run or a non-deciding conclusion can never stand in for the failure.
red_push="$(run 1 "${ci}" push 7 completed failure)"
fixture failure-cancel-other-event-green "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 3 "${red_push}" "$(run 1 "${ci}" push 8 completed cancelled)" "$(run 1 "${ci}" workflow_dispatch 9 completed success)")"
fixture failure-then-pending "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "${red_push}" "$(run 1 "${ci}" push 8 in_progress null)")"
fixture failure-then-skipped "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "${red_push}" "$(run 1 "${ci}" push 8 completed skipped)")"
fixture failure-then-neutral "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "${red_push}" "$(run 1 "${ci}" push 8 completed neutral)")"
fixture failure-cancel-same-event-green "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 3 "${red_push}" "$(run 1 "${ci}" push 8 completed cancelled)" "$(run 1 "${ci}" push 9 completed success)")"
fixture failure-skipped-then-green "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 3 "${red_push}" "$(run 1 "${ci}" push 8 completed skipped)" "$(run 1 "${ci}" push 9 completed success)")"
fixture green-then-skipped "${head_ok}" "$(checks 1 "${check_ok}")" \
  "$(runs 2 "$(run 1 "${ci}" push 7 completed success)" "$(run 1 "${ci}" push 8 completed skipped)")"
# A check run an Actions workflow run created is judged through that run, so superseding covers it
# too (the cloudflare head, 2026-10-25: a failed dispatch re-run green kept weekly pacing off through
# the failed run's job check). A check run of any other suite still counts on its own.
fixture superseded-failure-job-check "${head_ok}" \
  "$(checks 2 "$(suite_check check failure 501)" "$(suite_check check success 502)")" \
  "$(runs 2 "$(run 4 probe.yaml workflow_dispatch 1 completed failure 501)" "$(run 4 probe.yaml workflow_dispatch 2 completed success 502)")"
fixture live-failure-job-check "${head_ok}" \
  "$(checks 1 "$(suite_check check failure 501)")" \
  "$(runs 1 "$(run 4 probe.yaml workflow_dispatch 1 completed failure 501)")"
fixture red-check-other-suite "${head_ok}" \
  "$(checks 2 "$(suite_check Build failure 777)" "$(suite_check check success 502)")" \
  "$(runs 1 "$(run 4 probe.yaml workflow_dispatch 2 completed success 502)")"
# A failed head read is UNKNOWN unless the branch list proves the repository empty.
fixture head-unreadable - "$(checks 1 "${check_ok}")" "$(runs 1 "${run_ok}")"
fixture head-unreadable-branches-exist - "$(checks 1 "${check_ok}")" "$(runs 1 "${run_ok}")"
printf '[{"name":"main"}]\n' >"${tmp}/fx/head-unreadable-branches-exist/branches.json"
fixture empty-repo - - -
printf '[]\n' >"${tmp}/fx/empty-repo/branches.json"

cases=0
failures=0
pass() { echo "ok   $1"; }
flunk() { echo "FAIL $1" >&2; failures=$((failures + 1)); }
probe_in() { # probe_in <fixture> [args…] — the tool's stdout; its exit status in ${rc}
  local fx="$1"
  shift
  set +e
  got="$(STUB_LOG="${log:-/dev/null}" STUB_DIR="${tmp}/fx/${fx}" PATH="${tmp}/bin:${PATH}" bash "${tool}" "$@" 2>/dev/null)"
  rc=$?
  set -e
}
expect() { # expect <fixture> <want-rc> <want-substring> — against --repo devantler-tech/monorepo
  cases=$((cases + 1))
  probe_in "$1" --repo devantler-tech/monorepo
  if [ "${rc}" = "$2" ] && [[ "${got}" == *"$3"* ]]; then pass "$1"
  else flunk "$1: rc=${rc} (want $2), output: ${got} (want: $3)"; fi
}

expect green 0 "sha=${sha} checks=2 runs=1 OK"
expect zero-checks-nojob-red 1 "BREAKAGE workflow:${rel}=failure"
expect green-check-beside-nojob-red 1 "BREAKAGE workflow:${rel}=failure"
expect startup-failure 1 'workflow:.github/workflows/scan.yaml=startup_failure'
expect red-check 1 'BREAKAGE check:Build=failure'
expect red-check-truncated-runs 1 'BREAKAGE check:Build=failure'
expect zero-checks-zero-runs 2 'UNKNOWN no-check-runs'
expect zero-checks-green-run 2 'UNKNOWN no-check-runs'
expect green-checks-zero-runs 2 'UNKNOWN no-workflow-runs'
expect truncated-checks 2 'UNKNOWN truncated check_runs fetched=1 total=150'
expect truncated-runs 2 'UNKNOWN truncated workflow_runs fetched=1 total=2'
expect unfinished 0 'OK'
expect head-malformed 2 'UNKNOWN malformed head'
expect checks-unreadable 2 'UNKNOWN read-failed check-runs'
expect runs-unreadable 2 'UNKNOWN read-failed workflow-runs'
expect runs-wrong-shape 2 'UNKNOWN malformed workflow_runs'
expect runs-ungroupable 2 'UNKNOWN malformed conclusions'
expect two-pages 0 'checks=2 runs=1 OK'
expect superseded-failure 0 'OK'
expect later-failure 1 'BREAKAGE workflow:digest.yaml=failure'
expect other-event-does-not-supersede 1 'BREAKAGE workflow:digest.yaml=failure'
expect other-workflow-does-not-supersede 1 'BREAKAGE workflow:digest.yaml=failure'
expect cancelled-then-green-other-event 0 'runs=2 OK'
expect cancelled-alone 1 "BREAKAGE workflow:${ci}=cancelled"
expect cancelled-then-red-other-event 1 "BREAKAGE workflow:${ci}=cancelled,workflow:${ci}=failure"
expect cancelled-then-unfinished-other-event 1 "BREAKAGE workflow:${ci}=cancelled"
expect cancelled-after-green-other-event 1 "BREAKAGE workflow:${ci}=cancelled"
expect cancelled-then-green-other-workflow 1 "BREAKAGE workflow:${ci}=cancelled"
expect failure-cancel-other-event-green 1 "BREAKAGE workflow:${ci}=failure"
expect failure-then-pending 1 "BREAKAGE workflow:${ci}=failure"
expect failure-then-skipped 1 "BREAKAGE workflow:${ci}=failure"
expect failure-then-neutral 1 "BREAKAGE workflow:${ci}=failure"
expect failure-cancel-same-event-green 0 'runs=3 OK'
expect failure-skipped-then-green 0 'runs=3 OK'
expect green-then-skipped 0 'runs=2 OK'
expect superseded-failure-job-check 0 'checks=2 runs=2 OK'
expect live-failure-job-check 1 'BREAKAGE workflow:probe.yaml=failure'
expect red-check-other-suite 1 'BREAKAGE check:Build=failure'
expect head-unreadable 2 'UNKNOWN read-failed head'
expect head-unreadable-branches-exist 2 'UNKNOWN read-failed head'
expect empty-repo 0 'RUNG0 devantler-tech/monorepo EMPTY'

# Two repositories print one line each, in order.
cases=$((cases + 1))
probe_in green --repo devantler-tech/a --repo devantler-tech/b
if [ "${rc}" = 0 ] && [ "$(grep -c ' OK$' <<<"${got}")" = 2 ]; then pass "two repositories, one line each"
else flunk "two repositories: rc=${rc} output: ${got}"; fi

# The workflow-run read is the one that catches a failed zero-job workflow: prove it is made at the head.
cases=$((cases + 1))
log="${tmp}/gh.log"
: >"${log}"
probe_in green --repo devantler-tech/monorepo
if grep -qx "repos/devantler-tech/monorepo/actions/runs?head_sha=${sha}&per_page=100" "${log}" &&
  grep -qx "repos/devantler-tech/monorepo/commits/${sha}/check-runs?per_page=100" "${log}" &&
  grep -qx "repos/devantler-tech/monorepo/commits/main" "${log}"; then
  pass "reads check runs and workflow runs at the resolved head"
else flunk "head reads: $(tr '\n' ' ' <"${log}")"; fi
log=""

# --- The organization census (Codex on #4518: the census is the live org, not the map) ------------
org_ok='{"public_repos":2,"total_private_repos":1}'
repo_row() { printf '{"name":"%s","archived":%s,"default_branch":"%s"}' "$1" "$2" "$3"; }
census() { # census <name> <org|-> <repos|->
  local d="${tmp}/fx/$1"
  fixture "$1" "${head_ok}" "$(checks 1 "${check_ok}")" "$(runs 1 "${run_ok}")"
  [ "$2" = - ] || printf '%s\n' "$2" >"${d}/org.json"
  [ "$3" = - ] || printf '%s\n' "$3" >"${d}/repos.json"
}
three="[$(repo_row alpha false main),$(repo_row beta false trunk),$(repo_row old true main)]"
census org-complete "${org_ok}" "${three}"
census org-truncated '{"public_repos":3,"total_private_repos":1}' "${three}"
census org-private-count-hidden '{"public_repos":3,"total_private_repos":null}' "${three}"
census org-unreadable - "${three}"
census org-repos-unreadable "${org_ok}" -
census org-repos-malformed "${org_ok}" '[{"name":"alpha"}]'
census org-bad-name '{"public_repos":1,"total_private_repos":0}' "[$(repo_row 'a b' false main)]"
census org-one-red "${org_ok}" "${three}"
mkdir -p "${tmp}/fx/org-one-red/beta"
runs 1 "${run_nojob_red}" >"${tmp}/fx/org-one-red/beta/runs.json"
census org-one-empty "${org_ok}" "${three}"
mkdir -p "${tmp}/fx/org-one-empty/beta"
: >"${tmp}/fx/org-one-empty/beta/head.json.missing"
printf '[]\n' >"${tmp}/fx/org-one-empty/beta/branches.json"
# Two pages of repositories must both count toward the total.
census org-two-pages '{"public_repos":3,"total_private_repos":0}' \
  "[$(repo_row alpha false main),$(repo_row beta false main)]
[$(repo_row gamma false main)]"

expect_org() { # expect_org <fixture> <want-rc> <want-substring> [<must-not-contain>]
  cases=$((cases + 1))
  log="${tmp}/gh.log"
  : >"${log}"
  probe_in "$1" --org devantler-tech
  if [ "${rc}" = "$2" ] && [[ "${got}" == *"$3"* ]] && { [ -z "${4:-}" ] || [[ "${got}" != *"$4"* ]]; }; then
    pass "org: $1"
  else flunk "org: $1: rc=${rc} (want $2), output: ${got} (want: $3${4:+, without: $4})"; fi
}
expect_org org-complete 0 'RUNG0-ORG devantler-tech repos=3 live=2' 'devantler-tech/old'
cases=$((cases + 1))
if grep -qx 'repos/devantler-tech/beta/commits/trunk' "${log}" && [ "$(grep -c '^RUNG0 ' <<<"${got}")" = 2 ]; then
  pass "org: each live repository is probed on its default branch, archived ones skipped"
else flunk "org default branches: $(tr '\n' ' ' <"${log}") / ${got}"; fi
expect_org org-truncated 2 'UNKNOWN truncated repos fetched=3 total=4' 'RUNG0 '
cases=$((cases + 1))
if ! grep -q '^repos/' "${log}"; then pass "org: an unproven list probes no repository"
else flunk "org: truncated list still probed: $(tr '\n' ' ' <"${log}")"; fi
expect_org org-private-count-hidden 2 'UNKNOWN malformed org-count' 'RUNG0 '
expect_org org-unreadable 2 'UNKNOWN read-failed org' 'RUNG0 '
expect_org org-repos-unreadable 2 'UNKNOWN read-failed repos' 'RUNG0 '
expect_org org-repos-malformed 2 'UNKNOWN malformed repos' 'RUNG0 '
expect_org org-bad-name 2 'UNKNOWN unsupported-name' 'RUNG0 '
expect_org org-one-red 1 "RUNG0 devantler-tech/beta sha=${sha} checks=1 runs=1 BREAKAGE workflow:${rel}=failure"
expect_org org-one-empty 0 'RUNG0 devantler-tech/beta EMPTY'
expect_org org-two-pages 0 'repos=3 live=3'
log=""

# Usage errors are UNKNOWN (exit 2) and never reach the forge.
log="${tmp}/gh.log"
for args in "" "--repo" "--repo someone-else/monorepo" "--repo devantler-tech/.." "--repo devantler-tech/a/b" "--bogus" \
  "--org" "--org someone-else" "--org devantler-tech --repo devantler-tech/a" "--repo devantler-tech/a --org devantler-tech" \
  "--org devantler-tech --org devantler-tech"; do
  cases=$((cases + 1))
  : >"${log}"
  # shellcheck disable=SC2086 # the cases are word lists on purpose
  probe_in green ${args}
  if [ "${rc}" = 2 ] && [ ! -s "${log}" ]; then pass "usage error: '${args}'"
  else flunk "usage error '${args}': rc=${rc}, forge reads: $(wc -l <"${log}")"; fi
done

rm -rf "${tmp}"
if [ "${failures}" -gt 0 ]; then
  echo "main-head-rung0-probe tests: FAIL (${failures} of ${cases})" >&2
  exit 1
fi
echo "main-head-rung0-probe tests: PASS (${cases} cases)"
