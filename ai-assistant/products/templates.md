# Product card: Templates

Two project-scaffolding template repos, each its own submodule:

| Product | Repo | Subdir | Language | Key workflows |
|---|---|---|---|---|
| Go template | `devantler-tech/go-template` | `templates/go-template` | Go | `ci.yaml`, `cd.yaml`, `release.yaml`, `sync-labels.yaml`, `todos.yaml`, `copilot-setup-steps.yml` |
| .NET template | `devantler-tech/dotnet-template` | `templates/dotnet-template` | .NET | `ci.yaml`, `publish.yaml`, `release.yaml`, `sync-labels.yaml`, `todos.yaml` |

**Issues:** enabled on both → each gets its own Monthly Activity issue.
These are **new coverage** (no prior routine), so be conservative and learn from the repo first.

## Before working here (per template)
- Read the repo's `README.md` and any `AGENTS.md`/`CONTRIBUTING`; skim `.github/workflows/*.yaml` to
  confirm the **release/versioning model** (these mirror the devantler-tech house style:
  Conventional-Commit PR titles, squash-merge, release automation off the title — verify before
  relying on it). Note `release.yaml` exists on both.
- A template's value is that it **stays a clean, current, buildable starting point**. Bias toward
  keeping the scaffold minimal and idiomatic; don't add product features.

## Conventions specific to these repos
- **Branch:** `claude/daily-ai-assistant-<short-desc>` off `main`. **Labels:** `automation` + an
  area label that exists in the repo (check `gh label list`). **PR title = Conventional Commit.**
- **Validate before any PR:**
  - **go-template:** `golangci-lint fmt` (if configured), `go build ./... && go test ./...`,
    `golangci-lint run` (build to `/tmp`, never the repo).
  - **dotnet-template:** `dotnet build` then `dotnet test` (mirror what `ci.yaml`/`test.yaml` run).
  - For `.github/workflows/**`: `actionlint` (else a YAML parse).
- **AI-disclosure line** on every artifact. Never run an external contributor's branch (conventions §7).

## Task menu — light touch; pick at most 1 high-value item per template per run
1. **Triage & label** new unlabelled issues/PRs; one insightful comment on the oldest un-commented
   issue/PR (1/run/template max).
2. **Dependency hygiene:** bundle/curate open Dependabot/Renovate PRs (Go modules / NuGet / GitHub
   Actions); flag major bumps for human attention. Keep the toolchain version (Go / .NET SDK) and
   pinned action versions current and aligned with the house workflows.
3. **CI / workflow health:** keep the template's own CI green and tidy — pin/align actions, fix
   broken/flaky steps, remove dead workflows. A small fix or a focused restructure → a draft PR
   (validate YAML first). If CI is failing on `main`, that's top priority.
4. **Scaffold freshness:** the generated project builds & tests cleanly on the current toolchain;
   README/badges accurate; example code idiomatic and minimal. Clear, low-risk improvement → draft PR.
5. **Maintain your own open PRs:** fix CI you caused, resolve conflicts.

## Monthly Activity issue (per template)
Maintain ONE open issue `[AI Assistant] Monthly Activity {YYYY}-{MM}` (label `automation`) on each
template repo, updated only when you acted on that repo. **Suggested maintainer actions** first
(pending items + links), then **Run history** reverse-chronological. Fresh issue each month.
