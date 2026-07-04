---
name: maintain-platform
description: Repo + live-platform health/maintenance menu for devantler-tech/platform (GitOps — Kustomize overlays + Flux CD, Cilium/Talos/KSail/SOPS). Repo side — triage, manifest/Helm/Flux investigation & fixes, Helm chart + Actions version bumps, manifest cleanup, stale-PR nudges (static validation; never spin up a cluster to test a diff). Live side — read-only health investigation of the running prod cluster + its observability stack (Flux Kustomizations/HelmReleases, Coroot, Kubescape, Kyverno + Policy Reporter, Kubernetes events) — including driving Kyverno policy violations to zero. Use when the daily maintainer selects Platform.
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
- **Kubescape** — the three finding surfaces (posture / CVE / runtime), for security-posture regressions
  vs the last run. **A `0`/empty reading is NOT automatically "clean" — verify the scanner is actually
  producing data first** (a broken scanner reads identically to a compliant cluster). See the dedicated
  **Security posture** section below for the object names, the broken-vs-clean checks, and the
  fix-vs-except ladder.
- **Kyverno + Policy Reporter** — policy **validation & enforcement**: `kubectl --context=admin@prod
  get cpol,pol` (policies present? mode Audit vs Enforce?) and `polr,cpolr` (PolicyReport /
  ClusterPolicyReport — failing rules and violating resources). **Policy Reporter** aggregates every
  report into a dashboard + read API (SSO UI at `policy-reporter.${domain}`; in-cluster API
  `policy-reporter.policy-reporter.svc:8080`) for a whole-cluster view of failing results. Driving
  those failures to **zero and holding it** is a standing objective — see the dedicated **Policy
  compliance** section below.
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

