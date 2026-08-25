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

# Assertions 1 and 3 match CONTIGUOUS literals with grep -qF, never a `case` glob. A glob written as
# *'third-party'*'upstream issue/PR'* permits arbitrary text between the fragments, which is fail-open
# twice over — both mutations below were demonstrated to PASS an earlier revision of this test:
#   * moving `third-party` into an unrelated earlier entry ("read-only third-party public web
#     research") while reverting the gated entry to a bare `upstream issue/PR` — the exact collision
#     this guard exists to prevent, reintroduced with the guard still green;
#   * rewriting the clause to `professional-work boundary; per-artifact approval is no longer
#     required` — both phrases still present, gate removed, guard still green.
# `case` is also the wrong primitive here regardless: these literals contain `*`, which a case pattern
# would interpret as a wildcard rather than matching.
has() { grep -qF -- "$1" <<< "${2}"; }

# 1. The qualifier must be bound to the gated entry ITSELF, contiguously.
has '**third-party upstream issue/PR only once' "${egress}" || \
  fail "the gated entry is not contiguously qualified as third-party (a 'third-party' elsewhere in the section does not count)"
ok

# 2. The section must resolve the overlap explicitly, or a later reader re-derives the same doubt from
#    *Definition routing* and stands down again.
has '**A `devantler-tech` repository is never that case**' "${egress}" || \
  fail "the Egress allow-list does not contiguously state that a devantler-tech repository is never the gated case"
ok

# 3. PRESERVATION — both gates must sit inside ONE CONTIGUOUS affirmative clause.
has 'only once both its gates are cleared** — the professional-work boundary and the explicit per-artifact approval' "${egress}" || \
  fail "the third-party gate's two requirements are no longer bound inside one contiguous affirmative clause"
ok

# 4. The exemption must follow the devantler-tech OWNER, never the word "upstream". *Definition
#    routing* calls a synced skill's repository an upstream too, and those are frequently third party
#    (`find-skills` is owned by `vercel-labs/skills`) — so an exemption phrased as "the skills
#    repositories" would exempt a third-party owner from the gate this very entry imposes.
has 'follows the `devantler-tech` owner' "${egress}" || \
  fail "the Egress entry no longer ties the exemption to the devantler-tech OWNER, so a third-party skill upstream could read as exempt"
ok


# 5. The ownership-resolution MECHANISM must survive too. Assertion 4 pins that the exemption follows
#    the owner, but not HOW a reader resolves one — and the resolver's fail-closed semantics is the
#    half that matters: `skill-owner.sh` exiting 2 means UNKNOWN, never "local". Without that clause an
#    unresolvable ownership could be read as suite-owned, i.e. exempt, which is the same third-party
#    fail-open assertion 4 exists to close, one step further down.
has '`.claude/scripts/skill-owner.sh` — whose exit 2 is UNKNOWN, never "local"' "${egress}" || \
  fail "the Egress entry no longer names skill-owner.sh with its fail-closed exit-2 semantics, so unresolvable ownership could read as exempt"
ok
# 6. VOCABULARY PIN — the canonical section must keep the wording the Egress entry mirrors. The defect
#    was these two drifting apart, so pinning only the copy would let the original move instead.
has 'Third-party upstream repos' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer says 'Third-party upstream repos' — the two sections have drifted apart again"
ok
has '`devantler-tech` repos are exempt — open drafts/issues there autonomously' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer contiguously states the devantler-tech exemption"
ok


# 8. The CANONICAL section must still impose BOTH gates. Assertions 6 and 7 pin its vocabulary and its
#    exemption, but not the requirements themselves — so the source could be rewritten to allow
#    autonomous external artifacts while still saying "Third-party upstream repos" and naming the
#    devantler-tech exemption, leaving the Egress copy contradicting it and this guard, whose whole
#    purpose is pinning the two together, green. Reproduced before this assertion existed.
has 'Do not even inspect an external repository until the maintainer confirms' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer requires the professional-work boundary before inspecting an external repository"
ok
has '**never autonomously open an issue or PR** — get explicit approval via the ask tool first' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer requires per-artifact approval before opening an external issue or PR"
ok

# ── 10. THIS JOB'S OWN CI WIRING — a guard that does not gate is not a guard ──────────────────────────
# Wiring a contract test into `ci.yaml` takes FIVE edits. Drop the `changes`-job output and the `if:`
# is never true, so the job reports `skipping` on every run while passing locally. Drop either the
# `status` job's `needs:` or its `job-results:` entry and the job still RUNS and still prints OK —
# while its failures no longer gate the required aggregate check. Both were reproduced against this
# very PR, so this is measured, not hypothetical.
workflow="${repo_root}/.github/workflows/ci.yaml"
# FAIL, never skip: guarding these behind `if [ -r ... ]` would let a renamed or unreadable workflow
# bypass every assertion below and still print OK — the same vacuous-success mode this guard exists
# to prevent, reintroduced one level up.
[ -r "${workflow}" ] || \
  fail "ci.yaml is missing or unreadable at ${workflow} — this job's own wiring cannot be verified, so an OK here would be vacuous"
for wiring in \
  '            egress-third-party-qualifier-contract:|paths-filter entry' \
  '      egress-third-party-qualifier-contract: ${{ steps.filter.outputs.egress-third-party-qualifier-contract }}|changes-job outputs declaration (its absence makes the job skip silently)' \
  '  test-egress-third-party-qualifier-contract:|job definition' \
  '      - test-egress-third-party-qualifier-contract|status job needs: entry (its absence stops the job gating the merge)' \
  '            ${{ needs.test-egress-third-party-qualifier-contract.result }}|status job job-results entry' \
  "    if: needs.changes.outputs.egress-third-party-qualifier-contract == 'true'|job if: condition (an 'if: false' leaves the aggregate green-by-skip while the guard never runs)" \
  '        run: bash .claude/scripts/egress-third-party-qualifier-contract.test.sh|job run: command (a replaced command would execute something else entirely)'; do
  needle="${wiring%%|*}"; what="${wiring#*|}"
  grep -Fqx -- "${needle}" "${workflow}" || \
    fail "ci.yaml is missing this job's ${what} — the guard would not gate"
done
# The filter must cover every surface this test reads, or an edit to an unlisted one skips the job.
for trigger in \
  "              - 'AGENTS.md'" \
  "              - '.claude/scripts/egress-third-party-qualifier-contract.test.sh'" \
  "              - '.github/workflows/ci.yaml'"; do
  grep -Fqx -- "${trigger}" "${workflow}" || \
    fail "ci.yaml's paths-filter for this job is missing ${trigger} — an edit to that surface would not run the guard"
done
ok

[ "${passed}" -eq 10 ] || fail "expected 10 assertions, ran ${passed}"
echo "egress-third-party-qualifier contract: PASS (${passed} assertions)"
