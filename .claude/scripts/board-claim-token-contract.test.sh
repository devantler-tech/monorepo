#!/usr/bin/env bash
#
# Guards monorepo#2265: board-only claims (path-less project-board mutations) must carry a unique,
# greppable per-RUN token. Every instance comments as `devantler`, so the disclosure line alone
# cannot tell siblings apart — and a lane-only token cannot tell two ticks of the SAME lane apart,
# which is the common case rather than an edge one (lanes dispatch hourly; 46% of runs exceed 60
# minutes, so a lane's next tick routinely starts before the previous one finishes).
#
# Pins the properties that make the scheme actually serialise concurrent board mutation:
#   1. the token template carries BOTH the lane and the run id;
#   2. the three live lanes are the only admitted lane values;
#   3. ownership is decided on the WHOLE token, never on lane equality;
#   4. the lease is timed from the comment's created_at (not assignment — there is none);
#   5. close-out is a matching `board-claim-done:<lane>-<run-id>` token, because issue comments are
#      FLAT — there is no reply-to field, so a "reply" cannot be matched to the claim it ends;
#   6. overlapping live claims elect a deterministic winner instead of both standing down;
#   7. the canonical skip test recognises an unclosed foreign token.
#
# Phrases are kept on ONE line so `grep -Fq` cannot go silently red on a soft wrap (same class as
# monorepo#2250 / #2312 / #2349).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
run_loop="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"
board_card="${repo_root}/.claude/skills/products/project-board/SKILL.md"

fail() {
  echo "board-claim-token contract: FAIL — $*" >&2
  exit 1
}

# --- 1. token template carries the run id -------------------------------------------------------
# A bare `board-claim:<lane>` is the defect, not the contract: it makes two ticks of one lane read
# each other's claim as their own. Assert the run-id-bearing template in every surface.
grep -Fq 'board-claim:<lane>-<run-id>' "${constitution}" ||
  fail "constitution does not require the per-run board-claim:<lane>-<run-id> token"
grep -Fq 'board-claim:<lane>-<run-id>' "${run_loop}" ||
  fail "portfolio-maintenance board Act step does not require board-claim:<lane>-<run-id>"
grep -Fq 'board-claim:<lane>-<run-id>' "${board_card}" ||
  fail "project-board card Mutation safety does not require board-claim:<lane>-<run-id>"

# The run id must be bound to the SAME identifier the worktree claim already uses, or a run is free
# to invent a per-lane-stable value and reintroduce the collision.
grep -Fq 'session-owner-token' "${constitution}" ||
  fail "constitution does not tie the board-claim run id to the existing session-owner-token"
grep -Fq 'session-owner-token' "${run_loop}" ||
  fail "run loop does not tie the board-claim run id to the existing session-owner-token"

# --- 2. the three live lanes ---------------------------------------------------------------------
grep -Fq 'exactly `claude`, `codex`,' "${constitution}" ||
  fail "constitution does not pin the three live lanes as the only admitted board-claim lanes"

# --- 3. ownership is a WHOLE-token test, never lane equality -------------------------------------
# This is the assertion that actually closes the same-lane race: without it a reader can satisfy
# every other check and still treat a sibling tick's claim as its own.
grep -Fq 'Match your own claim on the WHOLE token' "${constitution}" ||
  fail "constitution does not decide board-claim ownership on the whole token"
grep -Fq 'including your own lane under a' "${run_loop}" ||
  fail "run loop does not state that your own lane under a different run id is a sibling's claim"

# --- 4. lease timing -----------------------------------------------------------------------------
grep -Fq "timed from the comment's \`created_at\`" "${constitution}" ||
  fail "constitution does not time the board-only lease from the claim comment's created_at"
grep -Fq "timed from the comment's \`created_at\`" "${run_loop}" ||
  fail "run loop does not time the board-only lease from created_at"

# --- 5. close-out is a matching token, and the flatness reason is recorded -----------------------
# The reason is asserted, not just the mechanism: without it a later edit "simplifies" the token
# back into a reply and silently reintroduces an unmatchable close-out.
grep -Fq 'board-claim-done:<lane>-<run-id>' "${constitution}" ||
  fail "constitution does not require a matching board-claim-done close-out token"
grep -Fq 'board-claim-done:<lane>-<run-id>' "${run_loop}" ||
  fail "run loop does not require a matching board-claim-done close-out token"
grep -Fq 'board-claim-done:<lane>-<run-id>' "${board_card}" ||
  fail "project-board card does not require a matching board-claim-done close-out token"
grep -Fq 'GitHub issue comments are **flat**' "${constitution}" ||
  fail "constitution does not record WHY close-out is a token rather than a reply (flat comments)"
grep -Fq 'issue comments are FLAT' "${run_loop}" ||
  fail "run loop does not record WHY close-out is a token rather than a reply (flat comments)"
# Abandonment is the half that actually expires a lease, so assert it separately: a close-out rule
# that only covers the finished case would let a run drop the abandon path and still pass.
grep -Fq 'or when abandoning' "${constitution}" ||
  fail "constitution does not require close-out when ABANDONING a board-only claim"

# --- 6. deterministic election instead of symmetric stand-down ------------------------------------
# A symmetric "sibling claim present => stand down" deadlocks: both instances retreat and the work
# is never claimed. Assert both the rule and its deterministic ordering key.
grep -Fq 'elect a winner — never both stand down' "${constitution}" ||
  fail "constitution does not elect a winner when two live board claims overlap"
grep -Fq 'the winner is the earliest `created_at`, tie-broken by' "${constitution}" ||
  fail "constitution does not pin a deterministic winner ordering for overlapping board claims"
grep -Fq 'never both retreat' "${run_loop}" ||
  fail "run loop does not elect a winner when a live foreign board claim exists"
grep -Fq 'ascending comment id' "${run_loop}" ||
  fail "run loop does not pin the comment-id tie-break for overlapping board claims"
grep -Fq 'earliest `created_at` then lowest comment id' "${board_card}" ||
  fail "project-board card does not pin the deterministic election"

# --- 7. the canonical skip test recognises an unclosed foreign token ------------------------------
# The skip test is what a selecting run actually consults, so the board-only form has to appear
# there too — assigned-and-branched alone lets a board-only claim pass and repeat the mutation.
grep -Fq 'unclosed `board-claim:<lane>-<run-id>` comment whose token is not your own' "${constitution}" ||
  fail "canonical skip test does not recognise an unclosed foreign board-claim as a live claim"
grep -Fq 'is a whole-token test, not a lane test' "${constitution}" ||
  fail "canonical skip test does not state that the foreign-claim test is whole-token, not per-lane"

echo "board-claim-token contract: all assertions passed"
