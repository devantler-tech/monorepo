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
| **Coverage** | open issues in active **public** repos vs. items on the board (private-repo items are a maintainer decision, never counted against coverage) | 100% |
| **Status hygiene** | board items with no `Status` | 0 |
| **Type hygiene** | board items whose issue carries no **Issue Type** | 0 (the contract makes a type mandatory; an untyped item is invisible to Kanban/Roadmap type filters) |
| **Hierarchy** | open issues with a prose `Part of #N` but no real parent link | 0 |
| **Dangling parents** | `Part of` references resolving to a PR, to self, or to nothing | 0 |
| **Stale epics** | epics at `Sub-issues progress` 100% but still open | 0 (close or extend) |
| **Archive** | closed/merged items still active on the board | none older than **30 days closed** (archive those; younger ones stay active so Insights keeps its recent history — see the Insights trap below; manual until [#2238](https://github.com/devantler-tech/monorepo/issues/2238)'s auto-archive works) |

Coverage and hierarchy are the two that silently rot, because **auto-add is forward-only and capped at
5 workflows on the Team plan** — see [monorepo#2237](https://github.com/devantler-tech/monorepo/issues/2237).
Until that is solved, backfill is a standing duty, not an exception.

## What "advance" means here

- **Views — exactly three, and resist adding a fourth.** The board carries a **kanban (board)**, a
  **backlog (table)** and a **roadmap (roadmap)** view. **Epic breakdown lives on the Backlog view via
  the `Show hierarchy` toggle, NOT as a separate view and NOT as a `Parent issue` group-by** —
  maintainer direction 2026-07-18, when a proposed fourth "By epic" view was folded into the Backlog
  instead. The principle generalises: **prefer an extra grouping, slice or filter on an existing view
  over a new view.**
  Every additional view is another surface to keep honest and another place for the maintainer to
  look; a board with three well-configured views beats one with seven overlapping ones. Add a fourth
  only when a genuine audience or cadence cannot be served by grouping an existing view.
  ⚠️ **Creating a view is scriptable; EDITING one is not.** REST documents
  **`POST /orgs/{org}/projectsV2/{project_number}/views`** with `name`, `layout`
  (`table`/`board`/`roadmap`), `filter` and `visible_fields` — so a *new* view can be created from the
  API. There is **no documented PATCH/DELETE for a view**, `ProjectV2View` is a **read-only** GraphQL
  type (no view mutations), and `gh project` has no view subcommand — so **changing an existing view's
  filter, layout, grouping or toggles needs a browser** with the maintainer's session. (A GET against
  the views path 404s on this org, so treat the POST as documented-but-unexercised: verify before
  relying on it, and don't create a throwaway view to test — there is no documented way to delete it.)
  Propose view *edits* precisely (layout, filter string, grouping, visible fields) so applying them by
  hand is mechanical.

  **The only browser an agent can DRIVE is Chrome via the Claude extension.** Computer-use grants
  browsers at **read tier only** — screenshots work, clicks and typing are blocked at the OS level —
  so Safari/Firefox/Arc can be *seen* but never operated, by design. Don't burn a round trip
  requesting browser access for a click-through task; check `list_connected_browsers` first, and if
  nothing is connected, say so and offer the tooltip-guided walkthrough instead. When saving a view,
  GitHub prompts *"make it the default for everyone"* — the board is shared, so **every view save is
  a public change**.

  **Current configuration** (verified live 2026-07-18):

  | View | Layout | Filter |
  |---|---|---|
  | 🧮 Kanban | Board | `is:issue is:open -status:"✅ Done" -type:"Epic"` |
  | 📋 Backlog | Table | `is:issue is:open no:parent-issue` |
  | 🗺️ Roadmap | Roadmap | `is:issue is:open type:"Epic" no:parent-issue` |

  **Each view shows one layer of the hierarchy, and only one** (maintainer direction 2026-07-18):
  **Kanban = actionable work only** — a parent is resolved by finishing its children, so an epic is
  never something you drag across a board; **Backlog = top-level only** (`no:parent-issue`) with
  children reached by *expanding* the hierarchy, never listed as sibling rows; **Roadmap = top-level
  Epics**.

  ⚠️ **Filter on `type:"Epic"`, NOT on `no:sub-issues-progress` or `label:roadmap`.** The structural
  filter only excludes epics that have *already* been decomposed — 37 **undecomposed** epics were
  sitting on the Kanban looking like actionable work, because an epic nobody has broken down yet has no
  children to detect. Switching to `-type:"Epic"` dropped the Kanban 166 → 130 and is correct from the
  moment an issue is filed. The label is likewise unreliable: it depends on label hygiene, and `Epic`
  as a type is a superset (62 epics vs 55 roadmap-labelled).

  **The board tracks ISSUES, not PRs** (maintainer direction 2026-07-18): a PR that closes an issue
  stands in for that issue's progress, so showing both double-counts the same work — dropping `,pr`
  took the Ready column from 8/5 to a true 2/5. ⚠️ **No automation moves an issue card from its
  linked PR's state** — native Project workflows act only on the project's own items, and nothing in
  this org updates an issue's Status from PR events. **The agent working the PR moves the issue's
  Status by hand at each lifecycle step** (delivery PR opened → 👀 In Review; self-promoted →
  🚀 Ready to Merge; merged with post-merge verification pending → 📊 Verifying); only the final
  closed→Done move is a built-in workflow. **This also makes
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
- **Status semantics.** Options run **✅ Done → 📊 Verifying → 🚀 Ready to Merge → 👀 In Review →
  🏃🏻‍♂️ In Progress → 🫴 Ready → 📥 Backlog → 🧊 Icebox**, and the **merge is the boundary** between
  *Ready to Merge* (pre-merge, mechanical) and *Verifying* (post-merge, evidential). The order is
  **deliberately reversed** — finishing work sits leftmost, so the board reads *stop starting, start
  finishing* (maintainer direction 2026-07-18). **Never re-order it into left-to-right flow.** Column
  **limits** encode the same WIP discipline; treat an over-limit column as a signal to finish, never as
  a reason to raise the limit. **"Blocked" is intentionally not a status** — use a native issue
  dependency (Blocked badge renders in-place) and reserve the `blocked` label for cross-org blockers.
- **Issue Types are mandatory** — every issue carries exactly one of **Epic, Feature, Bug, Security,
  Performance, Refactor, Docs, Spike, Kata, Chore** (see the contract's *Issue hierarchy* for the
  definition-of-done each implies). An untyped issue is an incomplete issue. Managing the org type
  list needs **org settings in a browser** — a PAT gets 403 on `orgs/<org>/issue-types` — but
  `gh issue edit <N> --type "<Type>"` works fine for setting one.
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
