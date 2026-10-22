# Improvement katas — consumer records and flow

> Part of the devantler-tech agent contract. The portable procedure belongs to the reviewed
> agent-plugins gitlink's Agent Improvement skill, not this guide or a plugin cache.

## Ownership and records

The challenge is a safer, higher-quality engineer with shorter end-to-end delivery time. Improvement
is earned by observed outcomes, never by instruction volume or merged definition changes. Project 5
and typed Kata issues carry targets, obstacles and checkpoints; due measurements are finishing work.

The Agent Improver owns cross-run engineer/observer improvement and reads the reviewed skill's
`references/improvement-kata.md` when this opt-in resolves. The Agentic Engineer finishes its
assigned delivery and due product experiments through normal product-engineering gates; it never
widens its own authority. Do not turn every ordinary repair into a replacement experiment.

Use one typed **Kata** issue for the outcome, parented to its appropriate Epic. Keep its challenge,
dated measured current condition, next target, one current obstacle, one bounded experiment,
prediction, companion floors, eligibility, owner and measurement-viability deadline together.
Link the native hypothesis when authorized; native-memory writes still require their supported
path and applicable permission. This guide grants no new memory, scheduler, spend or inference authority.
Keep private evidence in the established private stores and publish only sanitized conclusions.

The outcome issue has exactly one canonical `**Measure on:** YYYY-MM-DD` line near its top.
Record exact UTC eligibility/not-before times in the experiment plan: Project DATE fields have
only day precision. Mirror the condition, obstacle and next date to Project 5's **Target condition**,
**Current obstacle** and **Measure on** fields. Leave **Kata decision** unset before measurement;
thereafter mirror Adopt, Iterate, Stop or Inconclusive with the actual decision evidence on the issue.
These are metadata, not a second backlog, roadmap or phase taxonomy.
Never move Measure on beyond the registered measurement-viability deadline without an explicit
re-scope or stopping decision. This keeps the existing date helper's future-date skip from hiding
a passed escalation deadline; its DUE result requests an eligibility readback, not an outcome verdict.

Delivery children are real sub-issues and close via their merged PRs. Use `Fixes #delivery` and
`Part of #kata`, never `Fixes #kata` for implementation alone. Record
`**Delivered on:** YYYY-MM-DD` when the complete delivery slice is available, without inventing
runtime activation or post-change observations. Source, release, packaging, consumer adoption,
native installation and actual later dispatch proof are distinct joins.

## Checkpoints finish existing work

Keep existing statuses, finishing-first order, views and configured WIP limits. A begun experiment
is In Progress/In Review until delivery is merged. It is **Verifying** only while a check can be
run now, which for a dated measurement means its exact eligibility time has passed, not only
its date. While it waits for that, for an event on its own schedule or for an act only the
maintainer can perform, it sits in **Ready** with its resume condition recorded as the
[board guide](issues-and-board.md#every-issue-belongs-on-the-board) describes (monorepo#4109):
the `Measure on` line, or an `outcome` or `authority` blocker record. An unstarted deferred Kata may stay Icebox; a running or due measurement
cannot be hidden there to manufacture capacity. Missing/misplaced cards remain unfinished WIP and
are reconciled by the work-selection guide.

Due eligible verification is finishing work ahead of new intake. Waiting and blocked measurement
remain started work wherever the card sits: the registered dates, floors and history do not move
with it. An explicit one-time maintainer exception is recorded on the affected delivery and
outcome issues with scope and recovery; it does not change limits or authorize unrelated starts.

Every Agent Improver run reads the Kata census before new intake, whichever lane delivered the
Kata: neither lane's native ledger lists the other's Katas, so #4030 stayed DUE through 39 Claude
Improver dispatches (monorepo#4429). For each live, non-archived repository in the **Portfolio map**,
list them with the command below, replacing `<repo>` with that declared repository name. Repeated
`repo:` qualifiers may combine declared repositories within the Search API's query-size limit;
do not expand the census to repositories outside the map.
`gh api --paginate --slurp -X GET search/issues -f q='repo:devantler-tech/<repo> archived:false is:issue is:open type:Kata' -f per_page=100 --jq 'if type == "array" and length > 0 and all(.[]; .incomplete_results == false and (.items | type) == "array" and (.total_count | type) == "number") then .[0].total_count as $total | [.[].items[]] as $items | if $total <= 1000 and all(.[]; .total_count == $total) and ($items | length) == $total and ([$items[].id] | unique | length) == $total then $items[].html_url else error("UNKNOWN: incomplete Kata census") end else error("UNKNOWN: incomplete Kata census") end'`
and classify each with
`gh api repos/devantler-tech/<repo>/issues/<n> --jq '{body:(.body // ""),sub_issues:.sub_issues_summary}' | .claude/scripts/kata-measure-date.sh --input -`.
A `DUE` Kata the Agent Improver owns is this run's finishing work. Complete every repository batch
before treating the census as complete. Slurp all pages before emitting any URLs: a failed search,
an `incomplete_results` search, a missing or duplicate page, changing result totals, a result over
the Search API's 1,000-result cap or a helper exit 2 is UNKNOWN, never an empty census. Narrow an
over-cap query into disjoint batches and verify each batch before using its results.

At Measure on, record expected versus actual, eligibility and attribution, protected floors,
coverage/UNKNOWNs, learning and the next obstacle. A missed date remains overdue until that
readback exists. If volume, deployment or liveness is insufficient, record Inconclusive and the
missing join before a justified next checkpoint; retain the original date in history and never
lower a preregistered floor retrospectively. At the registered measurement-viability deadline,
escalate persistent insufficient volume/liveness even if no dispatch became eligible; stop
expansion and obtain an explicit re-scope or stopping decision rather than rolling dates forever.

Adopt only the observed eligible scope with all companion floors intact. Iterate only after
recording the previous experiment's result and preregistering the next one. Stop on a protected
regression and follow the preauthorized revert-first procedure. Inconclusive keeps the outcome
open. A concluded stop/no-benefit experiment can close with its evidence and recovery/disposition;
it is calibration, not verified improvement.

## Continuous learning without self-scoring

Compare original lead/cycle time, throughput and CI/review/deploy/verification wait separately
from active time; use the unchanged existing cohorts and companion floors. Do not reset clocks
on parking, re-entry, bot comments or new measurements. A merged skill, green fixture, new board
field or CURRENT installation is delivery/configuration proof, not evidence that the engineer
improved. Obtain independent current-head review of observer changes and verify outcomes in a
later eligible deployed window; preserve negative results and the unchanged holdout.
