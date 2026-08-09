#!/usr/bin/env bash
#
# Guards the ONE sentence in *Latency discipline* that decides when a bare `sleep` is allowed.
#
# Why this needs a guard at all. The busy-wait hook and this contract are two halves of the same
# rule, and when they disagree the agent follows the prose while the guard blocks it — which shows
# up as a large, permanent, self-inflicted denial count rather than as a visible contradiction.
# Measured 2026-08-10 over the 7-day corpus, counting only structurally-anchored firings (a real
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

echo "latency discipline contract: OK"
