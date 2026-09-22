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
#      unpinned merge can never be the documented form.

# shellcheck disable=SC2016 # backticks are literal Markdown in the patterns, not substitutions
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${AGENTS_FILE:-${repo_root}/AGENTS.md}"

fail() {
  echo "merge-api fall-through contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

merge_policy="$(awk '
  /^### Merge policy/ { inside = 1; print; next }
  inside && /^### /   { exit }
  inside              { print }
' "${constitution}")"
[ -n "${merge_policy}" ] || fail "no '### Merge policy' section in ${constitution}"

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

# 5. Negative control across every definition surface: each prescribed PUT merge is pinned.
surfaces=("${constitution}")
while IFS= read -r f; do surfaces+=("${f}"); done < <(
  find "${repo_root}/.claude/agents" "${repo_root}/.claude/skills" -name '*.md' -type f 2>/dev/null | sort
)
unpinned=""
for f in "${surfaces[@]}"; do
  hits="$(grep -nE 'method[= ]PUT[^`]*pulls/[^ `]*/merge' "${f}" | grep -v 'sha=' || true)"
  [ -z "${hits}" ] || unpinned+="${f#"${repo_root}"/}: ${hits}"$'\n'
done
[ -z "${unpinned}" ] || fail "a PUT …/merge is prescribed without its sha= head pin:"$'\n'"${unpinned}"

echo "merge-api fall-through contract: all assertions passed"
