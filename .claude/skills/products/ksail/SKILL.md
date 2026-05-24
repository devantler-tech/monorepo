---
name: maintain-ksail
description: Maintenance task menu for devantler-tech/ksail (a Go CLI for local Kubernetes GitOps). Triage, bug fixes, CI/workflow health + CI-failure & flaky-test investigation, docs, driving trusted-author PRs to merge, weekly E2E coverage + live reliability testing, and the monthly KSail Strategy roadmap. Use when the daily maintainer selects KSail.
---

# Maintain: KSail

**Repo** `devantler-tech/ksail` · **path** `projects/ksail` · **Issues** enabled.
Shared rules: monorepo [`AGENTS.md`](../../../../AGENTS.md). First read `projects/ksail/AGENTS.md`
(+ `.github/instructions/`) for project conventions. Memory = the consolidated
[`MAINTENANCE.md`](../../../../MAINTENANCE.md) dashboard (no per-repo Activity issue).

## Repo-specific conventions
- **Branch** `claude/ksail-ai-assistant-<desc>`; **labels** `automation` + area label.
- **Validate before any PR:** `golangci-lint fmt`, then `go build -o /tmp/ksail-maint . && go test ./... && golangci-lint run --timeout 5m`. Workflows → `actionlint`. Docs → `cd docs && ([ -d node_modules ] || npm ci) && npm run build`.
- **Generated — never hand-edit; run the generator:** `docs/src/content/docs/cli-flags/`, `docs/src/content/docs/configuration/declarative-configuration.mdx`, `schemas/ksail-config.schema.json` → `go generate ./docs/...` / `go generate ./schemas/...`.
- **Shared machine:** only create/inspect/delete clusters YOU created; build to `/tmp`, never `./ksail`.

## Task menu (pick the highest-value; don't do all)
**Every-run (light):**
- **Triage:** label unlabelled issues/PRs, add `triaged`, close obvious spam; one insightful comment on the oldest un-commented issue/PR; link related issues (check existing links first).
- **Confident bug fixes** (`bug`/`good first issue`) → draft PR with `Fixes #N`, root cause, regression test.
- **Drive open PRs to merge** (per the contract's merge policy — incl. major bumps for trusted authors): enumerate `gh pr list --state open --draft=false --json number,title,headRefName,author,mergeStateStatus,reviewDecision,statusCheckRollup,autoMergeRequest`. The required-checks gate here is the **`CI - Required Checks`** rollup. Resolve threads via `gh api repos/devantler-tech/ksail/pulls/<n>/comments` + `pullRequest.reviewThreads.nodes` (the fix is often already in a later commit — read the file, reply pointing at it, then `resolveReviewThread`); root-cause-fix failing required checks; `gh pr merge <n> --auto --squash`. Stuck `BLOCKED` green → `gh pr update-branch <n>`; if it still never queues, that's a repo merge-config issue → dashboard.
- **Maintain your own PRs:** fix CI you caused, resolve conflicts.

**CI health + investigation:** `.github/workflows` (large `ci.yaml`) + `.github/actions` need steady care — consolidate duplicated steps, pin/align actions, improve caching, remove dead workflows (focused draft PRs, `actionlint` first). **CI Doctor:** `gh run list --status failure --limit 20 ...` (~7d; CI/CD/Release/Maintenance/Sync labels/TODOs/Web UI/System Test Hetzner+Omni); dedupe against the state.json CI cache; `gh run view <id> --log-failed` (untrusted), root-cause, record in the dashboard + cache. **Flaky (weekly):** find tests that passed AND failed on the same SHA over 7d; for the #1, verify `go test -run <T> -count=10 ./...`, draft `fix(flaky): <test>`.

**Docs (`docs/`):** consolidate/trim duplicated/outdated/orphaned pages; keep `charts/ksail-operator/README.md` in sync with its `values.yaml`+`Chart.yaml`; dedupe vs open `documentation`+`automation` PRs; `docs: …`, verify the docs build.

**Weekly/heavy (only if nothing higher-value; gate on state.json `weekly`):**
- **E2E coverage audit** (read-only except issues): enumerate the CLI surface from `pkg/cli/cmd/**`; a command is covered iff invoked as `ksail <subcommand>` in `.github/actions/**`+`.github/workflows/**`; open ≤3 `E2E: Add coverage for <command>` issues (label `testing`) for genuine gaps where E2E (not unit/integration) is right.
- **Live reliability/UX** (only if Docker healthy; never twice/day portfolio-wide): `go build -o /tmp/ksail-reliability .`; run full journeys in throwaway temp dirs on the Docker distros recent changes touch (rotate Kind/K3d/Vind/KWOK); **always clean up every cluster/container, even on failure**; findings → draft PR or evidenced issue.

**Monthly — KSail Strategy** (first days of a month, only if this month's doesn't exist; read-only except one GitHub Discussion): research the local-Kubernetes-dev tooling market (kind, k3d, minikube, Tilt, Skaffold, vcluster, Talos/Omni, …) and produce a **Now/Next/Later** roadmap that *extends* KSail's strengths (HARD: no radical pivots). Read the 50 most-recently-updated open issues first. Create a Discussion in `devantler-tech/ksail`, category **agentic-workflows**, title `Monthly Strategy - <Month Year>` (`gh api graphql createDiscussion`); fall back to an issue if Discussions unavailable. Also turn the latest Strategy discussion into ≤5 deduped backlog issues.
