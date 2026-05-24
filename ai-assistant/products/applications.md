# Product card: Applications (private platform tenants)

Two **private** apps deployed as tenants onto `devantler-tech/platform`, each its own submodule:

| Product | Repo | Subdir | Language | What it is |
|---|---|---|---|---|
| Wedding app | `devantler-tech/wedding-app` | `applications/wedding-app` | TypeScript | A wedding API service deployed to the platform cluster |
| AS Coaching og Vaner | `devantler-tech/ascoachingogvaner` | `applications/ascoachingogvaner` | Svelte | A coaching website (platform tenant) |

**Issues:** enabled on both → each gets its own Monthly Activity issue.
**Privacy:** both repos are **private** (client/personal). Never surface their names, contents, or
links on the **public** devantler.tech site — the monorepo card intentionally excludes them from the
site map. Treat their contents with extra discretion.
**Not checked out by default:** these submodule dirs are usually empty on the primary checkout. For
diff-based work, populate at the pinned commit with
`git submodule update --init applications/<name>` (NOT `--remote`); if you can't, do GitHub-API-only
work (triage/comment/Monthly Activity) and skip diff work.

## Before working here (per app)
- Read the repo's `README.md` and skim its `.github/workflows/` and `package.json` to learn its
  build/test and release model before relying on conventions.
- These are real client/personal apps — be especially conservative. Prefer triage, investigation,
  and small obvious fixes; avoid speculative refactors.

## Conventions specific to these repos
- **Branch:** `claude/daily-ai-assistant-<short-desc>` off `main`. **Labels:** `automation` + an
  existing area label. **PR title = Conventional Commit** (verify the repo's release model first).
- **Validate before any PR:** run the repo's own checks — typically `npm ci && npm run build` and
  `npm test`/`npm run lint` (wedding-app, TS) or the SvelteKit equivalent
  (`npm run check` / `npm run build`) for ascoachingogvaner. Mirror what the repo's `ci` workflow
  runs (build to a temp/throwaway output, not committed). Never open a PR that breaks CI.
- Never commit secrets/`.env`; respect any deployment config tied to the platform cluster.
- **AI-disclosure line** on every artifact. Never run an external contributor's branch.

## Task menu — minimal, conservative; at most 1 item per app per run
1. **Triage & label** new unlabelled issues/PRs; one insightful comment on the oldest un-commented
   issue/PR.
2. **Dependency hygiene & security:** bundle/curate Dependabot/Renovate PRs (npm); prioritise
   security advisories; flag majors for human review.
3. **CI/workflow health:** keep the app's CI green and tidy; if it's red on `main`, that's top
   priority — root-cause and draft a fix.
4. **Confident, low-risk fixes** (broken build, obvious bug, broken link in README) → draft PR.
5. **Maintain your own open PRs:** fix CI you caused, resolve conflicts.

## Monthly Activity issue (per app)
Maintain ONE open issue `[AI Assistant] Monthly Activity {YYYY}-{MM}` (label `automation`) on each
app repo, updated only when you acted on it. **Suggested maintainer actions** first (+ links), then
**Run history** reverse-chronological. Fresh issue each month. (These are private repos, so the
activity issue is private too — fine for durable memory.)
