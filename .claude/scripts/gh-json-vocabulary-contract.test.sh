#!/usr/bin/env bash
# shellcheck disable=SC2016 # Backticks and GitHub markers below are literal contract text.
#
# Guards the rule for discovering `gh --json` fields before an agent improvises a query.
# GitHub CLI field vocabularies are per-subcommand; borrowing a plausible field from another
# surface makes the whole read fail, not merely that field.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${AGENTS_FILE:-${repo_root}/AGENTS.md}"
workflow="${repo_root}/.github/workflows/ci.yaml"

fail() {
  echo "gh json vocabulary: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"
command -v gh >/dev/null 2>&1 || fail "gh is required to exercise the local vocabulary boundary"

merge_policy="$(awk '
  /^### Merge policy/ { inside = 1; print; next }
  inside && /^### /   { exit }
  inside              { print }
' "${constitution}")"
[ "$(printf '%s' "${merge_policy}" | wc -c)" -gt 500 ] ||
  fail "could not locate the Merge policy section; the prose assertions would be vacuous"
merge_policy_flat="$(printf '%s' "${merge_policy}" | tr '\n' ' ' | tr -s '[:space:]' ' ')"

assert_prose() {
  case "${merge_policy_flat}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}

assert_prose 'Before an ad hoc `gh <subcommand> --json <fields>` read' \
  "Merge policy does not gate an unreviewed gh --json field list"
assert_prose 'the same subcommand with bare `--json`' \
  "Merge policy does not require discovery against the exact subcommand"
assert_prose 'Never transfer a field list between subcommands' \
  "Merge policy permits cross-subcommand field reuse"
assert_prose 'one unknown field voids the whole read' \
  "Merge policy does not preserve the all-or-nothing failure boundary"
assert_prose 'Reuse an exact command that already succeeded in this run' \
  "Merge policy does not bound repeat discovery overhead"

# `gh <surface> --json` intentionally exits non-zero after printing that surface's available fields.
# Exercise the installed CLI rather than freezing a hand-written allowlist in this test.
vocabulary_for() {
  local output status
  status=0
  output="$(gh "$@" --json 2>&1)" || status=$?
  [ "${status}" -ne 0 ] || fail "gh $* --json unexpectedly succeeded; discovery semantics changed"
  printf '%s\n' "${output}" | awk '/^  [A-Za-z][A-Za-z0-9]*$/ { sub(/^  /, ""); print }'
}

contains_field() {
  local vocabulary="$1" field="$2"
  printf '%s\n' "${vocabulary}" | grep -Fqx -- "${field}"
}

assert_unknown_field() {
  local field="$1" output status
  shift
  status=0
  output="$(gh "$@" --json "${field}" 2>&1)" || status=$?
  [ "${status}" -ne 0 ] || fail "gh $* unexpectedly accepted ${field}"
  case "${output}" in
    *'Unknown JSON field:'*"${field}"*) ;;
    *) fail "gh $* rejected ${field} without the expected unknown-field boundary" ;;
  esac
}

pr_view_fields="$(vocabulary_for pr view)"
run_list_fields="$(vocabulary_for run list)"
search_prs_fields="$(vocabulary_for search prs)"

[ "$(printf '%s\n' "${pr_view_fields}" | grep -c .)" -gt 20 ] ||
  fail "pr view discovery returned an implausibly small vocabulary"
[ "$(printf '%s\n' "${run_list_fields}" | grep -c .)" -gt 10 ] ||
  fail "run list discovery returned an implausibly small vocabulary"
[ "$(printf '%s\n' "${search_prs_fields}" | grep -c .)" -gt 10 ] ||
  fail "search prs discovery returned an implausibly small vocabulary"

# Positive controls prove extraction works. Negative/cross-surface controls reproduce the defect
# class from issue #3049: plausible fields accepted on one surface are rejected on another.
contains_field "${pr_view_fields}" state || fail "pr view vocabulary omitted known field state"
contains_field "${run_list_fields}" workflowName || fail "run list vocabulary omitted workflowName"
contains_field "${search_prs_fields}" state || fail "search prs vocabulary omitted known field state"
contains_field "${pr_view_fields}" mergedAt || fail "pr view vocabulary omitted mergedAt"
contains_field "${run_list_fields}" path && fail "run list unexpectedly accepts path; update the measured contract"
contains_field "${search_prs_fields}" mergedAt &&
  fail "search prs unexpectedly accepts pr-view-only mergedAt; update the measured contract"
assert_unknown_field path run list
assert_unknown_field mergedAt search prs

# Self-gate the five pieces required for a path-filtered test to affect the required aggregate job.
[ -r "${workflow}" ] || fail "ci.yaml is missing; this guard's wiring cannot be verified"
for wiring in \
  '      gh-json-vocabulary-contract: ${{ steps.filter.outputs.gh-json-vocabulary-contract }}|changes output' \
  '            gh-json-vocabulary-contract:|paths-filter entry' \
  '  test-gh-json-vocabulary-contract:|job definition' \
  '      - test-gh-json-vocabulary-contract|status dependency' \
  '            ${{ needs.test-gh-json-vocabulary-contract.result }}|aggregate result'; do
  needle="${wiring%%|*}"
  what="${wiring#*|}"
  grep -Fqx -- "${needle}" "${workflow}" || fail "ci.yaml is missing ${what}"
done

# Scope path assertions to THIS filter. AGENTS.md and ci.yaml occur in many sibling filters, so a
# workflow-wide grep would stay green if either trigger disappeared from this one.
filter_block="$(awk '
  /^            gh-json-vocabulary-contract:/ { inside = 1; print; next }
  inside && /^            [a-z0-9-]+:/       { exit }
  inside                                        { print }
' "${workflow}")"
[ "$(printf '%s' "${filter_block}" | wc -c)" -gt 100 ] ||
  fail "could not isolate the gh-json-vocabulary-contract paths filter"
for trigger in \
  "              - 'AGENTS.md'" \
  "              - '.claude/scripts/gh-json-vocabulary-contract.test.sh'" \
  "              - '.github/workflows/ci.yaml'"; do
  printf '%s\n' "${filter_block}" | grep -Fqx -- "${trigger}" ||
    fail "ci.yaml filter is missing ${trigger# *}"
done

echo "gh json vocabulary: OK — exact-subcommand discovery guarded against three live gh vocabularies"
