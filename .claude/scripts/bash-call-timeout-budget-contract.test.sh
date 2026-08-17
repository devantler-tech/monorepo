#!/usr/bin/env bash
#
# Guards the *Latency discipline* bullet that stops a `Bash` call being killed by the tool's
# two-minute default timeout.
#
# Why this needs a guard. Measured over the 7 days to 2026-08-17T10:03Z on a single denominator —
# every `Bash` call whose own record falls in that window, measuring session excluded: 26,967 calls
# across 299 sessions. 112 were killed by the timeout and 90 of them (80%) ran at the untouched
# default, costing ~180 minutes of blocked wall-clock that produced nothing. 66 of those 299 sessions
# (22%) lost at least one call that way, at most 5 in any one session — so this is broad behaviour
# rather than one looping run.
#
# The subtle part, and the reason a presence-only check is not enough: 56 of those 66 sessions (85%)
# used `timeout` or `run_in_background` elsewhere in the SAME session. The capability was never
# missing; it was applied only after the first failure had already been paid for. A bullet that
# merely names the parameters therefore fixes nothing — it has to pin (a) that the budget is spent
# up front on the call you are about to make, and (b) that backgrounding, not a bigger timeout, is
# the default answer. Bumping the timeout keeps the foreground block and still returns nothing when
# the work exceeds the ten-minute ceiling, which several of the measured classes do.
#
# Assertions are scoped to the bullet, not the whole file — asserting against the whole constitution
# is a scope hole, since an unrelated section containing the phrase would satisfy the check while the
# real sentence stayed wrong.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "bash-call-timeout-budget contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract ONLY this bullet, then flatten it: the sentences wrap across source lines, so a fragment
# spanning a line break would never match and the test would be always-red regardless of content.
# The end anchor is the section's closing paragraph, which follows this bullet. The extraction emits
# a sentinel line when it sees that anchor, so a missing anchor is detected DIRECTLY rather than
# inferred from the size of what got captured.
sentinel='@@END-ANCHOR-SEEN@@'
extracted="$(
  awk -v s="${sentinel}" '
    /^- \*\*SIZE A `Bash` CALL BEFORE YOU MAKE IT/ { inb = 1 }
    inb && /^This changes only /                   { inb = 0; print s }
    inb                                            { print }
  ' "${constitution}"
)"

end_anchor_seen=0
case "${extracted}" in
  *"${sentinel}"*) end_anchor_seen=1 ;;
esac

# `sed` rather than `grep -v`: grep exits 1 when it emits no lines, and under `set -e` + `pipefail`
# that aborts the script mid-assignment — so a MISSING START ANCHOR would kill the test silently
# instead of reaching the "could not locate" failure below. Verified by ablation on 2026-08-17.
bullet="$(printf '%s\n' "${extracted}" | sed "/^${sentinel}\$/d" | tr '\n' ' ' | tr -s '[:space:]' ' ')"

# Test the RAW extraction, not the flattened bullet. Flattening turns an empty capture into a single
# space, which is non-empty — so a `-n "${bullet}"` test passes on a missing START anchor and the
# failure surfaces later as a misleading "end anchor was never reached". Verified by ablation.
[ -n "${extracted}" ] ||
  fail "could not locate the size-the-call bullet — the start anchor moved, so every assertion below would be vacuous"

# Guard the extraction itself, DIRECTLY. If the terminating anchor disappears, awk runs to
# end-of-file and `bullet` becomes the rest of the contract, silently restoring the scope hole while
# every assertion still passes.
#
# A word-count bound alone does NOT close this. It only fires because a lot of file happens to follow
# this bullet today: measured 2026-08-17, deleting the anchor captures 7,544 words, so the bound
# catches it — but the bound is a proxy for "something else came after", and it silently stops working
# the moment this bullet becomes the last content in the file. Requiring the anchor to have been SEEN
# holds in that case too, which the size bound cannot.
[ "${end_anchor_seen}" -eq 1 ] ||
  fail "the closing-paragraph end anchor was never reached, so the extraction ran to end-of-file and these assertions are no longer scoped to this bullet"

