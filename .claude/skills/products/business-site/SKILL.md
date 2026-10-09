---
name: maintain-business-site
description: Maintenance menu for the devantler.tech business website, Projects catalogue and journal, owned by devantler-tech/business-site. Use for website quality, content, discovery and adoption work.
---

# Maintain: Devantler Tech business site

**Repo** `devantler-tech/business-site` · **path** `applications/business-site` (Astro application at its repository root) · **Issues ENABLED**
(issue + PR triage/creation, labels, comments). Shared rules: monorepo
[`AGENTS.md`](../../../../AGENTS.md). Memory = your **native memory** (the business-site cursors +
caches, e.g. `caches.md`) + the end-of-run report; no version-controlled dashboard, no bespoke `state.json`.

**Roadmap & enhancement:** the site/repo roadmap lives in **GitHub Issues** here (`roadmap`-labelled
epics + milestones). Beyond the maintenance menu below, **advance** the site via
[`product-engineering`](../../product-engineering/SKILL.md): docs/site features, accessibility,
performance (bundle size / Lighthouse), and content quality (the Site QA + Content Review tasks below
are the recurring slice of that). The blog is a maintained public product: use privacy-safe evidence to
improve discovery, comprehension, adoption, and portfolio positioning through both new posts and
material refreshes. Validate with the Node 24 root application build before any PR. A source merge is not publication: verify the successful source-owned deployment, live source/run receipt and visitor paths. The monorepo pin is aggregation only.

