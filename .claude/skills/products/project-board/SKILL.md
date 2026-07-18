---
name: maintain-project-board
description: Maintenance + advance task menu for the 🌊 Project Board (org project 5) — the maintainer's single cross-portfolio navigation surface. Covers coverage, hierarchy, status hygiene, views, and the roadmap axis. Use when the daily maintainer selects the project board on rotation, or when a survey shows board drift.
---

# Maintain: 🌊 Project Board (org project 5)

**[github.com/orgs/devantler-tech/projects/5](https://github.com/orgs/devantler-tech/projects/5)** is a
**product**, not a byproduct — it is the maintainer's *single* surface for seeing what exists, what is
moving, and where it is headed across ~20 repos. It gets the same continuous-enhancement treatment as
every other product: it participates in the normal rotation, it has a roadmap, and drift in it is a
defect (maintainer direction 2026-07-18).

Its users are the maintainer and the agent instances. **Judge it the way a user would: open it and ask
"can I tell what is happening here?"** — not "is the data technically present". A board that is
accurate but unreadable has failed.

Shared cross-repo rules live in the monorepo [`AGENTS.md`](../../../../AGENTS.md) — in particular
*Issue hierarchy* and *Every issue belongs on the board*, which are binding on **every** run whatever
product it is working on. This card is the place where the board itself gets *improved*.

## Health checks (the operate half — cheap, every rotation)

Run these as a survey pass; each has a known-good answer.

| Check | Query | Healthy |
|---|---|---|
| **Coverage** | open issues in active repos vs. items on the board | 100% |
| **Status hygiene** | board items with no `Status` | 0 |
| **Hierarchy** | open issues with a prose `Part of #N` but no real parent link | 0 |
| **Dangling parents** | `Part of` references resolving to a PR, to self, or to nothing | 0 |
| **Stale epics** | epics at `Sub-issues progress` 100% but still open | 0 (close or extend) |
| **Archive** | closed/merged items still active on the board | aged out per the rule |

Coverage and hierarchy are the two that silently rot, because **auto-add is forward-only and capped at
5 workflows on the Team plan** — see [monorepo#2237](https://github.com/devantler-tech/monorepo/issues/2237).
Until that is solved, backfill is a standing duty, not an exception.

## What "advance" means here

- **Views.** The board must carry at least a **kanban (board)**, a **backlog (table)** and a **roadmap
  (roadmap)** view, and should grow more as they earn their place (an epic-breakdown view grouped by
  `Parent issue`; a per-product slice; a triage view). ⚠️ **Views are UI-only — there is NO GraphQL or
  `gh` mutation to create or edit one.** Field and option changes are scriptable; view changes are the
  maintainer's click or nothing. Propose view changes precisely (layout, filter string, grouping,
  visible fields) so applying them is mechanical.
- **Status semantics.** Options run **✅ Done → 🚀 In Finalization → 🏃🏻‍♂️ In Progress → 🫴 Ready →
  📥 Backlog → 🧊 Icebox**. The order is **deliberately reversed** — finishing work sits leftmost, so the
  board reads *stop starting, start finishing* (maintainer direction 2026-07-18). **Never re-order it
  into left-to-right flow.** Column **limits** encode the same WIP discipline; treat an over-limit column
  as a signal to finish, never as a reason to raise the limit.
- **The roadmap axis.** A roadmap layout plots **date or iteration fields only** — it does **not** render
  hierarchy. The `Year` iteration field (2026/2027/2028) is the current coarse axis and is assigned **on
  evidence of activity**, never by assumption. Finer `Start date`/`Due date` values encode *the
  maintainer's intent* — **do not invent them**; propose a sequence and let him drag, or ask.
- **Fields.** 50-field cap per project. Prefer an **org-level issue field** over a project field when the
  value should be identical everywhere (25/org) — project fields are per-board by design.
- **Insights.** Charts exist and are underused. Note the trap: **archived items are excluded from Insights
  entirely**, so an aggressive archive rule silently truncates historical burn-up.

## Mutation safety

- `updateProjectV2Field` with `singleSelectOptions` **replaces the whole option list** — always pass the
  existing option **`id`**s or every assignment is destroyed. Verify emoji codepoints after writing
  (🫴 Ready is **U+1FAF4**; a wrong codepoint silently rewrites the option name).
- Adding an item and setting its fields are **two separate calls** — you cannot do both at once.
- **Pace bulk work**: ~80 content-generating requests/minute, 500/hour. Serialize; never fan out.
- The board is **public**. Adding items from **private** repos is a maintainer decision, not an
  agent default.

## Roadmap & enhancement

Roadmap lives in **GitHub Issues on `devantler-tech/monorepo`** (`roadmap` label, board-related). Current
open work: [#2236](https://github.com/devantler-tech/monorepo/issues/2236) (dangling parent references),
[#2237](https://github.com/devantler-tech/monorepo/issues/2237) (coverage independent of the auto-add
quota), [#2238](https://github.com/devantler-tech/monorepo/issues/2238) (auto-archive archiving nothing).

The strategic frame: *what can the maintainer still not see at a glance?* Answer that, and the board has
advanced.
