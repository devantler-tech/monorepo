---
name: maintain-khoist
description: Product card for devantler-tech/khoist (KHoist), the cloud-native control plane and open API for portable, composable data products. Use when the Agentic Engineer selects KHoist.
---

# Maintain: KHoist

- **Serves:** teams that publish data products, and the people and tools that consume them · **Outcome:** each product is described as a Kubernetes resource, its readiness is reported and the registry lists it ([README](https://github.com/devantler-tech/khoist#readme))
- **Constraints:** the controller handles descriptions only; product data and credentials stay with the owning team; `v1alpha1` is deliberately small and expected to change
- **Non-goals:** holding product data or credentials; the registry does not embed product pages or execute publisher code (README)
- **Evidence:** UNKNOWN

The canonical maintenance procedure lives in the **`## Maintenance`** section of
`applications/khoist/AGENTS.md` on the submodule's latest `main`:
<https://github.com/devantler-tech/khoist/blob/main/AGENTS.md>.

Shared cross-repository rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a
thin pointer by design so the product contract remains authoritative for every engineering tool.

## Roadmap & enhancement

The roadmap lives in **GitHub Issues** on `devantler-tech/khoist`, rooted at the
[`roadmap` epic](https://github.com/devantler-tech/khoist/issues/1). Advance it with
[`product-engineering`](../../product-engineering/SKILL.md), preserving the accepted **API-only**
integration direction (the product's ADR 0023): consumers own their UIs and integrate through the
product API, and the retained legacy UI metadata is deprecated compatibility, never new surface.
