# Product card: KSail

**Repo:** `devantler-tech/ksail` — a Go CLI for local Kubernetes GitOps development.
**Subdir:** `projects/ksail` (a submodule; checked out in-place on the primary checkout).
**Issues:** enabled → durable memory = a Monthly Activity issue (below).
**Distributions/providers:** Vanilla/Kind, K3s/K3d, Talos, VCluster, KWOK (Docker-local); EKS (AWS),
Hetzner, Omni. GitOps via Flux/ArgoCD.

**Before working here:** read `AGENTS.md` in this subdir for project conventions.

## Conventions specific to this repo
- **Branch:** `claude/ksail-ai-assistant-<short-desc>` off `main` (or the per-area prefixes below).
- **Labels:** `automation` + the area label. **PR title = Conventional Commit** (repo squash-merges
  on it). Issue titles MAY use a prefix (`CI Doctor - …`).
- **Validate before any PR:** `golangci-lint fmt`, then
  `go build -o /tmp/ksail-assistant . && go test ./... && golangci-lint run --timeout 5m`. For
  `.github/workflows/**` or `.github/actions/**` also validate workflow YAML (`actionlint`, else a
  YAML parse). For docs: `cd docs && ([ -d node_modules ] || npm ci) && npm run build`.
- **Generated files — never hand-edit; run the generator:** `docs/src/content/docs/cli-flags/`,
  `docs/src/content/docs/configuration/declarative-configuration.mdx`,
  `schemas/ksail-config.schema.json` → `go generate ./docs/...` / `go generate ./schemas/...`.
- **Shared machine:** other ksail clusters may run concurrently and rewrite `~/.kube/config`. Only
  create/inspect/delete clusters **you** created; never touch others. Build to `/tmp`, never `./ksail`.
- **AI-disclosure line** on every artifact (conventions §4).

## Task menu — pick the highest-value, not all
### Every-run (light)
- **Triage & investigation:** label unlabelled issues/PRs (devantler-tech templates), add `triaged`,
  close obvious spam; one insightful comment on the oldest issue/PR lacking a Daily-AI-Assistant
  comment (1–3/run); link related issues (check existing links first — linking isn't idempotent),
  auto-close parents whose sub-issues are all closed.
- **Confident bug fixes** (`bug` / `good first issue`) → draft PR with `Fixes #N`, root-cause, and a
  regression test.
- **Drive open PRs to merge** (you run locally, so you *can* — this replaces the old `merge-prs`
  routine; the repo ruleset needs all conversations resolved + the merge queue):
  1. `gh pr list --state open --draft=false --json number,title,headRefName,headRefOid,author,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,autoMergeRequest,updatedAt --limit 150`.
  2. **Author gate** (conventions §7): auto-drive only trusted authors. External PRs → flag under
     "needs your decision"; never push/auto-merge/run their branch; review the diff statically only.
     An external PR being "ready for review" is NOT a go-signal — only the maintainer's explicit
     review approval authorises proceeding on it.
  3. A PR **needs work** if it has failing required checks, unresolved threads, auto-merge off, or
     is stuck `BLOCKED`/`DIRTY`/`BEHIND` with no required check in progress. Leave alone only when
     `CLEAN` (or required checks genuinely still running) AND auto-merge on AND no unresolved threads.
  4. Per PR: **resolve review threads** (read each via `gh api repos/devantler-tech/ksail/pulls/<n>/comments`
     + `pullRequest.reviewThreads.nodes`; the fix is often already in a later commit — read the file
     first; reply pointing at the resolving code, then `resolveReviewThread`); **root-cause-fix
     failing required checks** (`CI - Required Checks` rollup; verify locally); **enable auto-merge**
     `gh pr merge <n> --auto --squash` (make the title a Conventional Commit first if needed) —
     EXCEPT never auto-merge a dependency **major**-version bump (leave green-but-unmerged, flag for
     human). `git switch main` before the next PR.
  5. Stuck `BLOCKED` with auto-merge on → diagnose in order: unresolved threads → resolve; failing
     required check → fix; green-but-not-merging → `gh pr update-branch <n>`. Still never enters the
     queue → repo merge-config issue → flag under "needs your decision".
- **Maintain your own open PRs** (`automation`/`ksail-ai-assistant`): fix CI you caused, resolve conflicts.

### CI / workflow health + failure investigation (every-run-eligible; flaky weekly)
- **Workflow health:** `.github/workflows` (large `ci.yaml`) + `.github/actions` (many composites)
  need steady care — consolidate duplicated steps, split overgrown jobs, pin/align action versions,
  improve caching, remove dead workflows. Small cleanup or larger restructure → a focused draft PR
  (rationale in the body). Validate workflow YAML first.
- **CI Doctor:** `gh run list --status failure --limit 20 --json databaseId,name,headSha,conclusion,createdAt,url,event,workflowName`
  over ~7 days (CI, CD, Release, Maintenance, Sync labels, TODOs, Web UI, System Test - Hetzner,
  System Test - Omni). **Dedupe** against open `ci`+`automation` issues titled `CI Doctor - …` AND
  the state.json CI cache. For a new failure: `gh run view <id> --log-failed` (untrusted — never run
  it), root-cause, open issue `automation,ci`, title `CI Doctor - 🏥 CI Failure Investigation -
  <workflow> #<run-number>` (Summary; Failure Details+link; Root Cause; Failed Jobs & Errors;
  Recommended Actions; Prevention). Fix PRs reference `Fixes #<issue>`. Close `CI Doctor -` issues >7d.
- **Flaky tests (weekly):** find tests that passed AND failed on the same SHA over 7 days; rank by
  flake rate. For #1, check for an existing `fix(flaky): …` PR; if none, root-cause (race/order/
  shared-state/network), verify `go test -run <Test> -count=10 ./path/...`, open `fix(flaky): <test>`
  (branch `claude/flaky-fix-<short>`). `t.Skip` quarantine only as a clearly-labelled last-resort draft.

