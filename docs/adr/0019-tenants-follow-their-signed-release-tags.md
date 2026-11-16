# ADR 0019: Tenants follow their signed release tags

Status: Accepted.

Date: 2026-11-16

Issue: the epic [#5094](https://github.com/devantler-tech/monorepo/issues/5094)

## Context

Some tenants on the platform pin the exact release they run: business-site and the KHoist
documentation by artifact digest, the KHoist controller chart by digest, and UniFi by Git commit.
Every release of a pinned tenant needs a platform pull request: a new pin, matching lines in the
platform's security ledgers, often a bot pull request that regenerates the publisher bindings first,
and a merge-queue deploy. On 2026-11-15 and 16 business-site shipped six releases this way, each
taking several hours.

The other tenants (AS Coaching, the wedding app, AWS, the GitHub configuration and World at Ruin)
already follow their release tags. They still need a platform approval whenever they move to a new
revision of the shared publisher, which [ADR 0017](0017-products-sign-their-own-releases.md) removes.

A tenant's Flux source and Kustomization also sit inside the platform's `apps` health gate, so a
failing tenant fails `apps`, and with it the platform's own merge-queue deploys.

On 2026-11-16 the maintainer asked that releasing a tenant no longer needs a manual re-pin on the
platform: "Automate this process, or remove it so new changes are automatically pulled in."

## Decision

1. **Every tenant follows its own release tags.** A tenant's Flux source selects the newest signed
   release of its manifests artifact (`ref.semver`) and checks for a new one every minute. Prod takes
   the newest stable release (`X.Y.Z`, no pre-releases). A release changes nothing in the platform
   repository.

2. **The signature is the trust, not the pin.** Under ADR 0017, Flux accepts an artifact only when
   it is keylessly signed by the tenant's own repository's release workflow on a `v<semver>` tag,
   and Kyverno and Talos check the image the same way. Release tags cannot be moved or deleted,
   only the release process may create one, and the publish action signs only tags on `main`. Until
   a tenant signs as itself, its currently approved shared-publisher revisions stay accepted.

3. **A tenant cannot break the platform.** The `apps` layer counts a tenant's Flux source and
   Kustomization as healthy once they exist; their health is the tenant's own. The deploy's
   reconcile already skips tenant Kustomizations, and a `Tenant` instance does not track its
   children's health. Flux refuses an artifact whose signature does not match and dry-runs the
   whole package before it applies anything, so a release that fails either check changes nothing.
   A release that passes them but fails while it is applied, or never becomes healthy, can leave
   part of the package applied; it keeps the old pods serving only through a rollout that keeps
   them until the new ones are ready. So a tenant serves through a rolling update that keeps every
   old pod until its replacement is ready, never `Recreate`. The existing Flux error alert covers
   every tenant source and Kustomization.

4. **Migrations run before the new revision serves, and keep the old one working.** A package that
   changes its database ships the migration as a Job in the package, and its new revision becomes
   ready only once the schema it needs exists. Old pods keep serving until then, and again after a
   roll-forward fix, so a migration only adds what the new revision needs; removing what the old
   revision reads waits for a later release. Business-site does this today.

5. **Roll forward, or pin in an emergency.** A bad release is fixed by the next release. To stop on a
   known-good release, set the tenant's version to that one release (`version: "3.12.0"` on a
   `Tenant`, `semver: "3.12.0"` on a hand-written source) in a normal platform pull request, and
   remove the pin once a fixed release exists. While that pull request is on its way, the maintainer
   may suspend the tenant's Kustomization (`flux suspend kustomization <tenant> -n <tenant>`). Once
   the pin is live, they resume it only after the tenant's source reports Ready with the pinned
   version (`kubectl -n <tenant> get ocirepository <tenant>`), so the Kustomization never re-applies
   the bad artifact it still holds. A release tag is never moved or deleted to roll back.

6. **Dev follows every signed release, prod the stable ones.** Dev selects the newest release
   including pre-releases, prod the newest stable release. Both update by themselves. Every signed
   tag is on `main` (ADR 0017), so dev shows merged work. The `Tenant` environment input of
   [platform#6126](https://github.com/devantler-tech/platform/issues/6126) selects the range.

7. **The re-pin machinery goes.** The digest and publisher-revision fields of the `Tenant` source,
   the publisher source bindings and the scripts, workflow and bot pull requests that maintain them,
   and the per-release ledger lines are deleted. The shared-publisher approval lists follow under
   ADR 0017 once the last tenant signs as itself.

8. **The release and Flux are the record.** What runs is the tenant's release (its tag, notes and
   signed artifacts) and the revision Flux reports: `kubectl -n <tenant> get ocirepository,kustomization`
   shows `<version>@sha256:<digest>`, and Flux events and alerts record each change and failure.

## Options compared

- **Automate the re-pin.** A bot opens and merges the pin pull request for each release. The
  platform repository keeps a record of each release, but every tenant release still waits for a
  platform merge-queue deploy and keeps the ledgers, so the tenant stays coupled to the platform.
- **Flux image automation writes the pin back to Git.** The same coupling, plus a cluster that can
  write to the platform repository.

## Consequences

- A tenant release reaches prod within a few minutes of publication, with no platform change.
- The platform repository no longer says which tenant release runs; the cluster and the release do.
- A platform change that breaks a tenant no longer fails the merge-queue deploy. The tenant's alert
  reports it, and the tenant keeps running its last good release.
- [platform#6377](https://github.com/devantler-tech/platform/issues/6377) (exact-digest promotion for
  own-release tenants) is superseded: an emergency pin names one release, checked by the same
  signature rule. [platform#6378](https://github.com/devantler-tech/platform/issues/6378) is fixed
  where tags are admitted: the publish action refuses build metadata, which no release process
  creates and an OCI tag cannot carry.
- Rollout: business-site first (its last manual re-pin, the switch, then signing as itself), then
  the KHoist documentation, the KHoist controller chart and UniFi, each wired so its health stays
  outside `apps`. The tenants already following tags only switch their signing under ADR 0017.

## Amendments

- **2026-11-16: a release starts on the settings the platform already has.** A release goes live as
  soon as it is published, so it can no longer ship in the same pull request as the platform
  settings it reads. Business-site showed the coupling: its v3.13.0 needed two new portal settings
  that its v3.12.0 refused at startup. So:
  - Settings that are not secret ship in the release's own package, beside the app that reads them.
  - The platform supplies only secrets and platform facts, and a tenant's runtime tolerates a key it
    does not know, so the platform can add a key before the release that reads it.
  - A release that needs a key the platform does not have yet keeps that feature off until it
    exists.
- **2026-11-16: check a package against the platform's admission rules before it is released.**
  Flux dry-runs a package against the live admission policies, so a refused release changes nothing,
  but it is found only after publication (business-site v3.9.0 was refused for a Job without
  `runAsNonRoot` on each container). A tenant's CI checks its package against the platform's
  admission policies, so a release that would be refused is not published.
