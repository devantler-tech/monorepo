# ADR 0016: Run a dev and a prod deployment of every custom-built app on the one platform

Status: Accepted.

Date: 2026-11-12

Issue: the epic [#4972](https://github.com/devantler-tech/monorepo/issues/4972)

## Context

The custom-built applications on the platform each run one deployment: the newest stable release,
at its public hostname. New work lands on `main` behind default-off feature flags, as the
[feature-flag-first rule](../../.claude/guides/advance-work.md#feature-flag-first-delivery) requires,
and every merge to `main` cuts a release. So unfinished features already ship in prod releases, but
switched off. Nobody can see them working until they are switched on in prod, which means feedback
comes late.

On 2026-11-12 the maintainer asked for a dev deployment beside every prod one: experimental features
on, mocked or non-prod integrations, on the same platform, at a `dev.` hostname, internal only. He
excluded third-party infrastructure and apps, such as Homepage and kagent, whose charts are trusted
to work.

## Decision

1. **Two environments per product.** Every app in the table below runs **prod** and **dev** on the
   production platform. Prod is unchanged: the newest stable release, at today's hostname, with flags
   as set.

   | Product | Prod | Dev |
   |---|---|---|
   | AS Coaching | `ascoachingogvaner.dk` | `dev.ascoachingogvaner.dk` |
   | devantler.tech site | `devantler.tech` | `dev.devantler.tech` |
   | Wedding app | `wedding.platform.devantler.tech` | `dev.wedding.platform.devantler.tech` |
   | World at Ruin zone server | `zone-trial.devantler.tech` | `dev.zone-trial.devantler.tech` |
   | KHoist | its `*.platform.devantler.tech` hosts | `dev.` + each prod host |

   A new custom-built app gets both environments when it is onboarded. The dev hostname is always
   `dev.` + the prod hostname.

2. **One signed artifact, two overlays.** Dev reconciles the same cosign-verified manifests artifact
   as prod, from the same publisher identity. The artifact carries a `deploy/dev` Kustomize overlay
   beside the prod manifests. Dev selects the newest version including pre-releases, so a product
   may preview unmerged work by publishing a pre-release; prod's range keeps excluding them.

3. **Dev turns every experimental flag on.** The overlay enables each flag through the product's
   own documented mechanism, so dev shows exactly what is latent in prod. Flags keep their
   lifecycle: a flag removed from the code leaves the overlay in the same change.

4. **Dev never touches prod data or prod integrations.** Each dev deployment has its own namespace,
   database, buckets and secrets, seeded with fake data where the product needs data to be useful.
   Mail goes to an in-cluster sink, payments and sign-in use the provider's test mode or a test
   realm, and analytics never reach the prod site.

5. **Internal only means behind single sign-on.** Dev hostnames resolve publicly and pass through the
   platform's oauth2-proxy gate, which already admits only the maintainer team to the platform UIs.
   A network policy also stops the gateway from reaching dev pods directly, so a tenant's own route
   cannot bypass the gate. This follows the zero-trust-first direction of 2026-10-17: access is
   decided by identity, not by being on the home network.

6. **Dev is cheap and never blocks prod.** One replica, no high availability, no backups, idle
   scale-to-zero where the product allows it. Dev deployments sit outside prod health gates, the
   merge-queue deploy checks and paging alerts.

7. **A controller that installs cluster-scoped CRDs runs its dev in a virtual cluster** on the
   platform, provisioned by KSail. Two versions of one CRD cannot coexist in one cluster, and a dev
   controller must not act on prod resources. KHoist is the first such product.

8. **Out of scope:** third-party apps and infrastructure (Homepage, kagent, Umami, Actual Budget,
   whoami, the mail stack, FleetDM and every controller), the configuration tenants that change real
   external systems (UniFi, AWS), the agent lanes, and the KSail operator. A dev copy of a
   configuration tenant would change the same real network or account. A dev agent lane would double
   paid inference and write to the same repositories. The KSail operator manages the live platform
   and is already exercised by KSail's ephemeral-cluster tests.

## Options compared

- **Dev from `main` builds instead of releases.** Every merge to `main` already cuts a release, so a
  separate build channel adds a second signing path for no gain. Pre-releases cover unmerged work.
- **A separate dev cluster.** The platform had one in April 2026
  ([platform#1346](https://github.com/devantler-tech/platform/issues/1346)). A second cluster doubles
  the fixed cost and the upgrade work, and can drift from prod. The maintainer asked for the same
  platform.
- **Internal only by network (home network or VPN).** It would hide dev from the maintainer when he is
  away from home, and the home-network bridge is not meant as an access boundary. The sign-on gate
  already protects every platform UI.
- **A dev hostname under `platform.devantler.tech`.** The existing wildcard certificate would cover
  it, but the maintainer asked for `dev.` + the product's own hostname, so each dev site sits beside
  the prod site it previews.

## Consequences

- The platform's `Tenant` graph gains an environment input, and the sign-on gate, certificates,
  listeners, DNS and hostname allow-list gain one entry per dev hostname
  ([platform#6126](https://github.com/devantler-tech/platform/issues/6126)). Every product issue is
  blocked by it.
- Each product ships and tests a `deploy/dev` overlay
  ([ascoachingogvaner#369](https://github.com/devantler-tech/ascoachingogvaner/issues/369),
  [wedding-app#467](https://github.com/devantler-tech/wedding-app/issues/467),
  [business-site#542](https://github.com/devantler-tech/business-site/issues/542),
  [world-at-ruin#1700](https://github.com/devantler-tech/world-at-ruin/issues/1700),
  [khoist#610](https://github.com/devantler-tech/khoist/issues/610)).
- The platform runs roughly one more small pod per product and one virtual cluster for KHoist.
- A feature becomes visible to the maintainer when it merges, not when its flag is switched on in
  prod. Switching it on in prod stays a separate, reviewed change.

## Amendments

- **2026-11-14: `deploy/` splits into `base`, `prod` and `dev`.** The maintainer asked that every
  product getting a dev deployment lays out its manifests as Kustomize `base/`, `prod/` and `dev/`
  folders, so the two environments share one copy of everything they have in common. This refines
  decision 2:

  ```text
  deploy/
  ├── kustomization.yaml   # includes only prod/
  ├── base/                # what both environments run, including the app the publisher pins
  ├── prod/                # base/ + what only prod has
  └── dev/                 # base/ + patches that turn it into dev
  ```

  `prod/` adds what belongs to prod alone: public routes, certificates, DNS, disruption budgets,
  backups, and every secret or integration that touches prod. `dev/` changes `base/` through
  Kustomize patches and never copies a manifest. The file at the artifact root only includes
  `prod/`, so the platform keeps reconciling prod at the root and renders exactly what it rendered
  before, while dev reconciles `./dev`.

  The shared publisher pins the image in `deploy/base/` when that folder exists. A product that
  publishes through it restructures only once its publisher pin carries that change, because the
  release would otherwise fail before publishing. KHoist's controller ships as a Helm chart, not
  from `deploy/`, so its layout is settled in
  [khoist#610](https://github.com/devantler-tech/khoist/issues/610).
