---
name: maintain-templates
description: Maintenance task menu for the devantler-tech project templates — go-template (Go) and dotnet-template (.NET). Keep each a clean, current, buildable scaffold: triage, dependency/toolchain hygiene, CI health, scaffold freshness. Use when the daily maintainer selects templates.
---

# Maintain: Templates (go-template + dotnet-template)

| Product | Repo | path | validate |
|---|---|---|---|
| Go template | `devantler-tech/go-template` | `templates/go-template` | `golangci-lint fmt` (if configured), `go build ./... && go test ./...`, `golangci-lint run` (build to /tmp) |
| .NET template | `devantler-tech/dotnet-template` | `templates/dotnet-template` | `dotnet build` then `dotnet test` (mirror `ci.yaml`/`test.yaml`) |

Both have **Issues enabled**. Shared rules: monorepo [`AGENTS.md`](../../../../AGENTS.md). First read
each repo's `AGENTS.md` + `.github/workflows/*` to confirm its release model (house style:
Conventional-Commit titles, squash-merge, release automation off the title). Memory = the
[`MAINTENANCE.md`](../../../../MAINTENANCE.md) dashboard.

- **Branch** `claude/daily-ai-assistant-<desc>`; **labels** `automation` + an existing area label; workflows → `actionlint`.
- **Bias:** keep the scaffold minimal and idiomatic — don't add product features.

## Task menu (light; ≤1 high-value item per template per run)
1. **Triage & label** new issues/PRs; one insightful comment on the oldest un-commented item.
2. **Dependency/toolchain hygiene:** curate Dependabot/Renovate PRs (Go modules / NuGet / Actions); keep Go / .NET SDK version + pinned action versions current and aligned with the house workflows; flag majors.
3. **CI/workflow health:** keep the template's CI green and tidy (pin/align actions, fix broken/flaky steps, remove dead workflows); red on `main` is top priority.
4. **Scaffold freshness:** the generated project builds & tests on the current toolchain; README/badges accurate; example code idiomatic — clear low-risk improvement → draft PR.
5. **Maintain your own PRs:** fix CI you caused, resolve conflicts.
