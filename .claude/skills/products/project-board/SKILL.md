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

🔴 **Do NOT check the board by enumerating it — an explicit high limit does NOT make enumeration
safe.** `gh project item-list` defaults to `--limit 30`, but raising the limit only moves the cut:
measured 2026-08-06, `--limit 3000` returned **exactly 3000** items against a true
`projectV2{items{totalCount}}` of **4988**, with **no truncation signal** — no warning, no error,
exit 0. ~40% of the board was silently absent, so every check below would have reported clean while
the drift sat past the cut. Returning exactly the limit is the *only* tell, and it is one the caller
has to look for.

⚠️ **Enumeration also costs the whole hourly GraphQL budget, which every lane shares.** That same
pass left `graphql: {limit:5000, remaining:73}`. The budget is attached to the **user**, so
`claude/*`, `codex/*` and `cursor/*` all draw on it — and the surveyor's paginated `reviewThreads`
queries are what the hygiene pentad's unresolved-thread count depends on. A starved pentad reads as
*clean*, which is a **fail-open on the promotion gate**. Never spend the shared budget on a board
sweep to answer a question a per-issue query answers for ~1 point.

**So: ask per issue, not per board.** For coverage and membership, query the issue's own side. That
read is cheap and it distinguishes "on no project" from "on the board" (negative control:
`platform#1` → `[]`, verified non-vacuous) — but it carries the *same* three fail-open traps the
enumeration does, so it gets the same discipline:

- **Identify the board by its `id`, never by `number` alone.** A number is unique only within one
  owner, so a repository-level project or another owner's project numbered 5 satisfies a
  number-only match and reports an unboarded issue as covered.
- **Paginate.** `projectItems(first: N)` truncates exactly like `item-list --limit N`, and here the
  truncated read produces the *worse* answer: "not on the board" for an issue that is.
- **Fail closed on the read itself.** An empty `projectItems` and a failed query look identical
  downstream. Only a successful query may be read as "not on a project"; anything else is
  **unverified**, which is a different outcome from either answer.

`includeArchived: false` is explicit because an archived item is not on the board for triage — it is
covered by the archive, not by the sweep, and the default would quietly count it as coverage.

```sh
# Resolved once per run; a number alone is not an identity.
BOARD_ID=$(gh api graphql -f query='{organization(login:"devantler-tech"){projectV2(number:5){id}}}' \
  --jq '.data.organization.projectV2.id') \
  || { echo "board id lookup failed; refusing" >&2; exit 1; }

# 0 = on the board, 1 = verified absent, 2 = UNVERIFIED (never conflate 1 and 2).
on_board() { # on_board <owner> <repo> <issue-number>
  after=null
  while :; do
    page=$(gh api graphql -F owner="$1" -F name="$2" -F number="$3" -F after="$after" -f query='
      query($owner:String!,$name:String!,$number:Int!,$after:String){
        repository(owner:$owner,name:$name){ issue(number:$number){
          projectItems(first:100, after:$after, includeArchived:false){
            nodes{ project{ id } } pageInfo{ hasNextPage endCursor } } } } }') || return 2
    printf '%s' "$page" | jq -e '.data.repository.issue.projectItems' >/dev/null 2>&1 || return 2
    if printf '%s' "$page" | jq -e --arg id "$BOARD_ID" \
         '[.data.repository.issue.projectItems.nodes[].project.id] | index($id)' >/dev/null; then
      return 0
    fi
    printf '%s' "$page" | jq -e '.data.repository.issue.projectItems.pageInfo.hasNextPage' >/dev/null \
      || return 1
    after=$(printf '%s' "$page" | jq -r '.data.repository.issue.projectItems.pageInfo.endCursor')
  done
}
```

**If a check genuinely needs the whole board**, pair the enumeration with a mandatory truncation
guard and treat a trip as a hard failure, never a result:

```sh
total=$(gh api graphql -f query='{organization(login:"devantler-tech"){projectV2(number:5){items{totalCount}}}}' \
  --jq '.data.organization.projectV2.items.totalCount') \
  || { echo "totalCount query failed; refusing" >&2; exit 1; }
items=$(gh project item-list 5 --owner devantler-tech --format json --limit "$LIMIT") \
  || { echo "item-list failed; refusing" >&2; exit 1; }
n=$(printf '%s' "$items" | jq '.items | length')
for v in "$n" "$total"; do
  case "$v" in ''|*[!0-9]*) echo "non-numeric count [$v]; refusing" >&2; exit 1 ;; esac
done
if [ "$n" -eq "$LIMIT" ]; then echo "TRUNCATED at limit ($n); refusing" >&2; exit 1; fi
if [ "$n" -lt "$total" ];  then echo "INCOMPLETE: $n of $total; refusing" >&2; exit 1; fi
```

