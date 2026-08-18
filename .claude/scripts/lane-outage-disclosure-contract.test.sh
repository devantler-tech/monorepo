#!/usr/bin/env bash
#
# Guards the disclosure rule for a lane / provider outage's CAUSE.
#
# Why this needs a guard. Two parts of the definition answered one question in opposite directions,
# and the deployment did both:
#
#   - `codex-lane-liveness.sh` treats "billing, credentials, account posture" as private runtime
#     state it "must not be able to carry into a repository artifact or a run report".
#   - *Issue-driven → Drain oldest-first* skip clause (b) REQUIRES a public `**Blocker:**` line
#     naming the blocker and its last-verified result, and calls a merely-prose note
#     under-specified. `devantler-tech/monorepo` is public, so that record is a public artifact.
#
# Measured 2026-08-18: an open blocked issue in this repo carried provider account posture — a
# cross-vendor exhaustion correlation and an exact reset timestamp — while the check that detects
# the same condition was forbidden from reading its cause at all.
#
# The resolution splits by GRANULARITY, as *Sensitive information stays private* already does for a
# security finding: the bounded cause CLASS is publishable, the supporting DETAIL is not. Both
# halves need pinning, and the second is the one a well-meaning tightening would delete:
#
#   1. the detail list must stay private, and
#   2. the cause class must stay PUBLISHABLE — resolving the contradiction by making everything
#      private would silently break every blocker line, which is the failure mode clause (b) exists
#      to prevent. A guard on half of a two-sided rule invites exactly the wrong repair.
#
# Assertions are scoped to their own section rather than the whole file: an unrelated section
# carrying a phrase would otherwise satisfy the check while the real passage stayed wrong.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "lane-outage-disclosure contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract one section and flatten it. Sentences wrap across source lines, so a fragment spanning a
# line break would never match and the test would be always-red regardless of content. A sentinel
# marks that the END anchor was actually seen, so a missing anchor is detected DIRECTLY instead of
# being inferred from how much text got captured — an unanchored capture would otherwise run to EOF
# and match fragments belonging to entirely different sections.
#
# Anchors are matched as LITERAL line PREFIXES via index(), never as regexes. `awk -v` applies its
# own escape processing to a variable's value, so a regex anchor containing `\[` or `\.` arrives
# mangled and silently matches nothing — which is exactly how this test first failed against a file
# that already contained the text it was looking for.
extract_section() {
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
    *) fail "could not locate section bounded by '${start_lit}' … '${end_lit}' (end anchor never seen)" ;;
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

# ---------------------------------------------------------------------------
# 1. The doctrine itself, inside *Sensitive information stays private*.
# ---------------------------------------------------------------------------
privacy="$(extract_section '### Sensitive information stays private' '### Local agent host')"

# A flattened empty capture becomes a single space, which would silently satisfy nothing below;
# assert real content was captured before testing it.
[ "${#privacy}" -gt 400 ] || fail "privacy section captured only ${#privacy} chars — extraction is broken"

assert_contains "${privacy}" 'provider and account posture' \
  'the doctrine must state that provider/account posture is governed by this rule'

# Backticked so each match is unambiguous: bare `unknown` could be satisfied by a future sentence,
# and an assertion a passing sentence satisfies by accident guards nothing.
for cls in '`quota/billing`' '`credentials/auth`' '`runtime/config`' '`unknown`'; do
  assert_contains "${privacy}" "${cls}" "the publishable cause classes must be enumerated (${cls})"
done

# The remaining publishable rows. Without these the table's LEFT column could be emptied row by row —
# reaching the same "make it all private" end state the two-sided assertions below guard against, but
# by deleting rows rather than by deleting the rule, so those assertions would not notice.
assert_contains "${privacy}" 'named lane or provider is degraded' \
  'the degraded lane/provider fact must stay publishable'
assert_contains "${privacy}" 'agent-actionable or maintainer-only' \
  'remediation ownership must stay publishable — it decides escalate vs act'
assert_contains "${privacy}" 'last-verified <date>: <result>' \
  'the blocker line verification record must stay publishable'

# The private side. Each is a distinct disclosure, so each is pinned separately — a single
# catch-all phrase could be narrowed later without any assertion noticing.
assert_contains "${privacy}" 'reset or retry timestamps' \
  'exact reset/retry timestamps must be named as private'
assert_contains "${privacy}" 'credit, or balance figures' \
  'quota/credit/balance figures must be named as private'
assert_contains "${privacy}" 'subscription identity' \
  'plan/tier/subscription identity must be named as private'
assert_contains "${privacy}" 'across vendors' \
  'cross-vendor correlation of posture must be named as private'

# The other half of the two-sided rule. Without this, "make it all private" reads as a valid
# tightening and every blocker line becomes under-specified for skip clause (b).
assert_contains "${privacy}" 'never withheld' \
  'the doctrine must state that a cause CLASS is never withheld'
assert_contains "${privacy}" 'under-specified for **skip clause (b)**' \
  'the doctrine must tie the publishable class back to the blocker-line requirement'

# ---------------------------------------------------------------------------
# 2. The liveness clause must no longer read as forbidding what the doctrine permits,
#    while its factual description of the script stays accurate.
# ---------------------------------------------------------------------------
liveness="$(extract_section 'Run [`.claude/scripts/codex-lane-liveness.sh`]' \
                            'The deployed Cursor Automation has no supported local write surface')"

[ "${#liveness}" -gt 200 ] || fail "liveness paragraph captured only ${#liveness} chars — extraction is broken"

# The factual description is TRUE of the script as it stands and must not be quietly dropped:
# deleting it would let a later reader assume the check already reports a cause.
assert_contains "${liveness}" 'reads only timings and an inbox-presence flag' \
  'the accurate description of what the script reads must survive'

assert_contains "${liveness}" 'defence in depth' \
  'the clause must say its narrowness is defence in depth, not a bar on naming the cause'

assert_contains "${liveness}" 'codex_error_info' \
  'the clause must name the per-turn field that carries the cause, so a NOT-PRODUCING verdict is not re-diagnosed by hand each time'

echo "lane-outage-disclosure contract: PASS"