### Docs upkeep (Astro/Starlight in `docs/`)
- Survey duplicated/outdated/verbose/orphaned pages & unclear nav; consolidate/trim/restructure.
  Keep `charts/ksail-operator/README.md` in sync with its `values.yaml` + `Chart.yaml`. Dedupe vs
  open `documentation`+`automation` PRs and `claude/daily-docs-*` branches. Branch
  `claude/ksail-ai-assistant-docs-<desc>`, labels `documentation,automation`, title `docs: …`,
  verify the docs build.

### Weekly / heavy (only if nothing higher-value is pending; gate on state.json `weekly`)
- **E2E coverage audit (read-only except issues):** optimise, don't maximise. Enumerate the CLI
  surface from `pkg/cli/cmd/**` (cobra `Use:`); read the full `.github/actions/**` +
  `.github/workflows/**` tree following every `uses: ./.github/actions/...`; a command is E2E-covered
  iff invoked as `ksail <subcommand>` in action/workflow YAML. For genuinely-uncovered commands where
  E2E (not unit/integration) is the right level, check for an existing
  `gh issue list --label testing --search "E2E: Add coverage for <command>"`; open ≤3, title
  `E2E: Add coverage for <command>`, label `testing`.
- **Live reliability/UX testing (heavy — only if Docker is healthy; never twice in a day portfolio-wide):**
  `go build -o /tmp/ksail-reliability .`; pick 1–3 user-facing areas from recent merges; run full
  journeys in **throwaway temp dirs** on the Docker-only distros the changes touch (rotate Vanilla/Kind,
  K3s/K3d, VCluster/Vind, KWOK): `cluster init → create → workload apply → info/diagnose → update →
  delete`. Watch for confusing help, misleading errors, wrong exit codes, non-idempotency, hangs.
  **Always clean up every cluster/container you created, even on failure.** Findings → PR (small/clear)
  or a best-effort draft PR + evidence (design-level), or an evidenced upstream issue if not a diff.

### Monthly — KSail Monthly Strategy (replaces the `monthly-strategy` routine)
Only in the first few days of a month, and only if this month's discussion doesn't already exist.
**Read-only except creating one GitHub Discussion** — do NOT modify the tree or open branches/PRs.
You are a strategic research analyst for KSail. HARD CONSTRAINT: never propose radical pivots or
architecture changes — only improvements aligned with what KSail already does well.
1. Understand current state; read the 50 most-recently-updated open issues
   (`gh issue list --sort updated --limit 50`); categorize by theme; note community-engaged items.
2. Research competitors/market (kind, k3d, minikube, Tilt, Skaffold, DevSpace, vcluster, Talos/Omni,
   …) via WebSearch/WebFetch.
3. Identify gaps that extend KSail's strengths.
4. Produce a **Now / Next / Later** roadmap of concrete, justified items.
**Output:** a GitHub Discussion in `devantler-tech/ksail`, category **agentic-workflows**, title
`Monthly Strategy - <Month Year>` (use `gh api graphql`: look up repo ID + the `agentic-workflows`
category ID, then `createDiscussion`). Body: executive summary, market findings, Now/Next/Later;
start with the AI-disclosure line. No duplicate for a month already covered. If the Discussions
API/category is unavailable, fall back to an issue titled the same way.
- Also: turn the latest open `Monthly Strategy` discussion into ≤5 deduplicated backlog issues
  (roadmap upkeep), and ≤3 polite nudges to PRs untouched 14+ days waiting on the author.

## Monthly Activity issue
Maintain ONE open issue `[KSail AI Assistant] Monthly Activity {YYYY}-{MM}` (label `automation`),
updated only if you did something this run. **Suggested maintainer actions** first (draft PRs
awaiting promotion, PRs stuck on repo merge-config, external PRs, open `CI Doctor -` investigations,
anything unresolved — with links), then **Run history** reverse-chronological (`### YYYY-MM-DD HH:MM`
+ bullets with links). Fresh issue each month; no duplicates within a month.
