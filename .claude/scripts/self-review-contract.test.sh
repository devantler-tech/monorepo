#!/usr/bin/env bash
#
# Guards the pre-submission self-review norm (maintainer direction 2026-07-20): the agent reviews its
# OWN diff — correctness pass plus quality pass — and fixes what it finds before the external review
# request goes out, so a rate-limited, portfolio-shared review lane is not spent on defects the agent
# could have caught itself.
#
# The rule is only useful if it stays bounded and stays distinguishable from the OTHER thing this
# repo calls a self-review, so this guards four properties, not one:
#   1. the contract carries the rule at all;
#   2. it exempts trivial/mechanical changes (its sibling mandates all do — an unbounded "every PR"
#      would put two agent review passes in front of a typo fix);
#   3. it is bounded to one pass + one re-verify (a judgement-based pass has no fixed point, so
#      "until clean" without a bound contradicts Latency discipline);
#   4. it is disambiguated, in BOTH directions, from `Local review round` — the mechanism that
#      SUBSTITUTES for a bot review. Conflating them would let routine hygiene satisfy the
#      green-review gate, which is the one failure mode here that silently lowers the quality bar.
# Plus: both run-loop skills carry the step, since a skill is meant to be followable on its own.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
maintenance_skill="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"
product_engineering_skill="${repo_root}/.claude/skills/product-engineering/SKILL.md"

fail() {
  echo "self-review contract: FAIL — $*" >&2
  exit 1
}

grep -Fq 'SELF-REVIEW YOUR OWN DIFF BEFORE YOU REQUEST A REVIEW ON IT' "${constitution}" ||
  fail "constitution does not require a pre-submission self-review of the agent's own diff"
# Keyed on wording unique to THIS bullet, and kept to ONE line. Two traps, both hit while
# RED-proving this file: the bare phrase "Trivial/mechanical changes are exempt" also appears in the
# feature-flag section, so matching it passes even with this exemption deleted (vacuous); and the
# sentence wraps, so a fragment spanning the line break never matches at all (always-red).
grep -Fq 'spend two review passes on a one-line fix' "${constitution}" ||
  fail "pre-submission self-review has no trivial-change exemption, unlike its sibling mandates"
grep -Fq 'fix **all** of it, re-verify **once**' "${constitution}" ||
  fail "the self-review loop is unbounded — Latency discipline requires one pass, then one re-verify"

# Both directions of the disambiguation, because an agent can arrive at either section first.
grep -Fq 'not** the last-resort' "${constitution}" ||
  fail "the pre-submission rule does not distinguish itself from the both-lanes-down fallback"
grep -Fq 'Not the same thing as the pre-submission self-review' "${constitution}" ||
  fail "the both-lanes-down fallback does not distinguish itself from the pre-submission pass"
grep -Fq 'having done it never counts toward this fallback' "${constitution}" ||
  fail "routine self-review could be claimed as satisfying the green-review gate"

# Maintainer direction, interactive session 2026-07-21: a review provider's quota state must not be
# what blocks a finished PR. Before this, a rate limit that stated a retry window was explicitly NOT
# a failed lane, so a throttle parked finished work indefinitely — which is what these assertions
# stop from silently reverting.
grep -Fq '*including one that states a retry window*' "${constitution}" ||
  fail "a rate limit with a stated window no longer admits a local review round, so a throttle can park finished work"
grep -Fq 'usage or spend limit' "${constitution}" ||
  fail "constitution does not admit a spend-exhausted lane as not-delivering"
grep -Fq 'structurally emits no artifact that satisfies the gate' "${constitution}" ||
  fail "a lane that reviews but never emits a gate-satisfying artifact is not recognised as not-delivering"
# The carve-out has to stay narrow, or it becomes a licence to merge past any red signal.
grep -Fq 'never a red CI check, never a required check, never a finding' "${constitution}" ||
  fail "the provider-quota merge carve-out is not bounded to the provider's own quota status"
# ...and the trigger widening must not be read as lowering the bar.
grep -Fq 'the bar, only the trigger' "${constitution}" ||
  fail "constitution does not state that widening the trigger leaves the review standard unchanged"
grep -Fq 'clean at a sha' "${constitution}" ||
  fail "a local review round no longer has to be clean at the current head to satisfy the gate"

grep -Fq 'Self-review the' "${maintenance_skill}" ||
  fail "portfolio-maintenance run loop does not self-review the diff before requesting review"
grep -Fq '**Self-review your own diff**' "${product_engineering_skill}" ||
  fail "product-engineering implement step does not self-review the diff before requesting review"

echo "self-review contract: all assertions passed"
