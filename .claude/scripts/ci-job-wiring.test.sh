#!/usr/bin/env bash
# RED/GREEN coverage for ci-job-wiring.sh: one ablation per wiring point, each asserting the
# specific defect it must report, plus the real workflow as a positive control.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$root/.claude/scripts/ci-job-wiring.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "ci-job-wiring test: $*" >&2; exit 1; }

fixture() {
  cat >"$tmp/ci.yaml" <<'YAML'
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      alpha: ${{ steps.filter.outputs.alpha }}
      beta: ${{ steps.filter.outputs.beta }}
    steps:
      - id: filter
        uses: dorny/paths-filter@v3
        with:
          filters: |
            alpha:
              - 'a/**'
            beta:
              - 'b/**'
  test-alpha:
    needs: changes
    if: needs.changes.outputs.alpha == 'true'
    runs-on: ubuntu-latest
  test-beta:
    needs: [changes]
    if: ${{ needs.changes.outputs.beta == 'true' }}
    runs-on: ubuntu-latest
  unfiltered:
    runs-on: ubuntu-latest
  advisory:
    name: Advisory report (non-blocking)
    runs-on: ubuntu-latest
  status:
    if: always()
    needs: [changes, test-alpha, test-beta, unfiltered]
    runs-on: ubuntu-latest
    steps:
      - uses: devantler-tech/actions/aggregate-job-checks@v1
        with:
          job-results: >-
            ${{ needs.changes.result }} ${{ needs.test-alpha.result }} ${{ needs.test-beta.result }} ${{ needs.unfiltered.result }}
YAML
}

run() { set +e; "$checker" "$tmp/ci.yaml" >"$tmp/out" 2>&1; rc=$?; set -e; }
expect_ok() {
  run
  [[ $rc -eq 0 ]] || { cat "$tmp/out" >&2; fail "expected OK: $1 (rc=$rc)"; }
}
expect_defect() { # <label> <expected message fragment> [<expected rc>]
  run
  [[ $rc -eq ${3:-1} ]] || { cat "$tmp/out" >&2; fail "expected rc ${3:-1}: $1 (rc=$rc)"; }
  grep -qF -- "$2" "$tmp/out" || { cat "$tmp/out" >&2; fail "wrong reason for: $1 (wanted '$2')"; }
}
edit() { yq -i "$1" "$tmp/ci.yaml"; }

fixture; expect_ok "fully wired fixture"

# (1) paths-filter entry missing: the output points at a filter that no longer exists.
fixture
edit '.jobs.changes.steps[0].with.filters = "alpha:\n  - '"'"'a/**'"'"'\n"'
expect_defect "missing filter" "changes output 'beta' has no paths-filter entry"

# (2) changes output missing: the job's if reads an empty string and skips forever.
fixture; edit 'del(.jobs.changes.outputs.beta)'
expect_defect "missing output" "test-beta: reads needs.changes.outputs.beta, which the changes job does not declare"
grep -qF "filter 'beta' has no changes output" "$tmp/out" || fail "missing output: dead filter not reported"

# Output wired to the wrong filter step output. GitHub expression syntax is literal candidate data.
fixture
# shellcheck disable=SC2016
edit '.jobs.changes.outputs.beta = "${{ steps.filter.outputs.alpha }}"'
expect_defect "mis-pointed output" "changes output 'beta' is"

# (3) job reads changes outputs without needing changes.
fixture; edit '.jobs.test-alpha.needs = []'
expect_defect "needs without changes" "test-alpha: reads needs.changes.outputs but does not list 'changes' in needs"

# Output no job reads.
fixture; edit 'del(.jobs.test-beta) | .jobs.status.needs -= ["test-beta"]'
edit '.jobs.status.steps[0].with."job-results" |= sub(" \$\{\{ needs.test-beta.result \}\}"; "")'
expect_defect "unread output" "changes output 'beta' filters no job"

# A reference outside the job-level if (here a step env) does not filter the job.
fixture
# shellcheck disable=SC2016
edit '.jobs.test-beta.if = "always()" | .jobs.test-beta.steps = [{"run": "true", "env": {"B": "${{ needs.changes.outputs.beta }}"}}]'
expect_defect "step-only reference" "changes output 'beta' filters no job"


# An output named only inside a string literal is constant text, not a filter.
fixture
edit '.jobs.test-beta.if = "'"'"'needs.changes.outputs.beta'"'"' == '"'"'true'"'"'"'
expect_defect "quoted-literal reference" "changes output 'beta' filters no job"

