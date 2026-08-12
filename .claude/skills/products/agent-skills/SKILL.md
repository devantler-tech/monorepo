---
name: maintain-skills
description: Maintenance + advance task menu for the shared AGENT-EXTENSION libraries — devantler-tech/agent-skills (generic, cross-tool agent skills) and devantler-tech/agent-plugins (a tool-neutral marketplace bundling those skills for VS Code / Copilot CLI / Claude Code). Generic, cross-tool, industry-standard building blocks reused across the suite; high-care and backward-compatible. Use when the Agentic Engineer selects skills/plugins or runs the holistic shared-library review.
---

# Maintain: Skills + Plugins (shared agent extensions)

The shared **agent-extension** libraries — the agentic counterpart to the CI building blocks in the
[github-actions](../github-actions/SKILL.md) card. Both are checked-in submodules, so a per-run
worktree can give you a working copy to build and validate in — but only once the submodule is
populated. Populate it with `.claude/scripts/submodule-init.sh <path>`, never a bare
`git submodule update --init`, which silently collapses every parallel session into one physical
tree; if that script fails, stop rather than work against an unpopulated gitlink. Each repo's
canonical task menu lives in its own `AGENTS.md` `## Maintenance`, and this card is a thin pointer
to it:

- `devantler-tech/agent-skills` — generic, cross-tool agent skills at submodule path
  `libraries/agent-skills`.
  Task menu: <https://github.com/devantler-tech/agent-skills/blob/main/AGENTS.md>.
- `devantler-tech/agent-plugins` — the tool-neutral marketplace at submodule path
  `libraries/agent-plugins`.
  Task menu: <https://github.com/devantler-tech/agent-plugins/blob/main/AGENTS.md>.
  This monorepo consumes `agentic-engineering@devantler-plugins` via
  [`.claude/settings.json`](../../../settings.json) (see monorepo#2363). Keep plugins
  additive & backward-compatible; generic role improvements land here so every consumer inherits them.

**These are shared libraries — design for reuse, not for one product.** Keep them **generic and
industry-standard** (the portability principle: a Claude→Copilot/ChatGPT switch should stay painless),
**additive & backward-compatible** (every product is a potential consumer), and **well-tested**. Don't
put product-specific logic here.

**Advance them via the holistic review** (contract *Holistic review*; [`product-engineering`](../../product-engineering/SKILL.md)
§7): when a generic skill/convention has emerged across 2+ products, extract it here so every product
inherits it, then migrate consumers. Triage/label issues, drive actionable trusted-author PRs to merge,
leave automation-owned dependency PRs alone, and keep dependency automation & docs current.
Programmed `chore(deps): update agent skills` PRs are the no-review exception defined in the root
contract only when `.claude/scripts/programmed-bot-review-exemption.sh` exits 0: let required CI and
auto-merge decide accepted exemptions, and never spend a review lane on exit-0 exemptions. Installed
skill roots hold copies from several upstreams, so exit 0 also requires every changed skill to be
listed in the reviewed `.claude/skill-ownership-allowlist.tsv`; an unlisted or third-party skill
returns 3. Never authorize that from the skill's own `metadata.github-repo` — its upstream writes that
line, so it can grant itself the carve-out; passing it to the classifier only corroborates. A genuine
`agent-plugins` marketplace update is trusted but review-bearing when the classifier exits 3; request
semantic review because bundled skill prose is executable agent instruction. Route classifier exit 1
and non-matching lookalikes through the external/static-only path; exit 2 is a fail-closed error.

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md).

## Roadmap & enhancement

The two libraries keep separate issue queues — do not conflate them:

- Skills: GitHub Issues on `devantler-tech/agent-skills` (`roadmap` label)
- Plugins: GitHub Issues on `devantler-tech/agent-plugins` (`roadmap` label)

Strategic frame for both: *what generic capability would most help the suite next?* — surface
candidates from the holistic review.
