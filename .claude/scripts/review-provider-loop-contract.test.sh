#!/usr/bin/env bash
#
# Guards the external-review loop (maintainer direction 2026-07-22): request the three providers in
# priority order, exactly one at a time, and stop as soon as one produces a successful current-head
# review. Findings restart the sequence after the fix; an acknowledged request stays in flight.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
maintenance_skill="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"
surveyor="${repo_root}/.claude/agents/portfolio-surveyor.md"
parity_checklist="${repo_root}/.claude/plugin-consumption/agentic-engineering-surveyor-diff.md"
workflow="${repo_root}/.github/workflows/ci.yaml"

fail() {
  echo "review-provider loop contract: FAIL — $*" >&2
  exit 1
}

# Prose in these files is hard-wrapped, so a line-based grep cannot see a phrase that straddles a
# wrap — and a reflow would silently disarm the assertion (the wrap evasion recorded on #2566, here
# in the false-failure direction). Match against a whitespace-normalised stream so the guard tracks
# the words, not the column at which someone happened to break the line.
assert_prose() {
  local file="$1" phrase="$2" message="$3"
  grep -Fq -- "${phrase}" < <(tr '\n' ' ' <"${file}" | tr -s '[:space:]' ' ') ||
    fail "${message}"
}

# The mirror of assert_prose. A presence-only suite cannot see a RETIRED claim that survived, so a
# correction reads as applied while the wrong text still stands (monorepo#2733). `if` is required:
# a bare `grep -q … && fail` returns 1 on the PASSING path, and `set -e` would abort the run there.
assert_absent() {
  local file="$1" phrase="$2" message="$3"
  if grep -Fq -- "${phrase}" < <(tr '\n' ' ' <"${file}" | tr -s '[:space:]' ' '); then
    fail "${message}"
  fi
}

grep -Fq 'CodeRabbit > Codex > Cursor Bugbot' "${constitution}" ||
  fail "constitution does not preserve the provider order"
grep -Fq 'STOP on the first successful current-head review' "${constitution}" ||
  fail "constitution does not stop the loop after one provider succeeds"
grep -Fq 'never request a second provider after the first success' "${constitution}" ||
  fail "constitution permits redundant reviews after the gate is already satisfied"
grep -Fq 'A provider reaction emoji on the trigger is positive in-flight evidence' "${constitution}" ||
  fail "constitution does not distinguish an acknowledged request from a silent trigger"
grep -Fq 'fix or refute every reported issue, then restart at CodeRabbit' "${constitution}" ||
  fail "constitution does not restart the ordered loop after review findings"
grep -Fq 'A refutation that changes no file restarts at the same head; never create an empty commit' "${constitution}" ||
  fail "constitution forces a meaningless push before restarting after a refuted finding"
grep -Fq 'A reaction earns a generous bounded wait, not an infinite lease' "${constitution}" ||
  fail "an acknowledged provider can stall the review loop forever"
grep -Fq 'body_findings=0-resolved@<sha>' "${surveyor}" ||
  fail "surveyor cannot clear a same-head CodeRabbit body finding after a recorded refutation"
grep -Fq '`body_findings=0-resolved@<sha>` counts as zero for CodeRabbit success' "${surveyor}" ||
  fail "a resolved repeated CodeRabbit finding can trap the provider loop"
grep -Fq 'same-SHA Codex clean supersedes findings only after all finding threads are resolved and a later re-request produces the clean marker' "${surveyor}" ||
  fail "a successful same-head Codex retry cannot terminate the loop"
grep -Fq 'same-SHA Bugbot success supersedes findings only after all finding threads are resolved and a later authenticated re-request produces that check' "${surveyor}" ||
  fail "Bugbot retries have no deterministic same-head supersession rule"
grep -Fq 'A later successful provider in the authenticated restarted sequence clears those resolved findings' "${surveyor}" ||
  fail "a successful restarted provider cannot clear resolved findings from another lane"
grep -Fq 'author exactly `devantler` and carry the structural disclosure prefix' "${constitution}" ||
  fail "an external account can spoof a same-head body-finding resolution record"
grep -Fq 'An identical repeated same-SHA CodeRabbit finding preserves its authenticated resolution record' "${constitution}" ||
  fail "an unchanged CodeRabbit false positive can reopen forever"
grep -Fq 'Immediately before every provider request, re-read the repository-visible current-head request' "${constitution}" ||
  fail "overlapping instances can open concurrent provider lanes"
grep -Fq 'review_pending=<cr@<sha>|codex@<sha>|bugbot@<sha>|none>' "${surveyor}" ||
  fail "surveyor does not expose an in-flight provider request to sibling instances"
grep -Fq 'A request marker is authoritative only from exact author `devantler` with the structural disclosure' "${constitution}" ||
  fail "an external comment can spoof an in-flight provider request"
grep -Fq 'Only one provider request may be active at a time' "${constitution}" ||
  fail "constitution does not forbid concurrent provider requests"
