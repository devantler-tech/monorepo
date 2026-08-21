#!/usr/bin/env bash
#
# Guards the *Cadence & focus* supersession notice that stops the historical `161/161` reading being
# taken for a current property of the Codex lane.
#
# Why this needs a guard. `161/161` measured DISPATCH — the scheduler started a run in every scheduled
# slot across 2026-08-02→08-08. It is contrasted there against the Claude lane's drop rate, so a run
# reads it as "Codex is the dependable lane". That inference does not follow from what was measured:
# a dispatch is recorded when a turn STARTS, so a lane whose every turn dies seconds in scores
# 161/161 exactly like a healthy one. Measured 2026-08-17, that is not hypothetical — 32 consecutive
# dead dispatches across both Codex automations, every scheduler-side signal reading healthy
# (monorepo#2885/#2886). Re-measured 2026-08-18 for this change: `codex-lane-liveness.sh` reports both
# automations NOT-PRODUCING against the live store and `OK` against the same store pinned inside
# 2026-08-16 — one store, one check, opposite verdicts.
#
# The measurement itself must NOT be rewritten: *Enhancement work → Documentation* preserves
# measurement records verbatim, and falsifying the record to fix an inference drawn from it is the
# worse defect. So this test pins BOTH halves — the historical reading survives byte-identical, AND a
# dated notice beside it separates dispatch reliability from production.
#
# Assertions are scoped to the section, not the whole file: asserting against the whole constitution
# is a scope hole, because an unrelated section carrying the phrase would satisfy the check while the
# real passage stayed wrong.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "codex-dispatch-supersession contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract ONLY this section, then flatten it: the sentences wrap across source lines, so a fragment
# spanning a line break would never match and the test would be always-red regardless of content.
# The extraction emits a sentinel when it sees the end anchor, so a missing anchor is detected
# DIRECTLY rather than inferred from the size of what got captured.
sentinel='@@END-ANCHOR-SEEN@@'
extracted="$(
  awk -v s="${sentinel}" '
    /^🔴 \*\*Scheduled is not delivered/          { ins = 1 }
    ins && /^\*\*So never time anything off /     { ins = 0; print s }
    ins                                           { print }
  ' "${constitution}"
)"

end_anchor_seen=0
case "${extracted}" in
  *"${sentinel}"*) end_anchor_seen=1 ;;
esac

# `sed` rather than `grep -v`: grep exits 1 when it emits no lines, and under `set -e` + `pipefail`
# that aborts the script mid-assignment — so a MISSING START ANCHOR would kill the test silently
# instead of reaching the "could not locate" failure below.
section="$(printf '%s\n' "${extracted}" | sed "/^${sentinel}\$/d" | tr '\n' ' ' | tr -s '[:space:]' ' ')"

# Test the RAW extraction, not the flattened section. Flattening turns an empty capture into a single
# space, which is non-empty — so a `-n "${section}"` test passes on a missing START anchor and the
# failure surfaces later as a misleading "end anchor was never reached".
[ -n "${extracted}" ] ||
  fail "could not locate the 'Scheduled is not delivered' section — the start anchor moved, so every assertion below would be vacuous"

# Guard the extraction itself, DIRECTLY. If the terminating anchor disappears, awk runs to
# end-of-file and the capture becomes the rest of the contract, silently restoring the scope hole
# while every assertion still passes.
[ "${end_anchor_seen}" -eq 1 ] ||
  fail "the section's end anchor was never reached — the capture ran to end-of-file, so the assertions below are no longer scoped to this section"

has() {
  case "${section}" in
    *"$1"*) return 0 ;;
    *)      return 1 ;;
  esac
}

