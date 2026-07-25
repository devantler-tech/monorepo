#!/usr/bin/env bash
#
# Guards the writer contract for the Agent Improver and for the Agentic Engineer's
# merged spend mandate: each must resolve reviewed sources and own selected
# engineering work from finding through merge. Spend is a dimension of the primary
# engineer, NOT a second scheduled role, so this test also pins that merge shut —
# a resurrected standalone FinOps agent, role, or schedule fails closed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
settings="${repo_root}/.claude/settings.json"
desired_state="${repo_root}/.claude/plugin-consumption/agentic-engineering.desired-state.json"
engineer_agent="${repo_root}/.claude/agents/daily-maintainer.md"
finops_skill="${repo_root}/.claude/skills/finops/SKILL.md"
lifestyle_floor="${repo_root}/.claude/finops/lifestyle-floor.md"
snapshot="${repo_root}/.claude/scripts/finops-snapshot.sh"
workflow="${repo_root}/.github/workflows/ci.yaml"

fail() {
  echo "agent-role delivery contract: FAIL — $*" >&2
  exit 1
}

# Prose guards must survive re-wrapping: a boundary sentence that happens to break
# across two lines is still present, so match against a whitespace-flattened copy
# rather than letting a paragraph reflow read as a removed protection.
flatten() { tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '; }
constitution_flat="$(flatten "${constitution}")"
engineer_flat="$(flatten "${engineer_agent}")"

assert_prose() {
  case "${constitution_flat}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}
assert_engineer_prose() {
  case "${engineer_flat}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}

grep -Fq '### Agent definition locations' "${constitution}" ||
  fail "consumer does not define Agent definition locations"
grep -Fq '### Authority model' "${constitution}" ||
  fail "consumer does not define Authority model"
grep -Fq 'plugins/agentic-engineering/agents/agent-improver.agent.md' "${constitution}" ||
  fail "consumer does not name the upstream Agent Improver source"

# The bundled SKILL.md is SYNCED from devantler-tech/agent-skills (it carries
# metadata.github-repo and the update-agent-skills workflow re-pulls it), so an edit there
# is silently reverted. The consumer listed it as an authoring surface until 2026-07-25,
# which would route a generic fix into a file that discards it.
#
# Both assertions name the bundled skill PATH. Generic fragments ("authors the bundled",
# "not an authoring surface") could otherwise be satisfied by unrelated ownership prose
# elsewhere in the contract, which would let the specific routing rule be deleted while the
# guard stayed green.
skill_path='plugins/agentic-engineering/skills/agent-improvement/SKILL.md'
assert_prose "\`devantler-tech/agent-skills\`** authors the bundled" \
  "consumer does not name agent-skills as the owner of bundled skills"
assert_prose "${skill_path}\` carries" \
  "consumer does not name the bundled agent-improvement/SKILL.md as the synced copy"
assert_prose "It is a synced artifact, **not** an authoring surface" \
  "consumer does not mark the synced SKILL.md copy as a non-authoring surface"

# Provenance is a per-FILE question: the same plugin directory holds synced skills and
# locally-authored agents, so a per-directory rule is wrong in one direction or the other.
#
# Match the github-repo KEY TOGETHER WITH ITS VALUE. A bare `grep -q github-repo` proves only
# that the file is synced from SOMEWHERE — it would stay green if the upstream moved to a
# different repository, which is exactly the case where the contract's routing text becomes
# wrong and this guard is the only thing that would notice.
bundled_skill="${repo_root}/libraries/agent-plugins/plugins/agentic-engineering/skills/agent-improvement/SKILL.md"
if [ -f "${bundled_skill}" ]; then
  grep -q 'github-repo: https://github.com/devantler-tech/agent-skills' "${bundled_skill}" ||
    fail "bundled agent-improvement/SKILL.md no longer declares devantler-tech/agent-skills as its upstream — re-check the owning repository before trusting the contract text"
fi

# Every machine-readable entrypoint pointer must resolve to an agent the pinned plugin
# actually BUNDLES. Derived from the submodule rather than hard-coded, so the next upstream
# rename cannot leave this consumer pointing at a file that no longer exists — which is
# exactly what happened when the entrypoint moved automated-ai-engineer -> agentic-engineer
# (agent-plugins#89, plugin 4.0.0) and the two sides were updated on different axes.
# FAILS CLOSED on a missing submodule. An earlier revision skipped the check when the
# directory was absent, which made it a no-op in CI (actions/checkout does not initialise
# submodules), so the guard against entrypoint drift would never have run where it matters.
plugin_agents="${repo_root}/libraries/agent-plugins/plugins/agentic-engineering/agents"
entrypoint="$(jq -r '.spec.source.entrypoint' "${desired_state}")"
[ -d "${plugin_agents}" ] ||
  fail "cannot resolve the entrypoint: ${plugin_agents} is missing. Initialise it with
       .claude/scripts/submodule-init.sh libraries/agent-plugins
       (CI does this in the workflow step before this test)."
[ -f "${plugin_agents}/${entrypoint}.agent.md" ] ||
  fail "desired state entrypoint '${entrypoint}' does not resolve to a bundled agent in ${plugin_agents}"
jq -e --arg e "${entrypoint}" '
  (.spec.roles | has($e))
  and .spec.runtime.scheduler.schedules[$e].definitionFrom
      == ("plugin:agentic-engineering/" + $e)
' "${desired_state}" > /dev/null ||
  fail "desired state role and schedule keys must match its declared entrypoint '${entrypoint}'"
# Backticks are literal Markdown, not command substitution.
# shellcheck disable=SC2016
assert_prose "entrypoint **\`${entrypoint}\`**" \
  "consumer prose names an entrypoint other than the declared '${entrypoint}'"
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
grep -Fq 'The `agent-improver` schedule intentionally shares its provider instance' \
  "${constitution}" ||
  fail "consumer does not declare the intentional provider-lane sharing model"
# shellcheck disable=SC2016
for writer_namespace in '`claude/*`' '`codex/*`' '`cursor/*`'; do
  grep -Fq "${writer_namespace}" "${constitution}" ||
    fail "consumer does not record writer namespace ${writer_namespace}"
done
grep -Fq 'remain undeployed and read-only' "${constitution}" ||
  fail "consumer does not fail closed for unmapped Cursor role schedules"

# --- The merged spend mandate -------------------------------------------------
# Spend is a dimension of the Agentic Engineer. The consumer must supply the Spend
# contract the plugin entrypoint resolves, and must keep the money boundary that
# used to live in the standalone agent — merging a mandate into a larger definition
# is exactly where a boundary gets quietly dropped by a later edit.
grep -Fq '### Spend contract' "${constitution}" ||
  fail "consumer does not define the Spend contract section the engineer resolves"
grep -Fq '| **Spend contract** |' "${constitution}" ||
  fail "plugin contract table does not map the Spend contract section"
assert_prose 'never moves money' \
  "Spend contract does not preserve the never-move-money boundary"
assert_prose 'private financial data never reaches a public artifact' \
  "Spend contract does not preserve the financial-confidentiality boundary"
assert_prose 'no personalised investment advice' \
  "Spend contract does not preserve the no-investment-advice boundary"
assert_prose 'Protected-outcomes floor' \
  "Spend contract does not name the protected-outcomes floor the cost pass vetoes against"
assert_prose 'fails closed on the cost dimension only' \
  "Spend contract does not fail closed on the cost dimension when its facts are missing"
# Feature-flag-first: the decision-producing half must ship default-off, gated on the private
# channel, so an unresolved destination cannot leave the ask path live.
assert_prose 'DEFAULT-OFF until the private channel resolves' \
  "Spend contract does not gate the decision-producing half default-off"
# Match the WHOLE clause, not just "stops before": the weak form survives even if the
# contract loses what stops, under which condition, and that resolving it is the maintainer's.
assert_prose "the cost pass runs steps 1–4 of its run loop and **stops before step 5's ask**" \
  "Spend contract does not tie the stop to the unresolved channel and the financial-ask boundary"
assert_prose 'Resolving the channel is what flips the second half on — a maintainer act, never an agent one' \
  "Spend contract does not reserve activation to the maintainer"
# The unresolved-channel state must read the same everywhere. This site previously said
# "route anything blocking through the run report", which contradicted the gate by letting a
# financial decision be parked in the report instead of not being produced at all.
assert_prose 'route only **non-financial** blockers through the run report' \
  "Spend contract lets a financial decision be parked in the run report while the channel is unresolved"

for spend_source in "${finops_skill}" "${lifestyle_floor}" "${snapshot}"; do
  [ -f "${spend_source}" ] ||
    fail "Spend contract names a source that does not exist: ${spend_source}"
done

# The deployed local actor must actually carry the merged mandate. Retiring the standalone
# agent without teaching the surviving one to do spend work would silently drop the role.
assert_engineer_prose 'Steward the spend' \
  "local engineer agent does not carry the merged spend mandate"
assert_engineer_prose 'never move money' \
  "local engineer agent does not carry the never-move-money boundary"
grep -Eq '^[[:space:]]*-[[:space:]]+finops[[:space:]]*$' "${engineer_agent}" ||
  fail "local engineer agent does not load the finops cost-pass skill"
grep -Fq 'drive the reviewed head to merge' "${finops_skill}" ||
  fail "spend run loop does not drive its engineering PR through merge"

[ ! -e "${repo_root}/.claude/agents/agent-improver.md" ] ||
  fail "deployment-local Agent Improver fork still exists"
[ ! -e "${repo_root}/.claude/skills/agent-improvement/SKILL.md" ] ||
  fail "deployment-local Agent Improver skill fork still exists"
[ ! -e "${repo_root}/.claude/agents/finops-engineer.md" ] ||
  fail "standalone FinOps agent still exists; spend is merged into the primary engineer"

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

jq -e '
  .spec.guardrails | index(
    "Spend stewardship never moves money: prepare the financial decision, route it to the maintainer'"'"'s declared private channel, and keep private financial data out of every public artifact."
  ) != null
' "${desired_state}" > /dev/null ||
  fail "provider-neutral desired state does not preserve the never-move-money boundary"

# A resurrected standalone FinOps role or schedule would put a second scheduled writer
# back over the repositories the engineer already owns — the exact shape the merge removed.
jq -e '
  (.spec.roles | has("finops-engineer") | not)
  and (.spec.runtime.scheduler.schedules | has("finops-engineer") | not)
  and (.spec.consumer | has("requiredWhenFinOpsEnabled") | not)
  and (.spec.consumer.requiredWhenSpendStewardshipEnabled == ["Spend contract"])
' "${desired_state}" > /dev/null ||
  fail "desired state must resolve spend through the Spend contract, not a separate FinOps role"

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
