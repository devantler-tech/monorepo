---
name: maintain-cloudflare
description: Product card for devantler-tech/cloudflare, the declarative owner of the suite's Cloudflare resources that must exist before the platform can start. Use when the Agentic Engineer selects cloudflare.
---

# Maintain: Cloudflare bootstrap owner

`devantler-tech/cloudflare` declares the Cloudflare resources the suite depends on before its
platform, Flux or Crossplane can run — DNS, certificate issuance and backup storage. It exists
outside the cluster deliberately: its automation and state must not depend on the platform it
bootstraps. It is **not a submodule** of this monorepo yet, so work there is API-first and a code
change is an ordinary draft PR **in that repository**. The ownership rules and the remaining
rollout live on [monorepo#3274](https://github.com/devantler-tech/monorepo/issues/3274).

**Read the repository's visibility live before every run touches it** —
`gh api repos/devantler-tech/cloudflare --jq .private` — never from this card or from memory; the
map deliberately records no visibility. While that read is `true`:

- **Nothing from it reaches a public surface.** Its issues are not boarded on project 5 (a private
  repo's item on the public board is a maintainer decision), and no file content, plan output,
  account detail or resource inventory read from it enters a public issue, PR body, comment or
  report — the sanitised-minimum rule in the monorepo [`AGENTS.md`](../../../../AGENTS.md) applies
  in full.

## Merge mechanics

- **No merge queue** (org rulesets confirmed 2026-09-12) — trusted authors merge directly with the
  head-pinned command from *Merge policy* once `CLEAN`.
- The `main` ruleset requires the `CI - Required Checks` status, so the repository's CI must keep
  producing that aggregate job; a `BLOCKED` PR with every check green is that check missing, not a
  review problem.

## Authority boundary

**Never make automation authoritative over live resources on your own.** Existing resources must be
imported and a **no-destroy plan read by a human** before the first apply; that needs credentials
and a maintainer decision, so a bootstrap or import PR stays a draft on that named blocker however
green it is. Engineering around it — CI, pins, docs, tests that need no credentials — is ordinary
work.

## First advance slices

1. **The missing `AGENTS.md`** with a `## Maintenance` section (validate command, release flow,
   protected files), so this card can shrink to the thin pointer every other product has. Until it
   exists, read the repository's own CI workflow for the validate command and never claim one from
   memory.
2. **Dependency automation**, tracked in that repository, so its pins are maintained like the rest
   of the portfolio.

## Roadmap & enhancement

The roadmap lives in **GitHub Issues** on `devantler-tech/cloudflare`, under the ownership epic
above. Advance it with [`product-engineering`](../../product-engineering/SKILL.md), keeping findings
private.
