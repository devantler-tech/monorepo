# Portfolio architecture records

[`adr/`](adr/) holds this monorepo's numbered architecture decisions. Website source and its
editorial standard are owned by [business-site](https://github.com/devantler-tech/business-site),
checked out at `applications/business-site`.

The old website files in this directory are temporarily retained as a frozen recovery snapshot.
They are not edited or published independently. They are removed only after the new publisher's
successful deployment and live source/caller receipt are verified under
[#3086](https://github.com/devantler-tech/monorepo/issues/3086).

The existing monorepo Pages workflow publishes that application's committed Gitlink through a
separately pinned reusable publisher. A reviewed source merge alone is not a live deployment.
[ADR 0007](adr/0007-business-site-source-ownership.md) defines source, publication and recovery
boundaries. Company/contact follow-up [#3917](https://github.com/devantler-tech/monorepo/issues/3917)
remains separate; no company or contact facts are invented as part of this repository move.