# The two-phase reservation was retired on measurement 2026-07-25: it posted a blank-rendering
# comment 1-2s before its own trigger (too narrow to be observable by a sibling) and closed zero
# races across 75 elections, at a cost of 90 blank comments/7d and a doubled write rate. These
# guards keep the replacement in force and stop the retired phase returning silently.
grep -Fq 'Never post a separate pre-trigger reservation comment' "${constitution}" ||
  fail "the measured-useless two-phase reservation can silently return"
grep -Fq 'Put the request marker in the SAME' "${constitution}" ||
  fail "the request marker can drift back out of the trigger comment"
grep -Fq 'There is no pre-trigger reservation surface to scan' "${surveyor}" ||
  fail "surveyor can resurrect a reservation surface from stray legacy markers"
! grep -Fq 'review_reservation=' "${surveyor}" ||
  fail "surveyor still reports a retired reservation field"
grep -Fq 'pair it with the next exact-author bare `@cursor review` trigger while ignoring interleaved comments' "${surveyor}" ||
  fail "Cursor request markers break when another comment lands before the bare trigger"
grep -Fq 'review_progress=<cr:no-gate@<sha>|codex:no-gate@<sha>|bugbot:no-gate@<sha>|none>' "${surveyor}" ||
  fail "a completed provider outcome without a green artifact is not durable across runs"
grep -Fq 'review-progress-head: <full sha> provider=<lane> outcome=no-gate' "${surveyor}" ||
  fail "silent provider expiry cannot persist progression across runs"
grep -Fq '`review_progress` is the furthest completed lane by provider order, never the latest artifact by time' "${surveyor}" ||
  fail "a delayed provider response can move review progression backward"
grep -Fq 'CodeRabbit is first and foremost a review provider' "${constitution}" ||
  fail "constitution still treats CodeRabbit primarily as a pre-merge evaluator"
grep -Fq 'a finding-free current-head CodeRabbit review completion is `cr@<sha>` even without `APPROVED`' "${constitution}" ||
  fail "a successful CodeRabbit review still cannot satisfy the review gate"
grep -Fq 'auto-generated summary comment' "${surveyor}" ||
  fail "CodeRabbit success has no recognizable substantive completion artifact"
# The protection is that an acknowledgement is not a review — not that a whole comment type is
# discarded. The verdict-bearing form of that same type is the third satisfier pinned below.
assert_prose "${surveyor}" 'is an acknowledgement and never a review' \
  "CodeRabbit acknowledgement can be mistaken for a successful review"
grep -Fq 'review object `submitted_at` must be later than the latest authenticated CodeRabbit request marker' "${surveyor}" ||
  fail "an old same-head CodeRabbit review can satisfy a later retry"
grep -Fq 'Missing or delayed pre-merge output never blocks promotion' "${constitution}" ||
  fail "absent ancillary CodeRabbit output can still block a reviewed PR"
grep -Fq 'fold it into `body_findings`' "${surveyor}" ||
  fail "an explicit CodeRabbit pre-merge problem is not preserved as a review finding"

# With `reviews.fail_commit_status: false`, the `CodeRabbit` commit status carries `state: success`
# for three different outcomes — a completed review, a review that never ran because auto-review is
# disabled, and a rate-limited refusal (monorepo#2676). Auto-review is disabled portfolio-wide, so
# the skipped form is the DEFAULT state
# of every head: a green keyed on the state alone marks every never-reviewed PR as reviewed. These
# guards keep the `description` discriminator, and the status's corroborator-not-satisfier role, in
# all three overlays that describe the swept surfaces.
assert_prose "${constitution}" 'Review skipped: automatic reviews are disabled' \
  "constitution does not name the not-run CodeRabbit status description"
assert_prose "${constitution}" 'the `description` is the only discriminator' \
  "constitution does not make the status description the discriminator"
assert_prose "${constitution}" 'required corroborator, never a satisfier' \
  "the CodeRabbit commit status can satisfy the green-review gate on its own"
assert_prose "${surveyor}" 'Review skipped: automatic reviews are disabled' \
  "surveyor lost the not-run CodeRabbit status marker"
assert_prose "${surveyor}" 'the `description` is the discriminator, never the state' \
  "surveyor can read a skipped CodeRabbit review as a green"
assert_prose "${maintenance_skill}" 'Review skipped: automatic reviews are disabled' \
  "portfolio-maintenance is blind to the not-run CodeRabbit status"
# The parity checklist gates deletion of the local surveyor overlay, so a deployment-hardened rule
# absent from it is one the overlay removal drops silently.
assert_prose "${parity_checklist}" 'CodeRabbit commit-status description discriminator' \
  "removing the surveyor overlay would silently drop the status discriminator"

