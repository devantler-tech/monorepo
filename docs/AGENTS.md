# AGENTS.md — portfolio architecture records

The root [AGENTS.md](../AGENTS.md) applies. This directory owns the monorepo's
architecture decisions in `adr/`, numbered `NNNN-title.md`; do not add website source here.
Describe present-state architecture and rationale. Preserve dated ADR records as history.

The legacy website files are a frozen migration snapshot, not a second maintained product.
Keep them until the new publisher has a successful deployment and live source/caller receipt.
Then remove that snapshot in a reviewed cleanup under monorepo#3086, retaining this file and ADRs.

The public website is `applications/business-site`, owned by `devantler-tech/business-site`.
Read that repository's `AGENTS.md` and `docs/AGENTS.md` before editing site content or code.
Its recurring work is defined by the [business-site product card](../.claude/skills/products/business-site/SKILL.md).
Validate aggregator changes with `.claude/scripts/run-affected-tests.sh`; website validation
uses the source owner's Node 24 production build and focused contracts.
