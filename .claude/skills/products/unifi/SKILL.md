---
name: maintain-unifi
description: Product card for devantler-tech/unifi, the UniFi network config tenant — the home network's desired state as Crossplane managed resources for provider-upjet-unifi, reconciled by the platform. Use when the Agentic Engineer selects unifi.
---

# Maintain: UniFi network

- **Serves:** the household on the suite's UniFi network · **Outcome:** SSIDs, VLANs, firewall rules, devices and the VPN match the reviewed desired state ([README](https://github.com/devantler-tech/unifi#readme), root `AGENTS.md` Stack map)
- **Constraints:** no controller credential in the repository; changing the live network needs the platform and authorized controller access
- **Non-goals:** a general-purpose UniFi tool, or UniFi setups in general (README, Stack map)
- **Evidence:** UNKNOWN

The canonical maintenance procedure lives in the **`## Maintenance`** section of
`infrastructure/unifi/AGENTS.md` on the submodule's latest `main`:
<https://github.com/devantler-tech/unifi/blob/main/AGENTS.md>.

Shared cross-repository rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a
thin pointer by design so the product contract remains authoritative for every engineering tool.

**Validate before every PR:** render with `kubectl kustomize .` and check the result against the
Crossplane provider schemas the platform pins, as the repository's `AGENTS.md` describes. The
provider itself is [provider-upjet-unifi](../provider-upjet-unifi/SKILL.md); a change that needs a new
resource kind starts there.