# Kept as a second, independent signal: it catches an anchor that still EXISTS but has moved far below
# the bullet, which the seen-check above would happily accept.
bullet_words="$(printf '%s' "${bullet}" | wc -w | tr -d ' ')"
[ "${bullet_words}" -lt 1000 ] ||
  fail "bullet extracted as ${bullet_words} words, which is runaway-extraction size — the closing-paragraph end anchor probably moved below unrelated content, so these assertions would no longer be scoped to this bullet"

assert_bullet() {
  case "${bullet}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}

# 1. The number itself. Without it the reader has no budget to size against and cannot tell whether
#    the call they are about to make is near the limit.
assert_bullet 'default budget is TWO MINUTES' \
  "the bullet does not state the two-minute default, leaving the reader with no budget to size against"

# 2. The ceiling, in the units the parameter actually takes. A reader who knows only the default will
#    reach for a bigger number without knowing where the number stops being available.
assert_bullet '600000' \
  "the bullet does not name the ten-minute ceiling in milliseconds, so a reader raising the timeout cannot tell where the parameter stops helping"

# 3. The consequence is stated as total loss. An agent that believes the command half-ran will debug
#    the pipeline instead of the budget — the same misreading that keeps the neighbouring
#    classifier-denial signature alive.
assert_bullet 'loses the WHOLE call' \
  "the bullet does not state that the entire call is lost, so a timeout reads as partial progress rather than discarded work"

# 4. THE TIMING CLAIM, and the assertion most likely to be cut as redundant by someone who reads the
#    bullet as "use the timeout parameter". It is not redundant: it is the measured finding that
#    distinguishes this defect from a missing-capability one. 85% of the sessions that paid already
#    used these parameters elsewhere, so a rule that only names them changes nothing.
assert_bullet '85%' \
  "the bullet does not record that the sessions which lost a call already used these parameters elsewhere, so it reads as teaching a parameter rather than fixing when it is chosen"

# 5. The classes that actually recur here, so the rule is actionable on sight instead of requiring a
#    judgement call about whether this particular command is slow. EVERY class is asserted separately,
#    not just one: pinning a single class leaves the other three deletable with the test still green,
#    and the list is the part a reader acts on — verified 2026-08-17 by removing the test-suite and
#    corpus-scan classes, which a one-class assertion passed.
assert_bullet 'contract-test-suite runs' \
  "the bullet no longer names contract-test-suite runs, the largest measured over-budget class"
assert_bullet 'portfolio sweeps' \
  "the bullet no longer names gh portfolio sweeps as an over-budget class"
assert_bullet 'corpus scans over the session transcripts' \
  "the bullet no longer names corpus scans over the session transcripts as an over-budget class"
assert_bullet '`ksail` validations' \
  "the bullet no longer names ksail validations as an over-budget class"

# 6. THE PRESCRIPTION, and the wrong reflex it displaces. Raising the timeout keeps the foreground
#    block and still returns nothing past the ceiling; backgrounding costs no wall-clock because the
#    runtime announces completion. Without this the reader complies by bumping the number and
#    converts a two-minute loss into a ten-minute one.
assert_bullet 'run_in_background: true' \
  "the bullet does not prescribe backgrounding as the default answer, so the reader complies by raising the timeout and keeps the foreground block"

# 7. The reason backgrounding is not merely a bigger budget. This is what ties the rule to the rest of
#    the section: the announcement is why a backgrounded call needs no waiting at all.
assert_bullet 'announces its completion' \
  "the bullet does not say the runtime announces a backgrounded call's completion, so backgrounding looks like a way to lose the result rather than a way to avoid waiting for it"

# 8. Closes the obvious wrong turn out of assertion 6: an agent told to background a long call is one
#    step from sleeping on its output file, which is the busy-wait this same section forbids and a
#    signature this corpus has repeatedly produced.
assert_bullet 'do not then poll what you backgrounded' \
  "the bullet prescribes backgrounding without ruling out polling its output, inviting the sleep-and-read busy-wait the section already forbids"

echo "bash-call-timeout-budget contract: OK — 11 assertions passed"
