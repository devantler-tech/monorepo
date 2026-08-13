#!/usr/bin/env bash
#
# Guards the work-selection ladder (maintainer direction 2026-07-25): a run picks work top-down —
# live breakage, then EVERY open PR it owns or trusts INCLUDING ITS OWN DRAFTS, then security
# issues, then bugs, then the oldest actionable issue.
#
# Why this needs enforcing rather than merely stating: the contract already said "PRs before issues"
# and already said "stop starting, start finishing", and the pile still happened. The mechanism was a
# SCOPING hole, not a missing rule — priority-1 was defined over `non-draft` PRs in Merge policy, so
# an own draft matched no rung and was reachable only through a paragraph 1,800 lines away that read
# as a precondition on opening new drafts. Measured 2026-07-25: 99 open own PRs, 100% drafts, none
# ever promoted, median age 6.9 days, 18 already CLEAN and idle a median 5.3 days, 16 conflicted,
# 49 of 88 untouched in the 24h after opening.
#
# So this guards the two properties that actually close that hole, plus the drift that reopened it:
#   1. the ladder exists, is ordered, and names all five rungs;
#   2. rung 1 explicitly covers OWN DRAFTS, and Merge policy's `non-draft` is explicitly scoped to
#      the merge command rather than the sweep — the exact misreading that produced the pile;
#   3. rung 1 is oldest-updated first across the whole lane, with explicit terminal states and no
#      replacement-intake loophole;
#   4. severity outranks age, so a Security issue is not queued behind an older Docs one;
#   5. the run-loop skill agrees with the contract — three surfaces restate this ordering, and a
#      silent divergence between them is how the previous wording drifted;
#   6. intake is CAPPED and not merely ordered — because fixing (2) still did not drain the pile, and
#      the re-measurement showed why: ordering is not the binding constraint, review capacity is.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
maintenance_skill="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"
surveyor="${repo_root}/.claude/agents/portfolio-surveyor.md"
workflow="${repo_root}/.github/workflows/ci.yaml"

fail() {
  echo "work-priority ladder: FAIL — $*" >&2
  exit 1
}

# Markdown prose is hard-wrapped, so a guarded sentence routinely spans two lines and exists on NO
# single line. Flatten once and match substrings against the flattened copy; keep `grep -Fq` only
# for things that genuinely live on one line (a heading, a table row, an identifier).
constitution_flat="$(tr '\n' ' ' < "${constitution}" | tr -s '[:space:]' ' ')"
skill_flat="$(tr '\n' ' ' < "${maintenance_skill}" | tr -s '[:space:]' ' ')"
surveyor_flat="$(tr '\n' ' ' < "${surveyor}" | tr -s '[:space:]' ' ')"

assert_prose() {
  case "$2" in
    *"$1"*) ;;
    *) fail "$3" ;;
  esac
}

# The mirror of assert_prose, and the reason this suite needed one. Presence-only assertions cannot
# see a RETIRED sentence that survived somewhere else in the file: when a policy is widened, the new
# wording is added where the diff is, while the old contradicting wording sits in the sections the
# diff never touched. Measured 2026-08-08 on the PR-ownership widening — CodeRabbit anchored 2
# surviving contradictions, there were actually 4, and all 420 presence assertions across the seven
# AGENTS.md-guarding suites passed green over every one of them (monorepo#2733 carries the
# cross-suite measurement). A contract test that only checks what was ADDED proves half the change.
assert_absent() {
  case "$2" in
    *"$1"*) fail "$3" ;;
    *) ;;
  esac
}

# ── 1. the ladder exists and is ordered ──────────────────────────────────────
grep -Fq '### The work-selection ladder — one ordering, checked top-down every run' "${constitution}" ||
  fail "contract does not define the work-selection ladder"
assert_prose 'you do not descend while a higher rung still has actionable work' \
  "${constitution_flat}" "ladder does not state that rungs are strictly ordered"

for rung in \
  '| **0** | **Live breakage** |' \
  '| **1** | **Open PRs — INCLUDING your own drafts** |' \
  '| **2** | **Security issues** |' \
  '| **3** | **Bugs** |' \
  '| **4** | **Oldest actionable issue** |'; do
  grep -Fq "${rung}" "${constitution}" ||
    fail "ladder is missing rung row ${rung}"
