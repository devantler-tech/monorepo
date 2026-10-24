# AGENTS.md — portfolio architecture records

The root [AGENTS.md](../AGENTS.md) applies. This directory owns the monorepo's
architecture decisions in `adr/`, numbered `NNNN-title.md`; do not add website source here.
Describe present-state architecture and rationale. Preserve dated ADR records as history.

`digests/` holds the maintainer's digests, one `YYYY-MM-DD.md` file per delivery date,
written from [`digests/TEMPLATE.md`](digests/TEMPLATE.md) and its rules
([monorepo#4285](https://github.com/devantler-tech/monorepo/issues/4285)). A workflow emails each
one daily only while unanswered asks exist, so check a digest with
`.claude/scripts/maintainer-digest.sh check` before it merges. Answered asks are excluded even
if their issues remain open. A quiet day sends nothing; its dated changelog stays pending and
is combined into following digests containing asks, in batches that fit in an email. Preserve old
ISO-week files as history.
An ask is an issue in this repository labelled `maintainer-ask` and titled `🙋 Ask: <decision>`,
with the sections `### Question`, `### Options` (lettered `A`, `B`, …), `### Recommendation` and
`### If unanswered`. Agents file asks through the API. There is deliberately no issue form: one local
form would hide the organization's shared issue forms in this repository.

The former website snapshot has been retired after successful replacement publication and
live source/caller verification under monorepo#3086. Git history retains it for recovery;
this directory holds architecture records, not a second application source tree.

The public website is `applications/business-site`, owned by `devantler-tech/business-site`.
Read that repository's `AGENTS.md` and `docs/AGENTS.md` before editing site content or code.
Its recurring work is defined by the [business-site product card](../.claude/skills/products/business-site/SKILL.md).
Validate aggregator changes with `.claude/scripts/run-affected-tests.sh`; website validation
uses the source owner's Node 24 production build and focused contracts.
