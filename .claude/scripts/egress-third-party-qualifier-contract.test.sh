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

egress="$(extract '### Egress' '### Sensitive information stays private')"
# Anchored on STRUCTURAL SECTION HEADINGS at both ends, never on a neighbouring bullet's prose. The CI
# filter runs this test on every AGENTS.md edit, so an anchor on any bullet's wording turns an
# unrelated reword into a required-check failure — measured for both the start and the end anchor.
conventions="$(extract '### GitHub artifact conventions' '### Cadence & focus')"

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
# A step can satisfy every connectivity assertion and still not be able to fail. Three constructs do
# it, each found separately by review: `continue-on-error` (step reports success), a step-level `if:`
# (command never runs), and a `shell:` override such as `bash {0} || true` (command runs, failure
# swallowed). Any step this guard depends on must be free of all three, so the check is factored here
# rather than repeated — the previous rounds fixed one step at a time and the next step stayed open.
step_can_fail() { # step_can_fail <step-text> <description>
  local step="$1" what="$2"
  grep -qE '^        continue-on-error:' <<< "${step}" && \
    fail "the ${what} declares continue-on-error — it would report success whatever its command returns, so the guard would not gate"
  grep -qE '^        if:' <<< "${step}" && \
    fail "the ${what} carries a step-level 'if:' — it could be skipped while the job and the required aggregate stay green"
  grep -qE '^        shell:' <<< "${step}" && \
    fail "the ${what} overrides 'shell:' — a wrapper such as 'bash {0} || true' converts its failure to success, so the guard would not gate"
  return 0
}
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

# 3. The POSITIVE destination must exist. Everything else here pins that a `devantler-tech` repo is
#    not the GATED case — but "not third-party" adds no destination of its own, and this section fails
#    closed. Delete the affirmative entry and every suite-owned issue, PR, comment, review and push
#    becomes un-sendable: the exact operational failure this guard exists to prevent, arrived at from
#    the opposite direction. Reproduced before this assertion existed.
has 'Outbound content goes only to: `devantler-tech` GitHub artifacts (issues, PRs, comments, reviews, pushes)' "${egress}" || \
  fail "the Egress allow-list no longer names `devantler-tech` GitHub artifacts as a permitted destination — a fail-closed list without it forbids all suite-owned output"
ok

# 4. PRESERVATION — both gates must sit inside ONE CONTIGUOUS affirmative clause.
has 'only once both its gates are cleared** — the professional-work boundary and the explicit per-artifact approval' "${egress}" || \
  fail "the third-party gate's two requirements are no longer bound inside one contiguous affirmative clause"
ok

# 4. The exemption must follow the devantler-tech OWNER, never the word "upstream". *Definition
#    routing* calls a synced skill's repository an upstream too, and those are frequently third party
#    (`find-skills` is owned by `vercel-labs/skills`) — so an exemption phrased as "the skills
#    repositories" would exempt a third-party owner from the gate this very entry imposes.
has 'The exemption follows the `devantler-tech` owner, never the word *upstream*' "${egress}" || \
  fail "the Egress entry no longer ties the exemption to the devantler-tech OWNER, so a third-party skill upstream could read as exempt"
ok


# 5. The ownership-resolution MECHANISM must survive too. Assertion 4 pins that the exemption follows
#    the owner, but not HOW a reader resolves one — and the resolver's fail-closed semantics is the
#    half that matters: `skill-owner.sh` exiting 2 means UNKNOWN, never "local". Without that clause an
#    unresolvable ownership could be read as suite-owned, i.e. exempt, which is the same third-party
#    fail-open assertion 4 exists to close, one step further down.
has 'Resolve ownership with `.claude/scripts/skill-owner.sh` — whose exit 2 is UNKNOWN, never "local"' "${egress}" || \
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
has 'Do not even inspect an external repository until the maintainer confirms in the current conversation that it is unrelated to professional work' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer requires the professional-work boundary before inspecting an external repository"
ok
has '**never autonomously open an issue or PR** — get explicit approval via the ask tool first' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer requires per-artifact approval before opening an external issue or PR"
ok

# ── 10. THIS JOB'S OWN CI WIRING — a guard that does not gate is not a guard ─────────────────────────
# Queried STRUCTURALLY with yq, never by grepping lines out of a textual block, and compared to EXACT
# values. Review demonstrated both failure modes: a value moved into an unused sibling key (valid YAML,
# referenced value absent) satisfies a block-scoped text match, and a neutralising expression
# (`… || true`, `… && false`, `false && …`) satisfies a substring match while inverting the meaning.
#
# This job is DELIBERATELY UNCONDITIONAL — no `needs:`, no `if:`, no paths-filter entry. A wiring
# validator gated on the very chain it validates cannot report its own disconnection: removing the
# filter or its exported output skips the job, and the aggregate accepts a skipped path-filtered job,
# so the required check stays green precisely when the wiring broke. Running always costs one fast
# bash job per PR and removes that whole class.
workflow="${repo_root}/.github/workflows/ci.yaml"
# FAIL, never skip: a renamed or unreadable workflow would otherwise bypass every assertion below and
# still print OK — the vacuous-success mode this guard exists to prevent, one level up.
[ -r "${workflow}" ] || \
  fail "ci.yaml is missing or unreadable at ${workflow} — this job's own wiring cannot be verified, so an OK here would be vacuous"
