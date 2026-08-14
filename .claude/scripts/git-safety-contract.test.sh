#!/usr/bin/env bash
#
# Guards the *Git safety* section's ban/alternative pair.
#
# Why this needs a guard at all. The runtime denies `git reset --hard` and the contract bans it, but
# for a long time neither said how to do the thing runs legitimately need: put a freshly-created
# maint worktree onto a PR's head commit. A prohibition with no named alternative does not stop the
# behaviour — it relocates the instruction somewhere unreviewed. Here it landed in durable memory,
# which came to prescribe `fetch` + `reset --hard FETCH_HEAD`, so every *compliant* run reached for a
# command that could never execute. Measured across one day's session corpus: 3-4 denied calls over
# three separate ticks, a standing share of the lane's permission-denial signature.
#
# The failure is worse than one wasted call. A denied COMPOUND call rolls the whole chain back, so
# the `fetch` never runs either; the follow-up then fails on a missing `FETCH_HEAD` and reads like a
# broken gitdir rather than a refusal, and the run diagnoses the wrong thing.
#
# BOTH HALVES ARE PINNED, and that is the point of this file rather than an accident of thoroughness.
# Asserting only that the alternative is named would pass a future edit that "simplifies" the section
# by keeping the alternative and dropping the prohibition — which converts a documentation fix into a
# guardrail loosening, silently, with a green test. Asserting only the ban would let the alternative
# be dropped again and re-open the vacuum this file exists to close. Neither assertion is redundant.
#
# Assertions are scoped to the Git safety section itself, not the whole file. A whole-file check is a
# scope hole: the phrases below appear in the memory/loader prose elsewhere in this repository, so a
# file-wide match would pass while the operative section said nothing.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "git safety contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract ONLY the Git safety section, then flatten it. Flattening matters because every sentence
# below wraps across source lines, so a fragment spanning a line break would never match and the
# test would be always-red regardless of the contract's content.
section="$(
  awk '
    /^### Git safety$/                              { ins = 1; next }
    ins && /^\*\*Worktree hygiene is SCHEDULED/     { ins = 0 }
    ins                                              { print }
  ' "${constitution}" | tr '\n' ' ' | tr -s '[:space:]' ' '
)"

[ -n "${section}" ] ||
  fail "could not locate the '### Git safety' section — the extraction anchor moved, so every assertion below would be vacuous"

# Guard the extraction itself. If the terminating anchor is renamed or removed, awk runs to
# end-of-file and \`section\` becomes the whole rest of the contract — which silently restores the
# scope hole described above while every assertion still passes.
#
# The bound separates two states that are orders of magnitude apart, and it is deliberately NOT set
# just above the current size: the section is ~250 words, while a runaway extraction (end anchor
# gone, awk running to EOF) measures in the tens of thousands. A snug bound would fail every
# legitimate edit to this section while reporting a missing anchor — a false message that sends the
# next reader hunting for a heading that is right there.
section_words="$(printf '%s' "${section}" | wc -w | tr -d ' ')"
[ "${section_words}" -lt 900 ] ||
  fail "Git safety section extracted as ${section_words} words, which is runaway-extraction size — the 'Worktree hygiene is SCHEDULED' end anchor was probably renamed or removed, so these assertions would no longer be scoped to this section"

assert_section() {
  case "${section}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}

# 1. THE BAN SURVIVES. This is the half that keeps the file from becoming a loosening: without it,
#    an edit that drops the prohibition and keeps only the alternative passes green.
assert_section 'Never `git reset --hard`' \
  "the Git safety section no longer bans \`git reset --hard\` — naming a safer alternative must never come at the cost of dropping the prohibition itself"

# 2. THE ALTERNATIVE IS NAMED, with the flag that makes it safe. \`checkout\` alone is not the
#    prescription: it is \`--detach\` onto an explicit commit that reproduces the banned form's
#    outcome, and a bare branch checkout would not.
assert_section 'git -C <wt> checkout --detach <sha>' \
  "the Git safety section does not name \`git -C <wt> checkout --detach <sha>\` as the permitted way to put a worktree on a specific commit, so the ban again has no stated alternative and the instruction migrates to unreviewed memory"

# 3. THE SEPARATE-CALLS REQUIREMENT. Chaining the fetch and the checkout is what turns a refusal into
#    a misdiagnosis, so the prescription is incomplete without it — this is the measured second-order
#    cost, not a style preference.
assert_section 'SEPARATE calls' \
  "the Git safety section does not require the fetch and the checkout to be issued as separate calls — a denied compound call rolls back the fetch too, and the follow-up then fails on a missing FETCH_HEAD in a way that reads like a broken gitdir rather than a refusal"

# 4. THE SWAP IS RECORDED AS SAFE, WITH ITS REASON. The dirty-worktree abort is the whole argument
#    that this needs no permission change; stated without it, a later reader cannot tell this apart
#    from a workaround and may "resolve" it by widening the guard.
assert_section 'aborts and preserves' \
  "the Git safety section does not record that \`checkout --detach\` aborts and preserves uncommitted work on a dirty worktree — that property is what makes this a strictly safer swap rather than a workaround, and without it the next reader may try to widen the guard instead"

echo "git safety contract: OK (${section_words} words scoped)"
