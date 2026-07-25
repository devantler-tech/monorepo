---
name: maintain-skills
description: Maintenance + advance task menu for the shared AGENT-EXTENSION libraries — devantler-tech/agent-skills (generic Copilot/agent skills, gh-skill-installable) and devantler-tech/agent-plugins (tool-neutral marketplace). Generic, cross-tool, industry-standard building blocks reused across the suite; high-care and backward-compatible. Use when the daily maintainer selects skills/plugins or runs the holistic shared-library review.
---

# Maintain: Skills + Plugins (shared agent extensions)

The shared **agent-extension** libraries — the agentic counterpart to the CI building blocks in the
[github-actions](../github-actions/SKILL.md) card:
- `devantler-tech/agent-skills` — generic Copilot/agent skills, `gh skill`-installable. **Not a submodule** —
  work via the GitHub API, or clone it standalone into a per-run worktree if you need to build/validate.
  Read its `## Maintenance` in <https://github.com/devantler-tech/agent-skills/blob/main/AGENTS.md> (create
  that section if missing — align it with the others).
- `devantler-tech/agent-plugins` — tool-neutral marketplace at submodule path `libraries/agent-plugins`.
  This monorepo consumes `agentic-engineering@devantler-plugins` via
  [`.claude/settings.json`](../../../settings.json) (see monorepo#2363 / #2403). Keep plugins
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
contract only when `.claude/scripts/programmed-bot-review-exemption.sh` classification succeeds:
let required CI and auto-merge decide accepted exemptions, and never spend a review lane on them.
Route classifier failures, non-matching PRs, and lookalikes through the normal review process.

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a pointer
by design.

## Roadmap & enhancement
Roadmap lives in **GitHub Issues** on `devantler-tech/agent-skills` (`roadmap` label). The strategic frame:
*what generic capability would most help the suite next?* — surface candidates from the holistic review.
