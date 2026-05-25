---
name: maintain-templates
description: Maintenance task menu for the devantler-tech project templates — go-template (Go) and dotnet-template (.NET). Keep each a clean, current, buildable scaffold: triage, dependency/toolchain hygiene, CI health, scaffold freshness. Use when the daily maintainer selects templates.
---

# Maintain: Templates (go-template + dotnet-template)

Each template's canonical maintenance task menu lives **in its own repo** — read the **`## Maintenance`**
section of each `AGENTS.md` (on the submodule's latest `main`):
- `templates/go-template/AGENTS.md` — <https://github.com/devantler-tech/go-template/blob/main/AGENTS.md>
- `templates/dotnet-template/AGENTS.md` — <https://github.com/devantler-tech/dotnet-template/blob/main/AGENTS.md>

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a
pointer by design — each menu is maintained once, in the template's own `AGENTS.md`.

## Roadmap & enhancement
Each template's roadmap lives in **GitHub Issues** on its repo (`roadmap` label). **Advance** via
[`product-engineering`](../../product-engineering/SKILL.md), but the bias is to keep the scaffold
**minimal, idiomatic, and current** — advance = better defaults, toolchain currency, exemplary
tests/CI, and keeping the two templates aligned where it makes sense; **don't add product features**.
