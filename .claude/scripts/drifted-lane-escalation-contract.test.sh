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
# `plugin-definition-refresh.sh` can REPAIR exactly one: it takes no runtime selector, and it drives
# the Claude CLI control plane — dying unless it resolves an executable `claude`. Its plugins root is
# NOT the constraint; `--plugins-root` makes that configurable, and naming it as the limitation would
# send a future repair at a filesystem restriction that does not exist. So on two of three lanes the
# script is never invoked, neither trigger can fire, and a
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
#   1. The obligation is keyed to the CONDITION — a lane reading DRIFT whose repair is unavailable,
#      refused, fenced or failed — never to a tool's exit code. `plugin-definition-currency.sh` detects
#      drift on three lanes; `plugin-definition-refresh.sh` repairs one and takes no runtime selector,
#      so an exit-code trigger is unreachable on the other two. Its Claude-only-ness is the CLI control
#      plane it drives, not its plugins root, which `--plugins-root` makes configurable.
#   2. The tracked issue is AUTHENTICATED. This repository is public, so opening an issue needs no write
#      access and existence alone establishes nothing. An issue counts only on BOTH halves of the
#      own-output test: an accepted agent author — `devantler` for a machine-local lane, or the cloud
#      App — AND the canonical disclosure. That test extends to every field a run reads back.
#
#      The cloud App answers to THREE different spellings, so a checker must compare against the one
#      its own surface returns. Measured 2026-08-23 against live artifacts:
#
#        search qualifier (input)     `app/cursor`     e.g. `--author app/cursor`, `author:app/cursor`
#        REST `user.login`            `cursor[bot]`
#        GraphQL `author.login`       `cursor`         (bare; `__typename: Bot`)
#
#      `app/cursor` is what you PASS to a search, never what a read returns, and GraphQL returns
#      neither of the bracketed forms. Hardcoding one spelling for the wrong surface rejects an
#      authentic Cursor tracker and opens a duplicate.
#   3. A FENCED repair qualifies exactly as a failed one does. Fencing is usually correct, so it reads
#      as a non-event, and a decision recorded as nothing is what makes the staleness unbounded.
#   4. The rule stays ADDITIVE: a DRIFT is never a run-stopper and the reviewed-definition fallback
#      survives, or a later tightening turns a reporting obligation into a halt.
#   5. The scripts' premises stay true, verified against the CLIs rather than their source spelling.
#
# The clause tracks drift as an issue and does not page a maintainer channel; that is deliberate scope,
# recorded in the prose and asserted below, because sound delivery needs an unforgeable delivery
# record, a crash-safe ordering, an arbitration token distinct from the work claim, and closure
# serialised against sending — none of which prose can carry.
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
assert_contains "${section}" 'act on the CONDITION, not on a tool' \
  'the escalation must be keyed to the condition rather than to a refresh-tool exit code'

assert_contains "${section}" 'takes no runtime selector' \
  'the section must record WHY the exit-code form is unreachable — the refresh tool has no lane selector'

# An UNRESOLVED currency UNKNOWN is a qualifying trigger in its own right. Keyed only on DRIFT, a lane
# whose currency itself exits 2 never satisfies the rule, opens no tracker, and reports privately
# forever -- the exact unbounded silence this clause replaced. The per-instance table makes more than
# one cached Codex version an UNKNOWN by design, so this is a reachable state, not a corner.
assert_contains "${section}" "unresolved currency \`UNKNOWN\` qualifies" \
  'an unresolved currency UNKNOWN must open a tracker too, or a lane whose check never reaches a verdict is untracked forever'

assert_contains "${section}" 'this run'"'"'s prescribed recovery did not resolve' \
  'the UNKNOWN trigger must turn on the recovery NOT resolving it — a transient UNKNOWN resolved in the same tick is not tracked'

