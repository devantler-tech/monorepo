#!/usr/bin/env bash
#
# Guards the Agent Improver and FinOps writer contract: both roles must resolve
# reviewed sources and own selected engineering work from finding through merge.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
settings="${repo_root}/.claude/settings.json"
desired_state="${repo_root}/.claude/plugin-consumption/agentic-engineering.desired-state.json"
finops_agent="${repo_root}/.claude/agents/finops-engineer.md"
finops_skill="${repo_root}/.claude/skills/finops/SKILL.md"
workflow="${repo_root}/.github/workflows/ci.yaml"

fail() {
  echo "agent-role delivery contract: FAIL — $*" >&2
  exit 1
}

grep -Fq '### Agent definition locations' "${constitution}" ||
  fail "consumer does not define Agent definition locations"
grep -Fq '### Authority model' "${constitution}" ||
  fail "consumer does not define Authority model"
grep -Fq 'plugins/agentic-engineering/agents/agent-improver.agent.md' "${constitution}" ||
  fail "consumer does not name the upstream Agent Improver source"
grep -Fq 'Agent Improver scorecard store' "${constitution}" ||
  fail "Memory does not name the Agent Improver scorecard store"
grep -Fq 'open verification-hypothesis store' "${constitution}" ||
  fail "Memory does not name the Agent Improver hypothesis store"

for authority_row in \
  '| **Prose tightening**' \
  '| **Prose loosening**' \
  '| **Enforcement tightening**' \
  '| **Enforcement loosening**'; do
  grep -Fq "${authority_row}" "${constitution}" ||
    fail "Authority model is missing ${authority_row}"
done
grep -Fq 'FULL SYMMETRIC AUTHORITY' "${constitution}" ||
  fail "consumer does not preserve the maintainer-granted symmetric authority"
grep -Fq 'An issue, recommendation, or draft PR is not completion' "${constitution}" ||
  fail "consumer permits a write-capable role to stop before merge"
grep -Fq '### Writer namespaces' "${constitution}" ||
  fail "consumer does not record namespaces for its scheduled writers"
# Backticks are literal Markdown, not command substitution.
# shellcheck disable=SC2016
grep -Fq 'The `agent-improver` and `finops-engineer` schedules intentionally share their provider instance' \
  "${constitution}" ||
  fail "consumer does not declare the intentional provider-lane sharing model"
# shellcheck disable=SC2016
for writer_namespace in '`claude/*`' '`codex/*`' '`cursor/*`'; do
  grep -Fq "${writer_namespace}" "${constitution}" ||
    fail "consumer does not record writer namespace ${writer_namespace}"
done
grep -Fq 'remain undeployed and read-only' "${constitution}" ||
  fail "consumer does not fail closed for unmapped Cursor role schedules"

grep -Fq '## Delivery ownership — finding to fix' "${finops_agent}" ||
  fail "FinOps agent has no finding-to-fix delivery handoff"
grep -Fq 'drive the reviewed head to merge' "${finops_skill}" ||
  fail "FinOps run loop does not drive its engineering PR through merge"

[ ! -e "${repo_root}/.claude/agents/agent-improver.md" ] ||
  fail "deployment-local Agent Improver fork still exists"
[ ! -e "${repo_root}/.claude/skills/agent-improvement/SKILL.md" ] ||
  fail "deployment-local Agent Improver skill fork still exists"

jq -e '
  .enabledPlugins == {"agentic-engineering@devantler-plugins": true}
' "${settings}" > /dev/null ||
  fail "runtime settings do not enable only the reviewed agentic-engineering plugin"

jq -e '
  .spec.guardrails | index(
    "Write-capable roles own selected engineering work from claim through exact-head review and merge; issue-only handoff is allowed only for a named external blocker or missing authority."
  ) != null
' "${desired_state}" > /dev/null ||
  fail "provider-neutral desired state does not preserve delivery ownership"

# GitHub expression tokens are literal workflow syntax, not shell expansions.
# shellcheck disable=SC2016
grep -Fq 'agent-role-delivery-contract: ${{ steps.filter.outputs.agent-role-delivery-contract }}' "${workflow}" ||
  fail "CI does not export the agent-role delivery contract filter"
grep -Fq 'test-agent-role-delivery-contract:' "${workflow}" ||
  fail "CI does not define the agent-role delivery contract job"
grep -Fq 'run: bash .claude/scripts/agent-role-delivery-contract.test.sh' "${workflow}" ||
  fail "CI does not execute the agent-role delivery contract test"
# shellcheck disable=SC2016
grep -Fq '${{ needs.test-agent-role-delivery-contract.result }}' "${workflow}" ||
  fail "required checks do not aggregate the agent-role delivery contract"

echo "agent-role delivery contract: all assertions passed"