done

# ── 2. rung 1 covers own drafts, and `non-draft` is scoped to the merge command ──
assert_prose 'Rung 1 includes your own DRAFTS' \
  "${constitution_flat}" "ladder does not put own drafts in rung 1 — the exact hole that produced the pile"
assert_prose 'draft and non-draft alike' \
  "${constitution_flat}" "rung 1 does not state it covers drafts and non-drafts alike"
assert_prose 'scoping below bounds the merge COMMAND, never the SWEEP' \
  "${constitution_flat}" "Merge policy does not scope its non-draft clause to the merge command"

# ── 3. rung 1 drains the oldest work before the freshest ──────────────────────
assert_prose 'oldest-updated first across the whole lane' \
  "${constitution_flat}" "rung 1 does not order drafts oldest-updated first across the lane"
# Markdown backticks are literal prose, not command substitution.
# shellcheck disable=SC2016
assert_prose 'Sort the actionable non-automation set by `updatedAt` ascending' \
  "${constitution_flat}" "rung 1 does not specify the normative updatedAt ascending sort"
assert_prose 'a stale draft is not worth reviving' \
  "${constitution_flat}" "rung 1 allows close-and-refile for a draft still worth reviving"
assert_prose 'closed with every still-valid finding re-filed as an issue' \
  "${constitution_flat}" "rung 1 does not name close-and-refile as a legitimate terminal state"
assert_prose "the lane's total open own-PR count must not rise while the oldest cohort drains" \
  "${constitution_flat}" "rung 1 lets old-draft disposal finance replacement intake"
assert_prose 'no replacement draft may be opened merely because an old one was disposed of' \
  "${constitution_flat}" "rung 1 permits replacement drafts after old-draft disposal"

# ── 4. severity outranks age ──────────────────────────────────────────────────
assert_prose 'Severity outranks age at rungs 2–3; age decides only *within* a rung' \
  "${constitution_flat}" "contract does not state that severity outranks age"

# ── 5. the run-loop skill agrees with the contract ────────────────────────────
assert_prose 'Your own DRAFTS are rung-1 work' \
  "${skill_flat}" "run-loop skill does not carry the own-drafts rung-1 rule"
assert_prose 'severity is the primary sort, age the tiebreaker within a tier' \
  "${skill_flat}" "run-loop skill still sorts the issue queue by age alone"
assert_prose 'Resolve the next issue by the ladder' \
  "${skill_flat}" "run-loop skill's advance step does not follow the ladder"

# ── 6. intake is CAPPED, not merely ordered ──────────────────────────────────
# Re-measured 2026-07-26, after §2's fix landed: the pile did NOT drain. 99 → 91 open own PRs, still
# 100% drafts, and median age ROSE 6.9d → 8.0d. Per lane it was 88/91 `codex/*` — and 63 of those 88
# (72%) were opened on ONE day, all on one repo, all one theme, every sampled one NEVER reviewed and
# by then BLOCKED or DIRTY. So §2's diagnosis was incomplete: ordering cannot drain a pile, because
# promotion needs a green review at the current head and the review lanes are metered and shared. A
# run that opens its whole batch in one pass satisfies "finish before you start more" VACUOUSLY — it
# had nothing in flight when it started. These guard the cap that closes that, and the carve-outs
# that keep it from blocking mandated work.
assert_prose 'The WIP limit is also a CAP ON INTAKE, not only an ordering' \
  "${constitution_flat}" "contract does not bound draft intake — ordering alone cannot drain a pile"
assert_prose 'a run that opens its whole batch in one pass satisfies it **vacuously**' \
  "${constitution_flat}" "contract does not explain why the ordering rule is satisfiable vacuously"
grep -Fq '| **Per run** | Open at most **5** new own drafts. |' "${constitution}" ||
  fail "contract does not state the per-run draft intake cap"
# Assert the WHOLE row, not just the threshold: a prefix match would still pass with the actual
# instruction ("open no new ones") deleted, leaving a number that binds nothing.
grep -Fq '| **Per lane** | While your own lane holds **more than 20** open drafts, open **no** new ones — spend the whole run finishing. |' "${constitution}" ||
  fail "contract does not state the per-lane draft ceiling"
