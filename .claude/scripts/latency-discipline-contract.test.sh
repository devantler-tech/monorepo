#!/usr/bin/env bash
#
# Guards the ONE sentence in *Latency discipline* that decides when a bare `sleep` is allowed.
#
# Why this needs a guard at all. The busy-wait hook and this contract are two halves of the same
# rule, and when they disagree the agent follows the prose while the guard blocks it — which shows
# up as a large, permanent, self-inflicted denial count rather than as a visible contradiction.
# Measured over the 7 days to 2026-08-09T22Z, counting only structurally-anchored firings (a real
# errored tool_result, so quoted prose and fixtures cannot inflate it): 76 of 141 blocked actions
# were `sleep N && <poll>`, and 27 of those polled a BACKGROUNDED TASK'S OWN OUTPUT FILE.
#
# Those 27 were the contract's fault, not the agent's. The carve-out used to read "a local timer for
# a process you yourself started", which scopes the exception by WHO STARTED THE PROCESS and whether
# the state is LOCAL. A backgrounded tool call satisfies both halves — the agent started it, its
# output file is on disk — so the sentence licensed exactly the poll the same bullet forbids two
# sentences earlier and the guard refuses. The correct scope is whether the RUNTIME REPORTS
# COMPLETION, because that is what makes the poll redundant.
#
# So this pins BOTH halves. A presence-only guard would pass with the superseded absolute still
# sitting in the same paragraph, readable as the operative rule — which is how every contradiction
# found in this contract so far survived.
#
# Assertions are scoped to the latency bullet itself, not the whole file. Asserting against the
# whole constitution is a scope hole: verified while RED-proving this file, appending the expected
# phrase to an unrelated section passes a whole-file check while the real sentence stays wrong.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "latency discipline contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract ONLY the "NEVER foreground-block on a remote wait" bullet, then flatten it. Flattening
# matters because the sentence wraps across source lines, so a fragment spanning a line break would
# never match and the test would be always-red regardless of the contract's content.
bullet="$(
  awk '
    /NEVER foreground-block on a remote wait/ { inb = 1 }
    inb && /^- \*\*Long-pole first/           { inb = 0 }
    inb                                        { print }
  ' "${constitution}" | tr '\n' ' ' | tr -s '[:space:]' ' '
)"

[ -n "${bullet}" ] ||
  fail "could not locate the 'NEVER foreground-block on a remote wait' bullet — the extraction anchor moved, so every assertion below would be vacuous"

# Guard the extraction itself. If the terminating anchor ever disappears, awk runs to end-of-file and
# `bullet` becomes the whole rest of the contract — which silently restores the very scope hole this
# file exists to avoid, while every assertion still passes.
# The threshold separates two states that are an order of magnitude apart, and it is deliberately
# NOT set just above the current size: the bullet is ~380 words, while a runaway extraction (end
# anchor deleted, awk running to EOF) measures ~7200. A snug bound would fail every legitimate
# edit to this bullet while reporting a missing anchor — a false message that sends the next
# reader hunting for a heading that is right there.
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

# 1. The operative test is what the RUNTIME REPORTS, stated in the operative sentence rather than
#    only implied by surrounding prose.
assert_bullet 'is never the tool for anything the runtime will report to you' \
  "latency bullet does not scope the sleep prohibition by whether the runtime reports completion"

# 2. The carve-out itself is re-scoped the same way. Without this, assertion 1 could be satisfied by
#    a new sentence while the exception two clauses later still admits the wrong shape.
assert_bullet 'local timer for a process whose completion nothing will report' \
  "the sleep carve-out is not scoped by whether completion is reported"

# 3. BOTH-HALVES. The superseded absolute must be GONE, not merely supplemented. This is the
#    assertion that actually fixes the measured defect: while this phrase survives, an agent reading
#    the paragraph still finds a sufficient licence for polling a backgrounded task.
refute_bullet 'a process you yourself started' \
  "the superseded carve-out ('a process you yourself started') is still present — it licenses polling a backgrounded task whose completion the runtime reports, which is the shape the guard blocks"

# 4. The correct primitive is named. A prohibition that does not say what to do instead is the
#    DevEx tax this repo's own hardening rule forbids, and the guard's refusal already names it.
assert_bullet '`Monitor` with an until-loop' \
  "latency bullet forbids the poll without naming the runtime waiter to use instead"

