#!/usr/bin/env bash
# Exercise the repository-owned admission action against candidate workflow data.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$root/.github/workflows/ci-aggregate-contract.yaml"
action="$root/.github/actions/pr-admission/action.yaml"
tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$tmp"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then
    echo "ci-aggregate-contract.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    exit 1
  fi
}
trap on_exit EXIT
fail() {
  echo "ci-aggregate-contract test: $*" >&2
  exit 1
}

[[ -f "$workflow" ]] || fail "independent aggregate workflow is missing"
[[ -f "$action" ]] || fail "repository-owned admission action is missing"
yq -r '.runs.steps[] | select(.name == "Require the aggregate to always run") | .run' "$action" >"$tmp/check.sh"
[[ -s "$tmp/check.sh" ]] || fail "admission checker is missing"

check() { CI_WORKFLOW="$tmp/ci.yaml" bash "$tmp/check.sh" >"$tmp/output" 2>&1; }
expect_success() { check || fail "expected success: $1"; }
expect_failure() { if check; then fail "expected rejection: $1"; fi; }

cat >"$tmp/ci.yaml" <<'YAML'
on:
  pull_request:
  merge_group:
jobs:
  changes:
    runs-on: ubuntu-latest
  filtered:
    needs: changes
    if: needs.changes.outputs.docs == 'true'
    runs-on: ubuntu-latest
  status:
    if: always()
    needs: [changes, filtered]
    runs-on: ubuntu-latest
YAML
expect_success "ordinary path-filtered jobs may skip"
# GitHub expression syntax is literal candidate data.
# shellcheck disable=SC2016
yq -i '.jobs.status.if = "${{ always() }}"' "$tmp/ci.yaml"
expect_success "explicit expression delimiters"

for condition in 'false' 'true' 'success()' 'always() && false' ''; do
  CONDITION="$condition" yq -i '.jobs.status.if = strenv(CONDITION)' "$tmp/ci.yaml"
  expect_failure "aggregate condition $condition"
done
yq -i '.jobs.status.if = false' "$tmp/ci.yaml"
expect_failure "boolean false"
yq -i 'del(.jobs.status.if)' "$tmp/ci.yaml"
expect_failure "implicit success condition"
yq -i 'del(.jobs.status)' "$tmp/ci.yaml"
expect_failure "missing aggregate"
printf 'jobs: [unterminated\n' >"$tmp/ci.yaml"
expect_failure "malformed candidate YAML"

# Wiring is independent of the status aggregate and reads the candidate as data.
[[ "$(yq -r '(.on | has("pull_request")) and (.on | has("merge_group"))' "$workflow")" == true ]] ||
  fail "PR and merge-group triggers are required"
[[ "$(yq -r '(.jobs.validate | has("needs")) or (.jobs.validate | has("if"))' "$workflow")" == false ]] ||
  fail "the independent job must not depend on or condition itself on other jobs"
[[ "$(yq -r '(.on.pull_request // {} | keys | length)' "$workflow")" == 0 ]] ||
  fail "the control must not be path- or branch-filtered"
[[ "$(yq -r '.jobs.validate.permissions.contents' "$workflow")" == read ]] ||
  fail "candidate access must be read-only"
yq -o=json '.' "$workflow" | jq -e '
  [.jobs.validate.steps[] | select(.uses != null)] as $actions |
  ($actions | length) == 2 and
  ($actions[0].uses | test("^actions/checkout@[0-9a-f]{40}$")) and
  $actions[0].with == {
    "repository":"${{ github.repository }}",
    "ref":"${{ github.workflow_sha }}",
    "path":"trusted",
    "persist-credentials":false
  } and
  $actions[1].uses == "./trusted/.github/actions/pr-admission" and
  $actions[1].with == {"candidate-sha":"${{ github.sha }}"} and
  all($actions[]; .if == null and (.["continue-on-error"] // false) == false)
' >/dev/null || fail "only the reviewed source may supply the admission action"
yq -o=json '.' "$action" | jq -e '
  .runs.using == "composite" and
  (.runs.steps | length) == 2 and
  all(.runs.steps[]; .uses == null and .shell == "bash" and .if == null and (.["continue-on-error"] // false) == false) and
  .runs.steps[0].env == {
    "GH_TOKEN":"${{ github.token }}",
    "CANDIDATE_REPOSITORY":"${{ github.repository }}",
    "CANDIDATE_SHA":"${{ inputs.candidate-sha }}"
  } and
  .runs.steps[1].env == {"CI_WORKFLOW":"${{ runner.temp }}/candidate-ci.yaml"} and
  .inputs["candidate-sha"].required == true
' >/dev/null || fail "candidate collection must remain an API-only data read before the actual checker"
jq -e '. == {version:1,"timeout-minutes":10}' "$root/.github/pr-admission.json" >/dev/null ||
  fail "shared admission must retain a bounded product-owned execution budget"
completed=1
echo "ci-aggregate-contract: OK"
