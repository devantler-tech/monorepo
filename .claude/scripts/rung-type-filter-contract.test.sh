#!/usr/bin/env bash
#
# Guards the rung-2/3 type filter in *The work-selection ladder*.
#
# Why this needs a guard. `gh search issues` returns ZERO rows for a QUOTED issue-type filter and
# exits 0 while doing it. Measured across the portfolio on 2026-08-18: `type:"Security"` returned 0
# against 73 genuinely open, and `type:"Bug"` returned 0 against 269. A run that builds its rung-2/3
# query by retyping a quoted literal therefore descends straight past every open Security and Bug
# issue and reports a clean sweep — and nothing in gh's exit status distinguishes that from an empty
# queue, which is what makes it silent rather than merely wrong.
#
# The contract itself was the source of that literal: rungs 2 and 3 wrote `type:"Security"` and
# `type:"Bug"`, so following the ladder as written produced the failure. That is why the assertion
# is on the LADDER ROWS specifically and not on the file: the quoted form is still correct English
# elsewhere in the contract when naming a type rather than issuing a query (`type:"Spike"` in the
# Spike carve-out, `type:"Epic"` in the hierarchy section), and a whole-file ban would either fail
# on those or force them into a query form they are not.
#
# Assertion 3 pins the measurement rather than only the fix. Without it the warning can decay into
# "use the unquoted form" with no evidence, and the next reader who finds a quoted literal that
# happens to work on some other surface has nothing to weigh it against.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "rung type-filter contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract ONLY the ladder's rung rows. Anchored on the table's own row markers so an unrelated
# section mentioning a type filter cannot satisfy — or break — these assertions.
rows="$(
  awk '
    /^\| \*\*2\*\* \| \*\*Security issues\*\*/ { print }
    /^\| \*\*3\*\* \| \*\*Bugs\*\*/            { print }
  ' "${constitution}"
)"

[ -n "${rows}" ] ||
  fail "could not locate the rung-2/rung-3 ladder rows — the anchor moved, so every assertion below would be vacuous"

# Both rows, and only those two. A changed table shape that matched more rows would widen the scope
# silently; one that matched fewer would make an assertion pass by absence.
row_count="$(printf '%s\n' "${rows}" | wc -l | tr -d ' ')"
[ "${row_count}" = "2" ] ||
  fail "expected exactly 2 ladder rows (rung 2 and rung 3), found ${row_count} — the extraction anchor is wrong"

# 1. The rung rows must not carry a quoted type filter. This is the regression itself.
case "${rows}" in
  *'type:"'*)
    fail 'a rung row writes a QUOTED type filter (type:"X"). gh search issues returns 0 rows for that form and exits 0, so a run following the ladder skips every open Security and Bug issue. Use the unquoted type:Security / type:Bug.'
    ;;
esac

# 2. Both rows must still actually name their type filter — otherwise assertion 1 passes by absence.
printf '%s\n' "${rows}" | grep -q 'type:Security' ||
  fail "the rung-2 row no longer names type:Security, so assertion 1 would pass with no filter present at all"
printf '%s\n' "${rows}" | grep -q 'type:Bug' ||
  fail "the rung-3 row no longer names type:Bug, so assertion 1 would pass with no filter present at all"

# 3. The warning that explains WHY must survive, with its measurement. Flattened, because the
# sentences wrap across source lines.
warning="$(
  awk '
    /^🔴 \*\*Write that type filter UNQUOTED/ { inw = 1 }
    inw && /^Then \*\*capture any new finds/  { inw = 0 }
    inw                                       { print }
  ' "${constitution}" | tr '\n' ' ' | tr -s '[:space:]' ' '
)"

[ -n "${warning}" ] ||
  fail "the unquoted-type-filter warning is gone; the rung rows would then be a bare convention with nothing recording why"

case "${warning}" in
  *'returns ZERO rows'*) ;;
  *) fail "the warning no longer states that the quoted form returns zero rows — the trap it exists to name" ;;
esac

case "${warning}" in
  *'73'*) ;;
  *) fail "the warning no longer carries its measured Security count, so the claim is unfalsifiable" ;;
esac

case "${warning}" in
  *'269'*) ;;
  *) fail "the warning no longer carries its measured Bug count, so the claim is unfalsifiable" ;;
esac

# 4. The standing generalisation must stay attached: this is one instance of it, not a one-off.
case "${warning}" in
  *'empty FILTERED read is a claim about the FILTER'*) ;;
  *) fail "the warning no longer ties back to the standing rule that an empty filtered read is a claim about the filter" ;;
esac

echo "rung type-filter contract: OK — rungs 2/3 use the unquoted form, and the measured warning is intact"