command -v yq >/dev/null 2>&1 || \
  fail "yq is unavailable, so this job's wiring cannot be verified structurally and an OK here would be vacuous"
yq '.' "${workflow}" >/dev/null 2>&1 || \
  fail "ci.yaml does not parse as YAML — its wiring cannot be verified"

JOB='test-egress-third-party-qualifier-contract'
q() { yq -r "$1" "${workflow}" 2>/dev/null; }
present() { [ -n "$1" ] && [ "$1" != "null" ]; }

# (a) the job must exist and be UNCONDITIONAL — any `if:` or `needs:` reintroduces a skip path, and a
#     skipped path-filtered job is accepted by the aggregate.
present "$(q ".jobs.\"${JOB}\"")" || \
  fail "ci.yaml has no ${JOB} job — the contract is not checked at all"
for attr in if needs; do
  v="$(q ".jobs.\"${JOB}\".\"${attr}\"")"
  present "${v}" && \
    fail "the ${JOB} job declares ${attr}: ${v} — it must stay unconditional, or breaking the wiring would skip the very job that reports it"
done

# (b) it must run EXACTLY the contract script: a wrapper such as `… || true` converts every failure to
#     success while still containing the filename.
# Materialise before matching: `q … | grep -q` under pipefail reports failure when grep exits
# on a match and SIGPIPEs yq, so a present value reads as absent.
run_cmds="$(q ".jobs.\"${JOB}\".steps[] | select(.run != null) | .run")"
grep -Fqx -- 'bash .claude/scripts/egress-third-party-qualifier-contract.test.sh' <<< "${run_cmds}" || \
  fail "no step in the ${JOB} job runs exactly 'bash .claude/scripts/egress-third-party-qualifier-contract.test.sh' — a wrapper such as '… || true' converts every contract failure to success"

# (c) the aggregate must depend on this job, actually evaluate its dependencies, and receive this
#     job's result UNTRANSFORMED. `needs.<job>.result == 'failure' && 'success' || needs.<job>.result`
#     contains the reference while handing the action `success` whenever the contract fails.
status_needs="$(q '.jobs.status.needs[]?')"
grep -Fqx -- "${JOB}" <<< "${status_needs}" || \
  fail "the status job does not list ${JOB} in needs: — its failures would not gate the merge"
status_if="$(q '.jobs.status.if')"
[ "${status_if}" = "always()" ] || \
  fail "the status job is not 'if: always()' (got '${status_if}') — a skipped aggregate evaluates no failing dependency, so this job's entry in it would gate nothing"
agg_results="$(q '.jobs.status.steps[] | select(.uses != null and (.uses | test("devantler-tech/actions/aggregate-job-checks@"))) | .with."job-results"')"
present "${agg_results}" || \
  fail "the status job has no devantler-tech/actions/aggregate-job-checks step with a job-results input — nothing evaluates the dependency results"
# job-results is a FOLDED scalar — one line, space-separated — so match the exact token as a
# substring. The masking form `${{ needs.<job>.result == 'failure' && 'success' || … }}` does not
# contain it, because `result` is followed by ` ==` rather than ` }}`.
grep -qF -- "\${{ needs.${JOB}.result }}" <<< "${agg_results}" || \
  fail "the aggregate action's job-results does not receive exactly '\${{ needs.${JOB}.result }}' — a transformed entry can hand it 'success' while this contract fails"

# (d) neither this job nor the aggregate may be unable to fail — at JOB level or STEP level. Each of
#     these was found separately by review, and each satisfies every assertion above.
for j in "${JOB}" status; do
  v="$(q ".jobs.\"${j}\".\"continue-on-error\"")"
  present "${v}" && \
    fail "the ${j} job sets continue-on-error: ${v} at job level — the run passes even when the job fails, so the guard would not gate"
done
for spec in \
  "verification step|.jobs.\"${JOB}\".steps[] | select(.run != null and (.run | test(\"egress-third-party-qualifier-contract.test.sh\")))" \
  "status job's aggregate step|.jobs.status.steps[] | select(.uses != null and (.uses | test(\"aggregate-job-checks@\")))"; do
  what="${spec%%|*}"; path="${spec#*|}"
  [ "$(q "[${path}] | length")" = "1" ] || \
    fail "expected exactly one ${what} in ci.yaml — its failure-masking settings cannot be checked, so an OK here would be vacuous"
  for attr in continue-on-error if shell; do
    v="$(q "${path} | .\"${attr}\"")"
    present "${v}" && \
      fail "the ${what} sets ${attr}: ${v} — it could report success without its command failing, so the guard would not gate"
  done
done
ok
[ "${passed}" -eq 11 ] || fail "expected 11 assertions, ran ${passed}"
echo "egress-third-party-qualifier contract: PASS (${passed} assertions)"
