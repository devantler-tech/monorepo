#!/usr/bin/env bash
#
# Guards the *Latency discipline* bullet that stops a `Bash` command being rejected outright for
# carrying a raw control byte.
#
# Why this needs a guard. The runtime refuses such a call with `InputValidationError: command
# contains control characters that would be hidden in the approval dialog`. Nothing is partially
# applied — the call never runs — and the message names neither the offending byte nor its position,
# so a lane rediscovers the limit by improvising a second spelling of the same command. Measured over
# the 7 days to 2026-08-15: 18 occurrences across 14 distinct sessions, spread over 10+ branches in
# both the routine and the maintainer-interactive lanes.
#
# The subtle part, and the reason a presence-only check is not enough: the OBVIOUS diagnosis is
# wrong. Issue #2773 hypothesised "raw newlines and tabs ... inlining a multi-line jq program", and
# a fix written to that hypothesis ("put the program in a file") addresses nothing, because a raw
# newline and a raw tab are both ACCEPTED. The bytes that actually fire the guard are the
# non-whitespace C0 delimiters chosen as collision-proof separators — measured census NUL x5,
# SOH x5, US x4, SOH+STX x2. So assertion 3 pins the correction itself: while the contract can be
# read as blaming newlines/tabs, the reader is sent to a fix that cannot work.
#
# Assertions are scoped to the bullet, not the whole file — asserting against the whole constitution
# is a scope hole, since an unrelated section containing the phrase would satisfy the check while the
# real sentence stayed wrong. Assertion 8 is deliberately the exception and is whole-file by design.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "control-character command contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract ONLY this bullet, then flatten it: the sentences wrap across source lines, so a fragment
# spanning a line break would never match and the test would be always-red regardless of content.
#
# The end anchor is the NEXT BULLET, not the section's closing paragraph. It has to be: the
# size-the-call bullet that follows also contains the phrase `loses the WHOLE call`, so a
# paragraph-anchored extraction spans both and assertion 1 becomes satisfiable by the neighbour.
# Verified by ablation on 2026-08-17 — with that phrase removed from THIS bullet and left intact in
# the next one, the paragraph-anchored version still reported all 8 assertions passing. The closing
# paragraph is kept as a second stop so the extraction still terminates if that bullet is renamed.
bullet="$(
  awk '
    /^- \*\*A raw /             { inb = 1 }
    inb && /^- \*\*SIZE A /     { inb = 0 }
    inb && /^This changes only/ { inb = 0 }
    inb                         { print }
  ' "${constitution}" | tr '\n' ' ' | tr -s '[:space:]' ' '
)"

[ -n "${bullet}" ] ||
  fail "could not locate the raw-control-byte bullet — the extraction anchor moved, so every assertion below would be vacuous"

# Guard the extraction itself. If the terminating anchor disappears, awk runs to end-of-file and
# `bullet` becomes the rest of the contract, silently restoring the scope hole while every assertion
# still passes. The bound separates two states an order of magnitude apart (this bullet is ~330
# words; a runaway extraction measures thousands), so it does not fail legitimate edits.
bullet_words="$(printf '%s' "${bullet}" | wc -w | tr -d ' ')"
[ "${bullet_words}" -lt 1200 ] ||
  fail "bullet extracted as ${bullet_words} words, which is runaway-extraction size — the 'This changes only' end anchor was probably renamed or removed, so these assertions would no longer be scoped to this bullet"

assert_bullet() {
  case "${bullet}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}

# 1. The consequence is stated as total loss of the call, not a partial or retryable failure. An
#    agent that believes the command half-ran will debug the pipeline instead of the spelling.
assert_bullet 'loses the WHOLE call' \
  "the bullet does not state that the entire Bash call is lost, so the failure reads as partial or retryable"

# 2. The rejected class is named precisely in the HEADLINE claim. Without this the headline can say
#    "raw control byte" while the paragraph below says newline and tab are accepted — and a newline
#    and a tab ARE control bytes, so the bullet contradicts itself and reads as a ban on multi-line
#    commands. The two halves must agree, so the classification is pinned where the rule is stated.
assert_bullet 'raw non-whitespace C0 control byte' \
  "the bullet does not identify raw non-whitespace C0 control bytes as the rejected class, so its headline contradicts its own newline/tab carve-out"

# 3. THE CORRECTION. Without this the natural (and measured-false) 'newlines and tabs' reading
#    survives, and the reader is sent to a fix that changes nothing.
assert_bullet 'NOT "newlines and tabs"' \
  "the bullet does not correct the measured-false 'newlines and tabs' diagnosis, so the reader is sent to a fix that cannot work"

# 4. The accepted bytes are named explicitly. Assertion 3 says what the cause is not; this says what
#    is safe, which is what stops the over-correction of banning multi-line commands outright.
assert_bullet 'are both **accepted**' \
  "the bullet does not state that a raw newline and a raw tab are accepted, inviting an over-correction that bans multi-line commands"

# 5. The named alternative. A prohibition that does not say what to write instead is the DevEx tax
#    this repo's own hardening rule forbids, and it is what relocates the real instruction into
#    somewhere unreviewed.
assert_bullet "\$'\\x1f'" \
  "the bullet forbids the raw byte without naming the ANSI-C quoting alternative that emits the same byte"

# 6. The jq form, which is a different spelling from the shell one and is the case that actually
#    recurs in this deployment's TSV-shaped mining pipelines.
assert_bullet 'jq string escape' \
  "the bullet does not give the jq escape form, so a jq program is left with no stated alternative"

# 7. The comment trap. The code can be correct while the annotation explaining it costs the call —
#    reproduced live while this bullet was being written.
assert_bullet 'comments included' \
  "the bullet does not warn that the guard scans comments too, so a command whose code is fixed can still fail on its own annotation"

# 8. WHOLE-FILE, and deliberately so. The contract must not itself contain a raw control byte: it is
#    quoted, copied and grepped constantly, and a non-printing byte is invisible in review. This is
#    not hypothetical — the first draft of this very bullet embedded a raw 0x1F inside the backticks
#    meant to display the jq escape, so the rule forbidding raw control bytes was itself written with
#    one. `perl` rather than `grep -P`: on this host `grep` is a ugrep wrapper function whose -P
#    support is not reliably present, so a grep-based check can fail open.
if ! command -v perl >/dev/null 2>&1; then
  fail "perl is required for the raw-control-byte scan; without it assertion 8 would silently pass"
fi
raw_count="$(perl -ne '$n++ if /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/; END{print $n+0}' "${constitution}")"
[ "${raw_count}" = "0" ] ||
  fail "AGENTS.md contains ${raw_count} line(s) with a raw control byte — invisible in review, and the non-whitespace C0 bytes among them are rejected outright by the Bash guard; write the byte as an escape (\$'\\x1f', or the jq \\u001f form)"

echo "control-character command contract: OK — 8 assertions passed"