# The carve-outs are load-bearing: without them the cap would block a hotfix or stop the backlog
# being captured, which is a guard firing on correct mandated work.
assert_prose 'Rung-0 live breakage is exempt from both' \
  "${constitution_flat}" "intake cap does not exempt live breakage — it would block a hotfix"
assert_prose 'filing an issue is not opening a draft' \
  "${constitution_flat}" "intake cap does not exempt issue capture — the backlog would stop being capturable"
# Autonomy must no longer bless an unreviewable burst as "not sprawl".
assert_prose 'What IS sprawl is a burst that outruns your own review capacity' \
  "${constitution_flat}" "Autonomy still licenses an unbounded draft set as 'not sprawl'"
# A cap bounds STARTING, never the run itself — without this the cap reads as permission to idle,
# which would trade the floor and "work as long as there is work" for the pile fix.
assert_prose 'A cap is NOT licence to stop early, and it never blocks the floor' \
  "${constitution_flat}" "intake cap does not say it bounds starting rather than the run — it reads as licence to idle"
# ...and that it says what a capped run should do INSTEAD. Without this, "don't stop early" states
# only the prohibition, leaving the redirection to finishing implicit.
assert_prose 'the cap redirects a run **from starting toward finishing**, and finishing is unbounded' \
  "${constitution_flat}" "contract does not redirect a capped run toward finishing"

# ── the run floor's escape hatch must expire, like every other ownership signal ────────────────────
# The floor let a run author nothing when every actionable PR was "correctly maintainer-gated". That
# phrase is defined NOWHERE and reads as permanent, so it survived the PR-ownership widening as a
# standing excuse to stop: an agent could park a PR that is neither terminal nor covered by any live
# signal, which is exactly the passive self-blocking the contract forbids elsewhere. The replacement
# binds the exception to the data-only active-work test, whose every signal expires.
assert_absent 'every open actionable PR is correctly maintainer-gated' \
  "${constitution_flat}" "the retired permanent-sounding 'maintainer-gated' floor exception survived"
assert_prose 'already terminal or held by a live, unexpired' \
  "${constitution_flat}" "floor exception is not tied to the live, unexpired active-work signal"
assert_prose 'That exception is time-bounded, never a standing state' \
  "${constitution_flat}" "floor exception does not state that it expires — it reads as permanent"
assert_prose 'no undefined permanent-sounding gate' \
  "${constitution_flat}" "floor exception does not forbid an undefined gate standing in for a signal"

# ── `--auto` is for AUTHOR-scoped permissions only; a classifier result is COMMIT-scoped ───────────
# `--auto` merges whatever head passes checks LATER and re-evaluates nothing, so it can only ever
# carry a permission that a later head cannot invalidate — i.e. one held by the AUTHOR.
#
# The earlier form of this guard pinned a flat four-name list, `app/botantler-1` included "on a PR
# the classifier exits 0 on". That is a COMMIT-scoped permission sitting in an author-scoped list,
# and listing it there is what made the unsafe arming read as prescribed: exit 0 waives the REVIEW
# for one head, never the requirement to merge at that same head. An updater push during the
# `--auto` wait lands a replacement head the classifier never ran on — possibly an exit-1/3 head
# needing the very review exit 0 waived — and `--match-head-commit` does not close it, because it
# gates the ARMING, not the later merge. So pin the three-plus-one split in both surfaces, and pin
# the re-run that keeps the exemption tied to the commit it was granted for.
assert_absent '(`github-actions`/`ksail-bot`/`app/cursor`) uses pre-CLEAN' \
  "${constitution_flat}" "the ambiguous bare three-name --auto author list survived"
assert_prose 'The `--auto`-eligible authors are exactly three, and every one of them is eligible unconditionally' \
  "${constitution_flat}" "contract does not state the --auto author matrix as three unconditional authors"
assert_prose '`app/botantler-1` is NEVER `--auto`-eligible — not even on exit 0' \
  "${constitution_flat}" "contract does not exclude app/botantler-1 from --auto on every classifier result"
