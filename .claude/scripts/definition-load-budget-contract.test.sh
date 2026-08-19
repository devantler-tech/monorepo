#!/usr/bin/env bash
#
# Ratchets the byte size of the TEMPORARY `portfolio-surveyor` compatibility overlay.
#
# Why this needs a guard. The overlay is loaded on every `portfolio-surveyor` dispatch, and that
# subagent is 157 of 182 subagent dispatches (86%) in the 7-day corpus measured 2026-08-19. Its
# first-turn `cache_creation` median is 191,397 tokens against `Explore`'s 29,310 — `Explore`
# receives no project instructions and the surveyor does, so the gap is AGENTS.md plus this overlay.
# `cache_read` was 0 on 160 of 161 of those dispatches: every subagent writes the 5-minute cache
# while the surveyor is dispatched roughly hourly, so reuse is structurally zero and every dispatch
# pays the write premium in full. Daily medians rose monotonically 155,212 -> 207,321 across
# 08-13..08-19 — +52,109 tokens per dispatch in a single week — and nothing measured it.
#
# Why the OVERLAY specifically, and not AGENTS.md. This file is declared temporary: the contract
# retains it only until digest parity and allows it to carry only its named deployment/provider
# delta, with generic role logic changing at its owning upstream. That parity gate was reached —
# agent-plugins#78 closed COMPLETED on 2026-07-25 — and the overlay then grew 61,144 B -> 148,356 B
# (+143%) because generic refinements were appended here instead of upstreamed, re-opening the gap
# #78 had just closed. Growth in a file whose declared destination is deletion is always worth a
# deliberate decision. AGENTS.md is deliberately NOT gated: rules legitimately accrete there, and a
# ratchet firing on every definition PR — safety fixes included — would train the raise into a
# reflex and destroy the signal this guard exists to produce.
#
# This guard never vetoes mandated work. Raising the ceiling in the same pull request is always
# available; the ceiling's only job is to make the cost a decision somebody made rather than one
# nobody saw. Assertion 5 is what keeps a raise honest: the ceiling here and the figure quoted in
# AGENTS.md must agree, so a raise cannot land without updating the evidence the next reader weighs
# it against.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
overlay="${repo_root}/.claude/agents/portfolio-surveyor.md"

# The recorded high-water mark, in bytes. Raise this ONLY together with the figure quoted in
# AGENTS.md's *Context & token discipline* section (assertion 5 enforces that pairing).
CEILING_OVERLAY_BYTES=148356

