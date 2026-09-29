#!/usr/bin/env bash
# The asserted phrases quote Markdown code spans literally; nothing in them is meant to expand.
# shellcheck disable=SC2016
#
# Guards the anti-busy-wait rule in its two halves.
#
# The PORTABLE half — a hand-rolled poll loop is a busy-wait wherever it runs, never sleep for a
# result the runtime reports, a watcher that re-invokes the session is stopped before the run ends,
# and a watcher is never armed only to end the turn idle — is rule 7 of the pinned agentic-engineer
# definition (devantler-tech/agent-plugins#252, monorepo#3003). This file asserts it THERE, at the
# gitlink this repository pins, so a pin bump that drops it fails here rather than silently reaching
# every run.
#
# The DEPLOYMENT half stays in *Latency discipline*: the Claude primitives (`Monitor`, `TaskStop`,
# `run_in_background`), the rung-1 guarantee that makes ending a run safe, and the measurements.
#
# Why this needs a guard at all. The busy-wait hook and these rules are two halves of the same
# boundary, and when they disagree the agent follows the prose while the guard blocks it — which
# shows up as a large, permanent, self-inflicted denial count rather than as a visible contradiction.
# Measured over the 7 days to 2026-08-09T22Z, counting only structurally-anchored firings: 76 of 141
# blocked actions were `sleep N && <poll>`, and 27 of those polled a BACKGROUNDED TASK'S OWN OUTPUT
# FILE — licensed by a carve-out scoped to "a process you yourself started" rather than to whether the
# runtime reports completion. Measured over the 7 days to 2026-08-23 across 176 Agentic Engineer runs:
# 560 of 904 backgrounded Bash launches carried a hand-rolled poll loop, 240 idles waiting on one
# totalled 28.0h, and all 9 dropped dispatches (of 179 slots) were overlap-blocked by a still-open run.
#
# Every assertion is scoped. Asserting against the whole constitution is a scope hole: appending the
# expected phrase to an unrelated section passes a whole-file check while the real sentence is wrong.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guide="${repo_root}/.claude/guides/tool-call-discipline.md"
# The negative controls at the end re-run this file against a mutated COPY of the guide. The override
# exists only for that re-entry; a normal run always reads the real guide.
constitution="${LATENCY_CONTRACT_FIXTURE_GUIDE:-${guide}}"
plugin_dir="${repo_root}/libraries/agent-plugins"
engineer_path='plugins/agentic-engineering/agents/agentic-engineer.agent.md'

fail() {
  echo "latency discipline contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# The portable half is read from the gitlink this commit pins, never from the submodule's working
# tree. A populated checkout can sit on another revision or carry edited bytes, and a working-tree
# read would then vouch for rule text the pin does not contain. Reading the blob by the pinned commit
# is content-addressed, so it returns the reviewed bytes whatever the checkout holds.
pin="$(git -C "${repo_root}" --no-replace-objects rev-parse HEAD:libraries/agent-plugins)" ||
  fail "cannot resolve the libraries/agent-plugins gitlink at HEAD"
# An UNINITIALISED submodule is a normal local state, but it leaves the portable half unchecked, so
# it fails closed with the fix rather than passing on the deployment half alone.
engineer_text="$(git -C "${plugin_dir}" --no-replace-objects cat-file blob "${pin}:${engineer_path}")" ||
  fail "cannot read ${engineer_path} at the pinned ${pin} — initialise the submodule with
       .claude/scripts/submodule-init.sh libraries/agent-plugins"
[ -n "${engineer_text}" ] ||
  fail "the pinned ${engineer_path} at ${pin} is empty, so every portable assertion would be vacuous"

# ---------------------------------------------------------------------------
# DEPLOYMENT HALF — the "NEVER foreground-block on a remote wait" bullet, flattened so a sentence that
# wraps across source lines still matches.
bullet="$(
  awk '
    /NEVER foreground-block on a remote wait/ { inb = 1 }
    inb && /^- \*\*Long-pole first/           { inb = 0 }
    inb                                        { print }
  ' "${constitution}" | tr '\n' ' ' | tr -s '[:space:]' ' '
)"