assert_prose 're-run the classifier at the current head immediately before merging' \
  "${constitution_flat}" "contract does not require a classifier re-run at the head being merged"

# The DEPLOYED run loop is what a run actually follows, so fixing the contract alone leaves the
# unsafe path live where it is read — which is exactly what happened: the contract gained the
# direct-merge requirement while this overlay still listed the updater among the `--auto` authors,
# so scheduled runs kept following the unsafe path. Mirror both halves here.
assert_absent 'the three **trusted single-author Apps**' \
  "${skill_flat}" "the maintenance skill still states an exclusive three-App --auto list"
assert_absent '`--auto` is for those named Apps only' \
  "${skill_flat}" "the maintenance skill still scopes --auto to an unnamed 'those named Apps' set"
assert_prose '`--auto`-eligible authors are exactly three, and every one of them is eligible unconditionally' \
  "${skill_flat}" "the maintenance skill does not state the --auto author matrix as three unconditional authors"
assert_prose '`app/botantler-1` is never `--auto`-eligible, not even on exit 0' \
  "${skill_flat}" "the maintenance skill does not exclude app/botantler-1 from --auto on every classifier result"

# Asserting the COUNT leaves the three names unpinned — a policy edit could swap
# `github-actions`/`ksail-bot`/`app/cursor` for different authors and every assertion above would
# still pass. `--auto` merges whatever head passes checks later, so WHICH author holds that power is
# the whole security property; pin the contiguous list in both documents, not just its shape. The
# trailing `and` before `app/cursor` (rather than a comma) is what makes this fail if a fourth name
# is appended to the list — the exact regression this guard exists to catch.
for _doc_pair in "constitution:${constitution_flat}" "skill:${skill_flat}"; do
  _doc_label="${_doc_pair%%:*}"
  _doc_text="${_doc_pair#*:}"
  assert_prose '`github-actions`, `ksail-bot`, and `app/cursor`' \
    "${_doc_text}" "the ${_doc_label} does not name the three unconditional --auto authors as a closed contiguous list"
  assert_absent '`github-actions`, `ksail-bot`, `app/cursor`, and `app/botantler-1`' \
    "${_doc_text}" "the ${_doc_label} still lists app/botantler-1 in the --auto author list"
done

# ...and bind the exit-0 result to the direct-merge outcome in the SKILL. The contract side is
# asserted above and deliberately not repeated — a second copy would pass or fail in lockstep with
# the first while reading like independent coverage.
#
# Match a CONTIGUOUS span carrying the classifier re-run AND the head-pinned direct merge it feeds.
# Asserting the re-run alone proves the skill *mentions* re-running; it proves nothing about what
# the result is then used for, so a later edit could keep the phrase and re-arm `--auto` behind it
# while the assertion stayed green. This span fails if either half is edited away.
assert_prose 'Re-run the classifier at the current head immediately before the merge' \
  "${skill_flat}" "the maintenance skill does not require a classifier re-run at the head being merged"
assert_prose 'then merge head-pinned with `gh pr merge <n> --repo devantler-tech/<repo> --squash --match-head-commit <sha>`' \
  "${skill_flat}" "the maintenance skill does not bind the re-run to a head-pinned direct merge"

# ── PR ownership: every PR in the portfolio, whoever authored it (maintainer direction 2026-08-08) ──
# Rung 1 previously meant "own/trusted PRs in YOUR lane", with anyone else's draft stopping at hygiene.
# The maintainer retired that split interactively. These pin the three parts that a later run could
# each independently lose: the grant itself, closing as a real terminal state, and the data-only test
# for whether someone else is mid-flight (he was explicit: "No need to ask, just determine it").
assert_prose 'is now yours to carry to a **terminal state**, whoever' \
  "${constitution_flat}" "contract does not grant ownership of PRs authored by others"
assert_prose '**Three terminal states, and CLOSING is first-class.**' \
  "${constitution_flat}" "closing a valueless PR is not stated as a terminal state"
assert_prose 'is decided from data, never by asking' \
  "${constitution_flat}" "the active-work test does not forbid asking the maintainer"

