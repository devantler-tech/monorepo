---
name: maintain-platform
description: Maintenance task menu for devantler-tech/platform (a GitOps Kubernetes platform — Kustomize overlays + Flux CD, Cilium/Talos/KSail/SOPS). Triage, manifest/Helm/Flux investigation & fixes, Helm chart + Actions version bumps, manifest cleanup, stale-PR nudges. Static validation only — never runs a cluster. Use when the daily maintainer selects Platform.
---

# Maintain: Platform

**Repo** `devantler-tech/platform` · **path** `platform` · **Issues** enabled.
Shared rules: monorepo [`AGENTS.md`](../../../../AGENTS.md). First read `platform/AGENTS.md` and skim
`platform/.github/instructions/` (kustomize-manifests, talos-patches, sops-secrets) before editing
manifests. Memory = the [`MAINTENANCE.md`](../../../../MAINTENANCE.md) dashboard.

## Repo-specific conventions
- **Branch** `claude/repo-assist-<desc>`; **labels** `automation,repo-assist`.
- **Validate before any manifest PR** — both overlays MUST build: `kubectl kustomize k8s/clusters/local/` and `kubectl kustomize k8s/clusters/prod/` (standalone `kustomize` isn't installed; `kubectl` has it built in). Per-file: `kubectl apply --dry-run=client -f <file>`. The full Talos+Docker system test runs in CI on the PR (3–5 min, Docker+KSail) — don't run it locally.
- **Never run a cluster** — static validation only; no `ksail up`/create/switch/delete, no mutating `~/.kube/config`.
- **Protected — never modify:** `*.enc.yaml` (SOPS), `ksail.prod.yaml` (live prod), `.sops.yaml`. **Bases immutable** — change via Kustomize `patches:` in overlays, never edit `k8s/bases/` from an overlay. Respect Flux order: `variables → infrastructure-controllers → infrastructure → apps`.

## Task menu (pick 2–3; favour the "platform-useful" tasks in AGENTS.md)
1. **Triage & label** unlabelled issues/PRs; remove misapplied labels; close obvious spam/off-topic.
2. **Investigate & comment** on open issues lacking an AI comment (oldest first; 1–3/run) — manifest misconfigs, Helm chart issues, Flux sync/dependency-order problems; answer by type, no vague acknowledgements.
3. **Fix confident, low-risk issues** → branch `claude/repo-assist-fix-issue-<N>-<desc>`, minimal surgical fix, overlays build, draft PR with `Closes #N`, root cause, rationale, build-check result.
4. **Engineering investments:** Helm chart bumps via HelmRelease `spec.chart.spec.version` (prefer minor/patch; majors only with clear benefit); GitHub Actions/workflow health; bundle compatible Renovate/Dependabot PRs. One concern per draft PR.
5. **Manifest improvements:** Kustomize cleanup, dead-resource removal, doc gaps — only obviously-beneficial, low-risk, highly selective.
6. **Maintain your own PRs** (`repo-assist`): fix CI you caused, resolve conflicts; don't push for infra-only failures — comment instead.
7. **Stale-PR nudges:** ≤3 polite nudges to other contributors' PRs untouched 14+ days waiting on the author.

> Skip performance / test-suite / code-refactoring tasks — per AGENTS.md they're "Less Applicable" to a declarative manifest repo.
