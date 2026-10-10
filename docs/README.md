# Portfolio architecture records

[`adr/`](adr/) holds this monorepo's numbered architecture decisions. Website source and its
editorial standard are owned by [business-site](https://github.com/devantler-tech/business-site),
checked out at `applications/business-site`.

The former website snapshot is retired after replacement publication under
[#3086](https://github.com/devantler-tech/monorepo/issues/3086). Git history retains the original
source and assets; this directory is not a second maintained or publishable application.

Business-site independently publishes its reviewed default branch through its own Pages workflow
and protected environment. A source merge alone is not a live deployment; the source/run receipt
and actual visitor paths establish delivery. Its own publisher refreshes the complete public
project ranking daily at 06:17 UTC, without a monorepo trigger or implementation checkout.
Projects shows the actual metadata observation time. GitHub may delay or disable scheduled runs;
this is not a freshness SLA. An incomplete or failed upstream metadata read stops publication,
preserving the last successful website instead of deploying partial rankings. No monorepo publisher,
paid data service or chat automation is involved.
[ADR 0007](adr/0007-business-site-source-ownership.md) defines source, publication and recovery
boundaries. Company/contact follow-up [#3917](https://github.com/devantler-tech/monorepo/issues/3917)
remains separate; no company or contact facts are invented as part of this repository move.