# The widened MERGE authority must not be read as widening the EXECUTION guardrail. "Be careful" was
# the maintainer's whole qualifier on contribution PRs, and this is what it has to mean mechanically:
# CI is the sandbox, the local checkout is not.
assert_prose 'or otherwise run its branch locally' \
  "${constitution_flat}" "external-PR ownership no longer forbids running a contributor branch locally"

# Renovate/Dependabot stay out: their carve-out is an ownership boundary the 2026-08-08 direction did
# not revisit, and folding them into "all PRs" would have an agent driving the bots' own lifecycle.
assert_prose '**Automation-owned Renovate/Dependabot PRs stay excluded**' \
  "${constitution_flat}" "the automation-owned carve-out was swallowed by the all-PRs grant"

# ── the retired wording must STAY retired ────────────────────────────────────
# One negative assertion per sentence the 2026-08-08 widening replaced. Each of these was PRESENT in
# AGENTS.md before that change and is ABSENT after it, so every one of them fails on the pre-widening
# file and passes on the current one — they pin a real transition rather than restating it. They live
# in four different sections (the issue queue, the bot-PR paragraph, Merge policy, and the trust
# gate), which is exactly why the presence-only suite missed them: a reviewer anchors where the diff
# is, and a surviving contradiction lives where the diff is NOT.
assert_absent 'static-review-only and surfaced to the maintainer' \
  "${constitution_flat}" "the issue queue still routes external PRs to static review + the maintainer"
assert_absent 'the external-contributor gate, which stands unchanged' \
  "${constitution_flat}" "the bot-PR paragraph still claims the whole external gate is unchanged"
assert_absent '**Never merge external-contributor PRs**' \
  "${constitution_flat}" "Merge policy still forbids merging external-contributor PRs"
assert_absent 'never enable auto-merge; never merge' \
  "${constitution_flat}" "the trust gate still forbids merging an external contributor's PR"

# ── the CONSUMERS the runtime actually reads must agree, not just AGENTS.md ───
# The four assertions above pin the contract. They cannot see the two overlays a scheduled run
# actually loads — the maintenance skill and the surveyor — so the widening could be fully stated in
# AGENTS.md while the deployed digest still told the orchestrator the opposite. That is not
# hypothetical: at head 7b69df20 the surveyor's digest row still read "EXTERNAL/Copilot — review
# statically only (never auto-drive/merge)" and its trust-label rule still said "never imply they are
# mergeable", both retired by the 2026-08-08 grant. CodeRabbit anchored the first; the second sat
# eleven lines from a heading the diff never touched.
#
# These also pin the SELECTOR the overlays queue on. The predicate was widened from own/trusted to
# every actionable PR, and a consumer left on the old selector silently re-narrows rung 1 at runtime
# while every AGENTS.md assertion stays green.
assert_absent 'never auto-drive/merge' \
  "${surveyor_flat}" "the surveyor digest still tells the orchestrator not to drive an external PR"
assert_absent 'never imply they are mergeable' \
  "${surveyor_flat}" "the surveyor still treats external PRs as unmergeable"
assert_absent 'own/trusted' \
  "${surveyor_flat}" "the surveyor still selects PRs on the retired own/trusted predicate"
assert_absent 'own/trusted' \
  "${skill_flat}" "the maintenance skill still selects PRs on the retired own/trusted predicate"
assert_absent 'actionable trusted-author' \
  "${skill_flat}" "the maintenance skill still scopes its PR sweep to trusted authors"
assert_absent 'PRs static-review-only (trust gate)' \
  "${skill_flat}" "the skill still records external PRs as static-review-only rather than never-run-locally"

# ── the three PROHIBITIONS the assertions above could not see ────────────────
# Measured on this branch at head 55b76859: every assertion above passed while the loaded overlay
# still forbade merging an external PR in three separate places, one of them seven lines below a
# sentence in the same list item stating the new rule. A presence-only suite cannot catch that: it
# pins what the new text SAYS, never what the old text still says elsewhere. These three name the
# surviving sentences directly, so the suite fails on the unfixed skill instead of passing over it.
assert_absent 'Never run or merge **external-author** PRs anywhere' \
  "${skill_flat}" "the merge-path bullet still forbids merging an external-author PR"