## Security posture (Kubescape) — drive to 100% and hold
Kubescape runs **three finding surfaces**; **driving all three to 100% and holding them is a standing
objective, not a floor** (epic + children: [devantler-tech/platform#2447](https://github.com/devantler-tech/platform/issues/2447)).
The recurring trap, learned the hard way (2026-07-04, all three surfaces were silently dead): **an
empty/zero reading almost always means the scanner is broken, not that the cluster is clean** — a broken
scanner and a compliant cluster look identical, so **check liveness first, every time**:

- **Posture** (config scan) — `configurationscansummaries` / `workloadconfigurationscansummaries`
  (per-namespace scores + failed controls). **Broken if** scores are `0.00` across frameworks,
  `controls: null` en masse, or objects are days stale — check the `kubescape` scanner pod logs for scan
  aborts. Note: the CI gate (`ksail workload scan --framework nsa --compliance-threshold N`) is a
  **separate** static scan in a healthy CLI context — **a green CI gate does NOT prove the in-cluster
  scan works.**
- **CVE** (kubevuln) — `vulnerabilitymanifestsummaries` / `vulnerabilitymanifests`. **Broken if**
  manifests carry no grype `matches` / no `tool.name` and summaries are empty (both `.all` and
  `.relevant`) — check kubevuln logs for `ScanCP … partial` (the relevancy path aborting on partial
  ApplicationProfiles). Prioritise by relevancy × severity × fixability; emit VEX to suppress
  non-reachable CVEs.
- **Runtime** (node-agent) — `applicationprofiles`, `networkneighborhoods`, and the
  `node_agent_alert_counter` metric. **Invisible if** the exporters are stdout-only
  (`alertManagerExporterUrls: []`, `prometheusExporterEnabled: false`). Route **natively to Coroot**
  (minimal-custom, all declarative): node-agent Prometheus exporter → `coroot.com/scrape-metrics`
  annotation → a custom PromQL `alertingRules[]` in the Coroot CR → the existing Slack `notificationIntegrations`
  webhook — **no new infra** (Coroot CE supports custom-PromQL alerts natively; it has no standard
  Alertmanager, so don't add one).

**Fix-vs-except ladder — the definition of done for a finding.** An exception is the audited last resort,
never the first move:
1. **Fix the manifest/root cause** — the real remediation (securityContext, RBAC scope, probes, labels).
2. **Runtime-enforce** — if it's mutated/enforced at admission (Kyverno) or by the network layer
   (Cilium), it's covered even where the static scan can't see it; **graduate a fixed control into Kyverno
   `Enforce`** so it can't regress.
3. **Except only when genuinely irreducible** (e.g. C-0002, the KubeVirt operator's `pods/exec` RBAC) — a
   narrow, justified `ClusterSecurityException` in `k8s/bases/infrastructure/cluster-security-exceptions/`
   with a written *why*, reviewed via PR, and periodically pruned. A growing exceptions dir is a smell,
   not progress.

A confirmed off-baseline finding on any surface — **including a scanner that has silently stopped
producing data** — becomes a `security` issue under the epic (capture step), or a hotfix if it's active
breakage. Ratchet the CI `--compliance-threshold` up as gaps close; never lower it.

## Policy compliance (Kyverno) — drive violations to zero and hold
Kyverno admission policies emit `PolicyReport` / `ClusterPolicyReport` results for every workload;
**driving the failing results to zero and holding them there — so everything in the cluster runs
compliant — is a standing objective, not a floor.** This is the admission-time twin of the Kubescape
*Security posture* program above (policy vs posture scan); apply the same discipline.

- **Enumerate every run** via **Policy Reporter** — the dashboard/read API that aggregates all reports
  (SSO UI at `policy-reporter.${domain}`; in-cluster API `policy-reporter.policy-reporter.svc:8080`) —
  or `kubectl --context=admin@prod get polr,cpolr -A`. Count the `fail` (and `warn`) results and treat
  a **newly introduced** failure as a regression to clear promptly, like a red CI check — not just the
  long-standing backlog.
- **Fix-vs-except ladder — same as Kubescape** (an exception is the audited last resort, never first):
  1. **Fix the manifest/root cause** — correct the offending workload at its source so it satisfies the
     rule (add the missing securityContext / limits / label / PDB / probe / image pin), shipped as a
     draft PR. **Never** silence a real violation.
  2. **Runtime-enforce & graduate** — once a rule's findings are at zero, **graduate its policy from
     `Audit` to `Enforce`** so the violation is blocked at admission and cannot regress (a weak
     Audit-only policy that could Enforce is itself a roadmap lever).
  3. **Except only when genuinely by-design** — add a **scoped, reasoned `exclude`** to the relevant
     Kyverno `ClusterPolicy` in `k8s/bases/infrastructure/cluster-policies/`, with a written *why*,
     reviewed via PR. The repo exempts via **per-policy `exclude` blocks — `PolicyException` CRs are
     not enabled**. An `exclude` that hides a fixable violation is a suppression, not an exception; a
     growing exclude list is a smell, not progress.

Record the residual (genuinely-excepted) baseline in native memory so a later run doesn't re-chase a
documented by-design exemption — mirroring the Kubescape known-non-issues baseline. A confirmed
violation becomes a `security`/`bug` draft PR (fix) or a triaged issue (larger cleanup); active
admission breakage (an `Enforce` policy rejecting a legitimate workload) is a hotfix.

## Roadmap & enhancement
Platform's roadmap lives in **GitHub Issues** on `devantler-tech/platform` (`roadmap` epics +
milestones). **Advance** via [`product-engineering`](../../product-engineering/SKILL.md) — on the
**repo** side: manifest/Helm/Flux structure & quality, policy & security posture, Kustomize hygiene
(static validation, not unit tests). On the **live** side: the health investigation above is also an
enhancement engine — gaps it surfaces (a missing alert/SLO, a weak/Audit-only policy that should
Enforce, an unaddressed Coroot risk or cost optimization, a reliability hotspot) become `roadmap`/
`enhancement` issues or focused draft PRs.
