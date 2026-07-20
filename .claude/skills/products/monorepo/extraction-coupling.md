# devantler.tech extraction — monorepo↔site coupling inventory

> Agent-facing measurement for [#2317](https://github.com/devantler-tech/monorepo/issues/2317)
> (child of epic [#2062](https://github.com/devantler-tech/monorepo/issues/2062)).
> Not a user-facing docs page. Update this file when coupling changes; do not treat it as the epic's
> status board.

**Recorded:** 2026-07-20 (Cursor cloud instance). **Method:** read the monorepo tree on `main`
(workflows, `docs/`, portfolio map) — no live Pages or DNS probe.

## Why this exists

Epic #2062 moves the Astro Starlight site out of this monorepo into its own repo and onto the
platform. Before any move, every path that is **site-owned** vs **monorepo-brain-owned** must be
named — otherwise extraction either strands the Daily AI Engineer definition in the site repo or
leaves Pages/deploy wiring behind.

## Site-owned (moves with the site)

These paths are the product `devantler.tech` today. They should leave with the extraction child
([#2318](https://github.com/devantler-tech/monorepo/issues/2318)).

| Path | Role |
|---|---|
| `docs/` (entire tree) | Astro + Starlight app: `package.json`, `astro.config.mjs`, `src/`, `public/`, content, site scripts |
| `docs/public/CNAME` | Pages custom domain (`devantler.tech`) |
| `docs/scripts/check-active-projects-drift.sh` (+ `.test.sh`) | Site content drift guard (invoked from monorepo CI today) |
| `docs/scripts/check-homepage-project-parity.mjs` | Homepage ↔ projects parity check |
| `.github/workflows/publish-pages.yaml` | GitHub Pages build+deploy; path filter `docs/**`; artifact `docs/dist` |

**CI jobs that are site-shaped** (today live in monorepo `.github/workflows/ci.yaml`, triggered on
`docs/**` path filters): the docs build, active-projects drift test/script, and related npm cache
keys pointing at `docs/package-lock.json`. Those job definitions either move into the new repo's CI
or become thin wrappers that call into the submodule — decide in #2318; do not leave them half-moved.

## Monorepo-brain (stays here)

These are the portfolio aggregator and the Daily AI Engineer definition. They must **not** move into
`devantler-tech/devantler.tech`.

| Path | Role |
|---|---|
| `AGENTS.md`, `CLAUDE.md` | Portfolio contract + shim |
| `.claude/` | Agents, skills, product cards, loaders, scripts |
| `.gitmodules` + submodule directories (`applications/`, `platform/`, `templates/`, `libraries/`, `homebrew-tap`, `github/`) | Product aggregation |
| Root helper scripts (`commit-and-push-all.sh`, `delete-submodule.sh`) | Monorepo ops |
| `.github/workflows/ci.yaml` agent/script self-tests (non-docs path filters) | Definition CI |
| `.github/workflows/todos.yaml`, `copilot-setup-steps.yml` | Monorepo automation |
| `.coderabbit.yaml`, `.editorconfig`, `.devcontainer.json`, `.vscode/` | Repo/editor config for the aggregator |
| Root `README.md` | Monorepo getting-started (submodule init), not the public site |

## Shared / must re-home carefully

| Surface | Today | Extraction note |
|---|---|---|
| Portfolio map row for the site | `AGENTS.md` → `docs/` + repo root | After #2318: point at the new submodule path (proposed `applications/devantler.tech`) |
| Product card | `.claude/skills/products/monorepo/SKILL.md` | Split or retarget once the site has its own repo card |
| GitHub Pages settings / environment `github-pages` | Repo Settings + `publish-pages.yaml` deploy job | Retire only in [#2319](https://github.com/devantler-tech/monorepo/issues/2319) after DNS cutover |
| DNS `devantler.tech` | Pages (via `docs/public/CNAME`) | Cut over in #2319; do not delete CNAME before the cluster serves TLS |
| Org `.github` declarative repo bootstrap | N/A until create | #2318 creates `devantler-tech/devantler.tech` (custom-properties bootstrap caveat on #2062) |

## Current publish path (baseline)

1. Push to `main` touching `docs/**` (or `workflow_dispatch`).
2. `.github/workflows/publish-pages.yaml` → `npm ci` + `npm run build` in `docs/` → upload `docs/dist`.
3. Deploy job uses environment `github-pages` + `actions/deploy-pages`.

No behaviour in this inventory changes that path.

## Next shippable children (already filed under #2062)

1. **[#2317](https://github.com/devantler-tech/monorepo/issues/2317)** — this inventory (measurement).
2. **[#2318](https://github.com/devantler-tech/monorepo/issues/2318)** — extract site-owned paths into `devantler-tech/devantler.tech` + monorepo submodule pin.
3. **[#2319](https://github.com/devantler-tech/monorepo/issues/2319)** — host on the platform and retire GitHub Pages.

Open decisions that remain on #2062 (repo name, submodule path, WebApp archetype vs hand tenant,
static container vs SSR) are unchanged by this inventory — defaults on the epic still apply until a
draft PR says otherwise.
