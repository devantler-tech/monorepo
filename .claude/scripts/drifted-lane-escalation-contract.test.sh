#!/usr/bin/env bash
#
# Guards the escalation rule for a lane that is serving a SUPERSEDED agent definition and has no
# repair path available to it.
#
# Why this needs a guard. The currency block's original escalation sentence names two triggers, and
# both are exit states of `plugin-definition-refresh.sh`:
#
#     "When the script cannot resolve its CLI, or a refusal persists across rollouts, surface it on
#      a declared *Maintainer channel* ..."
#
# `plugin-definition-currency.sh` DETECTS drift on three lanes (`--runtime claude|codex|cursor`).
# `plugin-definition-refresh.sh` can REPAIR exactly one: it takes no runtime selector, hardcodes its
# plugins root to the Claude configuration directory, and dies unless it resolves an executable
# `claude` CLI. So on two of three lanes the script is never invoked, neither trigger can fire, and a
# run that follows the section exactly detects the drift, reports it privately, and continues — with
# no bound on how long that repeats.
#
# Measured 2026-08-22 (monorepo#2997): Claude CURRENT at 4.4.8, Codex DRIFT at 4.4.2 across 3 of 11
# pinned files including `agents/portfolio-surveyor.agent.md`; 26 Codex dispatches on the superseded
# copy since the pin moved; two Agent Improver dispatches saw it, correctly fenced the unsafe
# remove/add hot-swap, and continued, because nothing obliged them to do more.
#
# Three properties are pinned here, and the second and third are the ones a well-meaning edit would
# drop first:
#
#   1. Escalation is keyed to the CONDITION (drift + no available/safe repair), not to a tool's exit
#      code, and it is BOUNDED so one transient reading never pages the maintainer.
#   2. A FENCED repair counts toward that bound exactly as a failed one does. Fencing is usually the
#      correct call, so it reads as a non-event — and a decision recorded as nothing is what makes
#      the staleness unbounded. Without this assertion the clause could be narrowed to "failed or
#      refused" and lose the case it was written for.
#   3. The rule stays ADDITIVE. A `DRIFT` must remain a non-run-stopper and the reviewed-definition
#      fallback must survive, or a later tightening turns a reporting obligation into a halt — the
#      fail-closed direction this contract rejects everywhere else.
#
# Assertions are scoped to the currency section rather than the whole file: `AGENTS.md` discusses
# drift, fencing and maintainer channels elsewhere, so an unscoped match would pass on unrelated
# prose while this passage stayed wrong.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
refresh="${repo_root}/.claude/scripts/plugin-definition-refresh.sh"
currency="${repo_root}/.claude/scripts/plugin-definition-currency.sh"

fail() {
  echo "drifted-lane-escalation contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract one section and flatten it. Sentences wrap across source lines, so any fragment spanning a
# line break would never match and the test would be always-red regardless of content. A sentinel
# proves the END anchor was actually seen: without it a missing anchor lets the capture run to EOF
# and match text belonging to entirely different sections. Anchors are compared as LITERAL line
# prefixes via index(), never as regexes — `awk -v` applies its own escape processing, so an anchor
# containing `[` or `.` arrives mangled and silently matches nothing.
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

  # `sed` rather than `grep -v`: grep exits 1 when it emits no lines, which under `set -e` plus
  # `pipefail` would abort mid-assignment and kill the test instead of reaching a real failure.
  printf '%s\n' "${raw}" | sed "/^${sentinel}\$/d" | tr '\n' ' ' | tr -s '[:space:]' ' '
}

assert_contains() {
  haystack="$1"; needle="$2"; label="$3"
  case "${haystack}" in
    *"${needle}"*) ;;
    *) fail "${label} — expected to find: ${needle}" ;;
  esac
}

section="$(extract_section 'Refresh only through the runtime' '### Agent definition locations')"

# A flattened empty capture collapses to a single space, which would satisfy nothing below while
# reporting a pass on the FIRST assertion's failure message rather than on extraction. Assert real
# content was captured before testing it.
[ "${#section}" -gt 2000 ] || fail "currency section captured only ${#section} chars — extraction is broken"

# ---------------------------------------------------------------------------
# 1. The rule is keyed to the condition, and the reachability defect is named.
# ---------------------------------------------------------------------------
assert_contains "${section}" 'escalate on the CONDITION, not on a tool' \
  'the escalation must be keyed to the condition rather than to a refresh-tool exit code'