[ -n "${bullet}" ] ||
  fail "could not locate the 'NEVER foreground-block on a remote wait' bullet — the extraction anchor moved, so every assertion below would be vacuous"

# Guard the extraction itself: if the 'Long-pole first' end anchor disappears, awk runs to end of file
# and every assertion passes against the whole rest of the contract. The bullet is ~450 words; a
# runaway extraction measures thousands, so the bound sits far from both.
bullet_words="$(printf '%s' "${bullet}" | wc -w | tr -d ' ')"
[ "${bullet_words}" -lt 1200 ] ||
  fail "latency bullet extracted as ${bullet_words} words, which is runaway-extraction size — the 'Long-pole first' end anchor was probably renamed or removed, so these assertions would no longer be scoped to this bullet"

assert_bullet() {
  case "${bullet}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}
refute_bullet() {
  case "${bullet}" in
    *"$1"*) fail "$2" ;;
  esac
}

# 1. The bullet points at the upstream rule rather than silently restating or dropping it.
assert_bullet 'The portable rule is rule 7 of the pinned `agentic-engineer` definition' \
  "latency bullet no longer names the pinned plugin rule it specialises — a reader cannot tell the portable rule exists"

# 2. The superseded carve-out must stay GONE: it licensed polling a backgrounded task whose
#    completion the runtime reports, which is the shape the guard blocks.
refute_bullet 'a process you yourself started' \
  "the superseded carve-out ('a process you yourself started') is back — it licenses polling a backgrounded task whose completion the runtime reports"

# 3. The Claude waiter is named. A prohibition that does not say what to do instead is the DevEx tax
#    this repo's own hardening rule forbids, and the guard's refusal already names it.
assert_bullet '`Monitor` with an until-loop' \
  "latency bullet forbids the poll without naming the runtime waiter to use instead"

# 4. Backgrounding does not launder the wait — stated for this lane's live shape, run_in_background.
assert_bullet 'never out of the RUN' \
  "latency bullet does not say that run_in_background moves a poll loop out of the guard's view but not out of the run"

# 5. The Claude resurrection mechanism, which is why the cost lands on the NEXT dispatch.
assert_bullet 'resurrects the session' \
  "latency bullet does not state that a backgrounded task's completion notification resurrects the session"

# 6. Both alternatives, in this lane's terms. The anchor for ending is the rung-1 clause, which is
#    unique to it; a bare 'end the run' also matches the pointer sentence and would be vacuous.
assert_bullet 'arm `Monitor` and go do it' \
  "latency bullet does not name the Monitor alternative for when other work IS actionable"
assert_bullet '**end the run**: rung 1 of' \
  "latency bullet does not name the run-termination alternative with the rung-1 guarantee that makes ending safe"

# 7. The stop requirement and its mechanism. Anchor on the REQUIREMENT: a bare 'TaskStop' presence
#    check passes on "Ending the run NEVER requires ... TaskStop".
assert_bullet 'Ending the run REQUIRES stopping every in-flight watcher first' \
  "latency bullet does not REQUIRE in-flight watchers to be stopped before ending"
assert_bullet '`TaskStop`, not merely a' \
  "latency bullet states the stop requirement without naming TaskStop as the mechanism"

# 8. The DELEGATED-run case (monorepo#3645). Item 5's resurrection mechanism holds only for a
#    top-level session: a run dispatched as a subagent loses its background tasks when it returns, and
#    the runtime's launch message tells it to wait first. Without its own clause, delegated runs armed a
#    watcher and then foreground-polled that watcher's output file — 31 delegated Engineer runs averaged
#    69.0 min against 43.7 for 38 inline runs (09-25 to 09-28). Each anchor carries its own verb, so a
#    revision that keeps the words but licenses the poll fails.
assert_bullet 'In a **delegated run**' \
  "latency bullet does not name the delegated-run case, where nothing resurrects the session"
assert_bullet 'never poll a backgrounded task'"'"'s output file' \
  "latency bullet does not forbid a delegated run from polling its own backgrounded task's output file"
assert_bullet 'at most **one** bounded one-shot read of the condition itself' \
  "latency bullet does not cap a delegated run's gating check at one bounded one-shot read of the condition"
assert_bullet 'never `--watch`, which polls in the foreground' \
  "latency bullet does not forbid the foreground --watch poll as a delegated run's gating check"