# The Cursor reset reads a SIBLING checkout's remote-tracking ref, and the currency script contains no
# fetch at all. Without refreshing it first, a stale local ref reads CURRENT and closes a tracker while
# that lane still serves a superseded revision. A close discards state, so it must fail closed.
assert_contains "${section}" 'does NOT fetch' \
  'the reset must record that the currency script performs no fetch, or a stale sibling ref silently justifies the close'

assert_contains "${section}" 'Fetch that ref in the submodule immediately before the check' \
  'the reset must require a fresh ref before closing a Cursor tracker'

# A generic `git fetch origin main` writes FETCH_HEAD and updates refs/remotes/origin/main only as an
# opportunistic side effect of the remote's configured fetch refspec. Measured 2026-08-23: with
# remote.origin.fetch unset the ref stayed STALE while FETCH_HEAD was current, so the check would read
# the stale ref and close the tracker on pre-drift evidence. Pin the explicit refspec, which updates
# the consumed ref by construction rather than depending on submodule remote config nothing here owns.
assert_contains "${section}" 'git -C libraries/agent-plugins fetch origin main:refs/remotes/origin/main' \
  'the reset must pin an explicit refspec that updates the ref the check reads, not a generic fetch that only guarantees FETCH_HEAD'

assert_contains "${section}" 'never what the drifted dispatch actually loaded' \
  'the close must not overstate a sibling read as verification of what the Cursor lane loaded'

# The FOUR ways a repair fails to happen. Each is pinned separately: a single catch-all word could
# later be narrowed to the two that are easy to detect, silently dropping the others. **failed** is the
# one an enumeration naturally omits — a refresh that runs and errors is neither unavailable, refused,
# nor fenced, so without it an ordinary repair failure keeps the unbounded-silence path the clause
# exists to close, while the fenced-counts sentence below already presupposes that failed is in the set.
for state in '**unavailable**' '**refused**' '**fenced**' '**failed**'; do
  assert_contains "${section}" "${state}" \
    "the escalating condition must enumerate the repair state ${state}"
done

# ---------------------------------------------------------------------------
# 2. The tracked issue, and the authentication that makes reading it meaningful.
# ---------------------------------------------------------------------------
assert_contains "${section}" 'existence proves nothing on a PUBLIC repository' \
  'the clause must state that issue existence is not self-authenticating on a public repo'

# Both agent identities that can file one. The cloud lane's 403s cover Projects, comments, review
# requests and PR-state mutations — not issue creation — so excluding it would discard the only
# scheduled observation of the lane it is the sole checker for.
assert_contains "${section}" "exactly **\`devantler\`**" \
  'the machine-local agent identity must be named, not merely "an agent"'

assert_contains "${section}" "**\`app/cursor\`**" \
  'the cloud identity must be accepted — it files issues, and it is the only checker of its own lane'

# The OTHER half of the own-output test, and the conjunction. Asserting the accepted authors alone is
# not enough: with the disclosure requirement removed from the prose this guard would stay green, and a
# HUMAN-authored devantler issue matching the drift description would then read as agent-owned state
# that a later run may close — an agent closing the maintainer's issue. Author and disclosure are only
# meaningful together, so the conjunction is asserted as well as each half.
assert_contains "${section}" 'body begins with' \
  'the disclosure must be required at the START of the body — the disambiguator anchors at position zero'

assert_contains "${section}" '🤖 Generated by the' \
  'the issue must require the canonical disclosure — without it a human-authored issue reads as agent state'

assert_contains "${section}" '**both** halves of the own-output test' \
  'author and disclosure must be required TOGETHER, or either alone can be read as sufficient'

# ALL THREE spellings, each bound to the surface that actually produces it. GitHub renders this App
# differently per surface, and no surface returns more than one: a run reconciling through REST that
# checks only app/cursor -- or through GraphQL that checks only cursor[bot] -- rejects the authentic
# tracker and files the duplicate the reuse rule exists to prevent.
assert_contains "${section}" "**\`cursor[bot]\`**" \
  'the REST spelling of the cloud identity must be accepted, or a REST-side lookup rejects its own issue'