# 1. The HISTORICAL RECORD survives BYTE-FOR-BYTE.
#
# Three fragment assertions are NOT enough, and the difference is the whole point of this half: a
# fragment check pins the number, the window and the denominator while leaving every other byte of
# the paragraph free to be edited — its prose, its Markdown, its wrapping, the order of its clauses.
# A measurement record is preserved verbatim, so what has to be asserted is the record, not three
# quotations from it. This compares the RAW block (never the flattened one, which would collapse the
# whitespace and line structure that "verbatim" is precisely about) against the literal below.
# `read -r -d ''` rather than `$(cat <<EOF …)`: bash 3.2 (the macOS default) scans a command
# substitution for quotes and parens WITHOUT skipping heredoc bodies, so the apostrophe in
# "Claude's" below makes it die with `unexpected EOF while looking for matching `)''`. It parses
# fine under bash 5, so CI would have gone green while every macOS run failed — verified 2026-08-18.
IFS= read -r -d '' historical_expected <<'HISTORICAL' || true
🔴 **Scheduled is not delivered — on the Claude lane about one tick in five never happens.** The two
machine-local schedulers differ. Measured across 2026-08-02T03:50Z → 2026-08-08T19:50Z (**161 scheduled
slots per lane**), **Codex dispatched 161/161**, because that scheduler starts a run even when the
previous one is still open — one run whose record stayed open for 240 minutes did not block any of the
four ticks behind it. Claude's refuses any dispatch that would overlap the previous run of the same
task and records it as `per_task_limit`. The reading over that same window was
**Claude dispatched 108/161** — 53 ticks, 32.9% — with 36.6% over 2026-08-01→08-07. Those measurements
are preserved as what they were; **both overstate the loss, and the cause is the METHOD, not the lane.**
HISTORICAL
# `read -d ''` keeps the body's trailing newline; `$(…)` strips it from the actual. Strip it here so
# the comparison is between the same two things.
historical_expected=${historical_expected%$'\n'}

# Read the block back from the file the same way: from the start anchor through the line that ends
# the historical paragraph. `awk` exits at that line, so a later paragraph cannot pad the capture.
historical_actual="$(
  awk '
    /^🔴 \*\*Scheduled is not delivered/ { ins = 1 }
    ins                                  { print }
    ins && /not the lane\.\*\*$/         { exit }
  ' "${constitution}"
)"

[ -n "${historical_actual}" ] ||
  fail "could not capture the historical block — its start anchor moved, so the byte comparison below would be vacuous"

if [ "${historical_actual}" != "${historical_expected}" ]; then
  fail "the historical measurement block is no longer byte-identical — a measurement record is preserved verbatim, never rewritten to match a later reading. Diff it against the literal in this test before changing either."
fi

# 2. A DATED notice sits beside it. The date is asserted by SHAPE, not by value: pinning today's date
#    would make a legitimate re-dating fail, while dropping the date entirely is exactly the defect —
#    an undated correction becomes the next standing claim.
printf '%s' "${section}" | grep -Eq 'SUPERSEDING NOTICE \(20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)' ||
  fail "no dated 'SUPERSEDING NOTICE (YYYY-MM-DD)' beside the measurement — an undated correction is read as a standing property in its turn"

# 3. The notice states the DISTINCTION, which is the whole content of the fix. Without this the
#    notice could be a bare pointer that never says what 161/161 did and did not measure.
has 'measured DISPATCH, and dispatch is not PRODUCTION' ||
  fail "the notice does not separate what was measured (dispatch) from what is inferred (production)"
has 'a dispatch is recorded' ||
  fail "the notice does not state the mechanism — that a dispatch is recorded when a turn starts, which is why a dead lane scores like a healthy one"

# 4. It names the CHECK that answers the second question. A correction that leaves no way to
#    establish production replaces one unanswerable claim with another.
has 'codex-lane-liveness.sh' ||
  fail "the notice does not name codex-lane-liveness.sh, so it removes an inference without supplying the measurement that replaces it"

# 5. It refuses to become the next standing claim. This is the self-limiting half: the notice reports
#    a dated reading of its own, and must say that reading is not durable either.
has 'never inherit it' ||
  fail "the notice does not require production to be re-derived rather than inherited"
has 'neither is a standing property of any lane' ||
  fail "the notice does not mark its OWN reading as dated — a correction that presents itself as permanent recreates the defect it fixes"

echo "codex-dispatch-supersession contract: OK — historical measurement intact, dated supersession notice present and self-limiting"
