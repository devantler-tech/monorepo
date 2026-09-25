#!/usr/bin/env bash
#
# Guards AGENTS.md against a RETIRED rule surviving outside its supersession notice (monorepo#2733).
#
# Why this needs its own guard. Almost every contract suite here checks that new wording is PRESENT.
# None of that can see a retired sentence that survived somewhere the diff never touched: when a policy
# is widened, the new wording lands where the diff is, and the old contradicting wording stays in the
# sections nobody edited. Measured 2026-08-08 on the PR-ownership widening — CodeRabbit anchored 2 of
# 4 surviving contradictions, and every presence assertion across the AGENTS.md-guarding suites passed
# over all four. A run acts on whichever statement it reads first, so a contradiction is worse than a
# missing rule.
#
# The check. Each registry row names a phrase that only ever belonged to a retired rule, and the exact
# notice that retires it. The contract deliberately keeps that phrase ONCE, quoted inside that notice,
# so a later reader can see what changed. So the phrase must occur exactly once in the
# whitespace-flattened document, and so must its notice, which contains the phrase. Together those
# pin the phrase's only occurrence inside its own notice: a second occurrence is a survivor, and a
# notice that was rewritten or removed leaves the phrase standing as a current rule.
#
# Scope. The registry holds the retired rules, and withdrawn claims, whose OLD wording is still quoted
# in AGENTS.md (a sweep for "earlier version", "withdrawn" and supersession markers on 2026-09-23). The
# external-PR merge ban retired on 2026-08-08 is guarded in work-priority-ladder.test.sh, where its
# phrases never appear at all, and the reservation-comment and lane-order retirements carry their own
# negatives in review-provider-loop-contract.test.sh. When a rule is retired and its old wording is
# quoted in the notice, add a row here in the same PR.
#
# CONTRACT_DOC overrides the document under test; the self-test below uses it to prove each row fires.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The document under test is the whole contract — AGENTS.md plus every guide it indexes — unless
# CONTRACT_DOC names another. The scratch directory also holds the self-test's mutated copies.
if [ -n "${CONTRACT_DOC:-}" ]; then
  constitution="${CONTRACT_DOC}"
else
  scratch="$(mktemp -d)"
  trap 'rm -rf "${scratch}"' EXIT
  constitution="${scratch}/contract.md"
  "${repo_root}/.claude/scripts/contract-text.sh" >"${constitution}" ||
    { echo "retired-rule-survivors contract: FAIL — cannot assemble the agent contract" >&2; exit 1; }
fi

fail() {
  echo "retired-rule-survivors contract: FAIL — $*" >&2
  exit 1
}

# phrase<TAB>notice<TAB>what retired it. Both are matched literally after whitespace is flattened, so
# text wrapped across a line break still matches.
read -r -d '' registry <<'EOF' || true
its owner promotes	used to end "another trusted author's draft … gets hygiene, never promotion (its owner promotes)"	2026-08-08: every draft in the portfolio is driven through promotion, whoever authored it
standing ping duties	superseding the same-day "standing ping duties"	2026-07-12: Slack is a last-resort channel only, never status messages
lowest priority	superseding the bootstrap-day "lowest priority" note	2026-07-17: World at Ruin is a first-class product in the normal rotation
.claude/agents/finops-engineer.md	superseding the standalone FinOps Engineer that used to live at `.claude/agents/finops-engineer.md`	2026-07-25: spend stewardship is the Agentic Engineer's own mandate
automated-ai-engineer	`automated-ai-engineer` until [agent-plugins#89]	agent-plugins#89: the entrypoint is agentic-engineer
Codex > Cursor > CodeRabbit	superseding the 2026-07-20 order `Codex > Cursor > CodeRabbit`	2026-07-21: lane priority is CodeRabbit > Codex > Cursor Bugbot
with the pin, GitHub refuses instead	An earlier version of this paragraph claimed "with the pin, GitHub refuses instead"	Withdrawn: the head pin protects only the arming of --auto, never the later merge
EOF

flatten() {
  tr '\n\t' '  ' | tr -s ' '
}

# occurrences <needle> — count literal occurrences of needle in stdin, read as one record.
occurrences() {
  NEEDLE="$1" awk 'BEGIN { RS = "\001" } {
    n = 0; s = $0
    while ((i = index(s, ENVIRON["NEEDLE"])) > 0) { n++; s = substr(s, i + length(ENVIRON["NEEDLE"])) }
    print n
  }'
}

# check_document <path>: exit 0 when every row holds, else print the first broken row and exit 1.
check_document() {
  local document="$1" flat phrase notice reason count

  [ -r "${document}" ] || {
    echo "cannot read ${document}"
    return 1
  }
  flat="$(flatten <"${document}")"

  while IFS=$'\t' read -r phrase notice reason; do
    [ -n "${phrase}" ] || continue
    case "${notice}" in
      *"${phrase}"*) ;;
      *)
        echo "registry row '${phrase}' names a notice that does not contain it"
        return 1
        ;;
    esac
    count="$(occurrences "${phrase}" <<<"${flat}")"
    if [ "${count}" != "1" ]; then
      echo "'${phrase}' occurs ${count} times; it must appear once, inside the notice that retired it (${reason})"
      return 1
    fi
    count="$(occurrences "${notice}" <<<"${flat}")"
    if [ "${count}" != "1" ]; then
      echo "the notice retiring '${phrase}' occurs ${count} times, so the phrase is no longer pinned inside it and may read as a current rule (${reason})"
      return 1
    fi
  done <<<"${registry}"
}

result="$(check_document "${constitution}")" || fail "${result}"

# Self-test, skipped when checking an override. A negative guard that never fires is not a guard, so
# prove each row fails on the two ways a retired rule comes back.
if [ -z "${CONTRACT_DOC:-}" ]; then
  while IFS=$'\t' read -r phrase notice _; do
    [ -n "${phrase}" ] || continue

    # 1. A survivor elsewhere: append the retired wording as a plain rule.
    { cat "${constitution}"; printf '\n\n- Current rule: %s.\n' "${phrase}"; } >"${scratch}/survivor.md"
    check_document "${scratch}/survivor.md" >/dev/null &&
      fail "self-test: a surviving '${phrase}' outside its notice was not detected"

    # 2. The phrase moved out of its notice to sit beside an unrelated marker: its count stays one,
    # so only the notice pin can catch it.
    flatten <"${constitution}" |
      NOTICE="${notice}" PHRASE="${phrase}" awk 'BEGIN { RS = "\001"; ORS = "" } {
        i = index($0, ENVIRON["NOTICE"])
        print substr($0, 1, i - 1) substr($0, i + length(ENVIRON["NOTICE"]))
        print "\n\n- An unrelated rule was retired last year. Current rule: " ENVIRON["PHRASE"] ".\n"
      }' >"${scratch}/moved.md"
    check_document "${scratch}/moved.md" >/dev/null &&
      fail "self-test: '${phrase}' moved out of its notice beside an unrelated marker was not detected"
  done <<<"${registry}"
fi

echo "retired-rule-survivors contract: OK — each retired rule survives only inside its supersession notice"
