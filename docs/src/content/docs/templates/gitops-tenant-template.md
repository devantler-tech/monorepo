---
title: 🚀 GitOps Tenant Template
description: A stack-neutral template for GitOps tenants on the devantler-tech platform, with signed build → publish → release plumbing.
---

A template for **GitOps tenants** on the [devantler-tech platform](https://github.com/devantler-tech/platform) — an application that runs on the platform from its own repository. Skip the CI/CD boilerplate — bring your own stack and start shipping.

**Repository**: [devantler-tech/gitops-tenant-template](https://github.com/devantler-tech/gitops-tenant-template)

It is intentionally **stack-neutral**: it carries no application code or language-specific tooling. Bring your own language and framework, and fill in the scaffolding.

## What's Inside

- **Signed supply chain** — On a `v*` tag, the image and `deploy/` manifests are built, digest-pinned, pushed as an OCI artifact, and [cosign](https://docs.sigstore.dev/)-signed. The platform's `OCIRepository` verifies that signature, so only artifacts from this trusted workflow are reconciled.
- **Release automation** — [semantic-release](https://semantic-release.gitbook.io/) turns Conventional-Commit merges to `main` into `vX.Y.Z` tags that drive deployment.
- **Stays current** — [template-sync](https://github.com/AndreasAugustin/actions-template-sync) opens a weekly PR keeping the shared CI/CD plumbing up to date across every tenant.
- **Security baseline** — A `zizmor.yml` policy enforces GitHub Actions pinning, scanned in CI.

## What the template owns vs. what you own

template-sync overwrites the files the template **owns** (the shared `cd.yaml`, `release.yaml`, `template-sync.yaml`, `CLAUDE.md`, and `zizmor.yml`) and never touches the files **you own**. Declare the files you own — your app code, `Dockerfile`, `deploy/` manifests, `ci.yaml`, `AGENTS.md`, and `README.md` — in a **`.templatesyncignore`** (same syntax as `.gitignore`).

## Getting Started

```bash
# Create a new private repo from the template
gh repo create devantler-tech/my-tenant --template devantler-tech/gitops-tenant-template --private --clone

# Replace the scaffolding with your app (code, Dockerfile, deploy/ manifests, ci.yaml),
# then validate locally:
cd my-tenant
kubectl kustomize deploy/        # manifests build
actionlint .github/workflows/*   # workflows parse
```

Then register the tenant on the platform by following [`platform/docs/TENANTS.md`](https://github.com/devantler-tech/platform/blob/main/docs/TENANTS.md).

> **Convention:** the Deployment's container `name` MUST equal the repository name — `publish-app` pins the built image digest into the container with that name.

## Links

- 📦 [Template on GitHub](https://github.com/devantler-tech/gitops-tenant-template)
- 🛰️ [The devantler-tech platform](https://github.com/devantler-tech/platform)
- 🔄 [Reusable workflows used by this template](https://github.com/devantler-tech/reusable-workflows)