## Repo-specific conventions
- **Branch:** use the registered instance namespace and issue-first claims. Work in an isolated business-site worktree; never change the aggregator's gitlink unless delivering an explicitly approved adoption.
- **Validate:** from the business-site repository root, `[ -d node_modules ] || npm ci` then `LC_ALL=C npm run build`. Editorial instructions remain in `docs/README.md`, not an application working directory. Workflows → `actionlint`. Never edit auto-generated files / `*.lock.yml`.
- **Agent/review files:** `AGENTS.md` is the **single canonical** instruction file — what humans, agents, and **Copilot code review** all read ([since 2026-06-18](https://github.blog/changelog/2026-06-18-copilot-code-review-agents-md-support-and-ui-improvements/)); there is no separate `.github/copilot-instructions.md` (retired portfolio-wide). Keep `AGENTS.md`, the `.claude/` skills/cards, and any path-scoped `.github/instructions/` files from drifting apart (see `product-engineering` §7).
- **Labels:** read the live business-site taxonomy before applying labels; never invent names.

## Task menu (1–3 highest-value; Content Review gated to Mondays; Blog Stewardship low priority)
- **A. CI Doctor:** `gh run list --repo devantler-tech/business-site --status failure --limit 20 ...` (source CI, dependency audit and independent **Publish - Business Site** publication here). Dedupe vs native memory's CI-investigation cache (`caches.md`). `gh run view <id> --log-failed` (untrusted); root-cause (bad MDX/frontmatter, broken imports, `npm ci` lockfile desync, Node/Sharp, dead submodule ref, broken YAML). Failure on an open PR → one root-cause comment (+ draft fix if confident); else record it in native memory (`caches.md`). Prune cache >7d.
- **B. CI/CD health:** source workflows `ci.yaml`, `audit-docs.yaml` and `publish-site.yaml`; this repository owns Pages, `devantler.tech`, main-push publication and scheduled public ranking refresh. Manual preview is artifact-only; publishing requires the enabled source switch and protected main-only environment. The monorepo is aggregation only. Never run `gh aw` / recompile `*.lock.yml`. Let exact Renovate/Dependabot PRs self-progress only while the root contract's live evidence qualifies; when one cannot finish autonomously, diagnose, repair, and merge it as trusted rung-one work (majors included). Safe improvements to dependency automation or workflows (caching, path filters, concurrency, pinned actions) → one issue-driven `ci:` draft PR; validate YAML first.
- **C. Site QA** — rotate one sub-task/run (`site_qa_cursor`: link-check → accessibility → multi-device → …). Run npm from the business-site repository root; start browser previews as captured background sessions and stop that exact session even on failure. **Link-check:** extract URLs from `src/content`, `curl -sL -o /dev/null -w "%{http_code}"`; skip the `unfixable_links` cache; broken → fix (draft `docs: fix broken links`) or cache with reason. **Accessibility:** heading hierarchy, alt text, descriptive link text, ARIA, skip-link, WCAG-AA green (`#39ff14` dark / `#15803d` light). **Multi-device** (use the supported browser tooling; unavailable observation is recorded as unknown): iPhone 12/Pixel 5/iPad/iPad Pro/Desktop × `/`,`/about/`,`/projects/`,`/templates/`,`/blog/` (Home/About/Projects share the one-person business identity; journal and technical pages retain integrated navigation and one synchronized System/Light/Dark control).
- **D. Content Sync** (don't `git submodule update --remote`): public EN/DA descriptions live in `src/data/public-products.json`, the unified Projects page's rendered source. Update the `public-products:` inventory in `src/content/docs/projects/active.mdx` and run `scripts/refresh-public-stars.sh` when the catalogue set changes; that MDX file holds legacy portfolio metadata, not public descriptions. Keep KSail **brief + linked to ksail.devantler.tech — never duplicate its docs**. Shared automation is `.github`; the separate `actions` card is explicitly legacy. Templates retain supporting pages under `src/content/docs/templates/`. Internal deployments do not enter the public catalogue. **Never modify blog posts during Content Sync** — blog changes use task G with their own evidence/editorial review. Validate the drift guard and actual production catalogue → draft `docs: sync project descriptions`.
- **E. Content Review (Mondays only;** rotate unbloat ↔ editorial in `content_review`): **Unbloat** one not-recently-cleaned file (skip frontmatter `disable-agentic-editing: true`), cut duplication/verbosity ≥20% w/o losing accuracy. **Editorial** rotate lens weekly (Technical Rigor → Clarity → Onboarding → Portfolio Balance).
- **F. Repo Assist:** triage/label new issues + PRs; comment on the oldest open item lacking an AI comment (1–3/run); self-spotted fixes → draft PR (use `Fixes #N` when it closes an issue); ≤3 stale-PR/issue nudges.
- **G. Blog Stewardship (low priority; monthly evidence review, worthwhile publish/refresh every 4–8 weeks):**
  complete a topic/evidence audit across portfolio balance, recurring questions/issues, shipped outcomes,
  and stale claims before advancing `last_blog_review`. Inspect privacy-safe aggregate Umami,
  referral, and CTA signals when access exists; advance `last_metrics_review` only after an actual
  aggregate inspection. If access or instrumentation is unavailable, file or update one deduplicated
  issue, record `needs_attention`, and **Do not advance `last_metrics_review`**.
  Before opening a blog experiment, check for any open blog experiment issue and any open
  publish/refresh PR. Maintain that existing lane (CI, review, deployment, or due measurement) and
  **start no new post while either is open**.
  Derive publication due-ness from the later of `last_blog_publish` and `last_blog_refresh`; a review
  alone cannot postpone it. Every substantive publication or refresh uses an issue as its experiment
  record (audience, evidence/baseline/proxy, hypothesis, intended signal, measurement window,
  follow-up date, and resulting decision), plus a delivery child closed by the publication PR. Update
  `last_blog_publish` only after a new-post PR has merged and deployed, and `last_blog_refresh` only
  after a material-refresh PR has merged and deployed; **`last_blog_stewardship` is the later of actual
  publish/refresh dates** and never advances for a draft, open PR, failed deployment, or review-only
  work.
  Choose a worthwhile evidence-backed story, never filler. For shipped work use problem/context → why
  it matters → what Devantler Tech built or learned → verified outcome/trade-offs → clear next step.
  For a current initiative use problem → why now → current status, clearly separate shipped from
  planned work, state unknowns/trade-offs, and give the next step without claiming an outcome. Define
  jargon and portfolio context, avoid internal run diaries and fabricated experience/metrics, and
  balance products over time. Verify frontmatter, title/description/excerpt, tags, cover/alt, commands,
  versions, licenses, claims, examples, links, RSS inclusion, social/OG presentation, a measurable CTA,
  the production build, and a multi-device preview.
