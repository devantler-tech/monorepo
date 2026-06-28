---
name: maintain-provider-upjet-unifi
description: Maintenance + advance task menu for devantler-tech/provider-upjet-unifi — an Upjet-generated Crossplane provider for Ubiquiti UniFi (from ubiquiti-community/terraform-provider-unifi). A shared library consumed by the platform cluster to manage UniFi as Kubernetes resources. Use when the daily maintainer selects provider-upjet-unifi.
---

# Maintain: UniFi Crossplane provider (shared agent/infra library)

A [Crossplane](https://crossplane.io) provider for **Ubiquiti UniFi**, generated with
[Upjet](https://github.com/crossplane/upjet) from
[`ubiquiti-community/terraform-provider-unifi`](https://github.com/ubiquiti-community/terraform-provider-unifi)
(registry source `ubiquiti-community/unifi`). A **shared library** in the portfolio — the `platform`
cluster consumes it (a `Provider` CR + `ProviderConfig`) to manage UniFi networks/WLANs/firewall/VPN/
WireGuard/devices/settings as Kubernetes custom resources, exactly like it consumes `provider-upjet-github`.

The canonical task menu lives **in the repo itself** — read the **`## Maintenance`** section of
`libraries/provider-upjet-unifi/AGENTS.md` (on the submodule's latest `main`):
<https://github.com/devantler-tech/provider-upjet-unifi/blob/main/AGENTS.md>. This card is a pointer by
design — the menu is maintained once, in the product's own `AGENTS.md`.

**It's a generated provider — respect the generation boundary.** Change behaviour via `config/**`
(external-name coverage, groups) or `internal/clients/unifi.go` (auth), then `make generate`; never
hand-edit `apis/**`, `internal/controller/**`, or `package/crds/**`. The standout recurring task is
**tracking upstream `terraform-provider-unifi` releases**: bump `TERRAFORM_PROVIDER_VERSION`, regenerate,
draft-PR the regenerated tree; new upstream resources get an external-name config so they generate.

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md).

## Roadmap & enhancement
Roadmap lives in **GitHub Issues** on `devantler-tech/provider-upjet-unifi` (`roadmap`-labelled epics +
milestones). To **advance** (resource coverage, auth/reference-resolution improvements, test coverage,
CI/CD health, docs, and the eventual platform consumer wiring) follow
[`product-engineering`](../../product-engineering/SKILL.md).
