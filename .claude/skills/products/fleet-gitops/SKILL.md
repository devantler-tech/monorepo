---
name: maintain-fleet-gitops
description: Product card for devantler-tech/fleet-gitops, the FleetDM GitOps configuration for devantler-tech device management. Use when the Agentic Engineer selects fleet-gitops.
---

# Maintain: FleetDM device config

`applications/fleet-gitops` is the tracked submodule of `devantler-tech/fleet-gitops`, which holds
the FleetDM configuration for the suite's managed devices as GitOps-managed files.

**The repository is PRIVATE and carries no `AGENTS.md` yet.** Two consequences bind every run:

- **Nothing from it reaches a public surface.** Its issues are never boarded on project 5 (an item
  from a private repo on the public board is a maintainer decision, never an agent default), and no
  file content, CI detail, or device inventory read from it enters a public issue, PR body, comment,
  or report — the sanitised-minimum rule in the monorepo [`AGENTS.md`](../../../../AGENTS.md)
  applies in full. Work there is API-first; a code change is an ordinary draft PR **in that
  repository**.
- **The first advance slice is the missing `AGENTS.md`** — a `## Maintenance` section naming the
  validate command its CI runs, the release flow, and the protected files — so this card can become
  the thin pointer every other product has. Until it exists, read the repository's own CI workflow
  for the validate command and never claim one from memory.

Shared cross-repository rules are in the monorepo `AGENTS.md`; its Portfolio and Stack maps route
managed-device needs here. The site lists this repository as internal infrastructure (`infra` in
the Active Projects submodule marker), not as a public project.

## Roadmap & enhancement

The roadmap lives in **GitHub Issues** on `devantler-tech/fleet-gitops`. Advance it with
[`product-engineering`](../../product-engineering/SKILL.md), keeping findings private and sized to
the repository's low change rate.
