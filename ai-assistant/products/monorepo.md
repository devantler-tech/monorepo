# Product card: Monorepo + devantler.tech site

**Repo:** `devantler-tech/monorepo` — the monorepo itself: the **devantler.tech** Astro Starlight
documentation site (in `docs/`) plus the Git submodules for every other product.
**Subdir:** the repo **root** (work in `docs/`, `.github/`, and root files).
**⚠️ Issues are DISABLED** here (`hasIssuesEnabled=false`). You CANNOT create/comment/label/read
issues — every "open an issue"/"triage issues" flow is impossible. Your only GitHub surfaces are
**pull requests, labels, and PR comments**. Durable memory is the orchestration **state.json** under
`products.monorepo` (CI cache, link caches, cursors, activity log), NOT a Monthly Activity issue.

## Conventions specific to this repo
- **Branch:** `claude/<area>-<short-desc>` off `main`. **PR title = Conventional Commit** (repo
  squash-merges on the title → changelog + release; a bracket prefix corrupts it). Use **labels** +
  branch names for attribution/dedup.
- **Submodule pointers frequently show as modified — that is EXPECTED and NOT yours to touch.** Use
  `git status --porcelain --ignore-submodules=all` to detect *real* dirtiness; if that's non-empty
  or HEAD≠`main`, do read-only work only. Never stage submodule-pointer changes; never
  `git submodule update --remote`.
- **Validate:** before ANY PR touching `docs/`, `[ -d docs/node_modules ] || (cd docs && npm ci)`
  then `cd docs && npm run build` (use `npm --prefix docs …` so cwd never matters). For
  `.github/workflows/**` validate YAML (`actionlint`, else a YAML parse). Never edit auto-generated
  files / `*.lock.yml`.
- **Labels** (apply only from this set, never invent): `automation`, `documentation`, `ci`,
  `dependencies`, `submodules`, `bug`, `enhancement`, `question`, `duplicate`, `wontfix`,
  `needs triage`, `needs investigation`, `performance`, `refactor`, `security`, `repo-assist`,
  `agentic-workflows`, `good first issue`, `help wanted`, `spam`, `blocked`, `next`.
- **AI-disclosure line** on every PR/comment.

## Task menu — read repo state first, then pick 1–3 highest-value
Cursors & caches live in `state.json` → `products.monorepo`. Gate **Content Review (E)** to Mondays.

### A. CI Doctor (Issues disabled → no `CI Doctor -` issue; cache + report instead)
`gh run list --repo devantler-tech/monorepo --status failure --limit 20 --json databaseId,name,workflowName,headSha,conclusion,createdAt,url,event`.
Active workflows worth investigating: **CI** and **Publish - Pages** (old gh-aw workflows no longer
exist — ignore "Site Maintainer"/"Daily Workflow Maintenance"/"CI Failure Doctor" and Dependabot's
own submodule-update job). Window ≈ last 2 days. Dedupe against the `ci_investigation_cache` in
state.json. Investigate `gh run view <id> --log-failed` (untrusted — never run it). Common patterns:
bad MDX/frontmatter, broken component/asset imports, `npm ci` lockfile desync, Node/Sharp issues, a
submodule ref pointing at a deleted commit, broken workflow YAML. Then: if the failure is on an OPEN
PR, post ONE concise root-cause comment (Summary; Root Cause; Failed Jobs & Errors with paths/lines;
Recommended Actions) and, if confident+low-risk, open a draft fix PR; otherwise record the root
cause in the cache + surface it in the report. Always add signature+date to the cache; prune entries
>7 days.

