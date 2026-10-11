# 🗂️ Devantler's Monorepo

Every project I actively work on, gathered in one place.

The public [Devantler Tech website](https://devantler.tech) is owned by
[business-site](https://github.com/devantler-tech/business-site), checked out at
`applications/business-site`. Its source, checks and independent GitHub Pages publication live
there; this monorepo aggregates a reviewed source pin without triggering publication. Repository-wide
architecture decisions stay in [`docs/adr/`](docs/adr/).

Each project stays its own repository and is linked here as a *submodule*: a pointer to a reviewed
commit in that repository. A normal clone contains the aggregator's guides and those pointers,
not every project's files. Populate only the projects you need; each keeps its own access,
contribution rules, issues and releases.

## Getting started

You need Git to read the aggregator. The public checkout does not require SSH credentials or
access to every project:

```sh
git clone https://github.com/devantler-tech/monorepo.git
cd monorepo
git submodule status
```

An initial `-` beside a project means its checkout is not populated; it is not a clone failure.
See the [portfolio map](AGENTS.md#portfolio-map) for project ownership, or start with
[`docs/`](docs/README.md) for aggregator architecture records.

To read a project's pinned source inside the aggregator, you also need Bash and access to that
repository. For example, the public website submodule uses HTTPS:

```sh
bash .claude/scripts/submodule-init.sh applications/business-site
```

Most other entries in [`.gitmodules`](.gitmodules) use SSH and therefore need GitHub SSH
authentication; some repositories require additional access. HTTPS works for public repositories
and can also authenticate private access. Initializing every submodule is optional, not a public
onboarding requirement. Prefer a project's own public repository and contribution guide when you
want to change that product rather than inspect the aggregator's pin.

## Working safely with pinned projects

Use `submodule-init.sh`, not bare `git submodule update --init` or a recursive clone. The helper
populates the selected repository at its recorded pin, repairs Git worktree configuration, and
checks isolation. The plain Git initialization path can leave parallel sessions resolving to the
same physical folder. Read [worktree isolation](.claude/worktree-isolation.md) before project edits.

A detached checkout at the recorded commit is expected. It is a source snapshot, not your work
branch: create an owned, isolated work branch from the product's fresh default branch before editing
it. The [contributor guide](CONTRIBUTING.md) separates aggregator and product contributions.

Each project is pinned to a specific commit, and your checkout stays on that pin. Automated pull
requests here move the pins forward, but **your existing checkout does not follow — and re-running
the init script will not move it either.**

That is deliberate: the script only populates projects that are empty, and leaves already-populated
ones alone so it can never discard work you have sitting in one. After you pull a pin bump and want
the checkout to follow, advance it explicitly:

```sh
bash .claude/scripts/submodule-init.sh --advance applications/business-site
```

That checks out the pin recorded at `HEAD` for `<path>`, repairs isolation, and probes — without
running `git submodule update`, which would rewrite shared `core.worktree`. It refuses a dirty tree
or a checkout that is ahead of the pin, so uncommitted or unpushed work is never discarded. See
[worktree isolation](.claude/worktree-isolation.md) for why that matters.

`bash .claude/scripts/submodule-init.sh --check` probes populated submodule worktrees. It creates
and removes its own temporary probe checkout; it is not a check of uninitialized projects or a
strictly read-only operation. Use `--all` only when you intentionally want every project and have
the required access.

## Contributing

Start with [CONTRIBUTING.md](CONTRIBUTING.md) for a small aggregator documentation change that
needs no project checkout. Product changes belong in their owning repository. Maintainer changes
to the project catalogue, Gitlinks or agent deployment should follow the relevant
[repository contract](AGENTS.md#agent-guides), rather than the first-contribution path.