# 🔴 The status is TRANSIENT and, where auto-review is disabled, PERMANENTLY UNINFORMATIVE — so it
# cannot be a required conjunct (monorepo#3015). Measured 2026-08-24:
#   * platform#3311 @ cd7f1c00eb — CodeRabbit posted 2 real findings; description
#     `Review skipped: automatic reviews are disabled`. A head CodeRabbit certainly reviewed is the
#     control, so the description cannot evidence whether an on-demand review ran.
#   * platform#3311 @ a2ada72723 — finding-free verdict; same description, `updated_at` 23:13:31Z
#     POSTDATING the 23:08:53Z request, so freshness is not the discriminator either.
#   * ksail / actions — NO CodeRabbit status at all (unfiltered controls: 0 commit statuses, and
#     43 check-runs on the ksail head with no CodeRabbit check). Absence is a fourth state.
#   * platform#3344 @ e94216b3 — CodeRabbit replied `Review rate limited` at 20:49:29Z (still
#     readable in the comment today); the status at that head now reads the disabled default,
#     `updated_at` 21:06:55Z. The status LOST the refusal.
# Requiring `Review completed` therefore fails CLOSED on every real review here, and reading the
# status later fails OPEN on a refusal. Both directions are guarded below.
assert_absent "${constitution}" 'is a not-run marker in the same family as a rate-limit marker' \
  "constitution still classes the auto-review-disabled default as a not-run marker (#3015)"
assert_prose "${constitution}" 'uninformative status' \
  "constitution does not name the uninformative-status class that must not defeat a green (#3015)"
assert_prose "${constitution}" 'no status at all' \
  "constitution does not treat an ABSENT CodeRabbit status as uninformative (#3015)"
assert_prose "${constitution}" 'durable record of a refusal is the reply comment body' \
  "constitution does not move refusal detection onto the durable reply body (#3015)"
assert_absent "${surveyor}" 'or `Review rate limited` when none did' \
  "surveyor still claims the skipped description evidences that no review ran (#3015)"
assert_absent "${surveyor}" 'fails closed to `none`' \
  "surveyor still fails an absent CodeRabbit status closed to none (#3015)"
assert_prose "${surveyor}" 'uninformative status' \
  "surveyor lost the uninformative-status class (#3015)"
assert_prose "${maintenance_skill}" 'uninformative status' \
  "portfolio-maintenance lost the uninformative-status class (#3015)"
assert_prose "${parity_checklist}" 'uninformative status' \
  "removing the surveyor overlay would silently drop the uninformative-status split (#3015)"
# 🔴 DIRECTION, not vocabulary. The assertions above are presence checks, so on their own they would
# still pass if a document named the uninformative class and then said it defeats a green. These bind
# the EFFECT of each class, in both directions, so the loosening and the protection are asserted
# together and neither can be dropped alone (CodeRabbit, #3016).
assert_prose "${constitution}" 'must NOT defeat the green' \
  "constitution names the uninformative class but never states that it must not defeat a green"
assert_prose "${constitution}" 'defeats the green' \
  "constitution no longer states that an explicit not-run marker DEFEATS a green — the protection was dropped with the loosening"
for direction_file in "${surveyor}" "${maintenance_skill}" "${parity_checklist}"; do
  assert_prose "${direction_file}" 'defeats the green' \
    "${direction_file} lost the statement that a not-run marker defeats a green"
done
# The transient status must be bound to THIS request, or a spent refusal from an earlier round vetoes
# a genuine later green — the fail-closed this change would otherwise re-introduce one round later.
for staleness_file in "${constitution}" "${surveyor}" "${maintenance_skill}" "${parity_checklist}"; do
  assert_prose "${staleness_file}" 'at least as new as the' \
    "${staleness_file} does not bind the not-run marker to the artifact's recency, so a spent refusal still vetoes a green"
done
# The refusal read must be scoped to a positively identified command-invocation reply. An unscoped
# "durable bot comment" match is a blocklist over arbitrary prose: any coderabbitai[bot] body that
# mentions a limit would veto a real green.
for scoped_file in "${constitution}" "${surveyor}" "${maintenance_skill}"; do
  assert_prose "${scoped_file}" 'newest same-head command-invocation reply' \
    "${scoped_file} does not scope the refusal read to a positively identified command reply"
done
# And the surveyor must still emit the refusal OUTCOME, not merely describe the input.
assert_prose "${surveyor}" 'green_review=none' \
  "surveyor no longer names the green_review=none outcome, so the refusal path has no asserted result"
# NEGATIVE CONTROL, kept as prose so it cannot be quietly dropped: a rate-limited head must still
# report `green_review=none`, and the check that proves it must read the durable reply body — a
# status-based control passes vacuously once the status has reverted to the default.
assert_prose "${constitution}" 'a rate-limit, quota, or service marker saying the review did not run is rejected whatever its shape' \
  "constitution lost the artifact-level refusal rejection that the durable control depends on"
for contract_file in "${constitution}" "${surveyor}" "${maintenance_skill}"; do
  if grep -Fq 'premerge=' "${contract_file}"; then
    fail "standalone CodeRabbit pre-merge readiness state remains in ${contract_file}"
  fi
done

