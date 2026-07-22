#!/usr/bin/env bash
#
# Guards the external-review loop (maintainer direction 2026-07-22): request the three providers in
# priority order, exactly one at a time, and stop as soon as one produces a successful current-head
# review. Findings restart the sequence after the fix; an acknowledged request stays in flight.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
maintenance_skill="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"
surveyor="${repo_root}/.claude/agents/portfolio-surveyor.md"
daily_maintainer="${repo_root}/.claude/agents/daily-maintainer.md"
workflow="${repo_root}/.github/workflows/ci.yaml"

fail() {
  echo "review-provider loop contract: FAIL — $*" >&2
  exit 1
}

grep -Fq 'CodeRabbit > Codex > Cursor Bugbot' "${constitution}" ||
  fail "constitution does not preserve the provider order"
grep -Fq 'STOP on the first successful current-head review' "${constitution}" ||
  fail "constitution does not stop the loop after one provider succeeds"
grep -Fq 'never request a second provider after the first success' "${constitution}" ||
  fail "constitution permits redundant reviews after the gate is already satisfied"
grep -Fq 'A provider reaction emoji on the trigger is positive in-flight evidence' "${constitution}" ||
  fail "constitution does not distinguish an acknowledged request from a silent trigger"
grep -Fq 'fix or refute every reported issue, then restart at CodeRabbit' "${constitution}" ||
  fail "constitution does not restart the ordered loop after review findings"
grep -Fq 'A refutation that changes no file restarts at the same head; never create an empty commit' "${constitution}" ||
  fail "constitution forces a meaningless push before restarting after a refuted finding"
grep -Fq 'A reaction earns a generous bounded wait, not an infinite lease' "${constitution}" ||
  fail "an acknowledged provider can stall the review loop forever"
grep -Fq 'premerge=not-posted` remains **NEEDS-FIX** when CodeRabbit reviewed the current head' "${surveyor}" ||
  fail "surveyor can promote before delayed CodeRabbit pre-merge output arrives"
grep -Fq 'body_findings=0-resolved@<sha>' "${surveyor}" ||
  fail "surveyor cannot clear a same-head CodeRabbit body finding after a recorded refutation"
grep -Fq 'same-SHA Codex clean supersedes findings only after all finding threads are resolved and a later re-request produces the clean marker' "${surveyor}" ||
  fail "a successful same-head Codex retry cannot terminate the loop"
grep -Fq 'Pre-merge output is required only when CodeRabbit reviewed the current head' "${constitution}" ||
  fail "pre-merge applicability incorrectly expires when the loop advances beyond CodeRabbit"
grep -Fq 'author exactly `devantler` and carry the structural disclosure prefix' "${constitution}" ||
  fail "an external account can spoof a same-head body-finding resolution record"
grep -Fq 'An identical repeated same-SHA CodeRabbit finding preserves its authenticated resolution record' "${constitution}" ||
  fail "an unchanged CodeRabbit false positive can reopen forever"
grep -Fq 'premerge=provider-stalled' "${surveyor}" ||
  fail "missing CodeRabbit pre-merge output can block a PR forever"
grep -Fq 'Immediately before every provider request, re-read the repository-visible current-head request markers' "${constitution}" ||
  fail "overlapping instances can open concurrent provider lanes"
grep -Fq 'review_pending=<cr@<sha>|codex@<sha>|bugbot@<sha>|none>' "${surveyor}" ||
  fail "surveyor does not expose an in-flight provider request to sibling instances"
grep -Fq 'A request marker is authoritative only from exact author `devantler` with the structural disclosure' "${constitution}" ||
  fail "an external comment can spoof an in-flight provider request"
grep -Fq 'Only one provider request may be active at a time' "${constitution}" ||
  fail "constitution does not forbid concurrent provider requests"

# The two maintained Claude entry points must remain independently followable without recreating the
# superseded multi-provider interpretation.
grep -Fq 'stop on its first successful current-head review' "${maintenance_skill}" ||
  fail "portfolio-maintenance does not stop after the first provider succeeds"
grep -Fq 'one provider request at a time' "${maintenance_skill}" ||
  fail "portfolio-maintenance permits concurrent provider requests"
grep -Fq 'a successful current-head review from any one provider completes the review gate' "${surveyor}" ||
  fail "portfolio-surveyor still requires CodeRabbit output in addition to another green provider"
grep -Fq 'stop after the first provider succeeds' "${daily_maintainer}" ||
  fail "daily-maintainer still asks for redundant reviews after one provider succeeds"

# The contract must be a required PR check, including when its own workflow wiring changes.
grep -Fq 'review-provider-loop-contract: ${{ steps.filter.outputs.review-provider-loop-contract }}' "${workflow}" ||
  fail "CI does not export the review-provider contract change filter"
grep -Fq 'test-review-provider-loop-contract:' "${workflow}" ||
  fail "CI does not define the review-provider contract test job"
grep -Fq 'run: bash .claude/scripts/review-provider-loop-contract.test.sh' "${workflow}" ||
  fail "CI does not execute the review-provider contract test"
grep -Fq '${{ needs.test-review-provider-loop-contract.result }}' "${workflow}" ||
  fail "the required aggregate check does not include the review-provider contract job"

echo "review-provider loop contract: all assertions passed"