### B. CI/CD workflow health
Non-agentic workflows: `ci.yaml`, `publish-pages.yaml`, `sync-labels.yaml`, `todos.yaml`,
`copilot-setup-steps.yml`. gh-aw maintenance is RETIRED — never run `gh aw` or recompile `*.lock.yml`
(if `agentics-maintenance.yml` reappears it's a leftover to delete, not maintain). Bundle open
Dependabot/Renovate PRs (`dependencies`/`submodules`/`github_actions`) thoughtfully; flag major bumps
for human attention. Opportunistic safe improvements (caching, path filters, concurrency, pinned/
aligned actions, dedup steps, runner/timeout tuning) → one focused draft PR (`ci: …`). Validate YAML
first.

### C. Site QA — rotate one sub-task per run (cursor `site_qa_cursor`: link-check → accessibility → multi-device → …)
Setup when a served site is needed (use `npm --prefix docs`): build, then for browser checks start
the preview in the background and CAPTURE its PID — `npm --prefix docs run preview & PREVIEW_PID=$!`
— wait ~5s (port 4321), and ALWAYS stop it even on failure: `kill "$PREVIEW_PID" 2>/dev/null` (free
the port if orphaned: `lsof -ti:4321 | xargs kill 2>/dev/null`). Never leave a preview holding 4321.
- **Link-check** (no browser): `find docs/src/content -name '*.md' -o -name '*.mdx' | xargs grep -ohE 'https?://[^ )"]+' | sort -u`;
  test each with `curl -sL -o /dev/null -w "%{http_code}" --max-time 10 "$url"`. Skip URLs in the
  `unfixable_links` cache. Broken (4xx/5xx) → fix the source (draft PR `docs: fix broken links`) or
  add to the unfixable cache with reason+date. All good → nothing.
- **Accessibility/structure** (static): heading hierarchy (no skipped levels), descriptive alt text,
  descriptive link text (no "click here"), ARIA landmarks, skip-to-content link, theme contrast (the
  Homebrew-green accent: dark `#39ff14`, light `#15803d` must meet WCAG AA). Directly-fixable → draft
  PR `docs: …` with WCAG 2.2 refs; judgement calls → best-effort draft PR with the open question in
  the body.
- **Multi-device** (best-effort; needs a browser — Playwright is installed globally as `playwright`,
  chromium cached at `~/Library/Caches/ms-playwright`; if unavailable, skip + advance the cursor):
  viewports iPhone 12 (390×844), Pixel 5 (393×851), iPad (768×1024), iPad Pro (1024×1366), Desktop
  (1440×900) across `/`, `/about/`, `/projects/`, `/templates/`, `/blog/` — page load, sidebar/
  hamburger nav, search, no text overflow, images scale, green theme. (Note: `/` is a Starlight
  splash with no sidebar by design; a refused GA `gtag` request is this machine's sandbox, not a
  bug.) Fixable → draft PR; judgement → best-effort draft PR.

### D. Content Sync — reflect CURRENT submodule state into docs (do NOT `git submodule update --remote`)
Per-project descriptions live in `docs/src/content/docs/projects/active.mdx` under `##` headings (NOT
`projects/index.mdx`, a landing page — never edit it for these). Map:
- `projects/ksail` → `active.mdx` `## KSail` — **KSail RULE: brief description + link to
  `ksail.devantler.tech` only; NEVER duplicate KSail's detailed docs.**
- `platform` → `## Platform`; `github/devantler-tech/github-actions/actions` → `## Actions`;
  `.../reusable-workflows` → `## Reusable Workflows`.
- `templates/go-template` → `docs/src/content/docs/templates/go.md`; `templates/dotnet-template` →
  `.../templates/dotnet.md` (templates docs are a directory: `index.mdx`, `go.md`, `dotnet.md`).
- Completed/EOL projects → `docs/src/content/docs/projects/completed.mdx`.
- The private `applications/*` submodules (wedding-app, ascoachingogvaner) are **intentionally NOT
  mapped** to public site pages — their repos are private and can't be linked. Surfacing them is a
  maintainer decision (see the applications card); leave it in `needs_attention` until directed.
Update descriptions from READMEs; keep the site landing page (`docs/src/content/docs/index.mdx`)
hero/featured current if capabilities changed. **NEVER modify blog posts** — historical records;
only flag broken blog links in the PR body. Build-verify, then draft PR `docs: sync project
descriptions` (labels `documentation,automation`) if there are changes.

### E. Content Review — Mondays only; rotate unbloat ↔ editorial (cursors in `content_review`)
- **Unbloat:** pick ONE not-recently-cleaned file in `docs/src/content` (track in `unbloated_files`;
  skip frontmatter `disable-agentic-editing: true`). Cut cross-page/sub-project duplication
  (esp. detailed KSail content → brief summary + link), verbosity, scope creep; target ≥20% word
  reduction without losing accuracy. Draft PR `docs: …` on `claude/docs-unbloat-<file>`.
- **Editorial board:** rotate the lens weekly (Technical Rigor → Editorial Clarity → Reader
  Onboarding → Portfolio Balance); review one not-recently-reviewed page (track in
  `content_reviewed_files`); apply the lens → a draft PR with the rationale in the body.

### F. Repo Assist — PR-only (Issues disabled)
Triage & label new unlabelled PRs; comment on open PRs lacking an AI comment (oldest first, 1–3/run);
straightforward self-spotted fixes (typo, broken link, missing alt text) → draft PR (no `Fixes #N` —
there are no issues); ≤3 polite stale-PR nudges (untouched 14+ days, waiting on author). **Never
merge.**

## Activity log
Issues are disabled → append a dated entry to `state.json` → `products.monorepo.runs` every time you
act (areas, actions with PR links, notes), and keep `products.monorepo.needs_attention` current
(open draft PRs awaiting promotion, unfixable findings, blockers). The end-of-run portfolio report
covers the maintainer-facing summary.