# monorepo#2620 established that an EMPTY CodeRabbit review object is a reply container, not a review.
# Its fix (#2677) landed only in the surveyor overlay, leaving the contract — the surface every lane
# reads, and the normative statement of the gate — accepting a bare `commit_id == head` match.
# Measured over the 60 most recently merged monorepo PRs (2026-08-07): 16 of 19 CodeRabbit review
# objects sitting at a merged head were empty, and monorepo#2607 and #2658 merged with an empty
# container as the ONLY head-matching artifact and no Codex or Bugbot green. The gate's own predicate
# matched a non-review, on the one control standing between an unreviewed change and main.
#
# Each assertion pins one COMPLETE operand: `assert_prose` flattens the file first, so the phrase is
# matched against the words rather than the column the prose happens to wrap at.
assert_prose "${constitution}" 'positively identified as a review' \
  "constitution accepts a CodeRabbit review object without identifying it as a review"
assert_prose "${constitution}" 'an empty object is a reply container, never a review' \
  "constitution does not reject an empty CodeRabbit reply container at head"
# The surveyor already carries the guard (#2677). Pinning it here too keeps the two surfaces from
# drifting apart again in the direction that caused this defect.
assert_prose "${surveyor}" 'Actionable comments posted:' \
  "surveyor lost the positive identification of a CodeRabbit review object"

# monorepo#2819: CodeRabbit now emits every real review body behind an agent-hint HTML comment, so a
# body that BEGINS WITH the marker no longer describes any genuine review. Measured on four
# substantive review objects (monorepo#2810 at 07:18:36Z and 10:56:58Z, monorepo#2723 on 2026-08-12
# at 20:33:20Z and 21:59:21Z) — all four carry the prefix. The identification fails CLOSED, so a real
# current-head review reads as "no review" and the run walks down into weekly-limited Codex and
# monthly-limited Bugbot: the exact inversion the cheapest-lane-first order exists to prevent.
#
# The rule is prose an agent executes, so the drift risk is a later edit quietly restoring the bare
# BEGINS-WITH test at one of the five sites. The fixture below is REAL captured output rather than a
# hand-written sample, and the OLD rule is kept as a live ablation: it must FAIL on that fixture, or
# the fixture no longer reproduces the defect this guard was filed against.
cr_hint_fixture="${repo_root}/.claude/scripts/fixtures/coderabbit-review-body-hint-prefix-2819.txt"
[ -r "${cr_hint_fixture}" ] ||
  fail "the captured CodeRabbit hint-prefixed review body fixture is missing"

# Remove leading HTML comment blocks (and the whitespace around them), then apply the unchanged
# BEGINS-WITH test. An unterminated comment stops the strip rather than consuming the whole body.
# The iteration bound makes the loop STRUCTURALLY terminating. Without it, the unterminated-comment
# branch below is the only thing stopping an infinite repeat, so removing that branch would make this
# contract test HANG rather than fail — an unbounded loop is a worse signal than a wrong answer, and
# `timeout` is not installed on macOS, so the bound cannot be applied from outside.
strip_leading_html_comments() {
  local body="$1" rest guard=0
  while [ "${guard}" -lt 64 ]; do
    guard=$((guard + 1))
    body="${body#"${body%%[![:space:]]*}"}"
    case "${body}" in
      '<!--'*)
        rest="${body#*-->}"
        # No closing delimiter: an unterminated comment must not consume the rest of the body.
        if [ "${rest}" = "${body}" ]; then break; fi
        body="${rest}"
        ;;
      *) break ;;
    esac
  done
  printf '%s' "${body}"
}

# The fixed rule: prefix-tolerant, but still ANCHORED — never a substring search.
cr_body_identifies_as_review() {
  case "$(strip_leading_html_comments "$1")" in
    '**Actionable comments posted:'*) return 0 ;;
    *) return 1 ;;
  esac
}

# The rule as it stood before #2819, kept ONLY as the ablation below.
cr_body_identifies_pre_2819() {
  case "$1" in
    '**Actionable comments posted:'*) return 0 ;;
    *) return 1 ;;
  esac
}

cr_hint_body="$(cat "${cr_hint_fixture}")"

# ABLATION — the defect must still reproduce on real data, or this guard proves nothing.
if cr_body_identifies_pre_2819 "${cr_hint_body}"; then
  fail "the captured fixture no longer reproduces #2819 — the pre-fix rule matched it, so this guard is vacuous"
fi
cr_body_identifies_as_review "${cr_hint_body}" ||
  fail "prefix-tolerant identification does not recognise a real hint-prefixed CodeRabbit review body"

# NEGATIVE CONTROLS — the empty-container rejection (#2620/#2677) must survive the widening, and
# stripping comments must not turn arbitrary prose into a review.
if cr_body_identifies_as_review ""; then
  fail "an empty CodeRabbit reply container is identified as a review"
fi
if cr_body_identifies_as_review "<!-- coderabbit-cli-agent-hint:v3
-->"; then
  fail "a body carrying only the hint comment is identified as a review"
fi
if cr_body_identifies_as_review "> [!TIP]
> For best results, initiate chat on the files or code changes."; then
  fail "a CodeRabbit chat acknowledgement is identified as a review"
fi
# The marker must still be at the START of the stripped body — a mention further in is not a review.
if cr_body_identifies_as_review "Some prose that merely mentions **Actionable comments posted: 2**"; then
  fail "identification degraded from an anchored match to a substring search"
