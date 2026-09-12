---
name: maintain-cloudflare
description: Product card for devantler-tech/cloudflare, the declarative owner of the suite's Cloudflare resources that must exist before the platform can start. Use when the Agentic Engineer selects cloudflare.
---

# Maintain: Cloudflare bootstrap owner

`devantler-tech/cloudflare` declares the Cloudflare resources the suite depends on before its
platform, Flux or Crossplane can run — DNS, certificate issuance and backup storage. It deliberately
exists outside the cluster: its automation and state must not depend on the platform it
bootstraps. The ownership rules and the remaining rollout live on
[monorepo#3274](https://github.com/devantler-tech/monorepo/issues/3274).

## Working on it

It is **not a submodule** of this monorepo, so the usual initialise-the-submodule-then-add-a-worktree
path cannot reach it — never run `submodule-init.sh` for it.

- **API-only work** (triage, review, comments) needs no checkout.
- **A code change** gets its own clone: `.claude/scripts/safe-clone.sh devantler-tech/cloudflare
  <scratch-dir>`. Acquire the issue claim against that clone
  (`.claude/scripts/agent-claim.sh acquire <issue> --repo-dir <clone>`), create the claimed work
  branch there with `.claude/scripts/worktree-claim.sh add <clone> ...`, and open an ordinary draft
  PR **in that repository**.

## Visibility decides what may be published

Read it live before every run touches the repository —
`gh api repos/devantler-tech/cloudflare --jq .private` — never from this card or from memory; the
map deliberately records no visibility.

- **While that read is `true`**, nothing read from the repository reaches a public surface —
  including this card and any other file committed to this monorepo. That covers its workflow and
  CI details, rulesets and required checks, plan output, account details and resource inventory:
  keep them in private operator notes. Its issues are not boarded on project 5, and the
  sanitised-minimum rule in the monorepo [`AGENTS.md`](../../../../AGENTS.md) applies in full.
- **If it turns `false`**, its issues join the ordinary board sweep and findings are published like
  any public repository's.

## Merge mechanics

Read them live each time — whether a merge queue is in use and which status checks `main` requires —
rather than from this card, and merge with the head-pinned command from *Merge policy*. A `BLOCKED`
PR with every check green is most often **unresolved review threads**, which no check reports: read
`reviewThreads` first, and only then suspect a required check that the repository's CI never
produces.

## Authority boundary

**Never make automation authoritative over live resources on your own.** Existing resources must be
imported and a **no-destroy plan read by a human** before the first apply; that needs credentials
and a maintainer decision, so a bootstrap or import PR stays a draft on that named blocker however
green it is. Engineering around it — CI, pins, docs, tests that need no credentials — is ordinary
work.

## First advance slices

1. **An `AGENTS.md` with a `## Maintenance` section** (validate command, release flow, protected
   files), so this card can shrink to the thin pointer every other product has. Until it exists,
   read the repository's own CI workflow for the validate command and never claim one from memory.
2. **Dependency automation**, so its pins are maintained like the rest of the portfolio.

## Roadmap & enhancement

The roadmap lives in **GitHub Issues** on `devantler-tech/cloudflare`, under the ownership epic
above. Advance it with [`product-engineering`](../../product-engineering/SKILL.md); what may be
published about that work follows the visibility rule above.
