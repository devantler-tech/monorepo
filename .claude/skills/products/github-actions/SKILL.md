---
name: maintain-github-actions
description: Maintenance task menu for shared CI/CD building blocks in devantler-tech/.github; devantler-tech/actions remains for unmigrated consumers. Load-bearing for every other repo's CI, so changes are high-care and backward-compatible. Use when the daily maintainer selects github-actions.
---

# Maintain: GitHub Actions (composite actions + reusable workflows)

The repo's canonical maintenance task menu lives **in its own repo** — read the **`## Maintenance`**
section of its `AGENTS.md` (on the submodule's latest `main`):
- `github/devantler-tech/.github-public/AGENTS.md` — <https://github.com/devantler-tech/.github/blob/main/AGENTS.md>

The standalone `devantler-tech/reusable-workflows` repo is archived. Shared composite actions and
reusable (`workflow_call`) workflows now live in `.github/actions/` and `.github/.github/workflows/`.
Never open PRs on the archived repo; target `.github` for new shared-CI work. The old `actions`
repository only takes urgent compatibility fixes for unmigrated consumers, each linked to its
`.github` counterpart; its retirement is tracked by [`.github#240`](https://github.com/devantler-tech/.github/issues/240).

**Blast radius:** changes here ripple to every consumer repo — prefer additive, backward-compatible
changes. Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card
is a pointer by design — the menu is maintained once, in the repo's own `AGENTS.md`.

## Roadmap & enhancement

The roadmap lives in **GitHub Issues** (`roadmap` label) on `devantler-tech/.github`. **Advance** via
[`product-engineering`](../../product-engineering/SKILL.md): new composite actions / workflow
capabilities and their tests — but because of the blast radius, keep everything **additive &
backward-compatible** and never break a consumer.
