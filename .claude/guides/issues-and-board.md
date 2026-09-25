# Roadmaps, issue hierarchy and the project board

> Part of the devantler-tech agent contract. [`AGENTS.md`](../../AGENTS.md) is the always-on core
> and indexes every guide; this guide carries the full rules for roadmap stewardship, sub-issue
> hierarchy, issue types, and the project-board duties. Read it before filing, triaging, decomposing
> or boarding any issue.

## Product strategy & roadmaps
You **own** each product's roadmap. The roadmap of record is **GitHub Issues** (Issues are enabled on
every repo) — never a version-controlled file (that was the retired dashboard's mistake). The scheme:
epic / theme-level items carry a **`roadmap`** label (create it once per repo if missing) and
optionally a **milestone**; their actionable children use the normal labels (`enhancement`,
`performance`, `refactor`, `security`, `bug`, `documentation`, …). On a per-product cadence (rotation
— see *Cadence*), run a **strategy review**: assess where the product is versus where it should be —
operator/user needs, ecosystem and dependency shifts, accumulated tech debt, gaps in features /
quality / performance / docs, and how it fits the portfolio — and from that create or refresh a small
set (≈3–7) of `roadmap` issues using the evidence-led shape in *Build the right thing*.
Decompose epics into small, well-specified, independently-shippable issues that preserve the parent's
evidence, audience, hypothesis, and success signal while adding concrete acceptance criteria — and
**link each child to its epic as a real sub-issue** (see *Issue hierarchy* below; a prose `Part of #N`
is not a link). Triage incoming issues into this structure (type, label, prioritise, dedupe, add to
the board with a `Status`, close stale/duplicate with a reason). Native memory holds only a lightweight per-product cursor (last
strategy review, current theme); the issues themselves are the durable roadmap, and they feed the
single work queue the agent drains **oldest-actionable-first** (see *Issue-driven*) — strategy and
decomposition exist to keep that queue stocked with well-formed, ready work. Implementing PRs use
`Fixes #delivery` to close the delivered slice and, when needed, `Part of #experiment` to preserve its
outcome record.

## Issue hierarchy — sub-issues are the structure; prose is NOT
**Writing `Part of #99` in an issue body creates NO relationship.** It renders a cross-reference and
nothing else: no parent, no rollup, no project field, no filterable edge. Decomposition is expressed
with GitHub **sub-issues** (GA since 2025-04-09) — a first-class link — and a decomposition that
exists only as prose is **not decomposed**, it is merely described. (Evidence, 2026-07-18: 52 of 203
open portfolio issues carried a prose `Part of #N` and **2** carried a real link, so every epic on
[project 5](https://github.com/orgs/devantler-tech/projects/5) showed an empty `Sub-issues progress`
and the maintainer could not see what belonged to what. Maintainer direction the same day: correct
hierarchy use is what makes that legible.)

**Every child issue gets a real link, at creation time:**
```sh
# SAME-REPO parent and child — bare numbers are fine:
gh issue create --repo devantler-tech/<repo> --title "…" --body "…" --parent <PARENT>
gh issue edit <PARENT> --repo devantler-tech/<repo> --add-sub-issue <CHILD>[,<CHILD>…]
gh issue edit <CHILD>  --repo devantler-tech/<repo> --remove-parent      # reversible

# CROSS-REPO (same owner) — you MUST pass a full URL for the other side. `--repo` selects the
# repo that bare numbers resolve against, so a bare <CHILD> here silently links the unrelated
# same-numbered issue in the parent's repo, or fails:
gh issue edit <PARENT> --repo devantler-tech/<parent-repo> \
  --add-sub-issue https://github.com/devantler-tech/<child-repo>/issues/<CHILD>
# bulk/scripted — NOTE the body param is the numeric DATABASE id, not the issue number,
# and the DELETE path is singular `sub_issue` while GET/POST are plural `sub_issues`.
# Resolve the id from the CHILD's OWN repo — a child may live in another same-owner
# repo, and fetching <CHILD> from the parent's repo returns an unrelated same-number issue:
# The URL path is the PARENT's repo; the id is resolved from the CHILD's repo. Mixing these up
# posts to the wrong repo and attaches the wrong issue:
gh api --method POST repos/devantler-tech/<parent-repo>/issues/<PARENT>/sub_issues \
  -F sub_issue_id="$(gh api repos/devantler-tech/<child-repo>/issues/<CHILD> --jq .id)"
```
Keep `Part of #N` in the body as human-readable context if you like — but it is **never** the link.

**The rules that bound it** (all documented limits): **100 sub-issues per parent**, **8 levels** of
nesting, children may live in **another repo of the same owner** (never another org), and an issue has
**at most ONE parent**, so pick the right parent rather than attaching an issue to two epics.
Re-parenting an issue that already has one needs the replace flag, and **the two APIs spell it
differently** — REST takes `-F replace_parent=true`, GraphQL's `AddSubIssueInput` takes
`replaceParent: true`. Omit it and the add **fails** instead of moving the child. Adding sub-issues
needs **triage** permission or above.

**Hierarchy is decomposition; it is NOT sequencing.** "This must land before that" is an **issue
dependency** (`gh issue edit <N> --add-blocked-by <M>` / `gh issue edit <N> --add-blocking <M>` —
both flags take the other issue's number or URL; 50 per relationship type,
cross-repo, renders a *Blocked* badge on the board) — never a nested sub-issue and never a bare
`blocked` label. Do not nest an issue to mean "waiting on".

**Two failure modes seen live, both of which produce a silently broken tree — do not repeat them:**
1. **`Part of #<PR>`** — pointing the parent reference at a *pull request*. A PR can never be a
   sub-issue parent; the link is unmakeable. Parent references point at **issues** only.
2. **A bare `#N` that means another repo.** `#N` always resolves within the *current* repo. A
   cross-repo parent must be written `owner/repo#N`, or the reference silently dangles.

**What a real link buys** (and why this is the whole point): the project's **`Parent issue`** field
becomes populated and **groupable** — a table view grouped by it renders each epic with its children
nested beneath (a capability; this board's chosen "what is part of what" surface is the Backlog
view's `Show hierarchy` toggle — see *Every issue belongs on the board*); **`Sub-issues progress`** gives
a live `completed/total` + percent rollup per epic; and the filters `parent-issue:owner/repo#N` and
`no:parent-issue` / `has:parent-issue` become available in both project views and repo issue search
(`has:sub-issue` is **repo issue search only** — see the warning that follows). ⚠️ **The two surfaces spell the parent/child qualifiers differently and are not
interchangeable:** *repo issue search* uses `has:sub-issue`, while a *project view filter* keys off the
project field name — **`has:sub-issues-progress` / `no:sub-issues-progress`**. GitHub **silently
ignores** an unrecognised qualifier in a project filter, so the wrong spelling looks like it worked
while filtering nothing. Projects' **hierarchy view** — [GA since 2026-03-19](https://github.blog/changelog/2026-03-19-hierarchy-view-in-github-projects-is-now-generally-available/)
and **enabled by default on new views** — renders the full nesting inline in table views, up to 8
levels, preserved through grouping, slicing and filtering. On an existing view, turn it on with
*View → Show hierarchy*.
Note the two features that do **not** exist: a roadmap layout does **not** render hierarchy (it plots
dates/iterations only — grouping by `Parent issue` yields flat groups, not nested bars), and closing a
parent is **not documented** to cascade to children in either direction — never assume it does.

**EVERY issue carries an Issue Type — no exceptions** (maintainer direction 2026-07-18). Types are
org-wide, exactly **one per issue**, filterable as `type:Bug` (unquoted — see the ladder's warning), and they are the structured
replacement for type-labels. An untyped issue is an incomplete issue: fix it at triage. Set it at
creation — `gh issue create --repo devantler-tech/<repo> --type "Feature"` — or retrofit with
`gh issue edit <N> --repo devantler-tech/<repo> --type "Bug"`. **Always name the repo** (or pass the
issue URL): a bare number resolves in the *current* repo, so triaging a submodule's issue from the
monorepo checkout would retype the same-numbered **monorepo** issue instead.

**Each type exists because it changes what *done* means** — that is the test for whether something
deserves a type rather than a label, and it is why the type tells you what "next" looks like:

| Type | What it is | The definition-of-done it implies |
|---|---|---|
| **Epic** | Strategic item | **Decomposed into sub-issues, never implemented directly**; closes when its children do |
| **Feature** | New user-visible capability | Feature-flag-first, default-off, **tested in BOTH states**, docs in the same PR |
| **Bug** | A defect | **RED/GREEN reproduction proof** |
| **Security** | Vulnerability or hardening gap | Fix-vs-except ladder; **sanitized** public body, evidence kept private |
| **Performance** | Speed / resource usage | **Before/after numbers** in the PR body, against a measured baseline |
| **Refactor** | Behaviour-preserving quality | **Never mixed with a behaviour change**; existing tests pass unmodified |
| **Docs** | Documentation | **Generated** docs are re-run, never hand-edited (authored prose is of course edited by hand); examples actually run |
| **Spike** | Timeboxed investigation | Output is a **recorded decision + follow-up issues**, not a PR |
| **Kata** | Improvement Kata | Target condition + **named measurement date**; stays open until the outcome is decided |
| **Chore** | Mechanical upkeep | No flag required |

**Spike execution path (#2267) — how a Spike clears the floor without a delivery PR.** A Spike's
definition-of-done deliberately forbids a PR, so when a Spike is the oldest actionable issue the
*Issue-driven* "ship a draft delivery PR" rule yields to this type's DoD: (1) investigate within the
Spike's timebox; (2) **record the decision on the Spike issue** (evidence → options considered →
chosen path → why); (3) **file the follow-up issues** the decision implies (linked as sub-issues when
they belong under the same Epic); (4) close the Spike. That recorded decision + filed follow-ups
**is** the run's authored artifact and **satisfies the floor** — inventing a delivery PR for a Spike
would contradict the type. A Spike is never a skip reason; it is work with a different shape of done.

**`type:"Epic"` — not a label, not a structural guess — is what keeps epics off the Kanban.** A
`no:sub-issues-progress` filter only excludes epics that have *already* been decomposed; an
**undecomposed** epic has no children and slips through looking like actionable work (37 were doing
exactly that on 2026-07-18). The type is true from the moment the issue is filed, so
`-type:"Epic"` is correct on day one.

Types and sub-issues are **orthogonal**: a type says what a thing *is*, a sub-issue link says what it
*belongs to*. Labels stay for cross-cutting, repo-local tags (`automation`, `kubernetes`,
`good first issue`).

**The queue selects BY TYPE, not by label.** The
[`portfolio-surveyor`](../agents/portfolio-surveyor.md) sweeps each of the ten types directly, so
**a correct type is sufficient to be queued** — no companion label is required. That matters because
labels were provably incomplete: on 2026-07-18, **8 of 63 open Epics carried no `roadmap` label**, and
`Spike`/`Kata`/`Chore` have no label equivalent at all, so a label-based sweep silently dropped them.
Existing type-labels are harmless legacy and stay until pruned (#2242); do **not** add new ones, and
never treat a missing label as a reason an issue is unqueued.

**Default: every issue belongs to an Epic** (maintainer direction 2026-07-18). A child that hangs off
nothing is work whose *why* is unrecorded — it cannot roll up, it cannot be prioritised against a
theme, and it makes the board a flat list again. So when filing, **ask which Epic this serves**; if
none fits, that is usually a signal the Epic is missing, not that the issue is exempt — **file the
Epic**. Genuine exemptions, kept narrow:
- **Hotfixes** — live breakage is fixed immediately; parenting it later is optional.
- **Trivial/mechanical one-offs** — a typo, a dead link, a stale pin: a `Chore` too small to belong
  to a theme.
- **Top-level Epics themselves**, and standalone `Spike`s whose whole purpose is to decide whether an
  Epic should exist.
Everything else gets a parent. A backlog of orphans is the failure state this rule prevents — and the
inverse is a signal too: **an Epic with no children is undecomposed, not finished** (37 such epics
existed on 2026-07-18), so decomposing them is real, high-value advance work.

## Every issue belongs on the board
[Project 5 (🌊 Project Board)](https://github.com/orgs/devantler-tech/projects/5) is the maintainer's
single navigation surface across the portfolio, so **every open issue in every active **public**
`devantler-tech` repo belongs on it, and every board item carries a `Status`** — an item with no
status is invisible in board layout and unsortable in triage, which defeats the surface. **The status
ladder mirrors the agent's actual lifecycle, so every state answers "what's next":**

| Status | Entry condition | What's next |
|---|---|---|
| **✅ Done** | Acceptance criteria validated, outcome decided | — |
| **📊 Verifying** | **Merged**, outcome not yet proven (covers the wait for an async release, and the wait for a Kata's measurement date) | Verify it actually works E2E once released; measure a Kata's signal; then decide |
| **🚀 Ready to Merge** | Green review at head, all checks green, nothing unresolved | Self-promote and merge |
| **👀 In Review** | PR open, CI green, review requested | Fix findings, re-request, re-secure green at the new head |
| **🏃🏻‍♂️ In Progress** | Assignee has time to implement | Finish the implementation, get CI green |
| **🫴 Ready** | Refinement criteria met | Pick it up, oldest first |
| **📥 Backlog** | Captured and triaged, not yet refined | Refine, or decompose if it is an Epic |
| **🧊 Icebox** | Parked | Revisit at triage |

**The merge is the boundary** between *Ready to Merge* (pre-merge, mechanical) and *Verifying*
(post-merge, evidential) — shipped is not the same as decided. The **reversed order is deliberate**:
finishing work sits leftmost so the board reads *stop starting, start finishing* (maintainer direction
2026-07-18). **Never re-order it into left-to-right flow**, and treat an over-limit column as a signal
to finish rather than a limit to raise. A newly-filed issue lands in **📥 Backlog** unless you know
better, and *never* in no-status. **Private repos are the exception: project 5 is PUBLIC, so putting an
item from ANY private repo on it is a maintainer decision, never an agent default** — do not sweep
them in during a coverage backfill. **Determine visibility live, never from a hard-coded list or from
the portfolio map's parenthetical** (both go stale — the map still said "UniFi network (private)" on
2026-07-18 when the repo had become public):
`gh api repos/devantler-tech/<repo> --jq .private`, or enumerate with
`gh api "orgs/devantler-tech/repos?type=private" --paginate --jq '.[]|select(.archived==false)|.name'`.

**"Blocked" is deliberately NOT a status.** Blocking is orthogonal to position — work can be blocked
while *Ready* or while *In Review* — so a Blocked column would destroy the information about where it
actually is. Express it as a native **issue dependency** (`gh issue edit <N> --add-blocked-by <M>`),
which renders a Blocked badge on the card in whatever column it sits. Reserve the `blocked` **label**
for blockers that dependencies cannot express — an upstream release in another org. The board carries **exactly three
views** — **kanban (board)**, **backlog (table)**, **roadmap (roadmap)** — and epic breakdown is the
**Backlog view's hierarchy** (its `Show hierarchy` toggle — **not** a `Parent issue` group-by), not a
fourth view: **prefer an extra grouping/slice on an
existing view over a new one** (maintainer direction 2026-07-18). See its
[product card](../skills/products/project-board/SKILL.md).

Two mechanics make this a standing duty rather than something automation handles:
- **Auto-add workflows are capped at 5 on the Team plan** and each one targets exactly **one**
  repository — so built-in auto-add can **never** cover a ~20-repo portfolio. The durable fix is an
  `actions/add-to-project` workflow backed by a GitHub App (`GITHUB_TOKEN` provably cannot reach
  Projects) — but note **a workflow lives in one repository and only fires on that repository's
  events**, so it must be deployed to **every** repo you want tracked; a single central workflow will
  silently miss all the others. Until that exists, **adding the issue to the board is part of filing
  it**.
- **Auto-add is forward-only** — enabling it never adds pre-existing issues. Any coverage gap must be
  **backfilled** deliberately. Adding an item is `item-add` **plus** `item-edit` (`item-add` has no
  Status option), and the first exits 0 and prints an item id, so a half-completed add is
  indistinguishable from a finished one — which is exactly how status-less items keep appearing
  (measured 2026-07-19: **0 status-less items at 15:25Z, 9 by 19:2xZ**, all created that day).
  Describing the two steps did not hold, so **use the script — it does both halves and verifies the
  Status by reading it back, exiting non-zero if it did not land**:
  ```sh
  .claude/scripts/board-add.sh <issue-url> [status]   # preserves Status; 📥 Backlog only when unset
  ```
  With no status argument it preserves an existing Status; an explicit argument deliberately sets
  or corrects it. Output distinguishes an added card from an existing card left untouched.
  It is idempotent for an issue already on the board, and **refuses a private repo's issue** — project
  5 is public, so that is a maintainer decision, never an agent default.
- **Board issues through a registered exact author identity.** If an instance cannot board its own
  issues, an instance with that verified capability runs
  `.claude/scripts/agent-issue-board-sweep.sh --author <registered-search-identity>`.
  The helper requires an explicit author, rejects incomplete discovery, excludes archived repositories,
  preserves the private-repository boundary, and delegates idempotent mutations to `board-add.sh`.
  A provider name never implies either missing permission or authority to act.

When bulk-operating on issues or board items, **serialize and pace** — GitHub's secondary limits allow
roughly **80 content-generating requests/minute and 500/hour**, and both sub-issue endpoints carry an
explicit rate-limit warning. Never fan these out concurrently.
