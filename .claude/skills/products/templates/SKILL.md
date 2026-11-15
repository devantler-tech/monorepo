---
name: maintain-templates
description: Maintenance task menu for the devantler-tech application template (platform-tenant-template, becoming application-template), whose scaffold lays a Go, .NET or own stack over it with optional platform tenancy, and for the retiring go-template and dotnet-template. Keep the scaffold clean, current and buildable: triage, dependency/toolchain hygiene, CI health, scaffold freshness. Use when the daily maintainer selects templates.
---

# Maintain: Templates (application template; go-template and dotnet-template retiring)

- **Serves:** developers starting a new devantler-tech application · **Outcome:** one command
  (`scripts/scaffold.sh <go|dotnet|none> [--tenancy]`) gives them a building, tested service,
  and a platform tenant that passes its probes, before they write any code
  ([ADR 0018](../../../../docs/adr/0018-one-application-template.md))
- **Constraints:** keep each stack minimal, idiomatic and current; keep the template's root
  shaped as a tenant so existing tenants keep syncing the same paths
- **Non-goals:** product features; carrying GoReleaser, NuGet publishing or other per-product
  tooling in the template (ADR 0018 decision 7)
- **Evidence:** UNKNOWN

The canonical maintenance task menu lives in the template's own repo — read the
**`## Maintenance`** section of `templates/platform-tenant-template/AGENTS.md` (on the submodule's
latest `main`): <https://github.com/devantler-tech/platform-tenant-template/blob/main/AGENTS.md>.

Every application syncs from the template, which owns the cross-cutting files (linting, CodeQL,
CodeRabbit, Renovate) while each application keeps its own overlays
([ADR 0018, 2026-11-15 amendment](../../../../docs/adr/0018-one-application-template.md#amendments)).
A concern several applications share belongs in the template, generically, not in each copy.

`go-template` and `dotnet-template` take only dependency and CI upkeep until KHoist and Bookkeeper
move their template-sync source and both repositories are archived. File new Go or .NET template
work on the application template.

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md). This card is a
pointer by design.

## Roadmap & enhancement
The roadmap lives in **GitHub Issues** on the template's repo (`roadmap` label). **Advance** via
[`product-engineering`](../../product-engineering/SKILL.md), but the bias is to keep each stack
**minimal, idiomatic, and current** — advance = better defaults, toolchain currency, exemplary
tests/CI, and keeping the stacks aligned where it makes sense; **don't add product features**.