assert_absent 'Never auto-drive or merge external PRs' \
  "${skill_flat}" "the hygiene sweep still forbids auto-driving an external PR"
assert_absent 'Never merge external PRs' \
  "${skill_flat}" "the non-negotiable global rules still forbid merging an external PR"

# The DEEPENING selector is a second, quieter way the surveyor re-narrows rung 1 at runtime. Widening
# which PRs the orchestrator may drive achieves nothing while the survey still pulls the pentad only
# for `devantler`/trusted-bot authors: every other PR arrives as a cheap static row carrying no
# checks, threads, review state or mergeability, and a PR whose pentad was never fetched cannot be
# reviewed, promoted, merged, closed or parked. The contract reads fully widened; the run cannot act.
assert_absent 'actionable trusted-bot PRs' \
  "${surveyor_flat}" "the surveyor still deepens only devantler/trusted-bot PRs, so every other PR arrives unactionable"
assert_prose 'drafts and non-drafts, whoever authored it' \
  "${surveyor_flat}" "the surveyor no longer deepens every open PR regardless of author"
# Trust must survive the widening in the one place it still belongs — which branch may be RUN — or
# the negative above could be satisfied by deleting the execution distinction rather than rescoping it.
assert_prose 'Author trust decides EXECUTION, never deepening' \
  "${surveyor_flat}" "the surveyor no longer separates execution trust from the deepening selector"

# The SAME re-narrowing lives a SECOND time in the loaded procedure overlay, and every assertion
# above is structurally blind to it — they read the surveyor agent file, not the skill. Measured at
# head 14e62397 (CodeRabbit, 🟠 Major): the overlay's deepening step still selected `devantler`
# candidates and trusted bots, while its own pentad line two paragraphs later demanded that evidence
# for every actionable PR whoever authored it. One file, two selectors, disagreeing — so a run
# following the overlay literally reports a pentad it never fetched for exactly the PRs the
# 2026-08-08 grant made it responsible for.
assert_absent 'candidate/actionable trusted-bot PR' \
  "${skill_flat}" "the maintenance skill still deepens only devantler/trusted-bot PRs"
assert_prose 'deepens every remaining open actionable PR' \
  "${skill_flat}" "the maintenance skill no longer deepens every actionable PR regardless of author"
# ...and here too the widening must RESCOPE execution trust, not delete it: deepening an external PR
# reads the GitHub API, which is not running its branch. Without this the negative above could be
# satisfied by dropping the distinction entirely.
assert_prose 'never an execution of its branch' \
  "${skill_flat}" "the maintenance skill no longer separates metadata deepening from branch execution"

# Deepening every PR costs far more API budget than the selector it replaces, and this survey's own
# pool ran out mid-run (2026-08-09), leaving 40 platform PRs with no pentad at all. Silent truncation
# is the dangerous shape: an undeepened PR reported as a cheap row is indistinguishable from one that
# was assessed and found unremarkable, so the run reads a coverage gap as a clean bill of health.
assert_prose 'NOT-DEEPENED (budget)' \
  "${surveyor_flat}" "the surveyor may drop PRs on budget exhaustion without declaring the gap"

# The ownership gate keyed on the orchestrator's creation record — which the surveyor cannot read,
# and which NO maintainer-authored PR can ever satisfy, so it structurally parked exactly the PRs the
# 2026-08-08 grant made the routine responsible for. It is replaced by signals the survey can observe.
assert_prose 'report the ACTIVE-WORK signals, not an ownership verdict' \
  "${surveyor_flat}" "the surveyor still returns an ownership verdict instead of the active-work signals"
# A finished bot review is the cue to ACT. Reporting it as active work parks the PR for ~2h against
# the mandatory every-run pentad sweep, which on an hourly cadence compounds into findings that never
# get fixed — so the one reviewer state that does own the next move is a request still awaiting reply.
assert_prose 'A COMPLETED bot review is NOT an active-work signal' \
  "${surveyor_flat}" "the surveyor may report a finished bot review as active work and park the PR"

