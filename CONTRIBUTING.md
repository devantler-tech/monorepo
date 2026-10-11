# Contributing to the portfolio aggregator

This repository links independently maintained products; it is not their shared build or release
pipeline. A useful first contribution is a clearer aggregator explanation or an architecture-record
link. Product fixes belong in the [owning repository](AGENTS.md#portfolio-map), not in an unrelated
aggregator PR. Discuss substantial changes in an [issue](https://github.com/devantler-tech/monorepo/issues)
first. Do not post credentials, private product content or sensitive operational details.
For a sensitive vulnerability, use this repository's private
[Report a vulnerability](https://github.com/devantler-tech/monorepo/security/advisories/new) form,
not a public issue or PR.

## Make a first documentation change

You need Git, Bash, `jq`, [Mike Farah's `yq` v4](https://github.com/mikefarah/yq), and Go to run the
selected checks. The guard module declares Go 1.24.0 as its minimum; use a compatible Go toolchain.
A cold Go cache needs network access to download its public dependencies. The unrelated Python
`yq` package is not a substitute. The first change below needs no submodules, application runtime,
cluster or organization token.

Fork `devantler-tech/monorepo` on GitHub. Replace `YOUR-LOGIN` with your login, then clone only the
aggregator and branch from the upstream default branch:

```sh
git clone https://github.com/YOUR-LOGIN/monorepo.git
cd monorepo
git remote add upstream https://github.com/devantler-tech/monorepo.git
git fetch upstream +refs/heads/main:refs/remotes/upstream/main
git switch -c docs/first-contribution upstream/main
```

Make a small wording correction in `README.md`, without changing the helper commands or project
ownership. Preview it as Markdown, then run from the repository root. Set `LC_ALL=C` for the
byte-oriented shell scanners so their interpretation is consistent across macOS and Linux:

```sh
LC_ALL=C bash .claude/scripts/run-affected-tests.sh --base upstream/main --list
LC_ALL=C bash .claude/scripts/run-affected-tests.sh --base upstream/main
git diff --check
```

The first command lists tests selected from the checked-in CI workflow; the second runs those tests
and reports their results. Every selected test and the diff check must pass. An empty selection
is reported explicitly and is not proof that all repository tests ran. Some other changes select
tests with additional prerequisites; follow their CI setup and the
[test-running guide](.claude/scripts/AGENTS.md#running-the-tests). Do not loop over every shell test
or disable a failing check. Native CI and review remain separate submission gates.

## Choose the right scope

- Aggregator guides and source pins belong here. Architecture decisions live under
  [`docs/adr/`](docs/adr/); read [`docs/AGENTS.md`](docs/AGENTS.md) before changing them.
- Product source, tests, deployment and release documentation belong in that product's repository.
  Read its README, CONTRIBUTING and repository contract, and use its own current default branch.
- For a project checkout inside this aggregator, use the [selective setup](README.md#getting-started)
  and [isolation procedure](.claude/worktree-isolation.md). A detached Gitlink pin is intentional;
  do not treat it as an editable branch or silently advance it as part of an unrelated PR.
- Parallel agent sessions must own a claimed, isolated worktree before edits, following the
  [worktree guide](.claude/guides/git-and-worktrees.md). Never edit a shared checkout, hand-edit
  generated files, stage unrelated paths or discard another session's work.

## Submit your change

Review the diff, configure commit signing, and stage only your changed paths. Use a Conventional
Commit subject describing the reader-facing outcome:

```sh
git add README.md
git commit -S -m "docs: clarify selective project setup"
git push -u origin docs/first-contribution
```

Open a **draft** PR from your fork's branch to `devantler-tech/monorepo:main`. Use the inherited
[PR template](https://github.com/devantler-tech/.github/blob/main/.github/PULL_REQUEST_TEMPLATE.md),
keep its Why/What sections focused on the reader-facing problem and outcome, and link the issue
for substantial work. Record detailed validation evidence in a PR comment or check summary, not
in those sections. Disclose AI assistance when used; autonomous Agentic Engineer artifacts
use the disclosure required by [AGENTS.md](AGENTS.md#maintainer-channels).

Address review findings. Required CI and a substantive review of the exact current head must pass
before merge; a draft or local check alone is not delivery. Follow the inherited
[code of conduct](https://github.com/devantler-tech/.github/blob/main/.github/CODE_OF_CONDUCT.md).
Product licenses and third-party attribution remain with their owning repositories; this aggregator
does not grant a blanket license for every linked project.
