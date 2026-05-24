# Product card: GitHub Actions + Reusable Workflows

The shared CI/CD building blocks used across **all** devantler-tech repos — so changes here ripple
everywhere. Two submodules:

| Product | Repo | Subdir | What it holds |
|---|---|---|---|
| Composite actions | `devantler-tech/actions` | `github/devantler-tech/github-actions/actions` | Composite actions for CI/CD pipelines |
| Reusable workflows | `devantler-tech/reusable-workflows` | `github/devantler-tech/github-actions/reusable-workflows` | `workflow_call` reusable workflows (e.g. `create-release`, `validate-go-project`, `run-dotnet-tests`, `enable-auto-merge`, `deploy-github-pages`, `publish-dotnet-library`, `sync-cluster-policies`, …) |

**Issues:** enabled on both → each gets its own Monthly Activity issue. **New coverage** — be
conservative; these are load-bearing for every other product's CI.

## Before working here
- Read each repo's `README.md` (they cross-reference each other) and skim its `.github/workflows/`
  (`ci.yaml`; `actions` has `active-release.yaml`/`active-sync-github-labels.yaml`;
  `reusable-workflows` has `create-release.yaml`, `scan-for-workflow-vulnerabilities.yaml`, etc.).
- **Blast radius first.** A change to a composite action or reusable workflow affects every consumer
  repo. Prefer additive, backward-compatible changes; call out any breaking input/output change
  prominently in the PR body and treat it as a deliberate decision the maintainer promotes.

## Conventions specific to these repos
- **Branch:** `claude/daily-ai-assistant-<short-desc>` off `main`. **Labels:** `automation` + an
  area label present in the repo. **PR title = Conventional Commit** (these repos release off it —
  note `active-release.yaml` / `create-release.yaml`).
- **Validate before any PR:** `actionlint` on every changed workflow/action (else a thorough YAML
  parse); confirm `uses:` refs resolve and are pinned/aligned; check inputs/outputs and `shell:` are
  declared. For `reusable-workflows`, verify `on: workflow_call` inputs/secrets stay
  backward-compatible. There's no app build/test here — YAML correctness + pinning is the gate.
- **Security:** these repos include workflow-vulnerability scanning for a reason — keep actions
  pinned to full-length commit SHAs where the house style does, avoid `pull_request_target` foot-guns,
  and never weaken a security control to make a check pass.
- **AI-disclosure line** on every artifact. Never run an external contributor's branch.

## Task menu — light touch, high care; at most 1–2 items per run across both repos
1. **Triage & label** new unlabelled issues/PRs; one insightful comment on the oldest un-commented
   issue/PR.
2. **Action/version hygiene:** keep referenced third-party actions pinned and aligned to current
   versions across both repos; bundle Dependabot `github_actions` PRs; flag majors for human review.
3. **Workflow health & dedup:** consolidate duplicated steps into composite actions, split overgrown
   jobs, improve caching, remove dead workflows — backward-compatible, one concern per draft PR,
   `actionlint`-clean.
4. **Consistency between the two repos** and with how consumer repos call them (e.g. an input renamed
   in `reusable-workflows` must keep an alias or be flagged breaking).
5. **Maintain your own open PRs:** fix CI you caused, resolve conflicts.

## Monthly Activity issue (per repo)
Maintain ONE open issue `[AI Assistant] Monthly Activity {YYYY}-{MM}` (label `automation`) on each
repo, updated only when you acted on it. **Suggested maintainer actions** first (pending items +
links), then **Run history** reverse-chronological. Fresh issue each month.
