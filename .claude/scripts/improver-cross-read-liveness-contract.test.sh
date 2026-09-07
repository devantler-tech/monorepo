#!/usr/bin/env bash
#
# Guards the LIVENESS PRECONDITION on the Agent Improver's mandated sibling cross-read.
#
# Why this needs a guard. The Improver's core method is reading the sibling instance's scorecard and
# hypothesis store. That store is the one input this instance cannot corroborate from its own lane,
# so it is exactly where a dead sibling silently becomes data — and a FROZEN ledger is byte-for-byte
# indistinguishable from a QUIET one.
#
# The contract already knew this. It did not connect it to the place it is acted on:
#
#   - the WARNING that a frozen ledger corrupts the cross-read sat in *Agent definition locations*,
#     inside the discussion of `last_run_at` and scheduler-pointer drift;
#   - the OBLIGATION to perform the cross-read sat in *Durable memory*;
#   - measured 2026-09-07, they were 4,107 lines apart in unrelated sections, and grepping the whole
#     27-line obligation clause for liveness|outage|frozen|producing returned ZERO matches.
#
# So a run following the obligation literally performed the read with no liveness check. The failure
# is not a missed signal but an INVERTED one: a dead lane's error count falls to zero, so a naive
# read scores it as having IMPROVED. It is also self-concealing — the scheduler's own view stays
# healthy, since `last_run_at` advances across every stub and each is recorded `PENDING_REVIEW`, the
# same status a healthy run carries.
#
# Measured on the run that filed monorepo#3267: the Codex lane was NOT-PRODUCING across 26
# consecutive stub dispatches while its ledger sat ~29 h stale.
#
# Both directions need pinning, and the second is the one a well-meaning tightening would delete:
#
#   1. the precondition and its handling must be present AT THE POINT OF USE, and
#   2. it must stay a NON-blocking check — turning a dead sibling into a run-stopper would be the
#      passive self-blocking the contract forbids everywhere else, and would let one lane's provider
#      quota halt the other lane entirely.
#
# Assertions are scoped to the clause itself rather than the whole file: the warning 4,107 lines away
# would otherwise satisfy every check while the passage that gets executed stayed silent — which is
# precisely the defect being guarded.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "improver cross-read liveness contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract one clause and flatten it. Sentences wrap across source lines, so a fragment spanning a
# line break would never match and the test would be always-red regardless of content. A sentinel
# marks that the END anchor was actually seen, so a missing anchor is detected DIRECTLY rather than
# inferred from how much text got captured — an unanchored capture would run to EOF and match
# fragments belonging to entirely different sections.
#
# Anchors are matched as LITERAL line PREFIXES via index(), never as regexes: `awk -v` applies its
# own escape processing, so an anchor containing `\[` or `\.` arrives mangled and silently matches
# nothing.
#
# The START anchor is the scorecard-store sentence rather than the mandate itself, deliberately. The
# precondition belongs BEFORE the mandate it qualifies, so anchoring on the mandate would place a
# correctly-positioned fix OUTSIDE the captured region and report it missing.
extract_clause() {
  start_lit="$1"
  end_lit="$2"
  sentinel='@@END-ANCHOR-SEEN@@'

  raw="$(
    awk -v s="${sentinel}" -v st="${start_lit}" -v en="${end_lit}" '
      index($0, st) == 1 { ins = 1 }
      ins && seen_first && index($0, en) == 1 { ins = 0; print s }
      ins { seen_first = 1; print }
    ' "${constitution}"
  )"

  case "${raw}" in
    *"${sentinel}"*) ;;
    *) fail "could not locate clause bounded by '${start_lit}' … '${end_lit}' (end anchor never seen)" ;;
  esac

  # `sed` rather than `grep -v`: grep exits 1 when it emits no lines, and under `set -e` +
  # `pipefail` that would abort mid-assignment, killing the test instead of reaching a real failure.
  printf '%s\n' "${raw}" | sed "/^${sentinel}\$/d" | tr '\n' ' ' | tr -s '[:space:]' ' '
}

