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

# The job-level if is an allow-list of two shapes; anything else does not filter the job.
fixture
# shellcheck disable=SC2016
edit '.jobs.test-alpha.if = "needs.changes.outputs.alpha == '"'"'true'"'"' && (github.event_name != '"'"'pull_request'"'"' ||\n github.event.pull_request.head.repo.full_name == github.repository)"'
expect_ok "same-repository clause after the filter"
for condition in \
  "needs.changes.outputs.alpha != 'true'" \
  "needs.changes.outputs.alpha == 'true' || always()" \
  "needs.changes.outputs.alpha == 'true' && (needs.changes.outputs.beta == 'true')" \
  "needs.changes.outputs.alpha == 'true' && (false)" \
  "needs.changes.outputs.alpha == 'true' && (a) || (b)"; do
  fixture
  COND="$condition" edit '.jobs.test-alpha.if = strenv(COND)'
  expect_defect "if shape: $condition" "test-alpha: job-level if is not needs.changes.outputs.<name> == 'true'"
done

# A filter with no rules never matches.
fixture
edit '.jobs.changes.steps[0].with.filters = "alpha: []\nbeta:\n  - '"'"'b/**'"'"'\n"'
expect_defect "empty filter" "filter 'alpha' has no path rules"

# The producer must always run and never suppress a failed filter.
fixture; edit '.jobs.changes.if = "false"'
expect_defect "conditional producer" "changes: has a job-level if"
fixture; edit '.jobs.changes."continue-on-error" = true'
expect_defect "producer continue-on-error" "changes: sets continue-on-error"
fixture; edit '.jobs.changes.steps[0].if = "false"'
expect_defect "conditional filter step" "changes: the filter step has an if"
fixture; edit '.jobs.changes.steps[0]."continue-on-error" = true'
expect_defect "filter step continue-on-error" "changes: the filter step sets continue-on-error"
# An unquoted YAML false is still a condition: `//` would read it as absent.
fixture; edit '.jobs.changes.if = false'
expect_defect "boolean-false producer" "changes: has a job-level if"
fixture; edit '.jobs.changes.steps[0].if = false'
expect_defect "boolean-false filter step" "changes: the filter step has an if"
# Another action sets none of the outputs.
fixture; edit '.jobs.changes.steps[0].uses = "actions/checkout@v4"'
expect_defect "wrong producer action" "changes: the filter step does not run dorny/paths-filter"
# The aggregate step itself must run and fail the job.
fixture; edit '.jobs.status.steps[0].if = false'
expect_defect "skipped aggregate" "status: the aggregate-job-checks step has an if or continue-on-error"
fixture; edit '.jobs.status.steps[0]."continue-on-error" = true'
expect_defect "suppressed aggregate" "status: the aggregate-job-checks step has an if or continue-on-error"

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

# A BLOCKING job that reads no changes output is skipped by its own job-level `if` before any
# filter check applies, and the aggregate accepts `skipped` — so a condition here can silently
# stop a required check from gating merges. Only an allow-listed condition passes.
fixture; edit '.jobs.unfiltered.if = false'
expect_defect "blocking job disabled outright" \
  "unfiltered: job-level if is not an allowed condition for a blocking job that reads no changes output"

# A repository variable can be flipped off without touching the workflow, so it must not decide
# whether a required check runs.
fixture; edit '.jobs.unfiltered.if = "vars.RUN_IT == '"'"'true'"'"'"'
expect_defect "blocking job behind a repo variable" \
  "unfiltered: job-level if is not an allowed condition for a blocking job that reads no changes output"

# `always()` is not an event gate: it reads as a condition that never filters, and it would also
# mask a later real one.
fixture; edit '.jobs.unfiltered.if = "always()"'
expect_defect "blocking job with always()" \
  "unfiltered: job-level if is not an allowed condition for a blocking job that reads no changes output"

# The one allow-listed shape: gating on the triggering event, which no setting can switch off.
fixture; edit '.jobs.unfiltered.if = "github.event_name == '"'"'pull_request'"'"'"'
expect_ok "blocking job gated on the event"
fixture
# shellcheck disable=SC2016
edit '.jobs.unfiltered.if = "${{ github.event_name == '"'"'pull_request'"'"' }}"'
expect_ok "blocking job gated on the event, wrapped"

# A non-blocking job is exempt: its result never reaches the gate, so a condition cannot weaken it.
fixture; edit '.jobs.advisory.if = false'
expect_ok "non-blocking job may carry any condition"

