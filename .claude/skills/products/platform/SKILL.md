---
name: maintain-platform
description: Maintenance task menu for devantler-tech/platform (a GitOps Kubernetes platform — Kustomize overlays + Flux CD, Cilium/Talos/KSail/SOPS). Triage, manifest/Helm/Flux investigation & fixes, Helm chart + Actions version bumps, manifest cleanup, stale-PR nudges. Static validation only — never runs a cluster. Use when the daily maintainer selects Platform.
---

# Maintain: Platform

The canonical Platform maintenance task menu lives **in the repo itself** — read the
**`## Maintenance`** section of `platform/AGENTS.md` (on the submodule's latest `main`):
<https://github.com/devantler-tech/platform/blob/main/AGENTS.md>. Static validation only — never run
a cluster.

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a
pointer by design — the menu is maintained once, in the product's own `AGENTS.md`.

## Roadmap & enhancement
Platform's roadmap lives in **GitHub Issues** on `devantler-tech/platform` (`roadmap` epics +
milestones). **Advance** via [`product-engineering`](../../product-engineering/SKILL.md) — but
**static validation only, never run a cluster**: here "advance" means manifest/Helm/Flux structure &
quality, policy & security posture, and Kustomize hygiene, not code unit tests.