assert_contains "${section}" "**\`app/cursor\`**" \
  'the search-qualifier spelling must be named, or a search for the tracker cannot be constructed'

# The GraphQL spelling is the one that was measured WRONG: the clause claimed cursor[bot] on "the REST
# and GraphQL APIs", but platform#2812 read both ways returns cursor[bot] on REST and the BARE cursor
# on GraphQL. A GraphQL checker matching the bracketed form rejects every authentic Cursor tracker.
assert_contains "${section}" "GraphQL \`author.login\`" \
  'the GraphQL spelling must be stated for its own surface, not folded in with REST'

assert_contains "${section}" "bare, \`__typename: Bot\`" \
  'GraphQL returns the BARE cursor -- pinning this stops the bracketed REST form being reintroduced there'

# Reconciliation must belong to the reader, not the creator: a creator that dies between filing and
# cleaning up leaves an orphan that nothing else is looking for.
assert_contains "${section}" 'closes ALL higher-numbered authenticated duplicates' \
  'every lookup must reconcile all duplicates, or a crashed creator orphans one permanently'

# Creation must be synchronised with recovery. Otherwise a run that saw DRIFT files after an
# overlapping run has already seen CURRENT and found nothing to close.
assert_contains "${section}" 'RE-READ currency immediately before filing' \
  'the creator must revalidate currency, or a recovered lane gets tracked from a stale observation'

# ...and the residual the recheck leaves. Stating it is what stops a later reader taking the recheck
# for atomicity and "simplifying" the reset away — the reset is the only thing bounding it.
assert_contains "${section}" 'NARROWS that window; it does not close it' \
  'the clause must admit the recheck is not atomic, or the reset that bounds it looks redundant'

assert_contains "${section}" 'The Cursor cloud lane files its own issue' \
  'the contract must not claim the cloud instance cannot open an issue — it can, and does so elsewhere'

# Authentication as a property of each value, not of the container that carried it.
assert_contains "${section}" 'governs EVERY field a run reads back' \
  'the authentication test must extend to any state a later edit adds, not only the issue'

# One occurrence, one issue. Overlapping same-lane runs are normal, so create-only produces duplicate
# queue items, and check-then-create cannot be made atomic — hence lookup plus a deterministic
# tie-break rather than a lock.
# The tracker is identified by an exact marker, never by resemblance. Without this, any authenticated
# issue discussing drift on that lane — including this change's own follow-up — can be selected as the
# tracker and then closed by the reset.
assert_contains "${section}" '**Lane drift tracker:**' \
  'the tracker must be identified by an exact marker, or the reset can close an unrelated drift issue'

assert_contains "${section}" 'one occurrence, one issue' \
  'a run must reuse the lane existing authenticated issue rather than always creating'

assert_contains "${section}" 'lowest-numbered' \
  'concurrent creations must be reconciled deterministically, or one drift yields several trackers'

assert_contains "${section}" 'tracked, repository-visible issue' \
  'the qualifying condition must produce a tracked issue — that artifact IS the fix'

assert_contains "${section}" 'Close the issue when that lane next reads' \
  'closing on CURRENT is the reset — without it a recovered lane stays tracked forever'

# The cloud lane can CREATE an issue but its measured write matrix returns 403 for CLOSING one, so its
# tracker has no reset unless a machine-local run performs it. Without this the round-9 fix (Cursor
# files its own issue) produces a tracker nobody can close.
# Repeat DRIFT from Cursor needs no handoff — the tracker already records the condition. Stated and
# asserted for the same reason the paging scope limit is: an unexplained absence reads as an oversight
# and invites someone building a delivery path for information that is not actually lost.
assert_contains "${section}" 'carries no new state' \
  'a repeat Cursor observation must be explained as needing no handoff, or its absence invites a mechanism'

