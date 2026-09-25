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
constitution="${repo_root}/AGENTS.md"
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

echo "latency discipline contract: OK"
