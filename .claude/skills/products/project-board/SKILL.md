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

- **Views — exactly three, and resist adding a fourth.** The board carries a **kanban (board)**, a
  **backlog (table)** and a **roadmap (roadmap)** view. **Epic breakdown is a *grouping* on the
  Backlog view (group by `Parent issue`), NOT a separate view** — maintainer direction 2026-07-18,
  when a proposed fourth "By epic" view was folded into the Backlog instead. The principle
  generalises: **prefer an extra grouping, slice or filter on an existing view over a new view.**
  Every additional view is another surface to keep honest and another place for the maintainer to
  look; a board with three well-configured views beats one with seven overlapping ones. Add a fourth
  only when a genuine audience or cadence cannot be served by grouping an existing view.
  ⚠️ **Views are UI-only — there is NO GraphQL or `gh` mutation to create or edit one** (`ProjectV2View`
  is a read-only type; `gh project` has no view subcommand). Field and option changes are scriptable;
  view changes need a browser with the maintainer's session. Propose them precisely (layout, filter
  string, grouping, visible fields) so applying them is mechanical.

  **Current configuration** (verified live 2026-07-18):

  | View | Layout | Filter |
  |---|---|---|
  | 🧮 Kanban | Board | `is:issue is:open -status:"✅ Done" no:sub-issues-progress` |
  | 📋 Backlog | Table | `is:issue is:open no:parent-issue` |
  | 🗺️ Roadmap | Roadmap | `is:issue is:open label:roadmap no:parent-issue` |

  **Each view shows one layer of the hierarchy, and only one** (maintainer direction 2026-07-18):
  **Kanban = leaves only** (`no:sub-issues-progress`) — a parent is resolved by finishing its children,
  so an epic is never something you drag across a board; **Backlog = top-level only**
  (`no:parent-issue`) with children reached by *expanding* the hierarchy, never listed as sibling rows;
  **Roadmap = top-level strategic items**. Excluding parents from Kanban dropped it 193 → 166 (exactly
  the 26 epics); excluding children from Backlog leaves 156 top-level rows.

  **The board tracks ISSUES, not PRs** (maintainer direction 2026-07-18): a PR that closes an issue
  moves that issue through the ladder via the linked-PR workflow, so showing both double-counts the
  same work — dropping `,pr` took the Ready column from 8/5 to a true 2/5. **This makes
  `Fixes #N` load-bearing for visibility, not just bookkeeping:** an agent-authored PR with no linked
  issue is now *invisible on the board*, so the capture-before-you-build rule is what keeps the board
  complete. When a substantive PR has no issue, the fix is to file/link the issue — never to put PRs
  back on the board. Dependency-automation PRs correctly disappear: they are automation-owned and
  need no action, so they were only ever noise on a planning surface.

  Backlog has **Show hierarchy = On**, which nests sub-issues under their parents inline (up to 8
  levels) — that is what makes it the by-epic view; do not add a `Parent issue` group-by on top, and do
  not turn the toggle off. Roadmap binds Start/Target to the **`Year` iteration's `Year start`/`Year
  end`**, zoom Year, with the Year marker on; items without a Year show an unscheduled `+` placeholder,
  which is the honest rendering of "not scheduled".

  **Hierarchy filters — use the FIELD name, and get it from the UI, not from docs.** The working
  qualifiers are **`has:sub-issues-progress`** (is a parent) / **`no:sub-issues-progress`** (is a leaf),
  and `has:parent-issue` / `no:parent-issue` / `parent-issue:owner/repo#N`. They key off the *project
  field* name ("Sub-issues progress"), **not** the issue-search spelling: **`has:sub-issue` is NOT a
  valid project filter** — GitHub silently ignores an unrecognised qualifier rather than erroring, so a
  wrong guess looks like it worked.

  ⚠️ **Two method rules, learned the hard way on 2026-07-18:**
  1. **Never compare item counts across views to test a filter.** Board and table layouts count
     differently — the same stricter filter read 193 on the board and 163 in the table. A cross-view
     comparison produced a confidently wrong conclusion (that `has:sub-issue` was being ignored *and*
     that no parent filter existed). **Always A/B a filter within ONE view.**
  2. **Type `no:` into the filter box to get the authoritative qualifier list.** GitHub autocompletes
     every supported field; picking from that list inserts the exact syntax. That is faster and more
     reliable than docs, which do not enumerate project-field qualifiers.
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