assert_contains "${section}" "EVERY close on a Cursor-filed tracker is a MACHINE-LOCAL run" \
  'every close on a Cursor tracker needs a writable lane — reset AND duplicate reconciliation, since that lane cannot close at all'

# The close handoff above says WHO closes; this says the reset is REACHABLE at all. Detection may stay
# lane-local, but nothing obliges a machine-local schedule to run `--runtime cursor`, so a Cursor
# tracker filed on DRIFT would never see the CURRENT that closes it — the clause would create state
# nothing can reset, and a stale open issue reads as a live condition. Pinned separately because the
# handoff assertion passes with the reachability gap wide open.
assert_contains "${section}" 'runs `--runtime cursor` itself' \
  'an open Cursor tracker must oblige the machine-local closer to run that lane check, or the reset is unreachable'

# Scope. The clause deliberately stops short of paging, and that decision has to stay legible or a
# later editor reads the absence as an omission and re-adds the delivery protocol this removed.
assert_contains "${section}" 'does NOT page a maintainer channel' \
  'the deliberate scope limit must be stated, or the absence of paging reads as an oversight'

assert_contains "${section}" 'separate decision' \
  'the paging question must be recorded as deferred rather than silently dropped'

assert_contains "${section}" 'A FENCED repair is a QUALIFYING state exactly as a failed one is' \
  'a fenced repair must qualify — this is the case the whole clause exists for'

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
#
#    These probe BEHAVIOUR, not source spelling. An earlier version grepped for the literal case-arm
#    `--runtime)`, which a valid `--runtime=*`, a short alias, or parsing delegated to a helper would
#    all slip past — CI would stay green while the contract went on claiming no selector exists, which
#    is precisely the drift this section is supposed to catch. Asking the CLI is spelling-independent.
#    It is also safe: both scripts reject an unknown option during argument parsing, before any
#    network, filesystem, or control-plane action.
# ---------------------------------------------------------------------------
if [ -x "${refresh}" ]; then
  # Probe every spelling a selector could plausibly take, AND read the CLI's own advertised option
  # surface. Enumerating spellings alone is a losing game — a source-grep missed `--runtime=*`, a
  # space-only probe missed it too, and a short `-r` would slip past both — so the enumeration covers
  # what can be named and the --help scan covers what cannot.
  #
  # 🔴 EVERY probe passes --dry-run, and that is a SAFETY requirement rather than tidiness. These
  # invocations are inert today only because the option is rejected during argument parsing. The moment
  # the selector this test exists to detect actually EXISTS, parsing succeeds and the run continues into
  # CLI resolution, marketplace refresh and potentially a plugin update — so the guard would mutate a
  # developer's live runtime at exactly the moment it fires. --dry-run makes the failing path
  # side-effect-free: the script exits 2 without applying anything (verified).
  for spelling in "--runtime codex" "--runtime=codex" "-r codex" "-r=codex"; do
    # shellcheck disable=SC2086 # deliberate word-splitting: each spelling is one or two argv entries
    refresh_out="$("${refresh}" --dry-run ${spelling} 2>&1)" && refresh_rc=0 || refresh_rc=$?
    case "${refresh_out}" in
      *"unknown argument"*) ;;
      *)
        fail "plugin-definition-refresh.sh no longer rejects '${spelling}' (rc=${refresh_rc}), so the contract's 'takes no runtime selector' premise is stale — update the prose in this change"
        ;;
    esac
  done

  # The advertised surface. This is the half that survives a spelling nobody thought to enumerate.
  refresh_help="$("${refresh}" --help 2>&1 || true)"
  case "${refresh_help}" in
    *"--runtime"*|*"-r "*|*"--lane"*)
      fail "plugin-definition-refresh.sh --help now advertises a runtime/lane selector, so the contract's 'takes no runtime selector' premise is stale — update the prose in this change"
      ;;
  esac
else
  fail "cannot execute ${refresh} — the premise this contract rests on is unverifiable"
fi

