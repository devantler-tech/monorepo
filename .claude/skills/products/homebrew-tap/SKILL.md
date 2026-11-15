---
name: maintain-homebrew-tap
description: Maintenance task menu for the devantler-tech Homebrew tap (repo devantler-tech/homebrew-tap; submodule path homebrew-tap). Cask hygiene and CI health only — never chase version/sha bumps (the tap's own bump-casks workflow owns those). Use when the daily maintainer selects homebrew-tap.
---

# Maintain: Homebrew tap

- **Serves:** Homebrew users installing released devantler-tech tools (ksail, ksail-desktop, world-at-ruin) · **Outcome:** a working install of the released binaries and apps ([README](https://github.com/devantler-tech/homebrew-tap#readme))
- **Constraints:** Cask versions and checksums are written only by the tap's own `bump-casks` workflow (below)
- **Non-goals:** source-built formulas; adding the tap creates no cluster and deploys no game (README)
- **Evidence:** UNKNOWN

The canonical maintenance task menu lives **in the repo itself** — read the **`## Maintenance`**
section of `homebrew-tap/AGENTS.md` (the submodule path; repo `devantler-tech/homebrew-tap`, on
its latest `main`): <https://github.com/devantler-tech/homebrew-tap/blob/main/AGENTS.md>. The tap
ships **Casks** (`Casks/*.rb`) — never chase version/sha bumps.

**The tap bumps its own Casks** (homebrew-tap#2568). Every hour `bump-casks.yaml` runs
`brew livecheck`, and for each Cask behind its latest GitHub release it opens a
`chore(cask): update <cask> to v<version>` PR from `bump-<cask>-<version>` and arms its auto-merge.
That release is published by construction, so there is no draft to promote. A bump PR qualifies for
the no-review carve-out only when `.claude/scripts/programmed-bot-review-exemption.sh` exits 0; the
rules for a stalled one are in the [merge-policy guide](../../../guides/merge-policy.md).

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a
pointer by design — the menu is maintained once, in the tap's own `AGENTS.md`.

## Roadmap & enhancement
The tap's roadmap lives in **GitHub Issues** on `devantler-tech/homebrew-tap` (`roadmap` label).
**Advance** via [`product-engineering`](../../product-engineering/SKILL.md) is deliberately limited
here — Casks are bumped by the tap's own workflow, so enhancement = CI / tap hygiene only, never
version/sha bumps by hand.