assert_contains() {
  haystack="$1"; needle="$2"; label="$3"
  case "${haystack}" in
    *"${needle}"*) ;;
    *) fail "${label} — expected to find: ${needle}" ;;
  esac
}

clause="$(extract_clause \
  '   **Agent Improver scorecard store:**' \
  '   **spend evidence/proposal/realisation ledger**')"

# A flattened empty capture becomes a single space, which would silently satisfy nothing below;
# assert real content was captured before testing it.
[ "${#clause}" -gt 600 ] || fail "cross-read clause captured only ${#clause} chars — extraction is broken"

# ---------------------------------------------------------------------------
# 1. The precondition must be present at the point of use, and must name the
#    deployment's own check rather than gesturing at the idea of one.
# ---------------------------------------------------------------------------
assert_contains "${clause}" 'codex-lane-liveness.sh' \
  'the cross-read clause must name the liveness check it depends on'
# shellcheck disable=SC2016  # The backticks are MARKDOWN in the contract text being matched, not
# command substitution. Single quotes are mandatory here: in double quotes the shell would try to
# EXECUTE `1`, so following SC2016 would turn a correct assertion into a bug.
# The verdict mapping must be EXACT, not gestured at. A bare 'producing' needle stays green if the
# clause drops the 1/2 mapping entirely, or permits a verdict while still mentioning "no movement" —
# so the weak form guards the vocabulary rather than the rule (CodeRabbit, PR #3268).
assert_contains "${clause}" '`1` not producing, `2` UNKNOWN' \
  'the clause must define the non-producing and unknown verdicts explicitly'
# shellcheck disable=SC2016  # markdown backticks, as above
assert_contains "${clause}" 'On a `1` or a `2`' \
  'the clause must handle BOTH outage verdicts, not only the not-producing one'

# ---------------------------------------------------------------------------
# 2. The required handling of a dead or unknown lane. Naming the check without
#    saying what its verdict OBLIGES is a check nobody has to act on.
# ---------------------------------------------------------------------------
assert_contains "${clause}" 'blocked by the outage' \
  'a non-producing sibling must have its hypotheses recorded as blocked by the outage'
assert_contains "${clause}" 'no movement' \
  'the clause must forbid the directional / "no movement" reading, which is the inverted-signal case'
# "no movement" alone is the weakest of the three prohibitions: a clause could forbid that phrasing
# while still permitting an outright verdict. Pin all three forms the rule actually names.
assert_contains "${clause}" 'no verdict' \
  'the clause must forbid taking a verdict from a frozen ledger'
assert_contains "${clause}" 'directional reading' \
  'the clause must forbid a directional reading, not only the "no movement" phrasing'

# ---------------------------------------------------------------------------
# 3. The other side of the rule — the one a tightening would delete. A dead
#    sibling must NOT become a run-stopper: that would let one lane's provider
#    quota halt the other lane, which is worse than the mis-read being guarded.
# ---------------------------------------------------------------------------
assert_contains "${clause}" 'never a run-stopper' \
  'a non-producing sibling must explicitly NOT stop the run'

# ---------------------------------------------------------------------------
# 4. The two halves must stay wired together. Without this the reasoning can be
#    deleted from its home section and nothing would notice.
# ---------------------------------------------------------------------------
assert_contains "${clause}" 'Agent definition locations' \
  'the clause must cross-reference the section carrying the measured reasoning'

# ...and that cross-reference must POINT AT SOMETHING. Asserting only that the clause names the
# section is a fail-open: this contract has renamed sections before (the actor was renamed twice),
# and a rename would leave the clause pointing at nothing while this test stayed green — silently
# un-wiring the two halves it exists to keep together. Verified against the heading itself.
grep -q '^### Agent definition locations' "${constitution}" ||
  fail 'the clause cross-references "### Agent definition locations" but no such section exists — the reference has rotted'

echo "improver cross-read liveness contract: PASS — precondition, handling, non-blocking guarantee and cross-reference all present at the point of use"