assert_bullet 'with no watcher armed beside it' \
  "latency bullet does not forbid pairing the delegated run's gating read with a background watcher"
assert_bullet 'If no result gates a terminal step, or the read shows it unresolved, `TaskStop` every watcher you armed and return' \
  "latency bullet does not tell a delegated run to stop its watchers and return when the gate is absent or unresolved"
assert_bullet 'reporting the PR'"'"'s state to your parent' \
  "latency bullet does not tell an abandoning delegated run to hand the PR's state back to its parent"
assert_bullet 'never a promised next tick' \
  "latency bullet promises that the next tick collects an abandoned PR, which the cadence contract forbids"
refute_bullet 'a delegated run may poll' \
  "latency bullet licenses a delegated run to poll"
assert_bullet 'If that read shows the condition resolved, finish the step.' \
  "latency bullet does not tell a delegated run to finish its terminal step when the one-shot read shows the gate resolved"
refute_bullet 'guarantees the next tick' \
  "latency bullet guarantees next-tick collection, but the Claude scheduler drops overlapping dispatches"
refute_bullet 'rung 1 collects the PR next tick' \
  "latency bullet promises next-tick collection of an abandoned PR"

# A next-tick promise anywhere in the guide contradicts the scheduler rule, not only inside the
# bullet, so these two refutations read the whole guide (a refutation cannot pass by relocation).
guide_flat="$(tr '\n' ' ' <"${constitution}" | tr -s '[:space:]' ' ')"
case "${guide_flat}" in
  *'next tick collect'* | *'guarantees the next tick'*)
    fail "the latency guide promises that the next tick collects a PR, but the Claude scheduler drops overlapping dispatches" ;;
esac

# ---------------------------------------------------------------------------
# 9. The REVIEW WAIT (monorepo#3660). The review-lanes guide tells a run to "wait for its substantive
#    outcome", and without saying how, runs waited in foreground loops that re-read the PR between
#    sleeps: foreground review-wait time across Claude Engineer runs went 4, 43, 71, 59, 215 min/day
#    from 09-24 to 09-28. The runtime's guard only catches a sleep chained straight into a poll, so a
#    loop with the sleep inside passes it. Scoped to the one bullet that prescribes the wait.
review_guide="${LATENCY_CONTRACT_FIXTURE_REVIEW_GUIDE:-${repo_root}/.claude/guides/review-lanes.md}"
[ -r "${review_guide}" ] || fail "cannot read ${review_guide}"
review_bullet="$(
  awk '
    /Only one provider request may be active at a time/ { inb = 1; print; next }
    inb && /^- \*\*/                                    { inb = 0 }
    inb                                                  { print }
  ' "${review_guide}" | tr '\n' ' ' | tr -s '[:space:]' ' '
)"
[ -n "${review_bullet}" ] ||
  fail "could not locate the review-lanes 'Only one provider request may be active at a time' bullet — the extraction anchor moved, so the review-wait assertions would be vacuous"
review_words="$(printf '%s' "${review_bullet}" | wc -w | tr -d ' ')"
[ "${review_words}" -lt 600 ] ||
  fail "review-wait bullet extracted as ${review_words} words, which is runaway-extraction size — the next bullet's '- **' anchor is gone"
case "${review_bullet}" in
  *'That wait is the *Latency discipline* wait, never a loop in the foreground'*) ;;
  *) fail "the review-lanes wait does not say it is the Latency discipline wait and never a foreground loop" ;;
esac
case "${review_bullet}" in
  *'leave the PR on rung 1'*) ;;
  *) fail "the review-lanes wait does not name leaving the PR on rung 1 when one read shows no review yet" ;;
esac
case "${review_bullet}" in
  *'whatever its iteration cap'*) ;;
  *) fail "the review-lanes wait lets an iteration cap make a foreground review-poll loop acceptable" ;;
esac
# The loop ban must not swallow the watcher it prescribes: the Latency discipline watcher IS a loop.
case "${review_bullet}" in
  *'The one watcher that section prescribes is the only loop allowed'*) ;;
  *) fail "the review-lanes wait no longer exempts the prescribed Latency discipline watcher from its loop ban" ;;