if [ -x "${currency}" ]; then
  # POSITIVE verification, not "anything but unknown argument". The negative form treats every other
  # failure as proof the flag was parsed — so if this script ever drops --runtime AND words its
  # unknown-option diagnostic differently ("invalid option", a usage dump, a bare exit), the branch
  # reads that as success and CI passes on a stale three-lane premise. Assert the advertised option
  # instead, which is the same "read what the tool declares" fix applied to the refresh probe above.
  currency_help="$("${currency}" --help 2>&1 || true)"
  # Assert the option AND its exact advertised VALUE SET. Checking the words separately is vacuous:
  # "cursor" and "codex" both appear in this script's surrounding help prose, so a usage line that had
  # quietly dropped a lane still satisfies a word-by-word scan — verified by ablation.
  case "${currency_help}" in
    *"--runtime claude|codex|cursor"*) ;;
    *)
      fail "plugin-definition-currency.sh --help no longer advertises the exact three-lane selector, so the three-lane detection the contract assumes is gone"
      ;;
  esac

  # Confirm the selector is really PARSED, not merely documented — and require the specific
  # unsupported-value result rather than "anything except unknown argument". The permissive form lets a
  # parser that has dropped --runtime pass, so long as its generic option error happens to be worded
  # differently and the manually maintained help still advertises the flag. Both the exit status and the
  # diagnostic are asserted, so a documented-but-unparsed selector cannot satisfy this contract.
  currency_out="$("${currency}" --runtime __contract_probe__ 2>&1)" && currency_rc=0 || currency_rc=$?
  case "${currency_out}" in
    *"unsupported runtime '__contract_probe__'"*) ;;
    *)
      fail "plugin-definition-currency.sh did not reject an invalid --runtime value with its unsupported-runtime diagnostic (rc=${currency_rc}), so the selector is advertised but not parsed"
      ;;
  esac
  [ "${currency_rc}" = "2" ] ||
    fail "plugin-definition-currency.sh returned ${currency_rc} for an invalid --runtime value, not the documented 2 — the selector's contract has changed"
else
  fail "cannot execute ${currency} — the premise this contract rests on is unverifiable"
fi


# ---------------------------------------------------------------------------
# 9. THE DEPLOYED CURSOR LOADER carries the same two facts, not just this contract.
#     Establishing a fact in AGENTS.md while the boot path still runs the old command
#     leaves the defect fully live: the loader is what the cloud lane actually executes.
#     Both of these were found live on the loader after the contract had already been
#     corrected here.
# ---------------------------------------------------------------------------
loader="${repo_root}/.claude/loaders/cursor-daily-ai-engineer.md"
[ -r "${loader}" ] || fail "cannot read ${loader} — the deployed Cursor boot path is unverifiable"
loader_text="$(tr '\n' ' ' <"${loader}" | tr -s '[:space:]' ' ')"
[ "${#loader_text}" -gt 2000 ] || fail "loader captured only ${#loader_text} chars — the read is broken"

# A bare `git fetch origin main` guarantees only FETCH_HEAD; the very next step of the loader reads
# refs/remotes/origin/main, so with remote.origin.fetch unset the boot loads a STALE reviewed
# definition while reporting success.
assert_contains "${loader_text}" 'git -C libraries/agent-plugins fetch origin main:refs/remotes/origin/main' \
  'the Cursor loader must pin an explicit refspec for the ref its next step reads, not a generic fetch that only guarantees FETCH_HEAD'

# GraphQL returns the BARE `cursor`; requiring `cursor[bot]` on the GraphQL fallback rejects the
# authentic identity and hard-stops the dispatch, which is the failure this fallback exists to avoid.
assert_contains "${loader_text}" 'The GraphQL API identity is the BARE `cursor`' \
  'the Cursor loader must accept the spelling the GraphQL surface actually returns, or its own fallback path rejects the authentic identity'
echo "drifted-lane-escalation contract: PASS — condition-keyed escalation, issue-latched, additive, and both script premises verified behaviourally"
