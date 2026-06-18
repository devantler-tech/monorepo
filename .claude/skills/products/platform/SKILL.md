---
name: maintain-platform
description: Repo + live-platform health/maintenance menu for devantler-tech/platform (GitOps — Kustomize overlays + Flux CD, Cilium/Talos/KSail/SOPS). Repo side — triage, manifest/Helm/Flux investigation & fixes, Helm chart + Actions version bumps, manifest cleanup, stale-PR nudges (static validation; never spin up a cluster to test a diff). Live side — read-only health investigation of the running prod cluster + its observability stack (Flux Kustomizations/HelmReleases, Coroot, Kubescape, Kyverno, Kubernetes events). Use when the daily maintainer selects Platform.
---

# Maintain: Platform

Platform has **two surfaces to keep healthy *and* advance** — the **repository** (manifests, Helm,
Flux, policies) and the **live platform** (the running prod cluster it delivers). **Cover both** each
time you select Platform: the repo can be green while the cluster is unhealthy (and vice-versa).

## Repository menu (canonical, maintained in the product itself)
The canonical repo maintenance task menu lives **in the repo** — read the **`## Maintenance`** section
of `platform/AGENTS.md` (on the submodule's latest `main`):
<https://github.com/devantler-tech/platform/blob/main/AGENTS.md>. For **validating a repo/PR change**,
use **static validation** (kustomize build + schema/kubeconform, per that menu) — **never spin up a
cluster just to test a manifest diff**. Shared cross-repo rules are in the monorepo
[`AGENTS.md`](../../../../AGENTS.md). This part of the card is a pointer by design — the repo menu is
maintained once, in the product's own `AGENTS.md`.

## Status & live-platform health investigation (read-only)
Investigating **how the platform itself is doing** is a first-class part of every Platform run — do it
**read-only** against the running prod cluster + its observability stack, and **dedupe against the
accepted "known non-issues" baseline in your native memory** so you don't re-chase by-design/transient
signals. Pin the context — `kubectl --context=admin@prod …` (the shared kubeconfig drifts across
parallel sessions, and its API endpoint can go stale after a control-plane recreate; the refresh recipe
+ healthy baseline counts live in native memory). Query **at least** the following; the list is
**non-exhaustive — chase any other anomaly** you see:

- **Flux Kustomizations** — `kubectl --context=admin@prod get kustomization -A` (Ready? suspended?
  drifting/last-applied revision? health-check timeouts?). For a stuck/failing reconciliation, the
  `gitops-cluster-debug` skill (Flux MCP server) traces the dependency chain on the live cluster.
- **Flux HelmReleases** — `kubectl --context=admin@prod get helmrelease -A` (Ready? install/upgrade
  retries exhausted? stuck/pending-upgrade?).
- **Coroot** — Incidents, Alerts/SLO burn, Traces, Logs, Risks (deployment & health-check risks), and
  **cost optimizations** (Node/cost view). Use its **read API** — the access recipe (project id, auth,
  the SPA-200-masks-404 gotcha, the empty-Hetzner-cost-rollup known limitation) is in native memory.
- **Kubescape** — its config-scan / vulnerability / compliance / RBAC report objects, for security-
  posture regressions vs the last run.
- **Kyverno** — policy **validation & enforcement**: `kubectl --context=admin@prod get cpol,pol`
  (policies present? mode Audit vs Enforce?) and `polr,cpolr` (PolicyReport / ClusterPolicyReport —
  failing rules and violating resources).
- **Kubernetes events & warnings** — `kubectl --context=admin@prod get events -A
  --field-selector type=Warning`, plus unhealthy / CrashLooping / Pending pods and abnormal restart
  counts.
- **Other problems** — node/Talos & etcd-quorum health, Longhorn volume health, cert-manager certs,
  external-secrets/OpenBao sync, ingress/Envoy reachability — and anything else off the healthy baseline.

**Guardrails.** Investigation is **read-only** — never mutate prod to "test", and never spin up a *new*
cluster for it (live-cluster reliability E2E is the ~weekly heavy task, and you **never spin up real
clusters more than once a day** portfolio-wide — contract *Cadence*). Operational recovery follows
`platform/AGENTS.md` + the DR runbook. Turn a **confirmed, off-baseline** problem into the right
artifact — a root-cause **draft PR** to the platform repo (manifest/Helm/policy fix) or a triaged issue
— never a hand-edit of generated files and never a guardrail bypass.

## Roadmap & enhancement
Platform's roadmap lives in **GitHub Issues** on `devantler-tech/platform` (`roadmap` epics +
milestones). **Advance** via [`product-engineering`](../../product-engineering/SKILL.md) — on the
**repo** side: manifest/Helm/Flux structure & quality, policy & security posture, Kustomize hygiene
(static validation, not unit tests). On the **live** side: the health investigation above is also an
enhancement engine — gaps it surfaces (a missing alert/SLO, a weak/Audit-only policy that should
Enforce, an unaddressed Coroot risk or cost optimization, a reliability hotspot) become `roadmap`/
`enhancement` issues or focused draft PRs.
