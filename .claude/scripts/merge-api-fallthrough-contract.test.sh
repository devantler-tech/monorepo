#!/usr/bin/env bash
#
# Guards the merge fall-through in Merge policy (monorepo#2710).
#
# Exception (a) tells a run to let the merge API decide when `mergeStateStatus` is stale, but the
# prescribed command, `gh pr merge`, checks `mergeStateStatus` itself and refuses before calling the
# endpoint. Measured on .github#138 (2026-08-06): two ticks parked on "the base branch policy
# prohibits the merge" while `PUT …/merge` merged the same head at the first attempt.
#
# Guarded properties, all scoped to the Merge policy section so a phrase surviving elsewhere does
# not count:
#   1. the mechanism is named: `gh pr merge` is not the merge API;
#   2. the fall-through command is prescribed, and it carries the head pin (`sha=`);
#   3. the generic refusal text is called out as naming no rule;
#   4. the fall-through is bounded: pentad-clear only, and never on a merge-queue repository;
#   5. NEGATIVE CONTROL: no definition surface prescribes a `PUT …/merge` without `sha=`, so an
#      unpinned merge can never be the documented form;
#   6. a PR in a GitHub-native stack merges through the asynchronous endpoint, head-pinned, with
#      its result read and every PR below it held to the same gates (monorepo#3587).

# shellcheck disable=SC2016 # backticks are literal Markdown in the patterns, not substitutions
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${AGENTS_FILE:-${repo_root}/.claude/guides/merge-policy.md}"

fail() {
  echo "merge-api fall-through contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

merge_policy="$(awk '
  /^## Merge policy/ { inside = 1; print; next }
  inside && /^## /    { exit }
  inside              { print }
' "${constitution}")"
[ -n "${merge_policy}" ] || fail "no '## Merge policy' section in ${constitution}"

has() { grep -Fq -- "$1" <<<"${merge_policy}"; }

# 1. The mechanism.
has '`gh pr merge` is NOT the merge API' ||
  fail "Merge policy must state that gh pr merge is not the merge API (it pre-checks mergeStateStatus)"

# 2. The prescribed fall-through, with its head pin.
fallthrough='gh api --method PUT repos/devantler-tech/<repo>/pulls/<n>/merge -f merge_method=squash -f sha=<headRefOid>'
has "${fallthrough}" || fail "Merge policy must prescribe the pinned fall-through: ${fallthrough}"

# 3. The refusal text is not a cause.
has 'That refusal text names no rule' ||
  fail "Merge policy must say the generic refusal text names no rule"

# 4. The bound.
has 'bounded to' || fail "Merge policy must bound the fall-through to the pentad-clear case"
has 'never on a merge-queue repository' ||
  fail "Merge policy must exclude merge-queue repositories from the fall-through"

# 6. A stacked PR's merge path (monorepo#3587): the async endpoint with its head pin, a result read
#    that is not the request's 202, and the whole-stack precondition.
has 'Merging stacked PRs via this endpoint is not supported' ||
  fail "Merge policy must quote the synchronous endpoint's stacked-PR refusal so it is recognised"
stacked='gh api --method PUT repos/devantler-tech/<repo>/pulls/<n>/merge-async -f merge_method=squash -f merge_action=default -f sha=<headRefOid>'
has "${stacked}" || fail "Merge policy must prescribe the pinned stacked-PR merge: ${stacked}"
has 'gh api repos/devantler-tech/<repo>/pulls/<n>/merge-async/<id>' ||
  fail "Merge policy must prescribe the read of the asynchronous merge's result"
has 'is an accepted request, never a merge' ||
  fail "Merge policy must say the 202 is not a merge, so the result and state are still read"
has 'result is a request still running, never a refusal' ||
  fail "Merge policy must keep a pending asynchronous merge distinct from a failed one"
has 'every PR below the one being merged must meet the same gates' ||
  fail "Merge policy must require the gates on every PR below the one merged in a stack"
has 'a stack you cannot enumerate completely is UNKNOWN' ||
  fail "Merge policy must fail closed when the stack cannot be enumerated"

# 5. Negative control across every definition surface: each prescribed PUT merge is pinned.
# An unreadable root would make this sweep read clean over it, so each root must exist and yield
# at least one file — an empty sweep is a claim about the enumeration, never a clean result.
surfaces=("${repo_root}/AGENTS.md")
for root in "${repo_root}/.claude/guides" "${repo_root}/.claude/agents" "${repo_root}/.claude/skills"; do
  [ -d "${root}" ] ||
    fail "definition surface is missing, so the sweep below would read clean over it: ${root#"${repo_root}"/}"
  found=0
  while IFS= read -r f; do
    surfaces+=("${f}")
    found=$((found + 1))
  done < <(find "${root}" -name '*.md' -type f | sort)
  [ "${found}" -gt 0 ] ||
    fail "definition surface yielded no Markdown file, so the sweep below would read clean over it: ${root#"${repo_root}"/}"
done
unpinned=""
for f in "${surfaces[@]}"; do
  hits="$(grep -nE 'method[= ]PUT[^`]*pulls/[^ `]*/merge' "${f}" | grep -v 'sha=' || true)"
  [ -z "${hits}" ] || unpinned+="${f#"${repo_root}"/}: ${hits}"$'\n'
done
[ -z "${unpinned}" ] || fail "a PUT …/merge is prescribed without its sha= head pin:"$'\n'"${unpinned}"

echo "merge-api fall-through contract: all assertions passed"
