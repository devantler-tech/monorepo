---
name: maintain-github-actions
description: Maintenance task menu for the shared CI/CD building block — devantler-tech/actions (composite actions + reusable workflows; the standalone reusable-workflows repo was merged into it and archived 2026-07-10). Load-bearing for every other repo's CI, so changes are high-care and backward-compatible. Use when the daily maintainer selects github-actions.
---

# Maintain: GitHub Actions (composite actions + reusable workflows)

The repo's canonical maintenance task menu lives **in its own repo** — read the **`## Maintenance`**
section of its `AGENTS.md` (on the submodule's latest `main`):
- `github/devantler-tech/github-actions/actions/AGENTS.md` — <https://github.com/devantler-tech/actions/blob/main/AGENTS.md>

The standalone `devantler-tech/reusable-workflows` repo was **merged into `actions` and archived
2026-07-10** — its reusable (`workflow_call`) workflows now live in actions' `.github/workflows/`.
Never open PRs on the archived repo; target `actions` for all shared-CI work.

**Blast radius:** changes here ripple to every consumer repo — prefer additive, backward-compatible
changes. Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card
is a pointer by design — the menu is maintained once, in the repo's own `AGENTS.md`.

## Roadmap & enhancement
The roadmap lives in **GitHub Issues** (`roadmap` label) on `devantler-tech/actions`. **Advance** via
[`product-engineering`](../../product-engineering/SKILL.md): new composite actions / workflow
capabilities and their tests — but because of the blast radius, keep everything **additive &
backward-compatible** and never break a consumer.
