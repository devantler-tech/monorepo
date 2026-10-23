---
name: maintain-github-actions
description: Maintenance task menu for shared CI/CD building blocks in devantler-tech/.github. Load-bearing for every consumer's CI, so changes are high-care and backward-compatible. Use when the daily maintainer selects github-actions.
---

# Maintain: GitHub Actions (composite actions + reusable workflows)

The repo's canonical maintenance task menu lives **in its own repo** — read the **`## Maintenance`**
section of its `AGENTS.md` (on the submodule's latest `main`):
- `github/devantler-tech/.github-public/AGENTS.md` — <https://github.com/devantler-tech/.github/blob/main/AGENTS.md>

Shared composite actions and reusable (`workflow_call`) workflows live in `.github/actions/`
and `.github/.github/workflows/`. Always target `.github` for new shared-CI work, not the retired
standalone catalogue. Do not reintroduce a dependency on a retired checkout. Final backup,
deletion and post-deletion checks are tracked by [`.github#240`](https://github.com/devantler-tech/.github/issues/240).

**Blast radius:** changes here ripple to every consumer repo — prefer additive, backward-compatible
changes. Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card
is a pointer by design — the menu is maintained once, in the repo's own `AGENTS.md`.

## Roadmap & enhancement

The roadmap lives in **GitHub Issues** (`roadmap` label) on `devantler-tech/.github`. **Advance** via
[`product-engineering`](../../product-engineering/SKILL.md): new composite actions / workflow
capabilities and their tests — but because of the blast radius, keep everything **additive &
backward-compatible** and never break a consumer.
