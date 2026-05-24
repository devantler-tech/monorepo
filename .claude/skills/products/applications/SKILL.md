---
name: maintain-applications
description: Maintenance task menu for the PRIVATE platform-tenant apps — wedding-app (TypeScript) and ascoachingogvaner (Svelte). Conservative: triage, dependency/security hygiene, CI health, small confident fixes. Extra discretion — these are private client/personal repos. Use when the daily maintainer selects applications.
---

# Maintain: Applications (private platform tenants)

| Product | Repo | path | lang | what |
|---|---|---|---|---|
| Wedding app | `devantler-tech/wedding-app` | `applications/wedding-app` | TypeScript | wedding API service on the platform cluster |
| AS Coaching | `devantler-tech/ascoachingogvaner` | `applications/ascoachingogvaner` | Svelte | coaching website (platform tenant) |

Both **private**, **Issues enabled**. Shared rules: monorepo
[`AGENTS.md`](../../../../AGENTS.md). Memory = the [`MAINTENANCE.md`](../../../../MAINTENANCE.md)
dashboard.

- **Privacy:** never surface these repos' names/contents/links on the **public** devantler.tech site (the monorepo card excludes them from the site map). Extra discretion.
- **Not checked out by default:** populate at the pinned commit with `git submodule update --init applications/<name>` (never `--remote`) for diff work; otherwise do GitHub-API-only work.
- First read each repo's `README.md` + `.github/workflows/` + `package.json` for its build/test & release model. **Branch** `claude/daily-ai-assistant-<desc>`; **labels** `automation` + an existing area label.
- **Validate:** the repo's own checks — wedding-app `npm ci && npm run build` + `npm test`/`npm run lint`; ascoachingogvaner the SvelteKit equivalent (`npm run check` / `npm run build`). Never commit secrets/`.env`.

## Task menu (conservative; ≤1 item per app per run)
1. **Triage & label** new issues/PRs; one insightful comment on the oldest un-commented item.
2. **Dependency & security hygiene:** curate Dependabot/Renovate PRs (npm); prioritise security advisories; flag majors.
3. **CI/workflow health:** keep CI green; red on `main` is top priority — root-cause + draft fix.
4. **Confident, low-risk fixes** (broken build, obvious bug, broken README link) → draft PR.
5. **Maintain your own PRs:** fix CI you caused, resolve conflicts.
