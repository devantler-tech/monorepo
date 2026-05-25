---
name: maintain-skills
description: Maintenance + advance task menu for the shared AGENT-EXTENSION libraries — devantler-tech/skills (generic Copilot/agent skills, gh-skill-installable) and devantler-tech/plugins (once it exists). Generic, cross-tool, industry-standard building blocks reused across the suite; high-care and backward-compatible. Use when the daily maintainer selects skills/plugins or runs the holistic shared-library review.
---

# Maintain: Skills + Plugins (shared agent extensions)

The shared **agent-extension** libraries — the agentic counterpart to the CI building blocks in the
[github-actions](../github-actions/SKILL.md) card:
- `devantler-tech/skills` — generic Copilot/agent skills, `gh skill`-installable. **Not a submodule** —
  work via the GitHub API, or clone it standalone into a per-run worktree if you need to build/validate.
  Read its `## Maintenance` in <https://github.com/devantler-tech/skills/blob/main/AGENTS.md> (create
  that section if missing — align it with the others).
- `devantler-tech/plugins` — **does not exist yet.** If a plugin-shaped pattern becomes ready, propose
  creating the repo (flag the maintainer) rather than forcing it into `skills` or a product.

**These are shared libraries — design for reuse, not for one product.** Keep them **generic and
industry-standard** (the portability principle: a Claude→Copilot/ChatGPT switch should stay painless),
**additive & backward-compatible** (every product is a potential consumer), and **well-tested**. Don't
put product-specific logic here.

**Advance them via the holistic review** (contract *Holistic review*; [`product-engineering`](../../product-engineering/SKILL.md)
§7): when a generic skill/convention has emerged across 2+ products, extract it here so every product
inherits it, then migrate consumers. Triage/label issues, drive trusted-author PRs to merge, keep deps
& docs current.

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a pointer
by design.

## Roadmap & enhancement
Roadmap lives in **GitHub Issues** on `devantler-tech/skills` (`roadmap` label). The strategic frame:
*what generic capability would most help the suite next?* — surface candidates from the holistic review.
