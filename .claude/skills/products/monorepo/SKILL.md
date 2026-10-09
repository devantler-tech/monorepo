---
name: maintain-monorepo
description: Maintenance menu for the portfolio aggregator, its agent tooling and cross-product contracts. Website source and publication belong to business-site.
---

# Maintain: Portfolio aggregator

**Repo** `devantler-tech/monorepo` · **path** repo root · **Issues ENABLED**.
Read the root [`AGENTS.md`](../../../../AGENTS.md) and its named guides. Use registered writer
namespaces, isolated worktrees, issue claims and reviewed signed commits; never sweep unrelated pins.
For existing claims, ignore a PR hit whose only issue reference is a foreign `owner/repo#<issue>`;
retain a hit that also names the local issue.

## Repo-specific conventions

- **Labels** (apply only from this set): `automation`, `documentation`, `github_actions`, `dependencies`, `submodules`, `bug`, `enhancement`, `question`, `duplicate`, `wontfix`, `needs triage`, `needs investigation`, `performance`, `refactor`, `security`, `repo-assist`, `roadmap`, `good first issue`, `help wanted`, `spam`, `blocked`, `next`.
  Read live taxonomy before applying labels. The label allowlist remains guarded by
  `.claude/scripts/product-value-contract.test.sh`.
- **Validate:** `.claude/scripts/run-affected-tests.sh`; workflow changes also need `actionlint`.
- **Ownership:** site source, dependency audits, Site QA, Content Sync and Blog Stewardship belong
  to the [business-site card](../business-site/SKILL.md), not a second monorepo content lane.

## Task menu

- **CI Doctor:** diagnose actual current-main and PR failures in this repository, including dead
  submodule pins; fix at the root and retain exact-head evidence.
- **Portfolio integration:** join the pinned site's documented inventory to this repository's
  actual submodules, Actions and templates. Initialize only required public submodules through
  the isolation-safe helper. Bind `GITHUB_WORKSPACE` to this aggregator and `SITE_ROOT` to its
  website submodule when running the site's drift checker locally. An unreadable source is
  unknown, never a clean empty inventory.
- **Website aggregation:** adopt a reviewed business-site commit without implementing its build
  or triggering publication. The source repository owns Pages, the public domain and refreshes.
  Source merge, successful source-owned deployment and live source/run receipt plus English/Danish
  visitor paths are separate gates; never close website delivery on a source merge alone.
- **Repo Assist:** triage issues and drive open drafts through current-head CI, ordered review,
  promotion and protected head-pinned merge. Keep architecture decisions in `docs/adr/`.
- **Dependency PRs:** when one cannot finish autonomously, diagnose, repair, and merge it as
  trusted rung-one work under the root contract; do not bundle unrelated updates.

Memory remains native; there is no checked-in status dashboard. Existing blog and website cursors
continue under the website owner; do not reset cadence or create competing experiments on transfer.