# A reference outside the job-level `if` does not decide when the job runs, so it must not exempt the
# job from the blocking-condition allow-list. Here `if: false` takes a required check out of the gate
# while a step env merely mentions an output — the old whole-job scan read that as "filtered".
fixture
# shellcheck disable=SC2016 # the GitHub expression must reach yq literally, unexpanded.
edit '.jobs.unfiltered.needs = ["changes"] |
  .jobs.unfiltered.if = false |
  .jobs.unfiltered.steps = [{"run": "echo hi", "env": {"A": "${{ needs.changes.outputs.alpha }}"}}]'
expect_defect "step reference does not exempt a switchable blocking job" \
  "unfiltered: job-level if is not an allowed condition for a blocking job"

# A blocking job must not depend on a non-blocking one: if the prerequisite fails the dependent is
# skipped, and the aggregate counts a skip as a pass, so the required check stops running silently.
fixture; edit '.jobs.test-alpha.needs = ["changes", "advisory"]'
expect_defect "blocking job needs a non-blocking one" \
  "test-alpha: needs 'advisory', which is non-blocking"

# The same hole one level up: renaming the changes producer non-blocking drops it from the gate, but
# every filtered job needs it, so the dependency check refuses that spelling too.
fixture; edit '.jobs.changes.name = "Detect changes (non-blocking)"'
expect_defect "changes producer renamed non-blocking" \
  "needs 'changes', which is non-blocking"

# An unfiltered blocking job must not depend on a path-filtered one: if the filter misses, the prerequisite
# skips, this job skips under implicit success(), and the aggregate accepts both skips.
fixture; edit '.jobs.unfiltered.needs = ["test-alpha"]'
expect_defect "unfiltered blocking job needs a path-filtered one" \
  "unfiltered: is unfiltered but needs 'test-alpha', which is path-filtered"

# Two path-filtered blocking jobs must not depend on each other when their filters differ: if the
# prerequisite's filter misses, it skips and forces the dependent to skip even when its own filter matched.
fixture; edit '.jobs.test-alpha.needs = ["changes", "test-beta"]'
expect_defect "differing filters between path-filtered jobs" \
  "test-alpha: needs 'test-beta', but their filter conditions differ"

# Substring matches in job-results (e.g. appended text) must not be counted as wired.
fixture
# shellcheck disable=SC2016 # the GitHub expression must reach yq literally, unexpanded.
edit '.jobs.status.steps[0].with."job-results" |= sub("\$\{\{ needs.test-alpha.result \}\}", "${{ needs.test-alpha.result }}-ignored")'
expect_defect "tampered result token" \
  "test-alpha: missing from status job-results"

# predicate-quantifier != some causes multi-path filters to require every rule to match.
fixture; edit '.jobs.changes.steps[0].with.predicate-quantifier = "every"'
expect_defect "predicate-quantifier every" \
  "changes: the filter step sets predicate-quantifier != some"

# No condition at all stays the normal case.
fixture; expect_ok "blocking job with no condition"

# A fatal abort must never be reported as a clean pass. Under bash 3.2 a successful `rm` in an EXIT
# trap replaces the failing status with 0, so the checker printed nothing and exited 0 — a guard
# silently passing is worse than one that errors. Inject a fatal error and assert the status survives.
fixture
# The fatal error goes AFTER the trap line: the point is that the cleanup is already installed when
# the abort happens, which is the only arrangement that can mask the status.
awk '{print} /^trap /&&!d{print ": \"${ci_job_wiring_deliberately_unset:?fatal}\""; d=1}' \
  "$checker" >"$tmp/aborting.sh"
awk '/^trap /{t=NR} /ci_job_wiring_deliberately_unset/{i=NR} END{exit !(t && i && i==t+1)}' "$tmp/aborting.sh" ||
  fail "abort fixture did not inject the fatal error directly after the trap"
set +e; bash "$tmp/aborting.sh" "$tmp/ci.yaml" >"$tmp/out" 2>&1; abort_rc=$?; set -e
[[ $abort_rc -ne 0 ]] || { cat "$tmp/out" >&2; fail "a fatal abort exited 0, so the cleanup trap masked it"; }
grep -qF "ci-job-wiring: OK" "$tmp/out" && fail "an aborting run printed the OK line"

# Positive control: the real workflow is wired.
"$checker" "$root/.github/workflows/ci.yaml" >/dev/null || fail "the real ci.yaml has wiring defects"

echo "ci-job-wiring: OK"