assert_contains "${section}" 'takes no runtime selector' \
  'the section must record WHY the exit-code form is unreachable — the refresh tool has no lane selector'

# The three ways a repair fails to happen. Each is pinned separately: a single catch-all word could
# later be narrowed to the two that are easy to detect, silently dropping the fenced case.
for state in '**unavailable**' '**refused**' '**fenced**'; do
  assert_contains "${section}" "${state}" \
    "the escalating condition must enumerate the repair state ${state}"
done

# ---------------------------------------------------------------------------
# 2. The bound, and the fenced case that the bound exists to capture.
# ---------------------------------------------------------------------------
assert_contains "${section}" 'two consecutive runs that checked it' \
  'escalation must be bounded, so one transient reading never pages the maintainer'

# Cross-instance evidence must keep counting. Scoping the bound per instance would discard the
# sibling's observations of the same lane and double the time to escalate — and this deployment
# reached three observations across two instances before the rule existed, so per-instance scoping is
# the reading that would have kept it silent.
assert_contains "${section}" 'whichever instance ran them' \
  'observations of one lane must count across instances, not restart per instance'


# Lane identity. Cross-INSTANCE counting (above) and cross-LANE counting are opposite requirements,
# and the sentence that grants the first is one word away from granting the second — the first draft of
# this clause said "does not restart per lane", which would let one Codex reading and one Cursor reading
# satisfy the counter, escalating a condition that persisted on neither. Pinned separately because the
# cross-instance assertion above passes either way.
assert_contains "${section}" 'Both observations must be of the SAME lane' \
  'the two observations must be of one lane — cross-instance evidence counts, cross-lane evidence never does'

assert_contains "${section}" 'Record each observation in durable memory' \
  'consecutiveness must be made measurable, or the bound cannot be evaluated by a later run'

assert_contains "${section}" 'FENCED repair counts toward that exactly as a failed one does' \
  'a fenced repair must count toward the bound — this is the case the whole clause exists for'

# ---------------------------------------------------------------------------
# 3. The rule stays ADDITIVE. Without these, tightening this into a halt reads as an improvement.
# ---------------------------------------------------------------------------
assert_contains "${section}" 'adds an obligation and removes none' \
  'the clause must state that it removes no existing protection'

assert_contains "${section}" 'still never a run-stopper' \
  'a DRIFT must remain a non-run-stopper — escalating is reporting, not halting'

assert_contains "${section}" 'not licence to perform a repair that was fenced as unsafe' \
  'the clause must not read as authorising the unsafe repair it exists to bound'

# ---------------------------------------------------------------------------
# 4. CONSERVATION. The original tool-exit-code escalation is NARROWER, not wrong, and it still
#    governs the Claude lane. This clause supplements it; an edit that deletes it would leave the one
#    lane that CAN be repaired with no escalation at all.
#    The needle is deliberately the ORIGINAL sentence's own continuation ("rollouts, surface it on a
#    declared ..."), not the bare phrase "a refusal persists across rollouts". The clause added above
#    QUOTES that phrase while explaining why it is unreachable, so a bare-phrase needle is satisfied by
#    the new prose and passes with the original sentence deleted — measured, not hypothetical: the
#    first version of this test did exactly that and its ablation caught it.
# ---------------------------------------------------------------------------
assert_contains "${section}" 'rollouts, surface it on a declared *Maintainer channel*' \
  'the original refresh-tool escalation must survive — this clause supplements it, never replaces it'

# ---------------------------------------------------------------------------
# 5. The premise must stay TRUE of the scripts, or the contract becomes a story about code that
#    changed underneath it. If a lane selector is ever added to the refresh path, this test fails and
#    whoever added it updates the prose in the same change.
# ---------------------------------------------------------------------------
if [ -r "${refresh}" ]; then
  if grep -qE -- '--runtime\)' "${refresh}"; then
    fail "plugin-definition-refresh.sh now accepts --runtime, so the contract's 'takes no runtime selector' premise is stale — update the prose in this change"
  fi
else
  fail "cannot read ${refresh} — the premise this contract rests on is unverifiable"
fi

if [ -r "${currency}" ]; then
  grep -qE -- '--runtime\)' "${currency}" ||
    fail "plugin-definition-currency.sh no longer accepts --runtime, so the three-lane detection the contract assumes is gone"
else
  fail "cannot read ${currency} — the premise this contract rests on is unverifiable"
fi

echo "drifted-lane-escalation contract: PASS — condition-keyed escalation, bounded, fenced-counts, additive, and both script premises verified"