esac

# ---------------------------------------------------------------------------
# PORTABLE HALF — rule 7 of the pinned engineer definition, flattened the same way. Scoped to that
# rule for the same reason the deployment half is scoped to its bullet: a whole-file check passes
# while rule 7 itself is weakened, as long as the phrases survive in some other paragraph.
engineer_flat="$(
  awk '
    /^7\. \*\*Give expected-to-run-long local commands/ { inr = 1 }
    inr && /^8\. \*\*/                                   { inr = 0 }
    inr                                                  { print }
  ' <<<"${engineer_text}" | tr '\n' ' ' | tr -s '[:space:]' ' '
)"

[ -n "${engineer_flat}" ] ||
  fail "could not locate rule 7 ('Give expected-to-run-long local commands') in the pinned engineer definition — the extraction anchor moved, so every portable assertion would be vacuous"

# Rule 7 is ~560 words; a runaway extraction (the '8. **' end anchor gone) runs to end of file and
# measures thousands, which would reopen the scope hole this extraction exists to close.
engineer_words="$(printf '%s' "${engineer_flat}" | wc -w | tr -d ' ')"
[ "${engineer_words}" -lt 1500 ] ||
  fail "rule 7 extracted as ${engineer_words} words, which is runaway-extraction size — the '8. **' end anchor was probably renamed or removed, so the portable assertions would no longer be scoped to rule 7"

assert_engineer() {
  case "${engineer_flat}" in
    *"$1"*) ;;
    *) fail "$2 (pinned libraries/agent-plugins)" ;;
  esac
}

# Each anchor carries its requirement's own verb or quantifier, so a revision that keeps the words but
# negates the rule ("no longer holds that session open", "need not stop every such watcher") fails.
assert_engineer 'Bounded one-shot remote reads or mutations are allowed.' \
  "the pinned engineer no longer limits remote state to bounded one-shot reads"
assert_engineer 'Never foreground-poll remote state' \
  "the pinned engineer no longer forbids foreground-polling remote state"
assert_engineer 'arm at most one detached watcher' \
  "the pinned engineer no longer caps a run at one detached watcher"
assert_engineer 'A hand-rolled poll loop is a busy-wait wherever it runs.' \
  "the pinned engineer no longer treats a backgrounded poll loop as a busy-wait"
assert_engineer 'never out of the run' \
  "the pinned engineer no longer says backgrounding moves the wait out of a guard's view but not out of the run"
assert_engineer 'Never sleep for a result the runtime will report to you' \
  "the pinned engineer no longer scopes the sleep prohibition by whether the runtime reports completion"
assert_engineer 'a local timer for a process whose completion nothing will report' \
  "the pinned engineer no longer limits a bare sleep to a process whose completion nothing reports"
assert_engineer 'it counts as your one watcher' \
  "the pinned engineer no longer counts a backgrounded poll loop against the one-watcher cap"
assert_engineer 're-invokes the current session holds that session open' \
  "the pinned engineer no longer states that a session-re-invoking watcher keeps the run open"
assert_engineer 'while one is armed: stop every such watcher before ending the run' \
  "the pinned engineer no longer requires session-holding watchers to be stopped before the run ends"