fi
# MULTILINE anchoring. The single-line control above displaces the marker only horizontally, so a
# LINE-anchored implementation (`grep '^\*\*Actionable'`, or a per-line loop) still passes it while
# accepting this body — the marker starts a line, just not the body. Pin the anchor to the whole
# stripped body, not to any line within it.
if cr_body_identifies_as_review "Some prose about a review.
**Actionable comments posted: 2**"; then
  fail "identification anchors per-LINE, so prose followed by the marker is accepted as a review"
fi
# A malformed body — a leading `<!--` with no `-->` — must be REJECTED rather than have its opening
# delimiter silently consume the rest. Verified 2026-08-13: deleting the early `break` leaves this
# control passing, because the iteration bound stops the loop and the body is returned unchanged, so
# it still fails the anchored match. That is stated rather than glossed — this control pins the
# REJECTION, not the break, and the bound above is what actually removes the hang risk. The break is
# an early exit, and its removal is observationally inert only while that bound stands.
if cr_body_identifies_as_review "<!-- unterminated hint
**Actionable comments posted: 2**"; then
  fail "an unterminated leading comment is consumed, so a malformed body is identified as a review"
fi

# The five prose sites that state the rule, each pinned by its OWN surrounding text.
# A bare file-wide presence check would be satisfied by any one occurrence, so the operational
# instruction — the lane table, or the surveyor's primary directive — could regress to the unstripped
# begins-with predicate while a later explanatory paragraph kept the phrase and the suite stayed
# green. Those are the occurrences a run actually executes, so each is asserted separately.
assert_prose "${constitution}" \
  'begins `**Actionable comments posted:` — **after stripping any leading HTML comments and the whitespace around them**, since CodeRabbit prefixes real bodies' \
  "constitution's green-review LANE TABLE lost the strip, so its operational row rejects every real review"
assert_prose "${constitution}" \
  'its body begins `**Actionable comments posted:` **after stripping any leading HTML comments and the whitespace around them**, because' \
  "constitution's CodeRabbit-success paragraph lost the strip, so a real review reads as none"
assert_prose "${surveyor}" \
  '`**Actionable comments posted:`, after stripping any leading HTML comments and the whitespace around them** — a positive' \
  "surveyor's primary cr@<sha> instruction lost the strip, so the digest reports green_review=none over a real green"
assert_prose "${surveyor}" \
  'begins `**Actionable comments posted: N**` **once its leading HTML comments and surrounding whitespace are stripped**' \
  "surveyor's artifact-shape rationale lost the strip, so the two surveyor sites can drift apart"
assert_prose "${parity_checklist}" \
  'begins `**Actionable comments posted:` **after stripping any leading HTML comments and the whitespace around them**; an empty object is a reply' \
  "surveyor parity checklist does not carry the prefix-tolerant identification"
# The widening must not become a bare commit_id match — the empty-container measurement still stands.
assert_prose "${constitution}" 'never weaken this to a bare' \
  "constitution lost the prohibition on weakening identification to a bare commit_id match"

# monorepo#2758, measured on platform#3051 head 992a93caecd1: the head's status read
# `Review completed`, the newest review object was an empty container at an OLDER head, and the
# summary comment named no sha at all — so the finding-free verdict existed ONLY in the
# command-invocation reply. Rejecting that comment TYPE reported `green_review=none` over a real
# green and sent the run down into weekly-limited Codex and monthly-limited Bugbot.
#
# Both halves are pinned deliberately. The ACCEPT half alone would still pass if a later edit
# re-broadened the rule to every command reply, and the REJECT half alone would still pass if the
# third artifact were dropped again — so each surface asserts that it accepts a verdict-bearing
# reply AND that a bare acknowledgement remains a non-review.
# EVERY deployed surface that describes the CodeRabbit artifacts is in this loop, including the
# run-loop overlay a scheduled execution actually follows (monorepo#2759 review, P1): a conjunct
# present in the contract but absent from the overlay is a fail-open with the suite still green.
for f in "${constitution}" "${surveyor}" "${maintenance_skill}"; do
  assert_prose "${f}" 'command-invocation reply comment carrying a verdict' \
    "$(basename "${f}") does not accept CodeRabbit's verdict-bearing command reply, so a real green at head reads as none"
  assert_prose "${f}" 'I found no actionable issues' \
    "$(basename "${f}") does not pin the verdict line that discriminates a review from an acknowledgement"
  assert_prose "${f}" 'prefix of `headRefOid`' \
    "$(basename "${f}") does not require the reply's sha to PREFIX-match the head, so a reply naming an older head would satisfy the gate"
  assert_prose "${f}" 'is an acknowledgement and never a review' \
    "$(basename "${f}") no longer rejects a bare Action-performed shell, so an acknowledgement carrying no verdict satisfies the gate"
  # Measured on the same corpus: platform#3051 comment 5236900950 carries the verdict phrase with NO
  # `at <sha>` clause and reviews an EARLIER head. Dropping the sha conjunct is the obvious
  # simplification and it fails OPEN, so each surface must keep saying both are required.
  assert_prose "${f}" 'no `at <sha>` clause' \
    "$(basename "${f}") does not record that a verdict can omit the sha, so a stale review would satisfy the gate"
  # Freshness is the THIRD conjunct and the easiest to lose: without it a reply posted BEFORE the
  # request satisfies a later round at the same head. The review object and the summary already
  # carry it, so the reply must too, on every surface that describes the reply.
  assert_prose "${f}" 'updated after that request' \
    "$(basename "${f}") does not require the verdict reply to post-date the request, so a pre-request reply satisfies a later round"
  # The reply is matched on plain prose, not a structural marker, so the author bind is what stops
  # any account posting the two phrases with the head prefix and being read as a green.
  assert_prose "${f}" 'user.login == "coderabbitai[bot]"' \
    "$(basename "${f}") does not bind the CodeRabbit artifacts to the bot author, so a spoofed comment satisfies the gate"
