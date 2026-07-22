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
grep -Fq 'fix or refute every reported issue, push the correction, and restart at CodeRabbit' "${constitution}" ||
  fail "constitution does not restart the ordered loop after review findings"
grep -Fq 'Only one provider request may be active at a time' "${constitution}" ||
  fail "constitution does not forbid concurrent provider requests"
grep -Fq 'Pre-merge output is required only when CodeRabbit is the provider currently serving the review loop' "${constitution}" ||
  fail "constitution still makes CodeRabbit pre-merge output mandatory after another provider succeeds"

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
