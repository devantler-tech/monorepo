#!/usr/bin/env bash
#
# Guards Claim protocol rule 6: fixing review findings on an existing PR is reserved with
# `agent-claim/<pr-number>` (monorepo#2999).
#
# Retiring the issue claim when the draft opens left a later review's findings with no reservation,
# so two lanes built the same fix twice in one hour on 2026-08-22 (platform#3313, #3314). The rule
# closes that with a cheap commit read, a PR-number claim on the existing helper, renew-before-push,
# retire-after-push, and a takeover gate that replaces "no open PR" (always false for a PR) with "no
# commit newer than the tip".
#
#   1. each load-bearing element of the rule is present in the claim-protocol guide;
#   2. ABLATIONS: the same check must fail against a copy of the guide with rule 6 removed, and
#      against one that keeps rule 6 but drops only its takeover gate, so a partial rule is caught
#      too.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guide="${CLAIM_GUIDE:-${repo_root}/.claude/guides/claim-protocol.md}"

fail() {
  echo "claim PR-findings contract: FAIL — $*" >&2
  exit 1
}

[ -r "${guide}" ] || fail "cannot read ${guide}"

# Rule 6 runs from its numbered item to the next paragraph that is not part of the list.
rule_of() {
  awk '
    /^6\. \*\*Fixing findings on an existing PR is claimed too/ { inside = 1 }
    inside && /^\*\*A live claim is a temporary skip/ { exit }
    inside { print }
  ' "$1"
}

# Prints the first missing element and exits 1; exits 0 when every element is present.
check() {
  local rule="$1" needle
  [ -n "${rule}" ] || { echo "rule 6 is missing"; return 1; }
  for needle in \
    'agent-claim/<pr-number>' \
    'pulls/<n>/commits' \
    'agent-claim.sh acquire <pr-number> --repo-dir <product-path>' \
    'share one number sequence per repository' \
    'stand down under rule 5' \
    'never to skip the PR'"'"'s other rung-1 duties' \
    'Renew immediately before you push the fix' \
    'Retire the acquired SHA once the fix is pushed' \
    'agent-claim-sweep.sh' \
    'no commit on' \
    'newer than the tip'"'"'s committer date'; do
    grep -Fq -- "${needle}" <<<"${rule}" || { echo "missing: ${needle}"; return 1; }
  done
}

# 1. The rule is present and complete.
rule="$(rule_of "${guide}")"
if ! missing="$(check "${rule}")"; then
  fail "${missing}"
fi

# 2. Ablation: drop rule 6 from a copy of the guide; the same check must now fail.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
awk '
  /^6\. \*\*Fixing findings on an existing PR is claimed too/ { skip = 1 }
  skip && /^\*\*A live claim is a temporary skip/ { skip = 0 }
  !skip { print }
' "${guide}" >"${tmp}/ablated.md"
cmp -s "${guide}" "${tmp}/ablated.md" && fail "ablation removed nothing"
if check "$(rule_of "${tmp}/ablated.md")" >/dev/null; then
  fail "ablation did not fire: the check passed with rule 6 removed"
fi

# 3. Ablation: keep rule 6 but drop its takeover gate line.
grep -v "newer than the tip's committer date" "${guide}" >"${tmp}/no-gate.md" || true
cmp -s "${guide}" "${tmp}/no-gate.md" && fail "takeover ablation removed nothing"
if check "$(rule_of "${tmp}/no-gate.md")" >/dev/null; then
  fail "takeover ablation did not fire: the check passed without the commit gate"
fi

echo "claim PR-findings contract: OK"