fail() {
  echo "definition-load budget contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"
# The overlay's declared destination is DELETION, so its ABSENCE is success, not a broken anchor.
# Failing here would make this guard fire exactly when the work it exists to encourage completes —
# the guard fighting its own goal. The contract assertions below are skipped with it, because they
# describe a file that no longer exists; retiring this test is then the follow-up.
if [ ! -e "${overlay}" ]; then
  echo "definition-load budget contract: PASS — the temporary surveyor overlay is GONE, which is its declared destination. Retire this guard and its AGENTS.md paragraph in the same pull request that removed the file."
  exit 0
fi

[ -r "${overlay}" ] || fail "${overlay} exists but is unreadable — cannot evaluate the ceiling"

overlay_bytes="$(wc -c < "${overlay}" | tr -d ' ')"

# 0. Integrity, checked by CONTENT rather than by size. A size floor was the obvious choice here and
# is wrong: SHRINKING is the goal, so any floor fires precisely when upstreaming succeeds. The
# frontmatter marker catches a truncated or clobbered file at any size instead.
grep -q '^name: portfolio-surveyor$' "${overlay}" ||
  fail "${overlay} no longer carries its 'name: portfolio-surveyor' frontmatter — the file is truncated or clobbered, so the ceiling check below would pass on a stub. (Do NOT 'fix' this by adding a size floor: shrinking this file is the objective.)"
[ -r "${overlay}" ] || fail "cannot read ${overlay} — the anchor moved, so every assertion below would be vacuous"

# 1. THE RATCHET. This is the regression itself.
[ "${overlay_bytes}" -le "${CEILING_OVERLAY_BYTES}" ] ||
  fail "$(printf '%s' "\
the temporary surveyor overlay grew to ${overlay_bytes} B, over its ${CEILING_OVERLAY_BYTES} B ceiling.
  This file is loaded on ~86% of all subagent dispatches, so every byte is paid roughly hourly with
  zero cache reuse — and its declared destination is DELETION, not growth.
  Two remedies, both legitimate:
    (a) UPSTREAM it. Generic role logic belongs in devantler-tech/agent-plugins, not in this
        temporary overlay. That is the routing rule in *Agent definition locations*, and it also
        moves the overlay closer to the deletion its own checklist describes.
    (b) RAISE the ceiling in THIS pull request, and say why in the PR body. Also update the byte
        figure quoted in AGENTS.md's *Context & token discipline* section — assertion 5 requires
        the two to agree, so the next reader can weigh the raise against real evidence.
  This guard never blocks mandated work; it only makes the cost visible at the moment it is made.")"

# 2. The measurement must stay in the contract. Without this the ceiling decays into an unexplained
# number and nobody can judge whether a raise is reasonable.
grep -qF '191,397' "${constitution}" ||
  fail "AGENTS.md no longer records the measured surveyor first-turn median (191,397 tokens) — the ceiling would become an unexplained constant"
grep -qF '157 of 182 subagent dispatches' "${constitution}" ||
  fail "AGENTS.md no longer records the dispatch share the cost is multiplied by — a raise could not be weighed without it"

# 3. Both remedies must stay named, so the guard keeps failing WITH the fix rather than just failing.
grep -qF 'goes UPSTREAM unless it is a genuine deployment fact' "${constitution}" ||
  fail "AGENTS.md no longer names the upstream remedy in the routing sentence. NOTE: do not weaken this to a bare 'upstream' match — that word appears ~49 times in this contract, so the assertion would pass with this whole section deleted."
grep -qF 'raise the ceiling' "${constitution}" ||
  fail "AGENTS.md no longer names the deliberate-raise remedy, leaving the ceiling looking like a hard veto"

# 4. The DevEx guarantee must stay stated. A ceiling read as a veto is the failure mode that turns a
# visibility guard into the friction tax *Security hardening without a DevEx tax* forbids.
grep -qF 'never vetoes mandated' "${constitution}" ||
  fail "AGENTS.md no longer states that the ceiling never vetoes mandated work"

# 5. CONSERVATION: the ceiling in this file and the byte figure quoted in AGENTS.md must agree.
# This is what stops a silent raise here from drifting away from the evidence over there.
# `|| true` is load-bearing: under `set -euo pipefail` a no-match grep makes this whole
# substitution non-zero, which killed the script BEFORE the explicit check below could report it —
# a guard that cannot announce its own failure. Caught by ablation A5b.
documented="$(grep -oE '61,144 B → [0-9,]+ B' "${constitution}" | head -1 | sed -E 's/.*→ ([0-9,]+) B/\1/' | tr -d ',' || true)"
[ -n "${documented}" ] ||
  fail "could not find the overlay size figure in AGENTS.md (expected the '61,144 B → <N> B' form) — assertions 2-4 anchor on that section, so its loss makes this guard unverifiable"
[ "${documented}" = "${CEILING_OVERLAY_BYTES}" ] ||
  fail "ceiling drift: this test allows ${CEILING_OVERLAY_BYTES} B but AGENTS.md documents ${documented} B. Raise both together, or the recorded evidence stops describing the enforced limit."

echo "definition-load budget contract: PASS — overlay ${overlay_bytes} B / ceiling ${CEILING_OVERLAY_BYTES} B; contract evidence and both remedies intact"
