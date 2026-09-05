---
name: maintain-aws
description: Product card for devantler-tech/aws, the AWS config tenant — desired AWS state as Crossplane managed resources, published as a cosign-signed OCI artifact that the platform's aws tenant reconciles. Use when the Agentic Engineer selects aws.
---

# Maintain: AWS config tenant

The canonical maintenance procedure lives in the **`## Maintenance`** section of
`applications/aws/AGENTS.md` on the submodule's latest `main`:
<https://github.com/devantler-tech/aws/blob/main/AGENTS.md>.

Shared cross-repository rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a
thin pointer by design so the product contract remains authoritative for every engineering tool.

**Validate before every PR:** `kubectl kustomize deploy/ > /dev/null` — what CI runs. Crossplane CRD
semantics are validated on-cluster, never here. **No credential or provider config belongs in this
repository**: authentication is provisioned platform-side, so anything credential-shaped in a manifest
is a bug to remove, never a value to rotate.

**Two halves, two repositories.** This repo holds only the desired AWS state under `deploy/`,
namespace-agnostic because the platform-side tenant injects the namespace. The
[platform](../platform/SKILL.md) holds the tenant wiring — namespace, `SecretStore`,
bootstrap-credential `ExternalSecret`, `ProviderConfig`, and the Flux `OCIRepository` +
`Kustomization` that verifies the cosign signature. A change that needs both lands as two PRs, the
platform half first whenever the tenant must be able to consume the new artifact. The signing
identity the platform verifies is the shared `publish-manifests.yaml` workflow path in
`devantler-tech/actions`, so relocating that workflow is a platform verifier change as well.

## Roadmap & enhancement

The roadmap lives in **GitHub Issues** on `devantler-tech/aws`. Advance it with
[`product-engineering`](../../product-engineering/SKILL.md): the AWS resources the platform actually
depends on, validation depth, and release hygiene. The site lists this repository as platform
infrastructure (`infra` in the Active Projects submodule marker), not as a public project.
