#!/usr/bin/env bash
# shellcheck disable=SC2016
# Contract prose uses literal backticks, never shell substitutions.
#
# Guards the PR sweep's enumeration rule in .claude/guides/pr-readiness.md (monorepo#4242).
#
# Why this needs a guard. No definition said how to list the PRs the every-run sweep checks, so runs
# wrote one org-wide GraphQL search that also asked for merge and check state. GitHub often answers
# that query with an HTML error page: 15 of 31 such calls failed between 2026-10-13 and 2026-10-16,
# while 49 identity-only searches failed 0 times. The guide now says to list with identity fields
# only and read merge and check state per PR. This test keeps that rule inside the sweep paragraph,
# where the run reads it, and keeps both halves of it.
#
# The checks run on a whitespace-flattened copy of the sweep paragraph only, so a line rewrap cannot
# break them and a matching phrase elsewhere in the guide cannot satisfy them. A negative control
# runs the same checks on the paragraph with the rule removed and requires them to fail.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guide="${repo_root}/.claude/guides/pr-readiness.md"
passed=0

fail() {
  echo "pr-sweep-enumeration contract: FAIL — $*" >&2
  exit 1
}

[ -r "${guide}" ] || fail "cannot read ${guide}"

start_anchor='**Beyond the live watcher, EVERY run sweep ALL actionable PRs'
end_anchor='**Review-BODY findings count toward (b)'
rule='**List the sweep'"'"'s PRs with identity fields only, then read each PR'"'"'s state on its own.**'

# Print the sweep paragraph, flattened. Both anchors must be seen, or the check fails closed.
sweep_section() {
  awk -v a="${start_anchor}" -v b="${end_anchor}" '
    index($0, a) { ins = 1; seen_a = 1 }
    ins && index($0, b) { ins = 0; seen_b = 1 }
    ins { print }
    END { if (!seen_a || !seen_b) exit 3 }
  ' "$1" | tr '\n' ' ' | tr -s ' '
}

# Every check reads the flattened paragraph on stdin and prints the first missing item, if any.
missing_item() {
  local text
  text="$(cat)"
  local item
  for item in \
    "${rule}" \
    'that also asks for `mergeStateStatus`, `statusCheckRollup` or `mergeable`' \
    'HTML error page' \
    'monorepo#4242' \
    'then read merge and check state per PR with `gh pr view <n> --repo devantler-tech/<repo> --json …`' \
    'A smaller page size does not fix it.'; do
    case "${text}" in
      *"${item}"*) ;;
      *) printf '%s\n' "${item}"; return 0 ;;
    esac
  done
}

section="$(sweep_section "${guide}")" || fail "sweep paragraph anchors not found in ${guide}"
[ -n "${section}" ] || fail "sweep paragraph is empty"

absent="$(printf '%s' "${section}" | missing_item)"
[ -z "${absent}" ] || fail "sweep paragraph lacks: ${absent}"
passed=$((passed + 1))

# Negative control: drop the rule from the paragraph; the check must now report it missing.
mutant="${section/"${rule}"/}"
[ "${mutant}" != "${section}" ] || fail "negative control could not remove the rule"
absent="$(printf '%s' "${mutant}" | missing_item)"
[ "${absent}" = "${rule}" ] || fail "negative control did not fire (got: '${absent}')"
passed=$((passed + 1))

# Negative control: a paragraph that keeps the rule but drops the per-PR read must also fail.
per_pr='then read merge and check state per PR with `gh pr view <n> --repo devantler-tech/<repo> --json …`'
mutant="${section/"${per_pr}"/}"
[ "${mutant}" != "${section}" ] || fail "negative control could not remove the per-PR read"
absent="$(printf '%s' "${mutant}" | missing_item)"
[ "${absent}" = "${per_pr}" ] || fail "per-PR negative control did not fire (got: '${absent}')"
passed=$((passed + 1))

echo "pr-sweep-enumeration contract: ${passed} checks passed"