# ---------------------------------------------------------------------------
# THIRD MIGRATION: the poll loop moved INSIDE a `run_in_background` call.
#
# Assertions 1-4 close the two earlier spellings (chained `sleep N && <poll>`, and the standalone
# `sleep` polling a backgrounded task's OUTPUT FILE). Neither reaches a hand-rolled loop placed
# WITHIN the backgrounded command itself — `for i in $(seq 1 40); do gh ...; sleep 30; done` with
# run_in_background:true. That form satisfies every sentence above while reproducing the identical
# waste, and the enforcement hook lives in `rtk` and cannot see inside a backgrounded command.
#
# Measured over the 7 days to 2026-08-23 across 176 Agentic Engineer runs: 560 of 904 backgrounded
# Bash launches (62%) carried such a loop; 240 idles waiting on one totalled 28.0h; runs using a
# poll loop ran a median 62.8min against 42.4min, overrunning the hourly slot 54% against 29%; and
# all 9 dropped dispatches (of 179 slots) were overlap-blocked by a still-open run.
#
# Each assertion below pins a DIFFERENT load-bearing half, because any one alone is satisfiable
# while the behaviour survives: naming the shape without the mechanism reads as style advice, and
# naming both without the alternative is the bare prohibition that caused migrations 1 and 2.

# 5. Backgrounding does not launder the wait. Without this, `run_in_background` remains a documented
#    escape from a rule the same bullet states two paragraphs earlier.
assert_bullet 'never out of the RUN' \
  "latency bullet does not say that backgrounding moves a poll loop out of the guard's view but not out of the run — so wrapping the loop in run_in_background still reads as compliant"

# 6. The RESURRECTION mechanism. This is what makes the poller cost the NEXT dispatch rather than
#    only its own wait, and it is the half an agent cannot deduce from the prohibition alone.
assert_bullet 'resurrects the session' \
  "latency bullet does not state that a backgrounded poller's completion notification resurrects the session and keeps the run open — which is why the measured cost lands on the following dispatch"

# 7. The operative rule, and the alternative. A prohibition that does not name what to do instead is
#    the DevEx tax this repo's own hardening rule forbids, and is precisely what pushed this
#    behaviour into its second and third spellings.
assert_bullet 'never launch a poller and then end your turn' \
  "latency bullet does not forbid the one combination that gets neither the work nor the run-end (launch a poller, then end the turn)"

# 8. BOTH permitted alternatives, because assertion 7 pins only the prohibition. The whole argument
#    for this rule is that a bare prohibition is what pushed the behaviour into its second and third
#    spellings, so the alternatives are the load-bearing half — and a future edit could strip them
#    while 7 still passed. (Raised by CodeRabbit on #3002; the finding was valid.)
assert_bullet 'arm `Monitor` and go do it' \
  "latency bullet forbids the poller-then-end-turn combination without naming the Monitor alternative for when other work IS actionable"

# NOTE the anchor. The obvious 'end the run' is VACUOUS here: the bare phrase already occurs earlier
# in this same bullet ("or end the run and let the next tick collect the result"), so it would pass
# with this sentence deleted — measured, 2 occurrences. Anchor on the run-end alternative's own
# clause instead, which is unique to it.
assert_bullet '**end the run**: rung 1 of' \
  "latency bullet does not name the run-termination alternative for when nothing else is actionable, with the rung-1 guarantee that makes ending safe"

# 9. Ending the run is not achievable by intent alone. The resurrection in assertion 6 is
#    unconditional, so "end the run" while a watcher is still armed does NOT end it — the session
#    reopens and the idle window is rebuilt. Measured in the same window: 6 idles (1.09h) woke on a
#    watcher that had merely TIMED OUT, i.e. runs that believed they were finished and were not.
#    Without this, the rule's own remedy preserves the defect it targets. (Raised by Codex on #3002.)
# Anchor on the REQUIREMENT, not the tool name. A bare 'TaskStop' presence check
# passes on "Ending the run NEVER requires ... TaskStop" — it admits the exact
# inversion it claims to prevent. (Raised by Codex on #3002; same weak-anchor
# class as the vacuous 'end the run' anchor rejected two assertions above.)
assert_bullet 'Ending the run REQUIRES stopping every in-flight watcher first' \
  "latency bullet does not REQUIRE in-flight watchers to be stopped before ending — but the resurrection it documents is unconditional, so an armed watcher reopens the session and rebuilds the idle window"
assert_bullet '`TaskStop`, not merely a' \
  "latency bullet states the stop requirement without naming TaskStop as the mechanism, leaving 'end the run' achievable by intent alone"

echo "latency discipline contract: OK"