(Written as `if`, not `cond && { …; exit 1; }`. Measured: the `&&` form is safe mid-script — `set -e`
exempts a non-final component of an AND-OR list — but on the **healthy** path it evaluates to **1**,
so as the last command of a script or function it returns a spurious failure and takes a `set -e`
caller down with it. `if` has no such edge. Set `LIMIT` above `totalCount`; the equality arm is what
catches the silent cut.)

🔴 **Each `gh` call is checked on its own line, and both counts are asserted numeric, because
otherwise this guard fails OPEN — the exact direction it exists to prevent.** Measured: with `gh`
returning non-zero, the old one-line pipeline left `n` empty; `[ "" -eq "$LIMIT" ]` and
`[ "" -lt "$total" ]` then both exit **2** with `integer expression expected`, and a `[` failure
*inside an `if` condition* is exempt from `set -e` — so both arms evaluated false, the script reached
its success path, and it **exited 0 having counted nothing**. A rate limit therefore read as a clean
board. `set -o pipefail` alone would not have saved it either: the pipeline masks `gh`'s status behind
`jq`'s. Verified in all three states — `gh` failing ⇒ exit 1, a genuine truncation (`n == LIMIT`) ⇒
exit 1, and a healthy full read ⇒ exit 0, so the guard is not vacuous.

Never suppress stderr on these calls: a rate-limited `gh` prints `API rate limit exceeded` and exits
non-zero, and a `2>/dev/null` turns that into an empty result indistinguishable from a clean board.

