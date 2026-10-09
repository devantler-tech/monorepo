# ADR 0007: Business-site source ownership and Pages publication

Status: Accepted

## Context

The business website is a portfolio application, independent of the monorepo's coordination tools.
Its public domain and existing GitHub Pages resource do not require a hosting migration.

## Decision

`devantler-tech/business-site` owns the Astro source, bilingual catalogue, journal, assets, local
checks and dependency audits. The monorepo includes it at `applications/business-site` as a pinned
Git submodule and retains portfolio architecture decisions under `docs/adr/`.

The monorepo is the sole Pages deployment caller. It reads the website Gitlink from committed HEAD
and invokes the source repository's reusable publisher at a separately immutable workflow SHA.
The publisher admits only this monorepo's main-branch push or manual dispatch, checks out the exact
source SHA, builds with Node 24, and deploys through the existing caller's Pages environment.
Neither repository inherits arbitrary caller secrets. No DNS, domain, cluster tenant or paid
hosting resource changes are part of this ownership boundary.

## Consequences

A source merge does not publish the site. Delivery requires a reviewed monorepo pin, successful
Pages deployment, and live English/Danish visitor checks. The public publication-source receipt
binds both source SHA and caller SHA; it contains no private deployment information.

Source CI owns site builds, dependency/toolchain checks and editorial contracts. Monorepo CI
retains the real joins against its full submodule inventory and the pinned Actions catalogue, plus
the pin resolver and publication bridge's negative controls.

Git history in the monorepo preserves the website's original commits and assets. The source
repository records the immutable extraction provenance. Recovery reverts the source Gitlink and,
when necessary, the publisher workflow pin together, then redeploys and verifies the live receipt.
The legacy website copy was retained as a frozen recovery snapshot until replacement publication
was proved. It is now removed under monorepo#3086; Git history preserves the original source and
assets. It is never a second maintained source tree or an independent publisher.

## Replacement publication evidence

On 9 October 2026, reviewed monorepo #4056 adopted root-layout business-site source
`ae3a41b912246c078d32a51191ccd4583d490ede`. Pages run
[37916186339](https://github.com/devantler-tech/monorepo/actions/runs/37916186339) succeeded for
caller `f54592a44ea8869a91f59ab6e0d086eacf532f5e`. The actual live publication receipt returned
that source/caller pair, and English/Danish Home and Projects visitor paths were checked before
retiring the snapshot. Recovery remains a reviewed change to both immutable pins followed by
publication and live verification, not restoration of a competing website owner.
