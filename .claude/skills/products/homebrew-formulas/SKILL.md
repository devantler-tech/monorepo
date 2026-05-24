---
name: maintain-homebrew-formulas
description: Maintenance task menu for the devantler-tech Homebrew tap (repo devantler-tech/homebrew-tap; submodule path homebrew-formulas). Cask hygiene and CI health only — never chase version/sha bumps (GoReleaser/release automation owns those). Use when the daily maintainer selects homebrew-formulas.
---

# Maintain: Homebrew tap

**Repo** `devantler-tech/homebrew-tap` (the `homebrew-formulas` submodule URL redirects here) ·
**path** `homebrew-formulas` · **Issues** enabled. Shared rules: monorepo
[`AGENTS.md`](../../../../AGENTS.md). The tap ships **Casks**, not Ruby formulas — `Casks/ksail.rb`
(CLI) and `Casks/ksail-desktop.rb` (app), both **GoReleaser-generated and marked `# DO NOT EDIT`**.
First read `README.md`, the casks, and `.github/workflows/ci.yaml` (CI is an aggregate
required-checks job — it does not run `brew style`/`audit`). Memory = the
[`MAINTENANCE.md`](../../../../MAINTENANCE.md) dashboard. Usually nothing to do.

- **Branch** `claude/daily-ai-assistant-<desc>`; **labels** `automation` + an existing area label.
- **Releases bump casks automatically.** A tool release (e.g. ksail) opens its own GoReleaser PR to update a cask's `url`/`version`/`sha256`. **Do NOT hand-edit version/sha to chase a release** — you'd race the automation and risk a wrong sha. The generated casks are `# DO NOT EDIT`. Your job is tap *correctness/hygiene*, not version bumps.
- **Validate:** `brew style ./Casks/<cask>.rb` and `brew audit --strict --online --cask <cask>` if `brew` is available; else `ruby -c Casks/<cask>.rb` + a careful read.

## Task menu (minimal)
1. **Triage & label** new issues/PRs; one insightful comment on the oldest un-commented item (e.g. an install-failure report → investigate the cask).
2. **Tap hygiene** (clear, low-risk only): deprecated Homebrew DSL, broken `homepage`/`url`, bad `desc`/license, lint/style failures, README-table drift, dead casks → draft PR (but never the `# DO NOT EDIT` generated fields). **Not** speculative version bumps.
3. **CI/workflow health:** keep the tap's CI green and tidy.
4. **Maintain your own PRs:** fix CI you caused, resolve conflicts.