# (4) missing from status.needs.
fixture; edit '.jobs.status.needs -= ["unfiltered"]'
expect_defect "missing status need" "unfiltered: missing from status.needs"
grep -qF "status job-results reads 'unfiltered', which status does not need" "$tmp/out" ||
  fail "missing status need: stale job-result not reported"

# (5) missing from job-results.
fixture
edit '.jobs.status.steps[0].with."job-results" |= sub(" \$\{\{ needs.test-alpha.result \}\}"; "")'
expect_defect "missing job-result" "test-alpha: missing from status job-results"

# An unevaluated reference is passed to the aggregate as literal text, so it does not count.
# shellcheck disable=SC2016
for literal in 'needs.test-alpha.result' '$ {{ needs.test-alpha.result }}'; do
  fixture
  LIT="$literal" edit '.jobs.status.steps[0].with."job-results" |= sub("\$\{\{ needs.test-alpha.result \}\}"; strenv(LIT))'
  expect_defect "unevaluated job-result ($literal)" "test-alpha: missing from status job-results"
done

# A transformed expression can hand the aggregate "success" for a failed job.
fixture
# shellcheck disable=SC2016
edit '.jobs.status.steps[0].with."job-results" |= sub("\$\{\{ needs.test-alpha.result \}\}"; "${{ needs.test-alpha.result == '"'"'failure'"'"' && '"'"'success'"'"' || needs.test-alpha.result }}")'
expect_defect "masked job-result" "test-alpha: missing from status job-results"

# A job that may fail without failing the workflow does not gate the merge, nor does such a status.
fixture; edit '.jobs.test-alpha."continue-on-error" = true'
expect_defect "continue-on-error job" "test-alpha: sets continue-on-error"
fixture; edit '.jobs.status."continue-on-error" = true'
expect_defect "continue-on-error status" "status: sets continue-on-error"

# Index syntax is equivalent in GitHub expressions, so it must be refused, not skipped: here the
# job drops `changes` from needs and nothing else would notice.
fixture
edit '.jobs.test-alpha.needs = [] | .jobs.test-alpha.if = "needs['"'"'changes'"'"']['"'"'outputs'"'"']['"'"'alpha'"'"'] == '"'"'true'"'"'"'
expect_defect "index syntax" "test-alpha: reads needs with index syntax"

# The index can also follow a dotted chain, which neither the dot-only extraction nor a guard
# anchored at needs/needs.changes sees.
fixture
edit '.jobs.test-alpha.needs = [] | .jobs.test-alpha.if = "needs.changes.outputs['"'"'alpha'"'"'] == '"'"'true'"'"'"'
expect_defect "mixed index syntax" "test-alpha: reads needs with index syntax"

# job-results is read only from the aggregate step: a decoy step listing the job does not count.
fixture
edit '.jobs.status.steps[0].with."job-results" |= sub(" \$\{\{ needs.test-alpha.result \}\}"; "")'
# shellcheck disable=SC2016
edit '.jobs.status.steps += [{"name": "decoy", "run": "true", "with": {"job-results": "${{ needs.test-alpha.result }}"}}]'
expect_defect "decoy job-results" "test-alpha: missing from status job-results"

fixture; edit '.jobs.status.steps[0].uses = "example/other@v1"'
expect_defect "no aggregate step" "expected exactly one aggregate-job-checks step, found 0"
fixture; edit '.jobs.status.steps += [.jobs.status.steps[0]]'
expect_defect "two aggregate steps" "expected exactly one aggregate-job-checks step, found 2"

# status names a job that does not exist.
fixture; edit '.jobs.status.needs += ["ghost"]'
expect_defect "ghost need" "status.needs names 'ghost', which is not a job"

# The non-blocking exemption is by name suffix only: drop the suffix and the gap is reported.
fixture; edit '.jobs.advisory.name = "Advisory report"'
expect_defect "exemption removed" "advisory: missing from status.needs"

# Unreadable or malformed input is UNKNOWN (2), never a clean result.
printf 'jobs: [unterminated\n' >"$tmp/ci.yaml"
expect_defect "malformed yaml" "ci-job-wiring:" 2
rm -f "$tmp/ci.yaml"
expect_defect "missing file" "cannot read" 2
fixture; edit 'del(.jobs.status)'
expect_defect "no status job" "has no status job" 2

# Positive control: the real workflow is wired.
"$checker" "$root/.github/workflows/ci.yaml" >/dev/null || fail "the real ci.yaml has wiring defects"

echo "ci-job-wiring: OK"
