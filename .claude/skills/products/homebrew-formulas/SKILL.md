---
name: maintain-homebrew-formulas
description: Maintenance task menu for the devantler-tech Homebrew tap (repo devantler-tech/homebrew-tap; submodule path homebrew-formulas). Cask hygiene and CI health only — never chase version/sha bumps (GoReleaser/release automation owns those). Use when the daily maintainer selects homebrew-formulas.
---

# Maintain: Homebrew tap

The canonical maintenance task menu lives **in the repo itself** — read the **`## Maintenance`**
section of `homebrew-formulas/AGENTS.md` (the submodule path; repo `devantler-tech/homebrew-tap`, on
its latest `main`): <https://github.com/devantler-tech/homebrew-tap/blob/main/AGENTS.md>. The tap
ships **Casks** (`Casks/*.rb`, GoReleaser-generated `# DO NOT EDIT`) — never chase version/sha bumps.

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a
pointer by design — the menu is maintained once, in the tap's own `AGENTS.md`.
