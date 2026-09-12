#!/usr/bin/env bash
# Verify portable ownership declarations and removal of retired engineering wiring.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL provider-neutral agents: %s\n' "$*" >&2; exit 1; }
[[ ! -e "$ROOT/.claude/loaders/cursor-daily-ai-engineer.md" ]] || fail 'retired loader remains'
[[ ! -e "$ROOT/.cursor/environment.json" ]] || fail 'retired environment configuration remains'
[[ ! -e "$ROOT/.claude/scripts/cursor-issue-board-sweep.sh" ]] || fail 'provider-specific board helper remains'
[[ -r "$ROOT/.claude/loaders/portable-agentic-engineer.md" ]] || fail 'portable loader is missing'
if rg -n 'Cursor (cloud|Automation)|cursor-daily|cursor-issue-board|cursor/\*|--runtime cursor|Antigravity' \
  "$ROOT/AGENTS.md" "$ROOT/.claude/skills/portfolio-maintenance/SKILL.md" \
  "$ROOT/.claude/agents/portfolio-surveyor.md" "$ROOT/.claude/plugin-consumption/inference-routing-runtime.md"; then
  fail 'active instructions retain retired engineering wiring'
fi
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
jq -e --slurpfile registry "$ROOT/.claude/plugin-consumption/agent-instances.json" '
  all(.routes[]; .runtime as $id | $registry[0].instances | has($id))
  and all(.runtimes | keys[]; . as $id | $registry[0].instances | has($id))
' "$ROOT/.claude/plugin-consumption/inference-routing.policy.json" > /dev/null || fail 'routing references an undeclared instance'
printf 'PASS provider-neutral ownership and active instruction boundaries\n'
