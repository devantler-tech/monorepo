---
name: maintain-skills
description: Maintenance + advance task menu for the shared AGENT-EXTENSION libraries — devantler-tech/agent-skills (generic Copilot/agent skills, gh-skill-installable) and devantler-tech/agent-plugins (a tool-neutral marketplace bundling those skills for VS Code / Copilot CLI / Claude Code; rescope in progress — plugins#7). Generic, cross-tool, industry-standard building blocks reused across the suite; high-care and backward-compatible. Use when the daily maintainer selects skills/plugins or runs the holistic shared-library review.
---

# Maintain: Skills + Plugins (shared agent extensions)

The shared **agent-extension** libraries — the agentic counterpart to the CI building blocks in the
[github-actions](../github-actions/SKILL.md) card. Both are checked-in submodules; each repo's
canonical task menu lives in its own `AGENTS.md` `## Maintenance` (this card is a thin pointer):

- `devantler-tech/agent-skills` — path `libraries/agent-skills` —
  <https://github.com/devantler-tech/agent-skills/blob/main/AGENTS.md>
- `devantler-tech/agent-plugins` — path `libraries/agent-plugins` —
  <https://github.com/devantler-tech/agent-plugins/blob/main/AGENTS.md>

**These are shared libraries — design for reuse, not for one product.** Keep them **generic and
industry-standard** (the portability principle: a Claude→Copilot/ChatGPT switch should stay painless),
**additive & backward-compatible** (every product is a potential consumer), and **well-tested**. Don't
put product-specific logic here.

**Advance them via the holistic review** (contract *Holistic review*; [`product-engineering`](../../product-engineering/SKILL.md)
§7): when a generic skill/convention has emerged across 2+ products, extract it here so every product
inherits it, then migrate consumers. Triage/label issues, drive actionable trusted-author PRs to merge,
leave automation-owned dependency PRs alone, and keep dependency automation & docs current.

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md).

## Roadmap & enhancement

Roadmaps are separate issue queues — do not conflate them:

- Skills: GitHub Issues on `devantler-tech/agent-skills` (`roadmap` label)
- Plugins: GitHub Issues on `devantler-tech/agent-plugins` (`roadmap` label; rescope tracked at
  [plugins#7](https://github.com/devantler-tech/agent-plugins/issues/7))

Strategic frame for both: *what generic capability would most help the suite next?* — surface
candidates from the holistic review.
