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
# Three hardenings came from review (Codex, 2026-08-25) and each closed a real hole:
#   * assertions 3 searched the section for the two gate phrases INDEPENDENTLY, so an edit reading
#     "per-artifact approval is no longer required" left both substrings present and the guard green
#     while the invariant was gone. It now matches the affirmative clause that GRANTS the destination.
#     Proven differentially: with that clause negated, the previous revision of this test PASSES and
#     this one fails.
#   * assertion 4 exists because the first draft of the prose exempted "the skills repositories" —
#     but a synced skill's upstream is frequently third party (`find-skills` is `vercel-labs/skills`),
#     so that phrasing would have exempted a third-party owner from the very gate this entry imposes.
#   * the conventions extraction anchored on prose owned by the PRECEDING bullet, so rewording an
#     unrelated PR-body sentence would have reddened a required check on every AGENTS.md edit.
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
# Anchored on the section HEADING, not on prose owned by the preceding bullet. The CI filter runs this
# test on every AGENTS.md edit, so anchoring on a neighbouring bullet's sentence would turn an
# unrelated documentation reword into a required-check failure.
conventions="$(extract '### GitHub artifact conventions' '- **Validate before every PR**')"

# 1. The gated entry must name THIRD-PARTY. A bare "upstream issue/PR" is the collision: the contract
#    calls `agent-plugins` an upstream too, so the unqualified noun reads as covering it.
case "${egress}" in
  *'third-party'*'upstream issue/PR'*) ok ;;
  *) fail "the Egress allow-list does not qualify its gated upstream entry as third-party" ;;
esac

# 2. The section must resolve the overlap explicitly, or a later reader re-derives the same doubt from
#    *Definition routing* and stands down again.
case "${egress}" in
  *'devantler-tech'*'never that case'*) ok ;;
  *) fail "the Egress allow-list does not state that a devantler-tech repository is never the gated case" ;;
esac

# 3. PRESERVATION — both gates must sit inside ONE AFFIRMATIVE CLAUSE. Searching the section for the
#    two phrases independently is a fail-open: an edit reading "per-artifact approval is no longer
#    required" leaves both substrings present, so the guard stays green while the invariant it claims
#    to protect is gone. Matching the clause that GRANTS the destination is what makes this real.
case "${egress}" in
  *'only once both its gates are cleared'*'professional-work'*'per-artifact approval'*) ok ;;
  *) fail "the third-party gate's two requirements are no longer bound inside the affirmative clause that grants the destination" ;;
esac

# 4. The exemption must follow the devantler-tech OWNER, never the word "upstream". *Definition
#    routing* calls a synced skill's repository an upstream too, and those are frequently third party
#    (`find-skills` is owned by `vercel-labs/skills`) — so an exemption phrased as "the skills
#    repositories" would exempt a third-party owner from the gate this very entry imposes.
case "${egress}" in
  *'follows the `devantler-tech` owner'*) ok ;;
  *) fail "the Egress entry no longer ties the exemption to the devantler-tech OWNER, so a third-party skill upstream could read as exempt" ;;
esac

# 5. VOCABULARY PIN — the canonical section must keep the wording the Egress entry mirrors. The defect
#    was these two drifting apart, so pinning only the copy would let the original move instead.
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
