# ADR 0007: Business-site source ownership and Pages publication

Status: Accepted

## Context and decision

`devantler-tech/business-site` owns the unified website and portal implementation,
Astro source, bilingual catalogue, Journal, assets, application checks and dependency
audits. It also owns GitHub Pages and the `devantler.tech` domain.

The source-owned `publish-site.yaml` publishes its exact main-event revision on main
pushes, daily public portfolio refreshes and explicit manual publication. Artifact-only
manual preview is isolated from production. Publication requires the source switch and
a protected environment admitting branch `main` only. The public receipt binds the
source repository, source revision and its own workflow run/attempt; there is no
monorepo caller or separate reusable-workflow pin.

The monorepo aggregates a reviewed product gitlink at `applications/business-site`.
It retains portfolio architecture records and genuine joins against its full submodule
inventory and current automation owner. It neither builds nor triggers website
publication. Source CI owns application tests and builds.

Static Pages publication does not deploy the private portal backend, identity,
customer isolation, agreements or payments. Those remain separate delivery gates.

## Consequences and recovery

A source merge, successful deployment and verified live visitor paths are separate
outcomes. Monorepo pin updates do not publish the website. Normal content recovery
is a reviewed source change followed by its own deployment and live receipt checks.

The controlled ownership transfer and rollback procedure is recorded in business-site
ADR 0003. The old monorepo Pages resource is retained without the domain for bounded
rollback; its disabled publisher is retired only after replacement live proof.
Git history preserves the original website and former caller. There is no second
maintained application tree under this repository's `docs/`.

## Source-owned replacement evidence

Business-site [#28](https://github.com/devantler-tech/business-site/pull/28) merged as
`460b39c5150d401738ad91ebdb5cdc14b80c2edb`. Artifact-only main preview
[37995820155](https://github.com/devantler-tech/business-site/actions/runs/37995820155)
succeeded with deployment skipped. Production
[37996176833](https://github.com/devantler-tech/business-site/actions/runs/37996176833)
succeeded before the domain transfer.

The actual live HTTPS receipt identifies that source, run 37996176833, attempt 1,
publish mode and no monorepo caller. Pages settings identify business-site as the
verified domain owner with an approved certificate and HTTPS enforced. Actual browser
checks cover EN/DA Home and Projects, the English Journal and a keyboard-opened
article, theme continuity, Danish 390px layout and the completed-projects URL redirect
to Projects research. The Danish navigation accurately labels the Journal as English.

Historical extraction and snapshot-retirement evidence remains in merged
monorepo #4056 and #3086. That former source/caller publication is not current
source-owned deployment proof.
