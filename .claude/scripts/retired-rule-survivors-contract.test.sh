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
# The check. Each registry row names a phrase that only ever belonged to a retired rule. The contract
# deliberately keeps that phrase ONCE, quoted inside the notice that retires it, so a later reader can
# see what changed. So each phrase must occur exactly once in the whitespace-flattened document, and
# the text just before it must carry a supersession marker. A second occurrence is a survivor; an
# occurrence with no marker in front of it is the retired rule restated as current.
#
# Scope. The registry holds the retirements whose OLD wording is still quoted in AGENTS.md. The
# external-PR merge ban retired on 2026-08-08 is guarded in work-priority-ladder.test.sh, where its
# phrases never appear at all, and the reservation-comment and lane-order retirements carry their own
# negatives in review-provider-loop-contract.test.sh. When a rule is retired and its old wording is
# quoted in the notice, add a row here in the same PR.
#
# CONTRACT_DOC overrides the document under test; the self-test below uses it to prove each row fires.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${CONTRACT_DOC:-${repo_root}/AGENTS.md}"

fail() {
  echo "retired-rule-survivors contract: FAIL — $*" >&2
  exit 1
}

# phrase<TAB>what retired it. Phrases are matched literally after whitespace is flattened, so a
# survivor wrapped across a line break is still counted.
read -r -d '' registry <<'EOF' || true
its owner promotes	2026-08-08: every draft in the portfolio is driven through promotion, whoever authored it
standing ping duties	2026-07-12: Slack is a last-resort channel only, never status messages
lowest priority	2026-07-17: World at Ruin is a first-class product in the normal rotation
.claude/agents/finops-engineer.md	2026-07-25: spend stewardship is the Agentic Engineer's own mandate
automated-ai-engineer	agent-plugins#89: the entrypoint is agentic-engineer
Codex > Cursor > CodeRabbit	2026-07-21: lane priority is CodeRabbit > Codex > Cursor Bugbot
EOF

# A notice frames the quoted wording with one of these, within 200 characters before it or 120 after
# it ('was `x` until …' puts the marker after).
marker_pattern='supersed|SUPERSEDED|used to|retired|until '

# check_document <path>: exit 0 when every row holds, else print the first broken row and exit 1.
check_document() {
  local document="$1" flat phrase reason count before

  [ -r "${document}" ] || {
    echo "cannot read ${document}"
    return 1
  }
  flat="$(tr '\n\t' '  ' <"${document}" | tr -s ' ')"

  while IFS=$'\t' read -r phrase reason; do
    [ -n "${phrase}" ] || continue
    count="$(PHRASE="${phrase}" awk 'BEGIN { RS = "\001" } {
      n = 0; s = $0
      while ((i = index(s, ENVIRON["PHRASE"])) > 0) { n++; s = substr(s, i + length(ENVIRON["PHRASE"])) }
      print n
    }' <<<"${flat}")"
    if [ "${count}" != "1" ]; then
      echo "'${phrase}' occurs ${count} times; it must appear once, inside the notice that retired it (${reason})"
      return 1
    fi
    before="$(PHRASE="${phrase}" awk 'BEGIN { RS = "\001" } {
      p = ENVIRON["PHRASE"]; i = index($0, p); start = i - 200; if (start < 1) start = 1
      print substr($0, start, i - start) " " substr($0, i + length(p), 120)
    }' <<<"${flat}")"
    if ! grep -Eq -- "${marker_pattern}" <<<"${before}"; then
      echo "'${phrase}' is no longer introduced by a supersession marker, so the retired rule reads as current (${reason})"
      return 1
    fi
  done <<<"${registry}"
}

result="$(check_document "${constitution}")" || fail "${result}"

# Self-test, skipped when checking an override. A negative guard that never fires is not a guard, so
# prove each row fails on the two ways a retired rule comes back.
if [ -z "${CONTRACT_DOC:-}" ]; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "${scratch}"' EXIT

  while IFS=$'\t' read -r phrase _; do
    [ -n "${phrase}" ] || continue

    # 1. A survivor elsewhere: append the retired wording as a plain rule.
    { cat "${constitution}"; printf '\n\n- Current rule: %s.\n' "${phrase}"; } >"${scratch}/survivor.md"
    check_document "${scratch}/survivor.md" >/dev/null &&
      fail "self-test: a surviving '${phrase}' outside its notice was not detected"

    # 2. The notice stripped of its marker: the quote then reads as the rule itself. Edited on the
    # flattened text, which is what the check reads, so the stripped window is exactly the one checked.
    tr '\n\t' '  ' <"${constitution}" | tr -s ' ' |
      PHRASE="${phrase}" MARKERS="${marker_pattern}" awk 'BEGIN { RS = "\001"; ORS = "" } {
        p = ENVIRON["PHRASE"]; i = index($0, p); start = i - 200; if (start < 1) start = 1; after = i + length(p)
        head = substr($0, 1, start - 1); before = substr($0, start, i - start)
        following = substr($0, after, 120); tail = substr($0, after + 120)
        gsub(ENVIRON["MARKERS"], "noted", before); gsub(ENVIRON["MARKERS"], "noted", following)
        print head before p following tail
      }' >"${scratch}/unmarked.md"
    check_document "${scratch}/unmarked.md" >/dev/null &&
      fail "self-test: '${phrase}' with its supersession marker removed was not detected"
  done <<<"${registry}"
fi

echo "retired-rule-survivors contract: OK — each retired rule survives only inside its supersession notice"