done
assert_prose "${parity_checklist}" 'user.login == "coderabbitai[bot]"' \
  "parity checklist does not bind the artifacts to the bot author, so a plugin implementation would accept a spoofed comment"
# The overlay's superseded blanket rejection is what Codex found still contradicting the contract.
assert_absent "${maintenance_skill}" 'Never count an auto-generated command reply/acknowledgement' \
  "portfolio-maintenance again rejects every CodeRabbit command reply, contradicting the contract at runtime"
# The refute half: the superseded rule rejected the comment TYPE outright, which is exactly what
# discarded the verdict. Its return would re-open the defect while every accept assertion above
# still passed.
assert_absent "${constitution}" 'Reject auto-generated command replies/acknowledgements' \
  "constitution again rejects every CodeRabbit command reply, discarding the verdict-bearing one"
assert_absent "${surveyor}" 'Never count an auto-generated command reply, acknowledgement, quota notice, or service shell as a review completion' \
  "surveyor again rejects every CodeRabbit command reply, discarding the verdict-bearing one"
# The parity checklist gates deletion of the local surveyor overlay, so a rule absent from it is one
# the overlay removal drops silently — the same guard pattern as 4c above.
assert_prose "${parity_checklist}" 'CodeRabbit review-object positive identification' \
  "removing the surveyor overlay would silently drop the review-object identification"
# The checklist is what a plugin implementation follows once the local overlay is deleted, so its
# SUBSTANCE is pinned, not just its section title (monorepo#2759 review): a conjunct present in the
# two prose surfaces but absent here is a fail-open with every other assertion above still green.
assert_prose "${parity_checklist}" 'CodeRabbit verdict-bearing command reply' \
  "removing the surveyor overlay would silently drop the third CodeRabbit satisfier"
assert_prose "${parity_checklist}" 'prefix-matching `headRefOid`' \
  "parity checklist does not require the reply's sha to prefix-match the head"
assert_prose "${parity_checklist}" 'I found no actionable issues' \
  "parity checklist does not require the verdict line, so an acknowledgement would satisfy a plugin implementation"
assert_prose "${parity_checklist}" 'updated after the latest authenticated' \
  "parity checklist omits request freshness, so a pre-request reply at the same head satisfies a later round"
assert_prose "${parity_checklist}" 'stays an acknowledgement' \
  "parity checklist no longer rejects a bare Action-performed shell"
if grep -Fq 'pre-merge summary parsing' "${parity_checklist}"; then
  fail "plugin-parity checklist can reintroduce the removed pre-merge gate"
fi
grep -Fq 'finding-free CodeRabbit completion without requiring `APPROVED`' "${parity_checklist}" ||
  fail "plugin-parity checklist does not recognize CodeRabbit review completions"

# The consumer contract, surveyor overlay, and deployment run-loop overlay must remain independently
# followable without recreating the superseded multi-provider interpretation. The legacy Claude alias
# is deliberately excluded: it routes to the plugin and must not duplicate review policy.
grep -Fq 'stop on its first successful current-head review' "${maintenance_skill}" ||
  fail "portfolio-maintenance does not stop after the first provider succeeds"
grep -Fq 'one provider request at a time' "${maintenance_skill}" ||
  fail "portfolio-maintenance permits concurrent provider requests"
grep -Fq 'a successful current-head review from any one provider completes the review gate' "${surveyor}" ||
  fail "portfolio-surveyor still requires CodeRabbit output in addition to another green provider"

# Codex publishes findings in COMMENT form as well as as review objects (monorepo#2577, measured on
# monorepo#2559 head 948bb06f73): a `## Review finding` issue comment carried an open P2 while the
# clean-pass comment landed 41s later at the same head, with zero review objects and zero threads at
# that head. Every pentad item therefore read clear over a live finding. These guards keep item (c)
# covering that surface.
assert_prose "${constitution}" 'its green and its findings in comment form' \
  "constitution still claims Codex findings are only ever review objects"
assert_prose "${constitution}" '`## Review finding` section is a non-thread review finding' \
  "a Codex comment-form finding does not count toward the non-thread finding gate"
assert_prose "${surveyor}" '`## Review finding` section is a non-thread review finding' \
  "surveyor item (c) is blind to a Codex comment-form finding"
