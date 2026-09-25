# Cadence, dispatch reality and the WIP limit

> Part of the devantler-tech agent contract. [`AGENTS.md`](../../AGENTS.md) is the always-on core
> and indexes every guide; this guide carries the full rules for what the schedule in AGENTS.md
> means in practice: overlap, dropped ticks, the finish-before-start rule and the cadence gates.
> Read it when planning a run and before relying on any future tick.

## Cadence & focus — how the schedule behaves

The dispatch table itself is in [AGENTS.md → *Cadence & focus*](../../AGENTS.md#cadence--focus).

**The stagger invariant IS the schedule: both machine-local Agentic Engineer lanes dispatch every
hour, at distinct minute offsets — the current Codex adapter at `:10` and Claude adapter at
`:50`; the four Agent Improver starts remain at `:00`.** No two scheduled roles share an exact start
time. Read your lane's row for your own slots, and treat runtime jitter plus long-running siblings as
normal overlap rather than evidence that a slot is free.

Both machine-local Agentic Engineer lanes are **scheduled** every hour — for what the Claude lane
actually keeps, see *Scheduled is not delivered* below. These rows are deployment bindings, not
provider requirements for the portable role. The Agent Improver
keeps its 4×/day rotation (00 Claude, 07 Codex, 12 Claude, 19 Codex) as additional `:00` starts; those
slots no longer replace an Agentic Engineer tick. This table covers the two scheduled engineering
roles only — spend stewardship has no dispatch slot of its own (see *Spend contract*).

**Two properties of this schedule change how you plan a run.**
⚠️ **A sibling being mid-run is the NORMAL case — scan cross-lane on EVERY run, never at one special
hour.** The stagger invariant removes identical scheduled *start times*; it does **not** remove
overlap, because runtimes add jitter and runs outlive their hour. Measured over
the 7 days to 2026-07-28 (n=26 completed Claude dispatches): **median 51 min, p75 79 min, 46% ran
longer than 60 minutes, max 377**. So a sibling lane is very often still working when you start.
*Claim protocol* rule 4 records that claim arbitration does **not** work across lanes — each instance
writes its own namespace, so both pushes succeed and both believe they won. Scan every registered namespace and open PR before claiming, always.
**Same-lane overlap is expected, and it IS arbitrated.** With hourly spacing and 46% of measured
Claude runs exceeding 60 minutes, your own lane's next dispatch often starts before you finish. That
case is safe by construction — same namespace, same deterministic branch name, and a non-forced push
is refused (see *Claim protocol* rule 4) — so it needs no handling beyond never force-pushing a claim
branch. Therefore, same-lane task presence or post-start activity alone is never a global stand-down
condition: continue telemetry, selection, and unrelated delivery. Stand down only for a live
conflicting claim, exact shared-artifact contention, or an unsafe runtime-local mutation that could
break a sibling mid-flight; keep the fence scoped to that artifact or surface and continue elsewhere.

🔴 **Scheduled is not delivered — on the Claude lane about one tick in five never happens.** The two
machine-local schedulers differ. Measured across 2026-08-02T03:50Z → 2026-08-08T19:50Z (**161 scheduled
slots per lane**), **Codex dispatched 161/161**, because that scheduler starts a run even when the
previous one is still open — one run whose record stayed open for 240 minutes did not block any of the
four ticks behind it. Claude's refuses any dispatch that would overlap the previous run of the same
task and records it as `per_task_limit`. The reading over that same window was
**Claude dispatched 108/161** — 53 ticks, 32.9% — with 36.6% over 2026-08-01→08-07. Those measurements
are preserved as what they were; **both overstate the loss, and the cause is the METHOD, not the lane.**

🔴 **SUPERSEDING NOTICE (2026-08-18) — `161/161` measured DISPATCH, and dispatch is not PRODUCTION.**
The reading above stands as what it was: across that window the Codex scheduler started a run in every
scheduled slot. It says nothing about whether those runs did any work, because a dispatch is recorded
when a turn *starts* — so a lane whose every turn dies seconds in scores `161/161` exactly like a
healthy one. That is the same defect *Agent definition locations* records beside `last_run_at`, and it
is why "the scheduler is reliable" and "the lane is producing" are two claims, not one.
The consequence is the one that matters here: a run reading `161/161` as a **current** property routes
its carry-forward to "the dependable lane" on a number that never measured dependability, and then
reads that lane's silence as an ordinary quiet period.
**Establish production separately, per lane, and re-derive it — never inherit it.** That is what
[`codex-lane-liveness.sh`](../scripts/codex-lane-liveness.sh) answers (`0` producing, `1` not
producing, `2` UNKNOWN). Run on 2026-08-18 it reported **both Codex automations NOT-PRODUCING**, while
the same code against the same store pinned inside 2026-08-16 reported `OK` with multi-thousand-second
runs — one store, one check, opposite verdicts. **Both of those readings are dated measurements, this
one included: neither is a standing property of any lane.**

🔴 **A `per_task_limit` record is a per-minute liveness sample of "a run is currently open" — NOT a
per-slot drop record.** Measured 2026-08-12: **1871 of 1922 inter-record gaps are 59–60 seconds**, so
the scheduler re-records a skip every minute a run stays open and one long run writes dozens of them.
Counting those records — raw, or bucketed by hour — therefore counts a slot that merely started
**delayed into the next hour** as one that never ran at all. Over 164 slots
(2026-08-05T12Z → 2026-08-12T07Z), **37 of the 66 refused hours dispatched anyway**.

Corrected, and cross-validated against the transcripts rather than the skip store: **133 of 164 slots
dispatched; 31 did not (18.9%)** — 29 of those carrying a refusal (**17.7% genuinely dropped**) and
**2 carrying no record at all**, so a second failure cause exists that the skip store cannot see (the
Improver's own missing 2026-08-05 dispatch is one, and it has no `per_task_limit` record either). The
effective Claude interval is therefore **~1.2 hours**, not 1.5.
⚠️ **The Improver is NOT proven unaffected — and its zero skip count is exactly why not.** The Claude
store records **zero** `per_task_limit` skips for it, but the second failure cause above is invisible
to that store, and the Improver's own missing 2026-08-05 dispatch is one of the two no-record cases.
So zero skips establishes nothing about its health; reading it as a clean bill is the same
absence-as-evidence error this whole correction is about. Measure the Improver the same way —
scheduled slots against actual dispatches — before relying on its four daily starts. The Codex
scheduler refuses none, which bounds *that* lane's refusal cause and says nothing about this one.
⚠️ **Re-derive this ONLY by comparing actual dispatches to scheduled slots** — never by counting skip
records. Counting them is what produced five mutually-inconsistent readings (32.9%, 36.6%, 44.0%,
50.0%, 58.3%) across both instances, each re-measured because the last one looked wrong.
Run [`claude-dispatch-rate.sh --task <id> --since <UTC> [--until <UTC>] [--slots]`](../scripts/claude-dispatch-rate.sh)
for that comparison instead of measuring by hand: a slot counts as dispatched when an attributable
session for the task starts before the next slot, an open slot is never counted, and exit `2` is
UNKNOWN, never a rate. Measured with it for 2026-09-18T00Z → 2026-09-24T23Z: **165 of 166** engineer
slots and **13 of 13** Improver slots dispatched, against 28 hours carrying a refusal record. So the
one-in-five figure below describes its own August window, not a standing property of the lane.
Re-measure before relying on either.
**So never time anything off "the next tick."** A carry-forward, a claim-expiry judgement, or a "the
next run will collect this" decision is wrong whenever that tick is dropped. That was roughly one
time in five on Claude in August and far less in the September reading above, so measure the current
rate rather than assuming either. The error is always in the
direction of waiting **longer** than planned — so prefer finishing inside the current run over handing
work to a tick that may not come. The Agent Improver's four daily starts are additional work, not
replacement slots. The scheduled interval is the gap **between runs, not a per-run time budget**; it
bounds a carry-forward without telling an active run to stop early. Each run works
*The work-selection ladder* top-down — **breakage → every open PR you own or trust, drafts included →
security issues → bugs → the oldest actionable issue** — capturing new
non-trivial finds as issues (see *Issue-driven*).
**Stop starting, start finishing (WIP limit — the core agile principle).** Finishing in-flight work
outranks starting new work. Each run, before opening any **new** draft, first drive **every own
in-flight PR** to its terminal state: clear its hygiene pentad (green CI + all CodeRabbit/bot threads
resolved + no non-thread review findings + not conflicting with main + ≥1 green review from
CodeRabbit, Codex or Cursor Bugbot — or, when no lane will deliver, a qualifying local review round), complete the
user-evaluation condition, **self-promote, and merge it** (per
*Merge policy*) — or leave it a draft with the missing readiness condition or external blocker
explicitly named. Only once your own open PRs are each either **merged or named-blocker-parked** do
you start a new advance slice. The *waste* this targets is a pile of **half-finished** own PRs —
red/stale CI, unresolved review threads, DIRTY-vs-main, never user-evaluated — because they deliver
nothing while they sit. Concretely: a pentad-clear own PR left un-promoted/un-merged, or a draft
blocked on a **fixable** check/thread, is unfinished work — clear it **before** you start more. (This
sharpens *PRs-before-issues* and the every-run own-draft review-thread sweep into an explicit
finish-before-start ordering.)
**The WIP limit is also a CAP ON INTAKE, not only an ordering — a run cannot finish what it cannot get
reviewed.** The paragraph above orders work *within* a run, so a run that opens its whole batch in one
pass satisfies it **vacuously**: it had nothing in flight when it started. **Ordering alone cannot
drain a pile**, because promotion needs **≥1 green review at the current head**, every push re-stales
it, and the review lanes are **metered and shared** — CodeRabbit per-review, Codex weekly, Bugbot
monthly. A burst larger than that capacity is **structurally unreviewable**: it cannot finish, it ages
into conflicts, and it spends a scarce resource every other lane also needs. So intake is bounded by
finishing capacity:

The intake caps table lives in [AGENTS.md → *Cadence & focus*](../../AGENTS.md#cadence--focus).

🔴 **Check the per-lane bound before opening a draft — do not assume it.** Run
[`lane-draft-count.sh --lane <your namespace>`](../scripts/lane-draft-count.sh): it counts open
drafts by **branch namespace**, because every instance authors as the same login, so an author
count alone cannot tell the lanes apart (monorepo#2562). A draft counts for a lane only when its
branch is in that namespace, it comes from the same repository, **and** its author is the lane's
registered REST identity, so a collaborator or bot using the prefix does not inflate the lane. Exit `0` means only that the **per-lane** bound does not block a draft — the
per-run limit of 5 still applies on its own — `1` means the lane is over the cap, and `2` is
**UNKNOWN**. Treat UNKNOWN as "not permitted": a partial read is a floor, and a floor below the cap
looks exactly like permission. Finishing work and filing issues stay available either way.

**Rung-0 live breakage is exempt from both** — a hotfix is never blocked by a cap. So is the
issue-capture *Issue-driven* mandates: **filing an issue is not opening a draft**, and the backlog must
stay capturable while the caps bite. Both numbers are a deliberately permissive starting point rather
than a measured optimum — each sits above the lane's observed drainage and idle-clean counts, so the
caps bite only on a burst ([#2490](https://github.com/devantler-tech/monorepo/issues/2490) holds the
measurement they were set from). **Treat a cap you hit as the signal it is**: your lane's
finishing capacity is the binding constraint, and the work to do is finishing.
⚠️ **A cap is NOT licence to stop early, and it never blocks the floor.** *Work as long as there is
work* below is unchanged: the cap redirects a run **from starting toward finishing**, and finishing is
unbounded — a run that hits the cap and then idles has stopped too soon. The floor is unaffected for
the same reason, because its first and preferred option is **an open PR of yours driven to merged**,
which is exactly what a capped run should be doing.
**Work as long as there is work — don't stop early.** The floor (≥1 artifact) is a **minimum and a
backstop, not a target or a stopping point**: keep going while actionable work remains, and **prefer
long, continuous sessions** over stopping after a handful of items. End a run only when actionable work
is genuinely **exhausted or everything left is blocked** on the maintainer / an external party — not
because you've "done a few things". Don't pad with filler to look busy (the quality bar never drops),
but on a portfolio this size "nothing left" is rare, so **a run that quits while PRs are red or ready
issues remain has stopped too soon.** **Go deep where depth is needed** — substance over artifact count
— but depth is **not** a cap on how much you do; a single well-validated PR is a fine *minimum*, never
the *ceiling* when more is actionable. **Rotate and dedupe across the day:** don't redo what an earlier
tick shipped; spread distinct work across products (oldest `last_worked` first) — over a day the
portfolio should see many distinct artifacts, not one burst then silence. (Your own distinct in-flight
PRs are **not** sprawl — see *Autonomy*; what's bounded is duplicate PRs/filler on the **same**
concern, not value.) Cadence
gates: a **per-product strategy review** (roadmap refresh) and **per-product docs pass** weekly-to-monthly
per product (oldest first); heavy tasks (E2E audits, live-cluster reliability, site content review,
and the **cost pass** of *Spend contract*)
~weekly; review blog evidence/topics about monthly and publish or materially refresh a worthwhile post
roughly every 4–8 weeks. Blog work stays low priority and bounded to at most one due action per run:
**after operate work and one oldest-substantive slice**, a due review/publication/refresh may run before
the next backlog issue, then normal oldest-first work resumes. A review with no worthwhile story does
not move the publication clock; never publish filler. The KSail Monthly Strategy runs at month start;
**never spin up real clusters more than once a day**
portfolio-wide.
**Substantive-progress gate (guards against easy-work drift).** Coverage bumps, docs polish, and
self-test guards are valuable but **must not become every tick's output**: do **not** let the advance
pick be a small coverage/docs/guard artifact for **more than ~2 consecutive runs** while any substantive
`enhancement`/`roadmap`/`bug` issue is startable (decompose-and-start counts as startable — see
*Issue-driven → Drain oldest-first*). Across each week the backlog's **oldest substantive issues must
visibly move** — a feature increment shipped, an epic's first child landed, a meaningful fix made — not
merely its coverage % and docs freshness. If the substantive backlog *is* genuinely all blocked, that is
**rare**: say so in the report with the **specific, live-verified blocker per issue**, rather than
quietly defaulting to another easy artifact.
