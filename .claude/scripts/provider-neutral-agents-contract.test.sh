#!/usr/bin/env bash
# test-inputs: .*/environment.json .claude/agents/agent-improver.md
# test-inputs: .claude/agents/daily-maintainer.md .claude/agents/finops-engineer.md
# test-inputs: .claude/agents/portfolio-surveyor.md .claude/finops/** .claude/guides/**
# test-inputs: .claude/loaders/** .claude/loaders/portable-agentic-engineer.md
# test-inputs: .claude/plugin-consumption/agent-instances.json
# test-inputs: .claude/plugin-consumption/agentic-engineering.desired-state.json
# test-inputs: .claude/plugin-consumption/inference-routing*
# test-inputs: .claude/scripts/agent-role-delivery-contract.test.sh
# test-inputs: .claude/scripts/contract-text.sh .claude/scripts/finops-snapshot.sh
# test-inputs: .claude/scripts/fixtures/** .claude/scripts/inference-routing-contract.test.sh
# test-inputs: .claude/scripts/inference-routing-scorecard.sh
# test-inputs: .claude/scripts/inference-routing-scorecard.test.sh
# test-inputs: .claude/scripts/markdown-structural-lines.awk
# test-inputs: .claude/scripts/portfolio-surveyor-forge-hook.sh .claude/scripts/pr-body-contract.sh
# test-inputs: .claude/scripts/pr-body-contract.test.sh .claude/scripts/pr-body-public-tlds.txt
# test-inputs: .claude/scripts/pr-worktree-holder.sh .claude/settings.json
# test-inputs: .claude/skills/agent-improvement/** .claude/skills/finops/SKILL.md
# test-inputs: .claude/skills/portfolio-maintenance/SKILL.md
# test-inputs: .claude/skills/product-engineering/SKILL.md .claude/skills/self-improvement/SKILL.md
# test-inputs: .github/workflows/ci.yaml AGENTS.md libraries/agent-plugins
# Verify portable ownership declarations and removal of retired engineering wiring.
set -euo pipefail
probe="$(mktemp)"
test_run_finished=0
# bash 3.2 can report a set -e abort inside an EXIT trap as exit 0, so require completion.
on_test_exit() {
  local status=$?
  rm -f -- "$probe"
  if [ "${test_run_finished}" != 1 ]; then
    echo "provider-neutral-agents-contract.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_test_exit EXIT
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL provider-neutral agents: %s\n' "$*" >&2; exit 1; }
[[ ! -e "$ROOT/.claude/loaders/cursor-daily-ai-engineer.md" ]] || fail 'retired loader remains'
[[ ! -e "$ROOT/.cursor/environment.json" ]] || fail 'retired environment configuration remains'
[[ ! -e "$ROOT/.claude/scripts/cursor-issue-board-sweep.sh" ]] || fail 'provider-specific board helper remains'
[[ -r "$ROOT/.claude/loaders/portable-agentic-engineer.md" ]] || fail 'portable loader is missing'
# `grep -E`, not `rg`: ripgrep is absent from the ubuntu-latest runner, so this
# scan exited 127 and the `if` read that as "no match" — the assertion printed
# PASS without ever executing (observed in CI run 34700104991 on this PR's own
# green head). grep is POSIX and present everywhere this runs.
#
# The status is read explicitly because grep overloads it: 0 = a retired
# reference is present, which is the failure this asserts against; 1 = none,
# the asserted state; anything else = the scan itself failed (unreadable or
# missing input, absent tool) and therefore proves nothing. Collapsing "could
# not look" into "found nothing" is what made this vacuous.
scan_status=0
grep -nE 'Cursor (cloud|Automation)|cursor-daily|cursor-issue-board|cursor/\*|--runtime cursor|Antigravity' \
  "$ROOT/AGENTS.md" "$ROOT"/.claude/guides/*.md "$ROOT/.claude/skills/portfolio-maintenance/SKILL.md" \
  "$ROOT/.claude/agents/portfolio-surveyor.md" "$ROOT/.claude/plugin-consumption/inference-routing-runtime.md" \
  >/dev/null || scan_status=$?
case "$scan_status" in
  0) fail 'active instructions retain retired engineering wiring' ;;
  1) : ;;
  *) fail "retired-wiring scan could not read its inputs (grep status $scan_status)" ;;
esac
jq -e '
  .version == 1 and (.instances | type == "object" and length > 0)
  and (.policyPublisher as $id | .instances[$id].roles | index("agent-improver") != null)
  and ([.instances[].namespace] | length == (unique | length))
  and all(.instances[];
    (.namespace | type == "string" and test("^[a-z][a-z0-9-]*$"))
    and (.authors | keys == ["cli","graphql","rest","search"])
    and all(.authors[]; type == "string" and length > 0)
    and (.definitionAdapter | type == "string" and length > 0)
    and (.roles | type == "array" and length > 0))
' "$ROOT/.claude/plugin-consumption/agent-instances.json" > /dev/null || fail 'invalid instance registry'
# A review lane's identity never registers as a writer: a row carrying one would let that
# lane's review artifacts satisfy checks written for our own instances (#3490).
reviewer_free() {
  jq -e '
    ["coderabbitai[bot]", "app/coderabbitai", "coderabbitai",
     "chatgpt-codex-connector[bot]", "app/chatgpt-codex-connector", "chatgpt-codex-connector",
     "cursor[bot]", "app/cursor", "cursor",
     "copilot-pull-request-reviewer[bot]", "app/copilot-pull-request-reviewer",
     "copilot-pull-request-reviewer"] as $reviewers
    | all(.instances[].authors[]; ascii_downcase as $a | ($reviewers | index($a)) == null)
  ' > /dev/null
}
reviewer_free < "$ROOT/.claude/plugin-consumption/agent-instances.json" ||
  fail 'instance registry assigns a review lane identity to a writer'
jq '.instances.probe = {namespace: "probe", definitionAdapter: "probe", roles: ["agentic-engineer"],
    authors: {cli: "app/cursor", rest: "cursor[bot]", graphql: "cursor", search: "app/cursor"}}' \
  "$ROOT/.claude/plugin-consumption/agent-instances.json" > "$probe"
if reviewer_free < "$probe"; then
  rm -f "$probe"
  fail 'reviewer-identity check accepted a row carrying a review lane identity'
fi
rm -f "$probe"
jq -e --slurpfile registry "$ROOT/.claude/plugin-consumption/agent-instances.json" '
  all(.routes[]; .runtime as $id | $registry[0].instances | has($id))
  and all(.runtimes | keys[]; . as $id | $registry[0].instances | has($id))
' "$ROOT/.claude/plugin-consumption/inference-routing.policy.json" > /dev/null || fail 'routing references an undeclared instance'
test_run_finished=1
printf 'PASS provider-neutral ownership and active instruction boundaries\n'
