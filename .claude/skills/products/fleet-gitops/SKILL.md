---
name: maintain-fleet-gitops
description: Product card for devantler-tech/fleet-gitops, the FleetDM GitOps configuration for devantler-tech device management. Use when the Agentic Engineer selects fleet-gitops.
---

# Maintain: FleetDM device config

`applications/fleet-gitops` is the tracked submodule of `devantler-tech/fleet-gitops`, which holds
the FleetDM configuration for the suite's managed devices as GitOps-managed files.

**Read the repository's visibility live before every run touches it** —
`gh api repos/devantler-tech/fleet-gitops --jq .private` — never from this card or from memory. The
portfolio map deliberately records no visibility. Then initialise the submodule with the monorepo's
submodule helper and read `applications/fleet-gitops/AGENTS.md`; that repository contract owns its
validation, apply flow, and protected-file guidance.

While the live read says private, nothing from the repository reaches a public surface. Its issues
are not boarded on project 5 (adding private work to the public board is a maintainer decision), and
no file content, CI detail, validation output, or device inventory enters a public issue, PR body,
comment, or report. Should the repository become public, its open issues join the ordinary board
sweep. Work there remains API-first; code changes use ordinary draft PRs in that repository.

Shared cross-repository rules are in the monorepo `AGENTS.md`; its Portfolio and Stack maps route
managed-device needs here. The site lists this repository as internal infrastructure (`infra` in
the Active Projects submodule marker), not as a public project.

## Roadmap & enhancement

The roadmap lives in **GitHub Issues** on `devantler-tech/fleet-gitops`. Advance it with
[`product-engineering`](../../product-engineering/SKILL.md), keeping findings private and sized to
the repository's low change rate.
