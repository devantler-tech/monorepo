# Portfolio architecture records

[`adr/`](adr/) holds this monorepo's numbered architecture decisions. Website source and its
editorial standard are owned by [business-site](https://github.com/devantler-tech/business-site),
checked out at `applications/business-site`.

The former website snapshot is retired after replacement publication under
[#3086](https://github.com/devantler-tech/monorepo/issues/3086). Git history retains the original
source and assets; this directory is not a second maintained or publishable application.

The existing monorepo Pages workflow publishes that application's committed Gitlink through a
separately pinned reusable publisher. A reviewed source merge alone is not a live deployment.
The same publisher refreshes the complete public project ranking at 00:13, 06:13, 12:13 and
18:13 UTC, using the default-branch event's exact caller revision and its committed source pin.
Projects shows the actual metadata observation time. GitHub may delay or disable scheduled runs;
this is not a freshness SLA. An incomplete or failed upstream metadata read stops publication,
preserving the last successful website instead of deploying partial rankings. No second publisher,
paid data service or chat automation is involved.
[ADR 0007](adr/0007-business-site-source-ownership.md) defines source, publication and recovery
boundaries. Company/contact follow-up [#3917](https://github.com/devantler-tech/monorepo/issues/3917)
remains separate; no company or contact facts are invented as part of this repository move.
