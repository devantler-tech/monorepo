---
title: "GitOps Without the Git Server: Using GHCR as a Flux Source with KSail"
date: 2026-03-25
authors:
  - devantler
tags:
  - kubernetes
  - gitops
  - flux
  - oci
excerpt: Most local Flux setups point at a Git repo. OCI registries are cleaner — here's a full walkthrough using KSail's workload push command and GHCR, including CI pipeline usage.
cover:
  alt: OCI artifacts as a Flux source with KSail
  image: ../../../assets/oci-artifacts.webp
---

The standard advice for running Flux locally is to point it at a Git repository. In practice that means either pushing to a remote repo and waiting for Flux to poll it, maintaining a local Git server, or wrestling with Flux's lack of support for local file paths. None of these are great for a tight development loop.

Flux has supported OCI repositories as sources since v2.0.0, and this is a much cleaner approach for local development. Instead of a Git repo, Flux watches an OCI artifact in a container registry. You push your manifests as a versioned artifact, Flux pulls and applies it. KSail has a `workload push` command that handles the packaging and push step, so the workflow after editing manifests comes down to two commands.

Here's a complete walkthrough.

## Prerequisites

You need Docker installed and a GHCR token. For GHCR, a Personal Access Token with `write:packages` scope works fine locally. In CI, the built-in `GITHUB_TOKEN` with `packages: write` permission is enough.

```bash
echo $GHCR_TOKEN | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

KSail itself only needs Docker — it bundles kubectl, helm, flux, kustomize, kind, and more into a single binary.

```bash
brew install --cask devantler-tech/tap/ksail
```

## Setting Up a Cluster with Flux

```bash
ksail cluster init \
  --name dev \
  --distribution Vanilla \
  --gitops-engine Flux
```

This scaffolds:

- `ksail.yaml` — KSail configuration
- `kind.yaml` — Kind cluster config (usable directly with `kind` if you ever want to bypass KSail)
- `k8s/kustomization.yaml` — root Kustomization manifest
- Flux HelmRelease and OCI source configs

Edit `ksail.yaml` to point at your GHCR repository. Add a `workload.tag` while you're there:

```yaml
apiVersion: v1alpha1
kind: Cluster
metadata:
  name: dev
spec:
  distribution: Vanilla
  gitops:
    engine: Flux
    registries:
      - host: ghcr.io
        username: YOUR_GITHUB_USERNAME
  workload:
    tag: dev
```

The `spec.workload.tag` field sets the OCI artifact tag used when pushing. For local iteration `dev` is convenient — every push overwrites the same tag, and Flux detects changes via digest rather than tag, so reconciliation still fires correctly.

Create the cluster:

```bash
ksail cluster create
```

Flux bootstraps during `cluster create`. By the time the command finishes, Flux is running and watching the OCI source you configured.

## Pushing Manifests

Add something to `k8s/` — a namespace, a Deployment, whatever you're working on:

```yaml
# k8s/my-app/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: nginx:stable-alpine
          ports:
            - containerPort: 80
```

Push and reconcile:

```bash
ksail workload push
ksail workload reconcile
```

`workload push` packages your `k8s/` directory as an OCI artifact and pushes it to GHCR. `workload reconcile` triggers Flux to pull the latest artifact and waits for all Kustomizations to report Ready.

On a decent connection the round trip from `workload push` to reconciliation complete is typically under 15 seconds for a small manifest set.

## How Tag Resolution Works

When you run `ksail workload push`, the tag for the artifact follows this priority chain:

1. An explicit `oci://` ref on the command line: `ksail workload push ghcr.io/org/repo:v1.2.3`
2. `spec.workload.tag` in `ksail.yaml`
3. A tag already embedded in the registry URL from config
4. The default: `dev`

This makes local and CI behavior easy to separate. Locally you set `spec.workload.tag: dev` in `ksail.yaml` and forget about it. In CI you override at the command line to tie the artifact to a specific commit:

```bash
ksail workload push ghcr.io/YOUR_ORG/my-manifests:${{ github.sha }}
ksail workload reconcile
```

Each commit produces an immutable artifact. If a deployment goes wrong you can point Flux at an earlier digest and reconcile back to a known-good state.

## Using It in CI

The `workload push` command includes retry logic specifically for GHCR (added in v5.67.0), which handles the transient authentication errors that GHCR occasionally returns under load. For pipelines that push during high-traffic windows this meaningfully improves reliability — previously a flaky GHCR response would fail the whole step.

A minimal GitHub Actions workflow step:

```yaml
- name: Push manifests to GHCR
  run: |
    echo "${{ secrets.GITHUB_TOKEN }}" | \
      docker login ghcr.io -u ${{ github.actor }} --password-stdin
    ksail workload push \
      ghcr.io/${{ github.repository_owner }}/my-cluster-manifests:${{ github.sha }}
  env:
    KSAIL_CLUSTER_NAME: staging
```

The `KSAIL_CLUSTER_NAME` environment variable tells KSail which cluster configuration to load when you have multiple clusters defined.

## What About `workload watch`?

For purely local iteration where you don't want to think about pushing at all, `ksail workload watch` is lower friction:

```bash
ksail workload watch --path ./k8s
```

This watches the `k8s/` directory and applies changes directly with kubectl, bypassing the OCI push step. If Flux is running it will also trigger selective Kustomization reconciliation on affected CRs automatically.

The OCI push workflow is the better choice when:

- You want local and CI behavior to be identical
- You're testing Flux OCI source configuration itself
- You need immutable versioned artifacts (each push gets a content digest)
- You're sharing manifests across multiple clusters or environments

`workload watch` is better when:

- You're iterating fast and CI parity doesn't matter right now
- The push/reconcile round trip feels slow for your current task

Both workflows coexist without conflict. It's a per-session choice.

## A Note on Registry Permissions

GHCR packages inherit from your repository's visibility by default. For anything sensitive, set the package visibility explicitly in GitHub's package settings, or use a private repository.

KSail has built-in SOPS integration (`ksail cipher encrypt`) for secret management. Secrets shouldn't be in your manifests regardless of registry visibility — encrypt them before they land in `k8s/`.

---

KSail is open source under Apache-2.0. Full documentation including the OCI push workflow, Flux source configuration, and the composite GitHub Action for CI is at [ksail.devantler.tech](https://ksail.devantler.tech).

---

_This blog post was written with the assistance of AI. The content reflects genuine experiences and opinions; the AI helped structure and articulate them._