# ...and the retired gate must be ABSENT, not merely outvoted by the new wording above. The two rules
# sat in one file at the same head: the new classification at the PR-reporting step, the old
# prohibition in the reporting-rules section the diff never reached. Presence-only assertions accept
# both, so the surveyor kept emitting OWNERSHIP-UNVERIFIED and withholding MERGE-READY for every
# `devantler` PR — defeating the widening's entire purpose while its own contract test passed green.
assert_absent 'tag it `OWNERSHIP-UNVERIFIED`' \
  "${surveyor_flat}" "the surveyor still tags a devantler PR OWNERSHIP-UNVERIFIED"
assert_absent 'never `MERGE-READY`' \
  "${surveyor_flat}" "the surveyor still forbids classifying a devantler PR MERGE-READY"
assert_absent 'Never assert ownership of a `devantler` PR' \
  "${surveyor_flat}" "the surveyor still carries the retired creation-record ownership gate"
# The positive half, so the negatives above cannot be satisfied by deleting the classification too.
assert_prose 'green non-drafts `MERGE-READY`' \
  "${surveyor_flat}" "the surveyor no longer classifies a green devantler non-draft MERGE-READY"

# Same drift class, two more surfaces a run LOADS. The retired creation-record gate survived where
# the widening's diff never reached: the surveyor re-imposed it after the fallback-review rule, which
# nullifies that fallback for the one class it was widened to cover (a taken-over
# maintainer-interactive PR can never satisfy a creation record); and the maintenance skill still
# instructed the run to apply the record before acting. Both passed every presence assertion.
assert_absent 'still applies its creation-record test before acting on any `devantler` row' \
  "${surveyor_flat}" "the surveyor re-imposes the retired creation-record gate after fallback review"
assert_prose 'What the orchestrator applies before acting on a `devantler` row is the **`active=` test**' \
  "${surveyor_flat}" "the surveyor does not route pre-action gating through the active-work test"
assert_absent 'apply your creation record to every surfaced' \
  "${skill_flat}" "the maintenance skill still gates maintainer comments on a creation record"
assert_prose 'Attribute the COMMENT; never gate on a creation record' \
  "${skill_flat}" "the maintenance skill does not separate comment attribution from drive authority"
# The disclosure still decides WHOSE control channel a comment is — retiring the gate must not
# delete that, or his commentary on his own PR becomes an instruction addressed to the run.
assert_prose 'his comments are him steering *his* work, not' \
  "${skill_flat}" "the maintenance skill no longer attributes comments on maintainer-interactive PRs"
# What SURVIVES the retirement: branch and disclosure stay, for comment attribution only, and the
# set-level ownership claim stays banned — an aggregate "no maintainer-interactive PRs here" still
# misleads the orchestrator about whose control channel a `devantler` comment is.
assert_prose 'never emit a set-level claim that the maintainer-interactive class is empty' \
  "${surveyor_flat}" "the surveyor may report the maintainer-interactive class as empty"

# The positive half: the execution guardrail must SURVIVE in the consumer that reports these PRs, or
# the negatives above could be satisfied by deleting the distinction rather than correcting it.
assert_prose 'never run locally' \
  "${surveyor_flat}" "the surveyor no longer records that an external branch is never run locally"

# ── the widening's remaining reach into the MERGE path ───────────────────────
# Four further contradictions the widening left behind, each in a section its diff never touched.
# Grouped here because they share one failure mode: the new eligibility is stated where the change
# was made, and the old precondition still gates the step that actually runs.

# (1) The merge preflight scoped the local review round to own PRs, while *Local review round* had
# already been widened to taken-over PRs. A taken-over PR could obtain the fallback review the
# contract defines for it and still be refused by the preflight that consumes it.
assert_absent 'which is available on own PRs only' \
  "${constitution_flat}" "the merge preflight still scopes the local review round to own PRs"
assert_prose 'available on your own **and on taken-over** PRs' \
  "${constitution_flat}" "the merge preflight does not carry the widened local-review-round eligibility"

