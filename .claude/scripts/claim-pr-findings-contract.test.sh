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
#   2. ABLATIONS: the same check must fail, for the stated reason, against a copy of the guide with
#      rule 6 removed, one without the paragraph that ends it, and
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

# Rule 6 runs from its numbered item to the next paragraph that is not part of the list. Exits 1
# when either end is missing, so an unterminated section can never pull in text after it.
rule_of() {
  awk '
    /^6\. \*\*Fixing findings on an existing PR is claimed too/ { inside = 1 }
    inside && /^\*\*A live claim is a temporary skip/ { ended = 1; exit }
    inside { print }
    END { if (!inside || !ended) exit 1 }
  ' "$1"
}

# Prints the first missing element and exits 1; exits 0 when every element is present.
check() {
  local rule="$1" needle
  [ -n "${rule}" ] || { echo "rule 6 is missing"; return 1; }
  for needle in \
    'agent-claim/<pr-number>' \
    'pulls/<n>/commits' \
    'Record the head SHA you validated' \
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

# Runs check against a guide file; an unterminated or absent rule 6 reads as missing.
check_file() {
  local rule
  rule="$(rule_of "$1")" || rule=""
  check "${rule}"
}

# 1. The rule is present, terminated and complete.
rule_of "${guide}" >/dev/null || fail "rule 6 section is missing or unterminated"
if ! missing="$(check_file "${guide}")"; then
  fail "${missing}"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# expect_ablation <name> <file> <want> — the check must fail on <file>, with exactly <want>.
expect_ablation() {
  local got
  cmp -s "${guide}" "$2" && fail "$1 ablation removed nothing"
  if got="$(check_file "$2")"; then
    fail "$1 ablation did not fire: the check passed"
  fi
  [ "${got}" = "$3" ] || fail "$1 ablation fired for the wrong reason: ${got}"
}

# 2. Ablation: drop rule 6 from a copy of the guide.
awk '
  /^6\. \*\*Fixing findings on an existing PR is claimed too/ { skip = 1 }
  skip && /^\*\*A live claim is a temporary skip/ { skip = 0 }
  !skip { print }
' "${guide}" >"${tmp}/ablated.md"
expect_ablation "rule-removal" "${tmp}/ablated.md" "rule 6 is missing"

# 3. Ablation: keep rule 6 but drop its takeover gate line.
grep -v "newer than the tip's committer date" "${guide}" >"${tmp}/no-gate.md" || true
expect_ablation "takeover" "${tmp}/no-gate.md" "missing: newer than the tip's committer date"

# 4. Ablation: remove the paragraph that ends rule 6, so extraction would run to end of file.
grep -v '^\*\*A live claim is a temporary skip' "${guide}" >"${tmp}/unterminated.md" || true
expect_ablation "unterminated" "${tmp}/unterminated.md" "rule 6 is missing"

echo "claim PR-findings contract: OK"
