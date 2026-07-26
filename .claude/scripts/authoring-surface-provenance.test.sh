#!/usr/bin/env bash
#
# Guards § Agent definition locations against naming a SYNCED file as an authoring
# surface.
#
# `plugins/*/skills/*/SKILL.md` in devantler-tech/agent-plugins carry
# `metadata.github-repo` provenance and are re-pulled by the daily
# `update-agent-skills` workflow. A hand-edit there survives until the next sync and
# then silently disappears — no conflict, no CI failure, no signal. The sibling
# `plugins/*/agents/*.agent.md` carry no provenance and ARE authored there, so
# "editable here?" is a per-file question and a per-directory rule gets it wrong.
#
# The contract named the synced agent-improvement SKILL.md as a version-controlled
# authoring target (caught 2026-07-25 on agent-plugins#89, rated Major), which would
# route a generic skill change into a file that reverts it. This pins that shut.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "authoring-surface provenance: FAIL — $*" >&2
  exit 1
}

[ -f "${constitution}" ] || fail "missing ${constitution}"

# Flatten so a rule wrapped across lines is still matched (prose guards must
# flatten whitespace — a line-anchored grep silently passes on reflowed text).
flat="$(tr '\n' ' ' <"${constitution}" | tr -s ' ')"

section="$(printf '%s' "${flat}" |
  sed -n 's/.*### Agent definition locations\(.*\)### Authority model.*/\1/p')"
[ -n "${section}" ] || fail "could not isolate § Agent definition locations"

# 1. No CONCRETE bundled skill path may be named as an authoring surface. The glob
#    form `plugins/*/skills/*/SKILL.md` is the warning itself and must stay allowed,
#    so match only path segments that name a real plugin and a real skill.
if printf '%s' "${section}" |
  grep -qE 'plugins/[A-Za-z0-9_.-]+/skills/[A-Za-z0-9_.-]+/SKILL\.md'; then
  fail "§ Agent definition locations names a concrete bundled
  plugins/<plugin>/skills/<skill>/SKILL.md path as an authoring surface.
  Those files are SYNCED from their metadata.github-repo upstream and an edit there is
  silently reverted. Name the upstream authoring repo instead (agent-skills)."
fi

# 2. The true upstream for skill bodies must be named, by its FULL slug. A bare
#    `agent-skills` would be satisfied by the `update-agent-skills` workflow name
#    that this same paragraph mentions — a vacuous assertion.
printf '%s' "${section}" | grep -q 'devantler-tech/agent-skills' ||
  fail "§ Agent definition locations must name devantler-tech/agent-skills as the
  authoring home for generic skill bodies."

# 3. The sibling agents file genuinely IS authored in agent-plugins — keep it named,
#    so a fix for (1) does not over-correct and strand the agent definition.
printf '%s' "${section}" | grep -q 'agents/agent-improver\.agent\.md' ||
  fail "§ Agent definition locations must still name
  plugins/agentic-engineering/agents/agent-improver.agent.md, which carries no
  provenance and is authored in agent-plugins."

# 4. The per-file provenance test must be stated, not just the conclusion — the
#    directory mixes both kinds, so the next new file needs the check, not the answer.
printf '%s' "${section}" | grep -q 'metadata\.github-repo' ||
  fail "§ Agent definition locations must state the per-file provenance check by its
  exact key (metadata.github-repo) rather than only its conclusion for today's files."

echo "authoring-surface provenance: OK — 4 assertions passed"