assert_prose "${surveyor}" 'full 40-character sha in its blob permalinks' \
  "surveyor has no way to attribute a Codex comment-form finding to a head"
assert_prose "${surveyor}" 'counts as CURRENT-HEAD until an authenticated disclosed resolution reply clears it' \
  "an unattributable Codex comment finding fails OPEN instead of closed"
assert_prose "${surveyor}" 'A newer Codex clean-pass comment never clears an older same-head comment finding' \
  "the 41-second ordering trap can clear an open Codex comment finding"
assert_prose "${maintenance_skill}" '`## Review finding` section is a non-thread review finding' \
  "portfolio-maintenance does not sweep the Codex comment-finding surface"

# Behavioural: the documented attribution mechanism must actually recover the reviewed head from a
# REAL Codex comment-form finding. Fixture is the verbatim monorepo#2559 pair, so a change in what
# Codex posts breaks this test rather than silently disarming the rule.
fixture="${repo_root}/.claude/scripts/fixtures/codex-comment-finding-2559.json"
[ -r "${fixture}" ] || fail "the monorepo#2559 Codex comment fixture is missing"
finding_body="$(jq -r '.[]|select(.body|test("^## Review finding"))|.body' "${fixture}")"
[ -n "${finding_body}" ] || fail "fixture carries no Codex comment-form finding"
green_body="$(jq -r '.[]|select(.body|test("Didn.t find any major issues"))|.body' "${fixture}")"
[ -n "${green_body}" ] || fail "fixture carries no Codex clean-pass comment"
# The defect itself: the finding comment carries NO `**Reviewed commit:**` marker, which is why the
# marker-based sweep could not see it. If that ever changes, this rule needs revisiting.
if grep -Fq '**Reviewed commit:**' <<<"${finding_body}"; then
  fail "fixture finding comment now carries a Reviewed-commit marker; re-derive the attribution rule"
fi
expected_head='948bb06f73809c3aee43501ed81a0904d0fa218e'
attributed="$(printf '%s' "${finding_body}" |
  grep -oE '/blob/[0-9a-f]{40}/' | head -1 |
  sed -E 's#^/blob/([0-9a-f]{40})/$#\1#')" || true
[ "${attributed}" = "${expected_head}" ] ||
  fail "documented blob-permalink attribution did not recover the reviewed head (got '${attributed}')"
# The clean pass names the SAME head 41s later, so recency must never decide between them.
# A here-string, not a pipe: `grep -q` exits at the first match, so the writer dies of SIGPIPE and
# `pipefail` reports THAT — the assertion failed while the fixture genuinely named the head.
grep -Fq -- "${expected_head:0:10}" <<<"${green_body}" ||
  fail "fixture clean-pass comment no longer names the same head; ordering trap not reproduced"

# The contract must be a required PR check, including when its own workflow wiring changes.
# A provider's rate limit is time-boxed and SHORT, so it is one fact PER HEAD, re-read per PR — never
# one fact per run. The window measurably clears in ~28 minutes, so a run-wide latch skips the free
# CodeRabbit lane over an expired refusal and spends the weekly-limited Codex lane instead.
# Measured 2026-08-08: 54 review requests -> 16 real CodeRabbit reviews, 17 rate-limit refusals. On
# #2720 specifically: 14 CodeRabbit requests across 12 DISTINCT heads, 10 of them refused — but only
# 2 were second-or-later requests WITHIN ONE ROUND (classified against the restarting artifact, not
# merely by repeated head). Those 2 are the only waste this probe removes; the other 12 each open a
# round, whose first request the rule preserves. Keep the two apart or the case is inflated.
# These pin the probe, that it is a READ, and that the gate is untouched.
assert_prose "${constitution}" 'READ a lane'"'"'s quota state before spending a request on it' \
  "constitution does not require reading a lane's quota state before spending a request"
assert_prose "${constitution}" 'readable with NO write' \
  "the quota probe is not required to be a read rather than a spent request"
assert_prose "${constitution}" 'Do NOT latch that refusal for the whole run' \
  "a short-lived quota refusal could be latched run-wide, burning the weekly Codex lane"
assert_prose "${constitution}" 'the window cleared inside ~28 minutes' \
  "the measured quota-window duration that refutes a run-wide latch is not recorded"
# The probe's LIMIT must be stated, or a reader takes it for a stronger guarantee than it is and is
# surprised by the one unavoidable refusal per fresh head.
assert_prose "${constitution}" 'cannot prevent the **first** refusal at' \
  "the probe's fresh-head limit is unstated, so it reads as preventing every refusal"
# ...and the obvious remedy for that limit must stay closed. A portfolio-wide TTL covers the fresh
# head and re-creates the latch: measured 2026-08-08, 14 minutes of inherited state already inverted
# the lane order on #2727 while CodeRabbit was serving at that head.
assert_prose "${constitution}" 'may never **replace** the per-head read' \
  "a portfolio-wide quota observation could replace the per-head read, re-creating the latch"
