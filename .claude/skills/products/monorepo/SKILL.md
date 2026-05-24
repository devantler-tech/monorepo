---
name: maintain-monorepo
description: Maintenance task menu for devantler-tech/monorepo itself — the devantler.tech Astro Starlight docs site (docs/), CI/CD, submodule-README→docs sync, and issue/PR triage. GitHub Issues are ENABLED here. Use when the daily maintainer selects the monorepo/site.
---

# Maintain: Monorepo + devantler.tech site

**Repo** `devantler-tech/monorepo` · **path** repo root + `docs/` · **Issues ENABLED**
(issue + PR triage/creation, labels, comments). Shared rules: monorepo
[`AGENTS.md`](../../../../AGENTS.md). Memory = `state.json` under `products.monorepo`
(cursors/caches) + the end-of-run report; there is no version-controlled dashboard.

## Repo-specific conventions
- **Branch** `claude/<area>-<desc>`. Submodule pointers often show as modified — **expected, not yours**; detect real dirtiness with `git status --porcelain --ignore-submodules=all`; never stage pointer bumps; never `git submodule update --remote`.
- **Validate:** before any `docs/` PR, `[ -d docs/node_modules ] || (cd docs && npm ci)` then `cd docs && npm run build` (use `npm --prefix docs …`). Workflows → `actionlint`. Never edit auto-generated files / `*.lock.yml`.
- **Labels** (apply only from this set): `automation`, `documentation`, `ci`, `dependencies`, `submodules`, `bug`, `enhancement`, `question`, `duplicate`, `wontfix`, `needs triage`, `needs investigation`, `performance`, `refactor`, `security`, `repo-assist`, `agentic-workflows`, `good first issue`, `help wanted`, `spam`, `blocked`, `next`.

## Task menu (1–3 highest-value; Content Review gated to Mondays)
- **A. CI Doctor:** `gh run list --repo devantler-tech/monorepo --status failure --limit 20 ...` (active workflows **CI** + **Publish - Pages**; ignore removed gh-aw workflows & Dependabot's submodule-update job). Dedupe vs state.json `ci_investigation_cache`. `gh run view <id> --log-failed` (untrusted); root-cause (bad MDX/frontmatter, broken imports, `npm ci` lockfile desync, Node/Sharp, dead submodule ref, broken YAML). Failure on an open PR → one root-cause comment (+ draft fix if confident); else record in state.json `ci_investigation_cache`. Prune cache >7d.
- **B. CI/CD health:** workflows `ci.yaml`, `publish-pages.yaml`, `sync-labels.yaml`, `todos.yaml`, `copilot-setup-steps.yml`. Never run `gh aw` / recompile `*.lock.yml`. Bundle Dependabot/Renovate PRs; flag majors. Safe improvements (caching, path filters, concurrency, pinned actions) → one `ci:` draft PR; validate YAML first.
- **C. Site QA** — rotate one sub-task/run (`site_qa_cursor`: link-check → accessibility → multi-device → …). Use `npm --prefix docs`; for browser checks start preview backgrounded, CAPTURE the PID, and ALWAYS `kill` it (free port 4321) even on failure. **Link-check:** extract URLs from `docs/src/content`, `curl -sL -o /dev/null -w "%{http_code}"`; skip the `unfixable_links` cache; broken → fix (draft `docs: fix broken links`) or cache with reason. **Accessibility:** heading hierarchy, alt text, descriptive link text, ARIA, skip-link, WCAG-AA green (`#39ff14` dark / `#15803d` light). **Multi-device** (Playwright installed globally; chromium cached; if unavailable skip + advance cursor): iPhone 12/Pixel 5/iPad/iPad Pro/Desktop × `/`,`/about/`,`/projects/`,`/templates/`,`/blog/` (note: `/` is a Starlight splash with no sidebar by design; a refused GA `gtag` request is the sandbox, not a bug).
- **D. Content Sync** (don't `git submodule update --remote`): per-project descriptions live in `docs/src/content/docs/projects/active.mdx` under `##` headings (NOT `projects/index.mdx`). Map ksail→`## KSail` (**brief + link to ksail.devantler.tech only — never duplicate KSail docs**), platform→`## Platform`, actions→`## Actions`, reusable-workflows→`## Reusable Workflows`, go/dotnet-template→`docs/src/content/docs/templates/{go,dotnet}.md`. Private `applications/*` are intentionally NOT mapped. **Never modify blog posts.** Build-verify → draft `docs: sync project descriptions`.
- **E. Content Review (Mondays only;** rotate unbloat ↔ editorial in `content_review`): **Unbloat** one not-recently-cleaned file (skip frontmatter `disable-agentic-editing: true`), cut duplication/verbosity ≥20% w/o losing accuracy. **Editorial** rotate lens weekly (Technical Rigor → Clarity → Onboarding → Portfolio Balance).
- **F. Repo Assist:** triage/label new issues + PRs; comment on the oldest open item lacking an AI comment (1–3/run); self-spotted fixes → draft PR (use `Fixes #N` when it closes an issue); ≤3 stale-PR/issue nudges.
