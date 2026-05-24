---
name: maintain-applications
description: Maintenance task menu for the PRIVATE platform-tenant apps — wedding-app and ascoachingogvaner (both SvelteKit + TS). Conservative: triage, dependency/security hygiene, CI health, small confident fixes. Use when the daily maintainer selects applications.
---

# Maintain: Applications (private platform tenants)

Each app's canonical maintenance task menu lives **in its own (private) repo** — read the
**`## Maintenance`** section of each `AGENTS.md` (on the submodule's latest `main`):
- `applications/wedding-app/AGENTS.md` — <https://github.com/devantler-tech/wedding-app/blob/main/AGENTS.md>
- `applications/ascoachingogvaner/AGENTS.md` — <https://github.com/devantler-tech/ascoachingogvaner/blob/main/AGENTS.md>

These submodules are usually not checked out — populate at the pinned commit with
`git submodule update --init applications/<name>` (never `--remote`), or do GitHub-API-only work.
**Private** repos — extra discretion. Shared cross-repo rules are in the monorepo
[`AGENTS.md`](../../../../AGENTS.md). This card is a pointer by design.