# The measured waste must separate a round's unavoidable FIRST request from a within-round repeat.
# Counting every refusal as waste overstates what the probe buys and hides whether the marker logic
# still permits the repeats that ARE preventable.
assert_prose "${constitution}" 'second-or-later requests within the same round' \
  "the measured waste is not split into within-round repeats vs unavoidable first attempts"
# ...and the split must be classified by ROUND, not by repeated head. A same-SHA refutation opens a
# new round at an unchanged head, so a head-based count can book two protected first attempts as one
# saved repeat. The two tests coincided on #2720; that is luck, not equivalence.
assert_prose "${constitution}" 'Classify by ROUND, not by repeated head' \
  "the waste metric could count repeated heads instead of within-round repeats, overstating the saving"
# ...and the retired overstatement must be GONE, not merely supplemented.
assert_absent "${constitution}" "#2720's eight requests were repeats inside five rounds" \
  "the retired '#2720's eight requests were repeats inside five rounds' overstatement still stands"
# The status is a NEGATIVE filter. Measured 2026-08-08: a run read the never-reviewed default at
# 19:29:29Z, asked on that basis, and was refused 16s later — the default promised nothing. Left
# unqualified, "serving state is readable" licenses the same inversion from the other direction.
assert_prose "${constitution}" 'it can never show the lane serving' \
  "the quota read could be taken as positive evidence that CodeRabbit is serving"
# ...and a refusal must not outlive its round, or a same-SHA restart after a refutation can never
# return to the free lane — the refutation path deliberately creates no new commit.
assert_prose "${constitution}" 'A refusal is scoped to its ROUND, never to the head forever' \
  "a one-off refusal at a head could permanently skip CodeRabbit there, inverting the lane order"
# ...and that scoping must key on WHICH REQUEST produced the refusal. Scoping it to "observed in this
# round" is circular: the mandatory pre-trigger read is itself an observation in the new round, so a
# durable old refusal reads as current forever and the skip never expires.
assert_prose "${constitution}" 'a refusal justifies skipping only when THIS round has already posted a CodeRabbit request marker' \
  "refusal provenance is not tied to a request marker, so a durable old refusal can read as current"
# The OPERATIVE instruction must carry the round qualification itself. Stating the skip unconditionally
# and qualifying it 35 lines later means an agent acts on the unqualified form first and advances to a
# metered lane before ever reaching the refinement -- the same-SHA restart is then skipped in practice
# however correct the later prose is. A rule is what its operative sentence says.
assert_prose "${constitution}" 'A refusal you cannot attribute to this round is **not** a reason to skip' \
  "the operative skip instruction is unqualified, so a durable prior-round refusal skips CodeRabbit before the round test is reached"
# ...and the marker test must NOT be claimed mechanical on its payload alone. At an unchanged SHA the
# previous round's marker is indistinguishable from this round's by head, provider, comment id or
# timestamp, so a durable refusal postdates the OLD marker just as well and the restarted round's
# mandatory first CodeRabbit request is skipped — the same-SHA refutation path this section protects.
assert_prose "${constitution}" 'do NOT identify its round' \
  "the marker payload is presented as round-identifying, so a same-SHA restart reuses the old round's marker"
assert_prose "${constitution}" 'newest RESTARTING ARTIFACT at that head' \
  "no round boundary is derivable, so the marker test cannot distinguish a restarted round"
assert_prose "${constitution}" 'a refusal never pre-empts the FIRST CodeRabbit request of a round' \
  "a stale refusal could still pre-empt a round's first CodeRabbit request"
# The optimisation must not become a way around the gate, nor a shortcut into the local fallback.
assert_prose "${constitution}" 'never WHETHER A REVIEW IS REQUIRED' \
  "the lane probe could be read as relaxing the green-review gate"
assert_prose "${constitution}" 'never** evidence for the *Local review round* fallback on its own' \
  "a per-head quota refusal could be misread as satisfying the local-review-round evidence bar"

grep -Fq 'review-provider-loop-contract: ${{ steps.filter.outputs.review-provider-loop-contract }}' "${workflow}" ||
  fail "CI does not export the review-provider contract change filter"
grep -Fq '.claude/plugin-consumption/agentic-engineering-surveyor-diff.md' "${workflow}" ||
  fail "parity-checklist changes do not trigger the review-provider contract check"
# The captured review bodies are inputs to this test, so a fixture-only edit can
# invalidate a regression case. Without the fixture path in the filter that edit
# skips this job and CI stays green over a case that no longer reproduces.
grep -Fq '.claude/scripts/fixtures/**' "${workflow}" ||
  fail "fixture changes do not trigger the review-provider contract check"
grep -Fq 'test-review-provider-loop-contract:' "${workflow}" ||
  fail "CI does not define the review-provider contract test job"
grep -Fq 'run: bash .claude/scripts/review-provider-loop-contract.test.sh' "${workflow}" ||
  fail "CI does not execute the review-provider contract test"
grep -Fq '${{ needs.test-review-provider-loop-contract.result }}' "${workflow}" ||
  fail "the required aggregate check does not include the review-provider contract job"

echo "review-provider loop contract: all assertions passed"
