---
title: ☸️ Platform Template
description: A batteries-included Kubernetes platform (Flux GitOps + KSail + Talos) you instantiate from a template and bootstrap onto Hetzner Cloud, fully unattended.
---

A GitHub template that provisions a complete, **batteries-included Kubernetes platform** for you — managed end-to-end with [Flux](https://fluxcd.io/) GitOps, [KSail](https://github.com/devantler-tech/ksail), and [Talos Linux](https://www.talos.dev/). It runs locally on Docker for development and in production on [Hetzner Cloud](https://www.hetzner.com/cloud), and every change is validated in CI before it reaches the cluster. It is a genericized, fully-automated-bootstrap version of the [devantler-tech platform](https://github.com/devantler-tech/platform), from which it is derived.

**Repository**: [devantler-tech/platform-template](https://github.com/devantler-tech/platform-template)

Use it as a starting point for your own homelab or small-team platform — instantiate it, point it at your accounts, and you get a production-grade cluster with networking, certificates, secrets management, SSO, policy/runtime security, storage, databases, observability, backups, and autoscaling already wired together.

## What's Inside

A high-level inventory of what Flux reconciles onto the cluster. The exact set is overlay-dependent — local/CI (Docker) deploys the full base set, while the Hetzner/prod overlay opts out of a few controllers to save resources.

- **GitOps & config** — Flux Operator, Reloader
- **Networking** — Cilium (CNI + Gateway API), CoreDNS, external-dns (Cloudflare), Hetzner CCM (prod)
- **Certificates** — cert-manager, trust-manager, Cloudflare Origin CA issuer
- **Secrets** — OpenBao + External Secrets Operator (runtime), SOPS + Age (at-rest seeds)
- **Identity / SSO** — Dex (OIDC) with oauth2-proxy / auth-proxy
- **Policy & runtime security** — Kyverno (admission policy), Kubescape (posture + runtime detection), Tetragon (runtime enforcement)
- **Storage** — Longhorn (replicated block / RWX), CloudNativePG (PostgreSQL operator)
- **Autoscaling** — Cluster Autoscaler, Vertical Pod Autoscaler, KEDA + KEDA HTTP add-on
- **Observability** — kube-prometheus-stack (Prometheus, Grafana, Alertmanager), Loki (logs), Grafana Alloy (collection), OpenCost (cost)
- **Backup / DR** — Velero with CloudNativePG backups to S3-compatible storage (Cloudflare R2 in prod)
- **Demo apps** — Homepage (dashboard), Headlamp (Kubernetes web UI), and whoami, so the platform stands up with something to look at

To run **your own** application on the platform, add it as a GitOps tenant from its own repository — see the [GitOps Tenant Template](/templates/gitops-tenant-template/).

## Getting Started

The headline feature is the **Bootstrap workflow**: it takes a fresh instance from "Use this template + GitHub config" all the way to a running Hetzner cluster, fully unattended.

```bash
# Create a new repo from the template
gh repo create my-platform --template devantler-tech/platform-template --private --clone
```

Then, in your new repository:

1. **Install a GitHub App** (or fine-grained PAT) granted **Contents: write, Secrets: write, Environments: write, Actions: write** — the bootstrap writes cluster-derived credentials back as `prod` environment secrets, which the default `GITHUB_TOKEN` cannot do.
2. **Set the Variables + Secrets** (`DOMAIN`, `CLOUDFLARE_ZONE`, `ADMIN_EMAIL`, `HETZNER_LOCATION`, `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`, …). A few cluster secrets (`SOPS_AGE_KEY`, `KUBE_CONFIG`, `TALOS_CONFIG`) are auto-generated — you never set those.
3. **Run the Bootstrap workflow** (Actions → 🌱 Bootstrap → *Run workflow*, choose `prod`, type `yes`). It provisions the Talos cluster via `ksail cluster create`, persists credentials back as `prod` secrets, points Cloudflare DNS at the new load balancer, and commits the rendered + encrypted tree back to your repo.

The authoritative, step-by-step guide — prerequisites, configuration tables, verification, teardown, and troubleshooting — lives in the template's [`docs/BOOTSTRAP.md`](https://github.com/devantler-tech/platform-template/blob/main/docs/BOOTSTRAP.md).

### Local development

You don't need Hetzner or the Bootstrap workflow to develop locally — the local cluster runs entirely on Docker via KSail, using Talos with the Docker provider. With [Docker](https://docs.docker.com/get-docker/) and [KSail](https://github.com/devantler-tech/ksail) installed:

```bash
ksail cluster create
ksail workload push
ksail workload reconcile
```

## Links

- 📦 [Template on GitHub](https://github.com/devantler-tech/platform-template)
- 🚀 [Bootstrap guide](https://github.com/devantler-tech/platform-template/blob/main/docs/BOOTSTRAP.md)
- 🛰️ [The devantler-tech platform](https://github.com/devantler-tech/platform) (the upstream this template is derived from)
- 🚀 [GitOps Tenant Template](/templates/gitops-tenant-template/) (run your own app on the platform)
