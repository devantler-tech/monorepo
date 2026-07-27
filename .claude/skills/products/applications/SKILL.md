---
name: maintain-applications
description: Maintenance task menu for the platform-tenant apps — private wedding-app and ascoachingogvaner (SvelteKit + TS), plus the public doggy-countdown site. Conservative: triage, dependency/security hygiene, CI health, small confident fixes. Use when the daily maintainer selects applications.
---

# Maintain: Applications (platform tenants)

Each app's canonical maintenance task menu lives **in its own repo**. For the two private SvelteKit
tenants, read the **`## Maintenance`** section of each `AGENTS.md` (on the submodule's latest `main`):
- `applications/wedding-app/AGENTS.md` — <https://github.com/devantler-tech/wedding-app/blob/main/AGENTS.md>
- `applications/ascoachingogvaner/AGENTS.md` — <https://github.com/devantler-tech/ascoachingogvaner/blob/main/AGENTS.md>

Those submodules are usually not checked out — populate at the pinned commit with the fail-closed
wrapper `.claude/scripts/submodule-init.sh applications/<name>` (**never** a bare
`git submodule update --init`, which re-introduces the shared `core.worktree` and collapses every
parallel session into one tree; never `--remote`), or do GitHub-API-only work.
**Private** repos — extra discretion.

**`devantler-tech/doggy-countdown`** is a **public**, small static countdown tenant (Simba). It is
**not a submodule yet** — work via the GitHub API (or a standalone clone). It has no `AGENTS.md`
yet; keep changes conservative (CI health, dependency hygiene, content the owner asks for). Shared
cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a pointer by
design.

## Roadmap & enhancement
Each app's roadmap lives in **GitHub Issues** on its repo (`roadmap` label). **Advance** via
[`product-engineering`](../../product-engineering/SKILL.md) **conservatively** (private apps: extra
discretion; doggy-countdown: keep the scope to that one countdown page): coverage / quality /
performance within the app owner's intent; don't add features without direction.