assert_engineer 'Never arm a watcher and then end your turn with nothing else to do' \
  "the pinned engineer no longer forbids arming a watcher and then ending the turn idle"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROLS for item 8 (monorepo#3645). Each one breaks a single delegated-run clause in a
# copy of the guide and re-runs this file against it; the run must fail with THAT clause's diagnostic,
# not merely exit non-zero. The phrase is matched across line wraps, and a mutation that changes
# nothing is itself a failure, so a reworded guide cannot turn a control into a silent no-op.
if [ -z "${LATENCY_CONTRACT_FIXTURE_GUIDE:-}" ]; then
  # No EXIT trap for the cleanup: macOS bash 3.2 can report an abort as exit 0 from one. A failing
  # control leaves its temporary directory behind, which is the cheaper failure.
  fixture_dir="$(mktemp -d)"

  expect_rejected() { # <phrase in the guide> <replacement> <expected diagnostic substring>
    local mutated="${fixture_dir}/guide.md" err="${fixture_dir}/err"
    FROM="$1" TO="$2" perl -0pe '
      my $re = join("\\s+", map { quotemeta } split(/ /, $ENV{FROM}));
      s/$re/$ENV{TO}/;
    ' "${guide}" >"${mutated}" || fail "negative control could not mutate the guide for: $1"
    ! cmp -s "${guide}" "${mutated}" ||
      fail "negative control for '$1' changed nothing — the phrase is no longer in the guide"
    if LATENCY_CONTRACT_FIXTURE_GUIDE="${mutated}" bash "${BASH_SOURCE[0]}" >/dev/null 2>"${err}"; then
      fail "negative control: the guide still passed with '$1' broken"
    fi
    grep -Fq -- "$3" "${err}" ||
      fail "negative control for '$1' failed for the wrong reason: $(cat "${err}")"
  }

  expect_rejected 'never poll a backgrounded task'"'"'s output file' 'poll a backgrounded task'"'"'s output file' \
    'does not forbid a delegated run from polling'
  expect_rejected 'bounded one-shot read of the condition itself' 'bounded wait on the condition itself' \
    'one bounded one-shot read of the condition'
  expect_rejected 'never `--watch`, which polls in the foreground' '`--watch` is fine' \
    'does not forbid the foreground --watch poll'
  expect_rejected 'with no watcher armed beside it' 'with a watcher armed beside it' \
    'does not forbid pairing the delegated run'
  expect_rejected 'If that read shows the condition resolved, finish the step.' '' \
    'finish its terminal step when the one-shot read shows the gate resolved'
  expect_rejected 'If no result gates a terminal step, or' 'If no result gates a terminal step or' \
    'stop its watchers and return when the gate is absent or unresolved'
  expect_rejected 'reporting the PR'"'"'s state to your parent' 'keeping the PR'"'"'s state to yourself' \
    'hand the PR'"'"'s state back to its parent'
  expect_rejected 'puts the PR first for whichever run is dispatched next' 'guarantees the next tick collects the PR' \
    'guarantees next-tick collection'
  expect_rejected 'never a promised next tick' 'and the next tick collects it' \
    'promises that the next tick collects an abandoned PR'
  expect_rejected 'let a later run collect the result' 'let the next tick collect the result' \
    'the latency guide promises that the next tick collects a PR'

  # Item 9's controls mutate a copy of the REVIEW guide, the same way.
  expect_review_rejected() { # <phrase in the review guide> <replacement> <expected diagnostic substring>
    local review_src="${repo_root}/.claude/guides/review-lanes.md"
    local mutated="${fixture_dir}/review.md" err="${fixture_dir}/err"
    FROM="$1" TO="$2" perl -0pe '
      my $re = join("\\s+", map { quotemeta } split(/ /, $ENV{FROM}));
      s/$re/$ENV{TO}/;
    ' "${review_src}" >"${mutated}" || fail "negative control could not mutate the review guide for: $1"
    ! cmp -s "${review_src}" "${mutated}" ||
      fail "negative control for '$1' changed nothing — the phrase is no longer in the review guide"
    if LATENCY_CONTRACT_FIXTURE_REVIEW_GUIDE="${mutated}" LATENCY_CONTRACT_FIXTURE_GUIDE="${guide}" \
      bash "${BASH_SOURCE[0]}" >/dev/null 2>"${err}"; then
      fail "negative control: the review guide still passed with '$1' broken"
    fi
    grep -Fq -- "$3" "${err}" ||
      fail "negative control for '$1' failed for the wrong reason: $(cat "${err}")"
  }
  expect_review_rejected 'never a loop in the foreground' 'which may loop in the foreground' \
    'Latency discipline wait and never a foreground loop'
  expect_review_rejected 'leave the PR on rung 1' 'keep polling' \
    'leaving the PR on rung 1'
  expect_review_rejected 'whatever its iteration cap' 'unless it has an iteration cap' \
    'iteration cap make a foreground review-poll loop acceptable'
  expect_review_rejected 'The one watcher that section prescribes is the only loop allowed' \
    'Every loop is forbidden' 'exempts the prescribed Latency discipline watcher'
  rm -rf "${fixture_dir}"
fi

echo "latency discipline contract: OK"
