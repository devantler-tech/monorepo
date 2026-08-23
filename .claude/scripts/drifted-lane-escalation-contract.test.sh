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
#   1. The obligation is keyed to the CONDITION — a lane reading DRIFT whose repair is unavailable,
#      refused, fenced or failed — never to a tool's exit code. `plugin-definition-currency.sh` detects
#      drift on three lanes; `plugin-definition-refresh.sh` repairs one and takes no runtime selector,
#      so an exit-code trigger is unreachable on the other two.
#   2. The tracked issue is AUTHENTICATED. This repository is public, so opening an issue needs no write
#      access and existence alone establishes nothing; only author `devantler` plus the canonical
#      disclosure counts, and that test extends to every field a run reads back.
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

assert_contains "${section}" "author is exactly **\`devantler\`**" \
  'the tracked issue must bind to the authenticated writer identity, not merely to a matching description'

assert_contains "${section}" '🤖 Generated by the' \
  'the issue must require the canonical disclosure — the second half of the own-output test'

# The authentication rule has to generalise, or the next field added here inherits the same gap.
assert_contains "${section}" 'applies to EVERY field a run reads back' \
  'the authentication test must extend to any state a later edit adds, not only the issue'

assert_contains "${section}" 'tracked, repository-visible issue' \
  'the qualifying condition must produce a tracked issue — that artifact IS the fix'

assert_contains "${section}" 'Close the issue when that lane next reads' \
  'closing on CURRENT is the reset — without it a recovered lane stays tracked forever'

# Scope. The clause deliberately stops short of paging, and that decision has to stay legible or a
# later editor reads the absence as an omission and re-adds the delivery protocol this removed.
assert_contains "${section}" 'does NOT page the maintainer' \
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
  # surface. Enumerating spellings alone is a losing game — the source-grep missed `--runtime=*`, the
  # space-only probe missed it too (both caught by ablation), and a short `-r` would slip past both.
  # So the enumeration covers what we can name, and the --help scan covers what we cannot: if the CLI
  # ever advertises a runtime/lane selector under any spelling, this fails and the prose gets updated
  # in the same change.
  #
  # Safe to invoke: the script rejects an unknown option during argument parsing, before any network,
  # filesystem, or control-plane action (verified: rc=2, "unknown argument").
  for spelling in "--runtime codex" "--runtime=codex" "-r codex" "-r=codex"; do
    # shellcheck disable=SC2086 # deliberate word-splitting: each spelling is one or two argv entries
    refresh_out="$("${refresh}" ${spelling} 2>&1)" && refresh_rc=0 || refresh_rc=$?
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

  # And confirm it is really parsed, not merely documented: a bad VALUE must be rejected as a value
  # rather than as an unknown option.
  currency_out="$("${currency}" --runtime __contract_probe__ 2>&1)" && currency_rc=0 || currency_rc=$?
  case "${currency_out}" in
    *"unknown argument"*)
      fail "plugin-definition-currency.sh advertises --runtime but rejects it as unknown (rc=${currency_rc}), so the three-lane detection the contract assumes is gone"
      ;;
  esac
else
  fail "cannot execute ${currency} — the premise this contract rests on is unverifiable"
fi

echo "drifted-lane-escalation contract: PASS — condition-keyed escalation, issue-latched, additive, and both script premises verified behaviourally"
