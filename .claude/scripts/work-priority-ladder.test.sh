#!/usr/bin/env bash
#
# Guards the work-selection ladder (maintainer direction 2026-07-25): a run picks work top-down —
# live breakage, then EVERY open PR it owns or trusts INCLUDING ITS OWN DRAFTS, then security
# issues, then bugs, then the oldest actionable issue.
#
# Why this needs enforcing rather than merely stating: the contract already said "PRs before issues"
# and already said "stop starting, start finishing", and the pile still happened. The mechanism was a
# SCOPING hole, not a missing rule — priority-1 was defined over `non-draft` PRs in Merge policy, so
# an own draft matched no rung and was reachable only through a paragraph 1,800 lines away that read
# as a precondition on opening new drafts. Measured 2026-07-25: 99 open own PRs, 100% drafts, none
# ever promoted, median age 6.9 days, 18 already CLEAN and idle a median 5.3 days, 16 conflicted,
# 49 of 88 untouched in the 24h after opening.
#
# So this guards the two properties that actually close that hole, plus the drift that reopened it:
#   1. the ladder exists, is ordered, and names all five rungs;
#   2. rung 1 explicitly covers OWN DRAFTS, and Merge policy's `non-draft` is explicitly scoped to
#      the merge command rather than the sweep — the exact misreading that produced the pile;
#   3. severity outranks age, so a Security issue is not queued behind an older Docs one;
#   4. the run-loop skill agrees with the contract — three surfaces restate this ordering, and a
#      silent divergence between them is how the previous wording drifted;
#   5. intake is CAPPED and not merely ordered — because fixing (2) still did not drain the pile, and
#      the re-measurement showed why: ordering is not the binding constraint, review capacity is.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
maintenance_skill="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"
workflow="${repo_root}/.github/workflows/ci.yaml"

fail() {
  echo "work-priority ladder: FAIL — $*" >&2
  exit 1
}

# Markdown prose is hard-wrapped, so a guarded sentence routinely spans two lines and exists on NO
# single line. Flatten once and match substrings against the flattened copy; keep `grep -Fq` only
# for things that genuinely live on one line (a heading, a table row, an identifier).
constitution_flat="$(tr '\n' ' ' < "${constitution}" | tr -s '[:space:]' ' ')"
skill_flat="$(tr '\n' ' ' < "${maintenance_skill}" | tr -s '[:space:]' ' ')"

assert_prose() {
  case "$2" in
    *"$1"*) ;;
    *) fail "$3" ;;
  esac
}

# ── 1. the ladder exists and is ordered ──────────────────────────────────────
grep -Fq '### The work-selection ladder — one ordering, checked top-down every run' "${constitution}" ||
  fail "contract does not define the work-selection ladder"
assert_prose 'you do not descend while a higher rung still has actionable work' \
  "${constitution_flat}" "ladder does not state that rungs are strictly ordered"

for rung in \
  '| **0** | **Live breakage** |' \
  '| **1** | **Open PRs — INCLUDING your own drafts** |' \
  '| **2** | **Security issues** |' \
  '| **3** | **Bugs** |' \
  '| **4** | **Oldest actionable issue** |'; do
  grep -Fq "${rung}" "${constitution}" ||
    fail "ladder is missing rung row ${rung}"
done

# ── 2. rung 1 covers own drafts, and `non-draft` is scoped to the merge command ──
assert_prose 'Rung 1 includes your own DRAFTS' \
  "${constitution_flat}" "ladder does not put own drafts in rung 1 — the exact hole that produced the pile"
assert_prose 'draft and non-draft alike' \
  "${constitution_flat}" "rung 1 does not state it covers drafts and non-drafts alike"
assert_prose 'scoping below bounds the merge COMMAND, never the SWEEP' \
  "${constitution_flat}" "Merge policy does not scope its non-draft clause to the merge command"

# ── 3. severity outranks age ──────────────────────────────────────────────────
assert_prose 'Severity outranks age at rungs 2–3; age decides only *within* a rung' \
  "${constitution_flat}" "contract does not state that severity outranks age"

# ── 4. the run-loop skill agrees with the contract ────────────────────────────
assert_prose 'Your own DRAFTS are rung-1 work' \
  "${skill_flat}" "run-loop skill does not carry the own-drafts rung-1 rule"
assert_prose 'severity is the primary sort, age the tiebreaker within a tier' \
  "${skill_flat}" "run-loop skill still sorts the issue queue by age alone"
assert_prose 'Resolve the next issue by the ladder' \
  "${skill_flat}" "run-loop skill's advance step does not follow the ladder"

# ── 5. intake is CAPPED, not merely ordered ──────────────────────────────────
# Re-measured 2026-07-26, after §2's fix landed: the pile did NOT drain. 99 → 91 open own PRs, still
# 100% drafts, and median age ROSE 6.9d → 8.0d. Per lane it was 88/91 `codex/*` — and 63 of those 88
# (72%) were opened on ONE day, all on one repo, all one theme, every sampled one NEVER reviewed and
# by then BLOCKED or DIRTY. So §2's diagnosis was incomplete: ordering cannot drain a pile, because
# promotion needs a green review at the current head and the review lanes are metered and shared. A
# run that opens its whole batch in one pass satisfies "finish before you start more" VACUOUSLY — it
# had nothing in flight when it started. These guard the cap that closes that, and the carve-outs
# that keep it from blocking mandated work.
assert_prose 'The WIP limit is also a CAP ON INTAKE, not only an ordering' \
  "${constitution_flat}" "contract does not bound draft intake — ordering alone cannot drain a pile"
assert_prose 'a run that opens its whole batch in one pass satisfies it **vacuously**' \
  "${constitution_flat}" "contract does not explain why the ordering rule is satisfiable vacuously"
grep -Fq '| **Per run** | Open at most **5** new own drafts. |' "${constitution}" ||
  fail "contract does not state the per-run draft intake cap"
grep -Fq '| **Per lane** | While your own lane holds **more than 20** open drafts' "${constitution}" ||
  fail "contract does not state the per-lane draft ceiling"
# The carve-outs are load-bearing: without them the cap would block a hotfix or stop the backlog
# being captured, which is a guard firing on correct mandated work.
assert_prose 'Rung-0 live breakage is exempt from both' \
  "${constitution_flat}" "intake cap does not exempt live breakage — it would block a hotfix"
assert_prose 'filing an issue is not opening a draft' \
  "${constitution_flat}" "intake cap does not exempt issue capture — the backlog would stop being capturable"
# Autonomy must no longer bless an unreviewable burst as "not sprawl".
assert_prose 'What IS sprawl is a burst that outruns your own review capacity' \
  "${constitution_flat}" "Autonomy still licenses an unbounded draft set as 'not sprawl'"

# ── CI wiring ─────────────────────────────────────────────────────────────────
# GitHub expression tokens are literal workflow syntax, not shell expansions.
# shellcheck disable=SC2016
grep -Fq 'work-priority-ladder: ${{ steps.filter.outputs.work-priority-ladder }}' "${workflow}" ||
  fail "CI does not export the work-priority ladder filter"
grep -Fq 'test-work-priority-ladder:' "${workflow}" ||
  fail "CI does not define the work-priority ladder job"
grep -Fq 'run: bash .claude/scripts/work-priority-ladder.test.sh' "${workflow}" ||
  fail "CI does not execute the work-priority ladder test"
# shellcheck disable=SC2016
grep -Fq '${{ needs.test-work-priority-ladder.result }}' "${workflow}" ||
  fail "required checks do not aggregate the work-priority ladder"

echo "work-priority ladder: all assertions passed"
