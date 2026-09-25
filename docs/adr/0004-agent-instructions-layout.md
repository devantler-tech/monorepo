# ADR 0004 — A small always-on AGENTS.md, with guides read on demand

- **Status:** Accepted
- **Date:** 2026-09-25
- **Deciders:** maintainer direction (interactive session, 2026-09-25)
- **Issue:** [#2726](https://github.com/devantler-tech/monorepo/issues/2726)

## Context

`AGENTS.md` is the one file every agent session in this repository loads: Claude Code through the
`CLAUDE.md` → `@AGENTS.md` shim, Codex, Copilot, Cursor and CodeRabbit directly. It had grown to
495 KB — 5,592 lines, roughly 125,000 tokens — because each rule and the evidence behind it were
appended to that single file.

That size had two costs:

- **Codex read only the first 6.6% of it.** Codex reads at most 32 KiB of project instructions by
  default (`project_doc_max_bytes`) and silently drops the rest. Its lanes stopped reading partway
  through the plugin-contract table, before the trust gate, untrusted-input, egress and git-safety
  rules.
- **Claude paid for all of it on every turn.** Every session and every subagent dispatch loaded the
  whole file, whatever the task. Claude Code's guidance is to keep an always-loaded instruction file
  under about 200 lines and to move procedures and area-specific rules into skills or path-scoped
  rules, because imported files load at launch too.

[#2726](https://github.com/devantler-tech/monorepo/issues/2726) found that rules and their evidence are
interleaved inside the same paragraphs, so separating them would mean rewriting paragraph by paragraph.
That route changes the wording of rules the contract tests pin, one paragraph at a time.

## Decision

Reduce what is **always loaded**, not what is written. Sections move whole and unedited into topic
guides that an agent reads when its work needs them.

| Layer | Holds | Loaded |
|---|---|---|
| Root `AGENTS.md` | the portfolio and stack maps, the deployment facts the plugin resolves by section name, the work-selection ladder, the rules that always apply, and an index of the guides with *read it before…* triggers | every session |
| `.claude/guides/*.md` | the full text of each topic: procedures, edge cases and the evidence behind each rule | on demand, named by the index and by the run procedure |
| Nested `AGENTS.md` (`docs/`, `.claude/scripts/`) | instructions for one directory, next to its code | when working there |
| Product submodules | each product's own `AGENTS.md` with its `## Maintenance` section | in that repository |

Guides live under `.claude/`, which already holds this deployment's scripts, plugin-consumption files
and overlays. Moving a section is lossless: only heading levels and relative link targets change, and
a script verified that every moved line survived.

`.claude/scripts/agent-instructions-layout-contract.test.sh` enforces the layout: a 29 KiB budget for
the root, Codex's 32 KiB limit for the root plus any nested file, an exact match between the guide
index and `.claude/guides/`, resolving links and anchors, and the sections other tools look up by
name staying in the root. `.claude/scripts/contract-text.sh` prints the assembled contract for tests
that assert rules spanning several guides.

## Consequences

- Codex now reads the whole always-on core, and the resident context of a Claude session or subagent
  falls by about 94%.
- A rule that every session must follow belongs in the root; everything else belongs in a guide. A
  change to a rule updates its root summary and its guide in the same pull request.
- Contract tests read the guide that holds their rule, or the assembled contract, instead of assuming
  one file.
- Condensing the guides themselves and moving generic role prose to its upstream owner
  ([#2363](https://github.com/devantler-tech/monorepo/issues/2363)) remain separate work; neither is
  needed for the resident saving.
