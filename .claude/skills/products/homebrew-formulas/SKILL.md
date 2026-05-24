---
name: maintain-homebrew-formulas
description: Maintenance task menu for devantler-tech/homebrew-formulas (the Homebrew tap, Ruby formulas e.g. ksail). Formula hygiene and CI health only — never chase version/sha bumps (release automation owns those). Use when the daily maintainer selects homebrew-formulas.
---

# Maintain: Homebrew Formulas

**Repo** `devantler-tech/homebrew-formulas` · **path** `homebrew-formulas` · **Issues** enabled.
Shared rules: monorepo [`AGENTS.md`](../../../../AGENTS.md). First read `README.md`, the formulas, and
`.github/workflows/ci.yaml` to see how formulas are validated. Memory = the
[`MAINTENANCE.md`](../../../../MAINTENANCE.md) dashboard. Usually nothing to do.

- **Branch** `claude/daily-ai-assistant-<desc>`; **labels** `automation` + an existing area label.
- **Releases bump formulas automatically.** A tool release (e.g. ksail) opens its own PR to update a formula's `url`/`version`/`sha256`. **Do NOT hand-edit version/sha to chase a release** — you'd race the automation and risk a wrong sha. Your job is formula *correctness/hygiene*, not version bumps.
- **Validate:** `brew style ./<formula>.rb` and `brew audit --strict --online <formula>` if `brew` is available; else `ruby -c <formula>.rb` + a careful read. Match what `ci.yaml` runs.

## Task menu (minimal)
1. **Triage & label** new issues/PRs; one insightful comment on the oldest un-commented item (e.g. an install-failure report → investigate the formula).
2. **Formula hygiene** (clear, low-risk only): deprecated Homebrew DSL, broken `homepage`/`url`, bad `desc`/license, lint/style failures, dead formulas, README-table drift → draft PR. **Not** speculative version bumps.
3. **CI/workflow health:** keep the tap's CI green and tidy.
4. **Maintain your own PRs:** fix CI you caused, resolve conflicts.
