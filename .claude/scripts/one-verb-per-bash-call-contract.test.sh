#!/usr/bin/env bash
#
# Guards the *Latency discipline* bullet that stops a `Bash` call being refused by the auto-mode
# classifier because it prefixes the real command with `cd` or a variable assignment.
#
# Why this needs a guard. Measured over the 7 days to 2026-08-16 across the Claude session corpus:
# 58 auto-mode classifier denials across 15 distinct sessions. The 27 multi-statement ones span 12
# sessions, and 25 of those 27 open with `cd ` (18) or a variable assignment (7) before the verb that
# matters. Each denial loses the whole call, so the setup in front of the verb is discarded with it.
#
# The subtle part, and the reason a presence-only check is not enough: the guard is PROBABILISTIC on
# this shape. The same `cd … ; <verb>` spelling usually succeeds, so a lane reads the occasional
# refusal as noise and keeps the habit — one measured session led every Bash call with `cd <worktree>`
# and paid for it repeatedly. A bullet that merely says "prefer one verb" without pinning (a) that the
# prefix is unnecessary because the working directory persists, and (b) that the recovery is to SPLIT
# rather than re-spell, leaves the reader with no reason to change and no working next step.
#
# Assertions are scoped to the bullet, not the whole file — asserting against the whole constitution
# is a scope hole, since an unrelated section containing the phrase would satisfy the check while the
# real sentence stayed wrong.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "one-verb-per-bash-call contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract ONLY this bullet, then flatten it: the sentences wrap across source lines, so a fragment
# spanning a line break would never match and the test would be always-red regardless of content.
# The end anchor is the raw-control-byte bullet that follows it.
bullet="$(
  awk '
    /^- \*\*Put ONE verb in a / { inb = 1 }
    inb && /^- \*\*A raw /      { inb = 0 }
    inb                         { print }
  ' "${constitution}" | tr '\n' ' ' | tr -s '[:space:]' ' '
)"

[ -n "${bullet}" ] ||
  fail "could not locate the one-verb-per-call bullet — the extraction anchor moved, so every assertion below would be vacuous"

# Guard the extraction itself. If the terminating anchor disappears, awk runs to end-of-file and
# `bullet` becomes the rest of the contract, silently restoring the scope hole while every assertion
# still passes. The bound separates two states an order of magnitude apart (this bullet is ~250 words;
# a runaway extraction measures thousands), so it does not fail legitimate edits.
bullet_words="$(printf '%s' "${bullet}" | wc -w | tr -d ' ')"
[ "${bullet_words}" -lt 1000 ] ||
  fail "bullet extracted as ${bullet_words} words, which is runaway-extraction size — the raw-control-byte end anchor was probably renamed or removed, so these assertions would no longer be scoped to this bullet"

assert_bullet() {
  case "${bullet}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}

# 1. The consequence is stated as total loss of the call. An agent that believes the command half-ran
#    will debug the pipeline instead of the shape, which is how this signature survived undiagnosed.
assert_bullet 'loses the **whole call**' \
  "the bullet does not state that the entire Bash call is lost, so the failure reads as partial or retryable"

# 2. THE BOUNDARY, and it is the assertion most likely to be "simplified" away by someone who checks
#    the runtime docs and reads "working directory persists between calls" as unconditional. It is
#    not: probed directly on 2026-08-16, a cd INSIDE the session worktree persists to the next call,
#    while a cd outside it is silently reset. Without this warning the obvious compliance route —
#    set the directory once, then use relative paths — resolves those paths in the wrong tree and
#    still reports success, which is the failure this deployment has already paid for once.
assert_bullet 'silently reset' \
  "the bullet does not warn that a cd outside the workspace is silently reset, so the reader complies by setting the directory once and has relative paths resolve in the wrong tree"

# 3. The location-carrying alternatives are named concretely. Assertion 2 says the prefix is
#    unnecessary; this says what to write instead in the cases that actually recur here.
assert_bullet 'git -C <path>' \
  "the bullet does not name the location-carrying alternatives (git -C / gh --repo / absolute path), leaving the reader without a concrete replacement"

# 4. THE REASON IT PERSISTS. This is the assertion that distinguishes a useful rule from a restatement:
#    while the guard is read as deterministic, an agent whose cd-prefixed calls keep succeeding
#    concludes the rule does not apply to it.
assert_bullet 'PROBABILISTIC on this shape' \
  "the bullet does not warn that the denial is probabilistic, so a lane whose cd-prefixed calls usually pass will keep the habit"

# 5. The recovery, and the wrong recovery it displaces. Re-spelling a denied content shape burns
#    another call to learn nothing; splitting is what has actually worked.
assert_bullet 'never re-issue a variant spelling' \
  "the bullet does not rule out re-spelling a denied call, so the reader retries instead of splitting"

# 6. The guard is not the defect. Without this, a reader hitting the denial while doing mandated work
#    is one step from proposing a permission change — the one direction this contract reserves.
assert_bullet 'Never touch the permission surface' \
  "the bullet does not forbid working around the denial via the permission surface, inviting a guard change instead of a command change"

# 7. The form that is correct regardless of which side of the boundary the path is on. Assertion 2
#    says the shortcut is unsafe; this names the one spelling that always works, so the warning does
#    not leave the reader stuck.
assert_bullet 'Absolute paths are the only form' \
  "the bullet warns about the cwd boundary without naming absolute paths as the form that is correct on both sides of it"

echo "one-verb-per-bash-call contract: OK — 7 assertions passed"
