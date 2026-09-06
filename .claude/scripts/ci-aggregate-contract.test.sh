#!/usr/bin/env bash
# Exercise the exact trusted, inline checker against candidate workflow data.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$root/.github/workflows/ci-aggregate-contract.yaml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "ci-aggregate-contract test: $*" >&2; exit 1; }

[[ -f "$workflow" ]] || fail "independent aggregate workflow is missing"
yq -r '.jobs.validate.steps[] | select(.name == "Require the aggregate to always run") | .run' "$workflow" >"$tmp/check.sh"
[[ -s "$tmp/check.sh" ]] || fail "inline checker is missing"

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
[[ "$(yq -r '[.jobs.validate.steps[] | select(has("uses"))] | length' "$workflow")" == 0 ]] ||
  fail "the control must not check out or execute candidate actions"
echo "ci-aggregate-contract: OK"
