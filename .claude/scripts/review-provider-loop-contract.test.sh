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
parity_checklist="${repo_root}/.claude/plugin-consumption/automated-ai-engineer-surveyor-diff.md"
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
grep -Fq 'body_findings=0-resolved@<sha>' "${surveyor}" ||
  fail "surveyor cannot clear a same-head CodeRabbit body finding after a recorded refutation"
grep -Fq '`body_findings=0-resolved@<sha>` counts as zero for CodeRabbit success' "${surveyor}" ||
  fail "a resolved repeated CodeRabbit finding can trap the provider loop"
grep -Fq 'same-SHA Codex clean supersedes findings only after all finding threads are resolved and a later re-request produces the clean marker' "${surveyor}" ||
  fail "a successful same-head Codex retry cannot terminate the loop"
grep -Fq 'same-SHA Bugbot success supersedes findings only after all finding threads are resolved and a later authenticated re-request produces that check' "${surveyor}" ||
  fail "Bugbot retries have no deterministic same-head supersession rule"
grep -Fq 'A later successful provider in the authenticated restarted sequence clears those resolved findings' "${surveyor}" ||
  fail "a successful restarted provider cannot clear resolved findings from another lane"
grep -Fq 'author exactly `devantler` and carry the structural disclosure prefix' "${constitution}" ||
  fail "an external account can spoof a same-head body-finding resolution record"
grep -Fq 'An identical repeated same-SHA CodeRabbit finding preserves its authenticated resolution record' "${constitution}" ||
  fail "an unchanged CodeRabbit false positive can reopen forever"
grep -Fq 'Immediately before every provider request, re-read the repository-visible current-head reservation' "${constitution}" ||
  fail "overlapping instances can open concurrent provider lanes"
grep -Fq 'review_pending=<cr@<sha>|codex@<sha>|bugbot@<sha>|none>' "${surveyor}" ||
  fail "surveyor does not expose an in-flight provider request to sibling instances"
grep -Fq 'A request marker is authoritative only from exact author `devantler` with the structural disclosure' "${constitution}" ||
  fail "an external comment can spoof an in-flight provider request"
grep -Fq 'Only one provider request may be active at a time' "${constitution}" ||
  fail "constitution does not forbid concurrent provider requests"
grep -Fq 'post a separate disclosed reservation marker before any provider trigger' "${constitution}" ||
  fail "provider selection is still vulnerable to a check-then-trigger race"
grep -Fq 'oldest `created_at`, then lowest comment id' "${constitution}" ||
  fail "concurrent review reservations have no deterministic winner"
grep -Fq 'review_reservation=<cr@<sha>|codex@<sha>|bugbot@<sha>|none>' "${surveyor}" ||
  fail "surveyor does not expose the pre-trigger reservation to sibling instances"
grep -Fq 'A winning request supersedes every reservation for that provider/head election' "${surveyor}" ||
  fail "losing reservations can revive after the winning request completes"
grep -Fq 'pair it with the next exact-author bare `@cursor review` trigger while ignoring interleaved comments' "${surveyor}" ||
  fail "Cursor request markers break when another comment lands before the bare trigger"
grep -Fq 'review_progress=<cr:no-gate@<sha>|codex:no-gate@<sha>|bugbot:no-gate@<sha>|none>' "${surveyor}" ||
  fail "a completed provider outcome without a green artifact is not durable across runs"
grep -Fq 'review-progress-head: <full sha> provider=<lane> outcome=no-gate' "${surveyor}" ||
  fail "silent provider expiry cannot persist progression across runs"
grep -Fq '`review_progress` is the furthest completed lane by provider order, never the latest artifact by time' "${surveyor}" ||
  fail "a delayed provider response can move review progression backward"
grep -Fq 'CodeRabbit is first and foremost a review provider' "${constitution}" ||
  fail "constitution still treats CodeRabbit primarily as a pre-merge evaluator"
grep -Fq 'a finding-free current-head CodeRabbit review completion is `cr@<sha>` even without `APPROVED`' "${constitution}" ||
  fail "a successful CodeRabbit review still cannot satisfy the review gate"
grep -Fq 'auto-generated summary comment' "${surveyor}" ||
  fail "CodeRabbit success has no recognizable substantive completion artifact"
grep -Fq 'Never count an auto-generated command reply, acknowledgement, quota notice, or service shell as a review completion' "${surveyor}" ||
  fail "CodeRabbit acknowledgement can be mistaken for a successful review"
grep -Fq 'review object `submitted_at` must be later than the latest authenticated CodeRabbit request marker' "${surveyor}" ||
  fail "an old same-head CodeRabbit review can satisfy a later retry"
grep -Fq 'Missing or delayed pre-merge output never blocks promotion' "${constitution}" ||
  fail "absent ancillary CodeRabbit output can still block a reviewed PR"
grep -Fq 'fold it into `body_findings`' "${surveyor}" ||
  fail "an explicit CodeRabbit pre-merge problem is not preserved as a review finding"
for contract_file in "${constitution}" "${surveyor}" "${maintenance_skill}" "${daily_maintainer}"; do
  if grep -Fq 'premerge=' "${contract_file}"; then
    fail "standalone CodeRabbit pre-merge readiness state remains in ${contract_file}"
  fi
done
if grep -Fq 'pre-merge summary parsing' "${parity_checklist}"; then
  fail "plugin-parity checklist can reintroduce the removed pre-merge gate"
fi
grep -Fq 'finding-free CodeRabbit completion without requiring `APPROVED`' "${parity_checklist}" ||
  fail "plugin-parity checklist does not recognize CodeRabbit review completions"

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
grep -Fq '.claude/plugin-consumption/automated-ai-engineer-surveyor-diff.md' "${workflow}" ||
  fail "parity-checklist changes do not trigger the review-provider contract check"
grep -Fq 'test-review-provider-loop-contract:' "${workflow}" ||
  fail "CI does not define the review-provider contract test job"
grep -Fq 'run: bash .claude/scripts/review-provider-loop-contract.test.sh' "${workflow}" ||
  fail "CI does not execute the review-provider contract test"
grep -Fq '${{ needs.test-review-provider-loop-contract.result }}' "${workflow}" ||
  fail "the required aggregate check does not include the review-provider contract job"

echo "review-provider loop contract: all assertions passed"
