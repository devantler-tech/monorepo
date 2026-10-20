---
name: maintain-khoist
description: Product card for devantler-tech/khoist (KHoist, formerly data-product-controller), the cloud-native control plane and open API for portable, composable data products. Use when the Agentic Engineer selects KHoist.
---

# Maintain: KHoist

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
