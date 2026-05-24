---
name: maintain-github-actions
description: Maintenance task menu for the shared CI/CD building blocks — devantler-tech/actions (composite actions) and devantler-tech/reusable-workflows. Load-bearing for every other repo's CI, so changes are high-care and backward-compatible. Use when the daily maintainer selects github-actions.
---

# Maintain: GitHub Actions + Reusable Workflows

| Product | Repo | path |
|---|---|---|
| Composite actions | `devantler-tech/actions` | `github/devantler-tech/github-actions/actions` |
| Reusable workflows | `devantler-tech/reusable-workflows` | `github/devantler-tech/github-actions/reusable-workflows` |

Both **Issues enabled**. Shared rules: monorepo [`AGENTS.md`](../../../../AGENTS.md). First read each
repo's `AGENTS.md`/`README.md` + `.github/workflows/`. Memory = the
[`MAINTENANCE.md`](../../../../MAINTENANCE.md) dashboard.

- **Branch** `claude/daily-ai-assistant-<desc>`; **labels** `automation` + an existing area label.
- **Blast radius first:** a change to a composite action / reusable workflow affects **every consumer repo**. Prefer additive, backward-compatible changes; call out any breaking input/output change prominently and treat it as a deliberate decision the maintainer promotes (keep an alias where feasible).
- **Validate:** `actionlint` on every changed workflow/action (else a thorough YAML parse); confirm `uses:` refs resolve and are pinned/aligned; check `inputs`/`outputs`/`shell:` are declared; for `reusable-workflows`, keep `on: workflow_call` inputs/secrets backward-compatible. No app build here — YAML correctness + pinning is the gate.
- **Security:** these repos include workflow-vulnerability scanning — keep actions pinned to full-length SHAs where the house style does, avoid `pull_request_target` foot-guns, never weaken a security control to pass a check.

## Task menu (1–2 items/run across both; high care)
1. **Triage & label** new issues/PRs; one insightful comment on the oldest un-commented item.
2. **Action/version hygiene:** keep third-party actions pinned & aligned across both repos; bundle Dependabot `github_actions` PRs; flag majors.
3. **Workflow health & dedup:** consolidate duplicated steps into composite actions, split overgrown jobs, improve caching, remove dead workflows — backward-compatible, one concern per draft PR, `actionlint`-clean.
4. **Consistency** between the two repos and with how consumer repos call them.
5. **Maintain your own PRs:** fix CI you caused, resolve conflicts.