# (2) The preflight demands owner `devantler-tech` from a read that cannot supply it: none of the
# requested fields carries the BASE repository's identity, and the command was unpinned, so a
# cross-repo sweep could inspect a colliding PR number in whatever checkout it stood in.
assert_prose 'gh pr view <n> --repo devantler-tech/<repo> --json number,isDraft,author,headRefOid,mergeStateStatus,statusCheckRollup' \
  "${constitution_flat}" "the prescribed pre-merge read is not pinned to the base repository with --repo"
assert_prose '`--repo` is part of the prescription, not an optional convenience' \
  "${constitution_flat}" "the contract does not say why the pre-merge --repo pin is load-bearing"

# (3) A COMPLETED reviewer artifact was read as "someone is working here", parking the PR ~2h against
# the mandatory every-run pentad sweep — on an hourly cadence, findings age untouched at the current
# head. Row 3 already covers the only reviewer state that owns the next move: a request still in its
# response envelope. The human row must stay human, or the parking returns.
assert_absent 'A **non-agent** comment or review within the last' \
  "${constitution_flat}" "a completed bot review still reads as active ownership and parks the PR"
assert_prose 'A reviewer'"'"'s COMPLETED output is the opposite of an ownership signal' \
  "${constitution_flat}" "the contract does not say a finished review is a cue to act rather than to park"

# (4) The CI-based user evaluation was hung on PROMOTION, which an external contributor never reaches:
# they open ready-for-review, so the preflight's isDraft/CLEAN/findings/review check would let a
# stranger's change merge with nobody having observed its behaviour.
assert_prose 'This is a MERGE precondition for an external PR, not a promotion one' \
  "${constitution_flat}" "the external-PR user evaluation is still gated on promotion, which a non-draft PR skips"
# ...but DECLARING it a merge precondition is not the same as the merge step REQUIRING it, and the
# assertion above cannot tell those apart. Measured at head 14e62397 (CodeRabbit, 🟠 Major): the
# preflight listed `isDraft:false` + owner + `CLEAN` + findings + review state and nothing else, so
# the operative checklist a run actually executes still merged a build-and-lint-only external PR that
# no one had observed — the exact hole the declaration was written to close, reopened one section
# later. Pin the binding itself, and its fail-closed branch.
assert_prose 'current-head evaluation record' \
  "${constitution_flat}" "the merge preflight does not require the external-PR behaviour record at head"
assert_prose 'park the PR on that named blocker' \
  "${constitution_flat}" "the preflight lets a build-and-lint-only external PR merge instead of parking it"
# ...and requiring the record is still not enough, because nothing said WHO may author it or that the
# run it names must be read. Measured at head 38786ef5 (CodeRabbit, 🟠 Major, Security & Privacy): the
# record was admitted on the strength of the disclosure prefix, which is a public convention anyone
# can type — so on an EXTERNAL PR the contributor could post it themselves and satisfy the one
# condition the paragraph exists to impose on them. Both halves are pinned, because either alone
# leaves the hole: an unauthenticated record, or an authenticated claim about a run nobody opened.
assert_prose 'the disclosure prefix is **NOT** authentication' \
  "${constitution_flat}" "an external contributor can author their own merge precondition"
assert_prose 'author exactly `devantler`' \
  "${constitution_flat}" "the external-PR evaluation record is not bound to an authorized author"
assert_prose 'a record is a claim, not evidence' \
  "${constitution_flat}" "the cited CI run is taken on trust instead of being read"

# ── CI wiring ─────────────────────────────────────────────────────────────────
# GitHub expression tokens are literal workflow syntax, not shell expansions.
# shellcheck disable=SC2016
grep -Fq 'work-priority-ladder: ${{ steps.filter.outputs.work-priority-ladder }}' "${workflow}" ||
  fail "CI does not export the work-priority ladder filter"
grep -Fq 'test-work-priority-ladder:' "${workflow}" ||
  fail "CI does not define the work-priority ladder job"
grep -Fq 'run: bash .claude/scripts/work-priority-ladder.test.sh' "${workflow}" ||
  fail "CI does not execute the work-priority ladder test"
# shellcheck disable=SC2016
grep -Fq '${{ needs.test-work-priority-ladder.result }}' "${workflow}" ||
  fail "required checks do not aggregate the work-priority ladder"

echo "work-priority ladder: all assertions passed"