| Check | Query | Healthy |
|---|---|---|
| **Coverage** | open issues in active **public** repos vs. items on the board (private-repo items are a maintainer decision, never counted against coverage) | 100% |
| **Status hygiene** | board items with no `Status` | 0 |
| **Type hygiene** | board items whose issue carries no **Issue Type** | 0 (the contract makes a type mandatory; an untyped item is invisible to Kanban/Roadmap type filters) |
| **Hierarchy — migration** | open issues with a prose `Part of #N` but no real parent link | 0 |
| **Hierarchy — orphans** | open **non-Epic** issues with `no:parent-issue`, minus the contract's exemptions (hotfixes, trivial `Chore`s, standalone `Spike`s) | 0 — the default is that every issue belongs to an Epic, so a growing orphan count means the board is flattening back into a list |
| **Hierarchy — undecomposed** | `type:"Epic"` issues with **no sub-issues** (`no:sub-issues-progress`) | 0 — an Epic with no children is *undecomposed, not finished*; decomposing them is high-value advance work (37 existed on 2026-07-18) |
| **Dangling parents** | `Part of` references resolving to a PR, to self, or to nothing | 0 |
| **Stale epics** | epics at `Sub-issues progress` 100% but still open | 0 (close or extend) |
| **Closed root with open work** | `type:"Epic"` issues that are **closed** yet still have any **open** descendant | 0 — **re-open the Epic** (do not re-parent, and do not change the Backlog filter). The Backlog view is `is:issue is:open no:parent-issue` with Show hierarchy; a closed root fails `is:open`, so its open children disappear from every expandable tree even though the parent link is correct ([#2266](https://github.com/devantler-tech/monorepo/issues/2266)). GitHub project filters have no "closed parent with open descendants" qualifier, so the fix is lifecycle, not a fourth view or a filter edit |
| **Reopened stuck at Done** | **open** issues whose Status is still `✅ Done` | 0 — closed→Done is a built-in workflow but **nothing moves an issue back out on reopen**, and the Kanban filters `-status:"✅ Done"`, so reopened work vanishes from the main view exactly when it needs attention. Move it back to the state that matches reality (0 on 2026-07-18 — latent, not live) |
| **Archive** | closed/merged items still active on the board | none older than **30 days closed** — **except any item whose hierarchy still contains open work**, in either direction: a closed item with any still-open **ancestor** (a closed sub-Epic under an open top-level Epic keeps its own closed children too), *and* a closed item with any still-open **descendant** (an Epic closed prematurely while a child is still open must stay visible, or the open child is orphaned from a tree nobody can see). These stay active. Archiving it removes it from the Backlog's hierarchy, so the decomposition becomes unreadable while the progress bar still counts it, and "what is part of what" (the whole point of the board) silently loses rows. Younger items also stay active so Insights keeps recent history — see the Insights trap below; manual until [#2238](https://github.com/devantler-tech/monorepo/issues/2238)'s auto-archive works |

**Never close an Epic while any descendant is still open.** Close the Epic only when its children are done (or explicitly cancelled). If a survey finds a closed Epic with open descendants, re-open it immediately — that is the #2266 resolution, not a Backlog filter change.

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

  **Keep these three filters.** [#2266](https://github.com/devantler-tech/monorepo/issues/2266)
  asked whether open work under a *closed* root should be fixed by changing the Backlog filter,
  re-opening the root, or re-parenting. **Decision (2026-07-22): re-open the root** (and never close
  an Epic with open descendants). A filter change cannot express that case, a fourth view would
  violate the three-view rule, and re-parenting destroys the recorded decomposition. No maintainer
  UI edit is required for this decision.

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
  Status by hand at each lifecycle step, **when that step's entry condition in `AGENTS.md` actually
  holds** — a PR merely being *open* is still 🏃🏻‍♂️ In Progress; it becomes 👀 In Review only once CI is
  green **and** a review has been requested, and 🚀 Ready to Merge only on a green review at head with
  the pentad clear. Moving a card early makes the board overstate progress, which is the one thing a
  status ladder must never do. Only the final closed→Done move is a built-in workflow.

  ⚠️ **📊 Verifying belongs on the issue that is still OPEN, not on the one the merge just closed.**
  A delivery PR carries `Fixes #delivery`, so merging **closes** that issue and the built-in
  closed→Done workflow marks it ✅ Done — moving it to *Verifying* would either be immediately
  overwritten or leave finished work looking pending. When the outcome cannot be known at merge, the
  PR also carries `Part of #experiment`; **that experiment/Kata issue stays open, and it is the one
  that goes to 📊 Verifying** until its measurement date, when it becomes ✅ Done with the decision
  recorded. If a change has no separate experiment issue but still needs a post-merge check, keep the
  delivery issue **open** (drop `Fixes`, use `Part of`) rather than closing it and reopening it. **This also makes
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
  definition-of-done each implies). An untyped issue is an incomplete issue. Setting one always works,
  but **always name the repo** — a bare number resolves in the *current* repo, so triaging another
  repo's item from the monorepo would type the same-numbered monorepo issue instead:
  `gh issue edit <N> --repo devantler-tech/<repo> --type "<Type>"` (or pass the issue URL). Managing
  the org type **list** is a REST surface — collection `GET`/`POST /orgs/{org}/issue-types`, then
  item-specific **`PUT`** and **`DELETE` `/orgs/{org}/issue-types/{issue_type_id}`** (there is no
  collection-level PATCH) — but it needs **`admin:org` (Issue Types write)**,
  which the routine's PAT does **not** carry (it 403s). So: **use the API when the token has the
  scope** — that is the auditable path and it works unattended — and fall back to **org settings in a
  browser** only when it does not. Do not treat type-list drift as un-fixable just because one token
  lacks the scope.
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

Roadmap lives in **GitHub Issues on `devantler-tech/monorepo`** — never enumerated here, because a
hard-coded list goes stale the moment an issue closes or a new one is filed (the same mistake the
retired status-board made). Query it live:

Board work hangs off the board Epic — **[monorepo#2261](https://github.com/devantler-tech/monorepo/issues/2261)** —
so it is found **structurally**, never by string matching:

```sh
gh api "search/issues?q=org:devantler-tech+is:issue+is:open+parent-issue:devantler-tech/monorepo%232261&per_page=100" \
  --jq '.items[] | "#\(.number)\t\(.created_at[0:10])\t\(.title)"'
```

A text search (`"board" in:title,body`) was tried and rejected: it misses board issues that don't
contain the word ("Automate stale-item archiving") and pulls in unrelated issues that merely mention a
board. A hard-coded list was rejected before that, for going stale on the first close. **File new board
work as a child of #2261** — the contract's default that every issue belongs to an Epic, applied to the
board's own product.

The strategic frame: *what can the maintainer still not see at a glance?* Answer that, and the board has
advanced.
