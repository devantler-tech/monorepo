#!/usr/bin/env bash
#
# Guards monorepo#2265: board-only claims (path-less project-board mutations) must carry a unique,
# greppable per-lane token. Every instance comments as `devantler`, so the disclosure line alone
# cannot tell siblings apart — without `board-claim:<lane>`, two runs racing the same board issue
# cannot recognise each other's claim, and the ~2h lease + reply-to-close rule has nothing durable
# to key on.
#
# Pins four properties across the contract + run-loop + board product card:
#   1. the greppable token template exists;
#   2. the three live lanes are the only admitted values;
#   3. the lease is timed from the comment's created_at (not assignment — there is none);
#   4. close-out is a reply to the claim comment.
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

grep -Fq 'board-claim:<lane>' "${constitution}" ||
  fail "constitution does not require the greppable board-claim:<lane> token"
grep -Fq 'exactly `claude`, `codex`, or `cursor`' "${constitution}" ||
  fail "constitution does not pin the three live lanes as the only admitted board-claim values"
grep -Fq "timed from the comment's \`created_at\`" "${constitution}" ||
  fail "constitution does not time the board-only lease from the claim comment's created_at"
grep -Fq 'Reply to your own claim comment when finished' "${constitution}" ||
  fail "constitution does not require reply-to-close on a board-only claim"
# Abandonment is the half that actually expires a lease, so assert it separately: a close-out rule
# that only covers the finished case would let a run drop the abandon path and still pass.
grep -Fq '(or when abandoning)' "${constitution}" ||
  fail "constitution does not require close-out when ABANDONING a board-only claim"
# The skip test is what a selecting run actually consults, so the board-only form has to appear
# there too — assigned-and-branched alone lets a board-only claim pass and repeat the mutation.
grep -Fq 'unreplied `board-claim:<lane>` comment from a different lane' "${constitution}" ||
  fail "canonical skip test does not recognise a board-only claim as a live claim"

grep -Fq 'board-claim:<lane>' "${run_loop}" ||
  fail "portfolio-maintenance board Act step does not require board-claim:<lane>"
grep -Fq '`board-claim:claude`' "${run_loop}" ||
  fail "run loop has no concrete lane example an instance can copy"
grep -Fq "timed from the comment's \`created_at\`" "${run_loop}" ||
  fail "run loop does not time the board-only lease from created_at"
grep -Fq 'reply to your own claim' "${run_loop}" ||
  fail "run loop does not require reply-to-close on a board-only claim"

grep -Fq 'board-claim:<lane>' "${board_card}" ||
  fail "project-board card Mutation safety does not mention board-claim:<lane>"

echo "board-claim-token contract: all assertions passed"
