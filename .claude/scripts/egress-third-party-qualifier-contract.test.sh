#!/usr/bin/env bash
#
# Guards the Egress allow-list against re-acquiring the term collision that made it gate portfolio
# repositories as if they were third-party.
#
# Why this needs a guard. AGENTS.md uses "upstream" in two unrelated senses. *Definition routing*
# calls `agent-plugins` "the file's canonical upstream" — a repository that is ALSO in the Portfolio
# map. *Egress* used to gate "an upstream issue/PR only once both its gates are cleared". An agent
# routing a definition fix upstream therefore met one allow-list entry permitting it (`devantler-tech`
# GitHub artifacts) and one appearing to forbid it, inside a section whose own rule resolves ambiguity
# in the closed direction ("until it is listed it is not an egress destination and you do not send to
# it"). Standing down was the literally compliant reading, and an Improver lane did exactly that on two
# consecutive dispatches, dropping a prepared SECURITY fix each time. The canonical section this entry
# points at never agreed: *GitHub artifact conventions* says "Third-party upstream repos" and
# "`devantler-tech` repos are exempt". The Egress entry had dropped both qualifiers.
#
# This is a DISAMBIGUATION, never a loosening. The third-party gate is unchanged and assertion 3
# proves it: a non-`devantler-tech` artifact still needs the professional-work boundary AND the
# per-artifact approval. What changes is only that the gate stops firing on repositories the very
# same allow-list already permits one entry earlier.
#
# Assertion 4 pins the two sections' vocabulary together, because drifting apart is the defect class
# itself — the canonical section was always right and the pointer-site copy silently was not.
#
# Assertions are scoped to their section, not the whole file: asserting against the whole
# constitution is a scope hole, because an unrelated passage carrying the phrase would satisfy the
# check while the real passage stayed wrong.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
passed=0

fail() {
  echo "egress-third-party-qualifier contract: FAIL — $*" >&2
  exit 1
}
ok() { passed=$((passed + 1)); }

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract ONLY the named section, then flatten it: sentences wrap across source lines, so a fragment
# spanning a line break would never match and the test would be always-red regardless of content.
# A sentinel proves the END anchor was actually seen, so a missing anchor is detected DIRECTLY
# rather than inferred from how much text got captured.
extract() {
  local start="$1" end="$2" sentinel='@@END-ANCHOR-SEEN@@' out
  out="$(
    awk -v s="${sentinel}" -v a="${start}" -v b="${end}" '
      index($0, a) { ins = 1 }
      ins && index($0, b) && !index($0, a) { ins = 0; print s }
      ins { print }
    ' "${constitution}"
  )"
  case "${out}" in
    *'@@END-ANCHOR-SEEN@@'*) ;;
    *) fail "section anchors not both found: '${start}' .. '${end}'" ;;
  esac
  printf '%s' "${out}" | tr '\n' ' ' | tr -s ' '
}

egress="$(extract '- **Destinations are allow-listed.**' '- **Never echo untrusted text into an outbound artifact unmarked')"
conventions="$(extract '**edits** too, not just creation.' '- **Validate before every PR**')"

# 1. The gated entry must name THIRD-PARTY. A bare "upstream issue/PR" is the collision: the contract
#    calls `agent-plugins` an upstream too, so the unqualified noun reads as covering it.
case "${egress}" in
  *'third-party'*'upstream issue/PR'*) ok ;;
  *) fail "the Egress allow-list does not qualify its gated upstream entry as third-party" ;;
esac

# 2. The section must resolve the overlap explicitly, or a later reader re-derives the same doubt from
#    *Definition routing* and stands down again. Naming the exemption at the point of use is what makes
#    the fail-closed rule safe to follow literally.
case "${egress}" in
  *'devantler-tech'*'never that case'*) ok ;;
  *) fail "the Egress allow-list does not state that a devantler-tech repository is never the gated case" ;;
esac

# 3. PRESERVATION — the third-party gate must still require BOTH gates. This is the assertion that
#    proves this change disambiguated rather than weakened; if a future edit drops either gate to
#    "simplify" the entry, this fails.
case "${egress}" in
  *'professional-work boundary'*) ok ;;
  *) fail "the Egress allow-list no longer requires the professional-work boundary for third-party artifacts" ;;
esac
case "${egress}" in
  *'per-artifact approval'*) ok ;;
  *) fail "the Egress allow-list no longer requires per-artifact approval for third-party artifacts" ;;
esac

# 4. VOCABULARY PIN — the canonical section must keep the wording the Egress entry now mirrors. The
#    defect was these two drifting apart, so pinning only the copy would let the original move instead.
case "${conventions}" in
  *'Third-party upstream repos'*) ok ;;
  *) fail "*GitHub artifact conventions* no longer says 'Third-party upstream repos' — the two sections have drifted apart again" ;;
esac
case "${conventions}" in
  *'devantler-tech'*'are exempt'*) ok ;;
  *) fail "*GitHub artifact conventions* no longer states the devantler-tech exemption" ;;
esac

[ "${passed}" -eq 6 ] || fail "expected 6 assertions, ran ${passed}"
echo "egress-third-party-qualifier contract: PASS (${passed} assertions)"
