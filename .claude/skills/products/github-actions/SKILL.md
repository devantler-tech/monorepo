---
name: maintain-github-actions
description: Maintenance task menu for the shared CI/CD building blocks — devantler-tech/actions (composite actions) and devantler-tech/reusable-workflows. Load-bearing for every other repo's CI, so changes are high-care and backward-compatible. Use when the daily maintainer selects github-actions.
---

# Maintain: GitHub Actions + Reusable Workflows

Each repo's canonical maintenance task menu lives **in its own repo** — read the **`## Maintenance`**
section of each `AGENTS.md` (on the submodule's latest `main`):
- `github/devantler-tech/github-actions/actions/AGENTS.md` — <https://github.com/devantler-tech/actions/blob/main/AGENTS.md>
- `github/devantler-tech/github-actions/reusable-workflows/AGENTS.md` — <https://github.com/devantler-tech/reusable-workflows/blob/main/AGENTS.md>

**Blast radius:** changes here ripple to every consumer repo — prefer additive, backward-compatible
changes. Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card
is a pointer by design — each menu is maintained once, in the repo's own `AGENTS.md`.
