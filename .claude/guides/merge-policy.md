# Merge policy and PR ownership

> Part of the devantler-tech agent contract. [`AGENTS.md`](../../AGENTS.md) is the always-on core
> and indexes every guide; this guide carries the full rules for how every actionable PR is driven
> to a terminal state whoever authored it, the merge preflight and merge commands, and the
> dependency-automation and programmed-bot PR rules. Read it before taking over, merging or closing
> any PR.

## Merge policy — drive every actionable PR to merge (incl. majors)

**Driving actionable PRs to merge is the first-priority work each run — ahead of
issues** (only live breakage on `main` outranks it; this is rung 1 of *The work-selection ladder*).
Dependency-automation PRs whose self-progressing evidence has expired or failed are part of this
queue. Sweep the actionable set **first**, every run, across the in-scope
`devantler-tech` portfolio. ⚠️ **The `non-draft` scoping below bounds the merge COMMAND, never the
SWEEP** — an own draft is rung-1 work you drive *through* promotion into this set, not work that
falls outside it (see the rung-1 note in the ladder, and the 99-draft pile it was written from).
On each portfolio repo, an **actionable non-draft** PR with the full
current-head hygiene pentad clear — green required checks, zero unresolved threads/body findings, no
conflict, and a current-head green review —
gets driven to merge:
resolve findings, root-cause-fix failing required checks, set a
Conventional-Commit title, then **merge with the command that matches the author** —
- an actionable **single-author App** uses pre-CLEAN auto-merge only after the review/current-head
  parts of that pentad are clear. 🔴 **The `--auto`-eligible authors are exactly two, and every one
  of them is eligible unconditionally:** `github-actions` and `ksail-bot`. Eligibility
  there is a property of the **author**, which a later head cannot change — which is exactly what
  `--auto` needs, because it merges whatever head passes checks later and re-evaluates nothing.
  🔴 **`app/botantler-1` is NEVER `--auto`-eligible — not even on exit 0 — because its permission
  comes from a CLASSIFIER RESULT about one specific commit, and `--auto` cannot carry a condition.**
  Exit 0 waives the **review** requirement for that head; it never waives the requirement to merge
  **directly, at the head you evaluated**. Arming `--auto` on it lets an updater push during the
  wait land a replacement head the classifier never ran on — a head that might return exit 1 or 3,
  i.e. one requiring the very review the exit-0 path waives. The head pin does not close it either:
  `--match-head-commit` gates the **arming**, not the later merge, so the post-arm confirmation
  detects the violation only after it has reached `main`. So: wait for the checks, **re-run the
  classifier at the current head immediately before merging** — a result from an earlier head is a
  statement about a commit that is no longer being merged — and merge with
  `gh pr merge <n> --repo devantler-tech/<repo> --squash --match-head-commit <sha>`. Reserving
  `--auto` for the two unconditional authors is what keeps that exemption tied to the commit it was
  granted for. State the matrix as this two-plus-one split and **never as a flat three-name list**:
  appending the updater to the two author-scoped names puts a commit-scoped permission in an
  author-scoped list, which is what made the unsafe arming look prescribed.
  For an unconditional author, use
  `gh pr merge <n> --repo devantler-tech/<repo> --auto --squash --match-head-commit <sha>`; for **trusted programmed bot PRs** (exit-0 agent-skills updater PRs,
  tap cask PRs, and KSail release bumps — the carve-out below) the review parts are intentionally absent and
  are NOT required — their required checks, zero threads, and no-conflict state alone gate the merge,
  which for the exit-0 updater is the head-pinned **direct** merge above, never `--auto`;
- a **human-trusted author** (`devantler`, i.e. **every machine-local agent-own PR**) **cannot use `--auto`**
  (auto-merge is bot-only) and merges **directly** with
  `gh pr merge <n> --repo devantler-tech/<repo> --squash --match-head-commit <sha>` once
  `mergeStateStatus` is CLEAN.

🔴 **Every merge mutation carries the same two pins the preflight read carries — `--repo` and
`--match-head-commit`.** Writing the merge as a bare `gh pr merge <n>` reopens, on the mutation, the
two holes the read above already closes:
- **`--repo devantler-tech/<repo>`** — a bare number resolves against whatever checkout the run is
  standing in, so across a cross-repo sweep a colliding PR number is inspected in the intended
  repository and then **merged in a different one**. Pinning the read and leaving the write bare
  makes the ownership check theatre.
- **`--match-head-commit <the headRefOid you evaluated>`** — the pentad, the green review and (for an
  external PR) the evaluation record are all statements about **one commit**, and the author may push
  between the read and the merge. Without this flag the merge lands whatever is at the tip, which is
  precisely the commit nobody evaluated; with it, GitHub refuses instead. Most reachable on an
  external PR, where the pusher is the party the evidence exists to check — and a replacement commit
  can arrive already carrying its own green commit-scoped checks.

So the merge is `gh pr merge <n> --repo devantler-tech/<repo> --squash --match-head-commit <sha>`,
and the App path is
`gh pr merge <n> --repo devantler-tech/<repo> --auto --squash --match-head-commit <sha>`. A refusal
from either pin is the guard working: re-read the PR and start the preflight again rather than
dropping the flag.

⚠️ **`--auto` has the WIDEST exposure window, and the head pin does NOT close it.** Arming auto-merge
defers the actual merge to whenever the checks settle, so the gap between the evaluated head and the
landed commit is not the milliseconds of a direct merge but however long CI takes — and a trusted App
that pushes during that window has its new commit merged by the arming you already performed.
🔴 **Pass the pin anyway, but do not believe it covers that window.** `gh pr merge --help` defines
`--match-head-commit` as the SHA the head must match *to allow merge*, and with `--auto` the thing
being allowed is the **arming**, not the later merge — so the flag protects the same instant a direct
merge protects, and everything after it is unprotected. An earlier version of this paragraph claimed
"with the pin, GitHub refuses instead"; that was asserted without evidence and is **withdrawn**.
**So the arming is never the completion.** On any `--auto` path, confirm afterwards which HEAD merged:
`gh pr view <n> --repo devantler-tech/<repo> --json state,headRefOid` — and compare **`headRefOid`** to
the head you evaluated. If they differ, the App pushed after you armed and a commit nobody assessed
reached `main`: say so in the report and treat it as breakage to repair, not as a merge that went
through. This holds whichever way GitHub's post-arm semantics actually work, which is why it is stated
as the requirement rather than a claim about them.
🔴 **The comparison counts ONLY once `state` reads `MERGED` — read it immediately after arming and it
confirms nothing.** `--auto` defers the merge until the checks settle, so the read a run naturally
makes next returns `state: OPEN` carrying **the head you just evaluated**: the two SHAs match, and the
check reports success at the one moment it cannot have observed anything. That is worse than no check,
because it manufactures a passing record for the window the guard exists to cover. So gate it: while
`state` is `OPEN` the confirmation is **outstanding, not satisfied**, and the arming is not yet
complete.
🔴 **Persist the armed PR, because nothing else will bring you back to it.** The merge can land long
after the run ends, and once it does the PR is closed — so the next survey's **open-PR enumeration no
longer contains it**, and an unconfirmed arming silently becomes an arming nobody ever checked. Record
`<repo>#<n>` with the evaluated `headRefOid` as a run carry-forward and, while the run is still alive,
watch it the way any other deferred remote result is watched (a background watcher, never a
foreground poll — *Latency discipline*). A later run resolves an outstanding entry by reading `state`
once: `MERGED` ⇒ compare the SHAs and close it out; still `OPEN` ⇒ carry it forward again; `CLOSED`
without merging ⇒ the arming never fired, which is its own thing to look at.
🔴 **Compare `headRefOid`, NOT `mergeCommit` — `mergeCommit` is not a source-head identity field under
ANY merge strategy.** It names the commit created ON THE BASE, which is a different object from the
head that was merged: a squash condenses the branch into a new commit, a merge commit is new by
definition, and a rebase rewrites the commits it replays. So the comparison fails on a correct merge
regardless of which strategy ran — including on the **merge-queue** repos below, where `--squash` is
deliberately dropped because the queue chooses the strategy. Measured on this repository's own #2795:
`headRefOid` `789ac1145e…` merged as `mergeCommit` `9c7a132930…`. Keying the check on `mergeCommit`
therefore reports false breakage on **every valid merge** — which is worse than no check, because a
guard that always fires is one people learn to ignore. `mergeCommit` is for locating the resulting
commit on `main`; `headRefOid` is what answers "whose head merged".

### You own EVERY pull request in the portfolio — whoever authored it

**Maintainer direction, interactive session 2026-08-08:** *"you are responsible to drive all prs to
merge on devantler-tech repos. Also ones from myself or others. You just need to make sure no one else
is actively working on it before you take over. No need to ask, just determine it based on available
data. You own the code"*; then *"Closing as not relevant or detrimental is also an option, when it does
not add value, or is in direct conflict with your goals"*; and, answering whether outside contributions
were included, *"Contribution PRs is also your responsibility just be careful!"*

This **supersedes** the previous split where a PR you did not author got hygiene only and its author
promoted it. Every open PR in `devantler-tech` is now yours to carry to a **terminal state**, whoever
opened it: your own lane, a sibling registered lane, the maintainer's own interactive
sessions, our bots, and external contributors. Exact Renovate/Dependabot PRs may remain temporarily
self-progressing under the evidence-bound rule below; once that evidence fails or expires, they are
yours too.

**Three terminal states, and CLOSING is first-class.** A PR is done when it is **merged**, **closed
with the reason recorded**, or **parked on a named, live-verified blocker**. Close one when it adds no
value, duplicates work already shipped, or conflicts with where the product is going — re-filing any
still-valid finding as an issue first, and stating the reason on the PR. A stale draft nobody will
finish is not neutral: it costs review capacity, ages into conflicts, and hides the work that matters.

**"Is someone actively working on it?" is decided from data, never by asking.** Treat a PR as actively
owned by someone else — and leave it alone this run — when any of these holds:

| Signal | Reading |
|---|---|
| A push to its head within the last **~2h**, **by anyone but you** | Someone is mid-flight; do not take over |
| A **human** comment or review within the last **~2h** | A person is engaged right now |
| A review request at the current head, **still inside its provider's response envelope** | That lane owns the next move |
| An in-flight `merge_group` run for that PR | It is already being merged |

🔴 **A reviewer's COMPLETED output is the opposite of an ownership signal — it is your cue to act.**
Row 2 says *human* deliberately. A finished CodeRabbit, Codex or Bugbot review is the next move having
already been made: its findings are ready to fix now, and row 3 already covers the only reviewer state
that genuinely owns the next move — a request still inside its response envelope. Reading a completed
bot review as "a reviewer is engaged" parks the PR for ~2h against the mandatory every-run pentad
sweep, and on an hourly cadence that compounds across runs into findings that age untouched at the
current head. The maintainer's own review still parks it, because he is a human mid-flight.

🔴 **Your OWN push is not evidence that someone else is active — row 1 says "by anyone but you" for
that reason.** Every instance pushes as `devantler`, so a run that has just created or repaired a PR
meets its own push on the next sweep and reads it as a rival mid-flight, parking its own in-flight work
behind a signal it produced itself. That is self-blocking of exactly the kind this contract forbids,
and it bites hardest on the PRs a run is actively driving — the ones rung 1 most wants finished.
**Resolve it from your creation record plus the branch namespace, never from the login**, which cannot
distinguish the three instances: a push to a branch in **your own** namespace, on a PR **your creation
record covers**, and that **this run actually made**, is yours and parks nothing. 🔴 **Lane membership
is not enough, because a lane is not one writer:** your namespace is shared with the Agent Improver
schedule (*Writer namespaces*), so a sibling role can push to a branch your creation record covers.
Discounting on lane alone throws away a live sibling push and authorises writing over work in
progress. Match the push against what **you** pushed this run — branch and sha — not against the
prefix. Absent that record, treat the push as someone else's —
the same asymmetry used elsewhere, since wrongly claiming a push costs a collision while wrongly
disclaiming one costs a delay. The survey reports the branch's lane alongside the push age so this
needs no re-derivation; the discount itself is yours to apply, because only you know what you created.

Nothing else parks a PR. Age, size, difficulty, an unfamiliar author, a `HANDS-OFF` note inherited from
memory, or a branch shape you did not create are **not** reasons to skip one — re-verify against live
state and act.

**Every one of those signals EXPIRES, or a dead request reserves a PR forever.** The two ~2h windows
are measured from the event itself. A **review request** holds the PR only while its provider is still
plausibly answering — the bounded envelope in *Local review round*: the short wait when the trigger
drew no reaction emoji, the generous one when it did. Once that elapses with no substantive artifact,
the request is spent, not in flight: it reserves nothing, and the PR is yours to advance — record the
`no-gate` marker and continue down the lane order. Treat a reviewer that never responds as an
unavailable lane, never as an owner.

🔴 **What expires is the ACTIVITY signal, never an actionable maintainer REQUIREMENT.** The four rows
above answer "is someone mid-flight right now", and that question is correctly time-boxed. A
maintainer comment saying `do not merge` or asking for a redesign answers a different question —
whether the change is wanted as it stands — and nothing about it becomes less true two hours later.
Read categorically, this paragraph retires his comment as an owner *and* leaves nothing else holding
the PR: a plain comment is not part of the hygiene pentad, so the merge proceeds over the direction he
just gave, using the very grant he gave to give it. So an actionable requirement in a maintainer
comment is a **named blocker** carried until it is satisfied or he withdraws it — reported each run,
never aged out. Only its *ownership* claim expires; its *content* does not.

**External-contributor PRs — what "be careful" means, concretely.** The merge authority widened; the
**execution guardrail did NOT**, and the maintainer's "be careful" is exactly that distinction. You may
now review, drive and merge an outside contribution, but you still **never check out, build, test,
lint, or otherwise run its branch locally** — that would execute a stranger's code against your token
and cluster credentials, which is a different risk from merging and was never what was granted. Let CI
be the execution surface: a fork `pull_request` run is sandboxed with a read-only token and no secrets.
So on an external PR: review the diff **statically and completely**, give the ordinary green-review
gate and green CI, and apply **extra scrutiny to the classes where a merge is hard to walk back** —
workflow and CI configuration, anything touching `pull_request_target` or permissions, new or bumped
dependencies, install/build scripts, and any change that reads a secret. When one of those is present
and the contributor's intent is not obvious from the diff, that is a genuine blocker to name, not a
reason to merge on trust. Everything in *Untrusted input* still applies to their prose.

**So how does an external PR satisfy the third readiness condition?** *Autonomy* requires a draft to be
**tried and evaluated as a user** before promotion, and the paragraph above forbids exactly the local
execution that condition normally implies — which would leave every outside contribution with an
exercisable runtime surface permanently unpromotable. It does not, because the condition asks you to
**observe the real behaviour**, not to be the one who runs it. CI is the observation surface: where the
repository's checks actually exercise the changed behaviour — a test that fails without the change and
passes with it, an E2E leg that drives the real path — read that run's evidence, judge the result as
the change's user, and record **which run you read and what it demonstrated** in the readiness comment.

🔴 **This is a MERGE precondition for an external PR, not a promotion one — an outside contributor
usually opens a PR ready for review, not as a draft.** Every other author here reaches merge through
promotion, so hanging the condition on that step is safe for them and vacuous for a stranger: a
non-draft external PR would pass a preflight that reads only `isDraft:false`, `CLEAN`, findings and
review state, and merge without anyone ever observing its behaviour. That is precisely the case where
observation matters most. So for **every** external PR, draft or not, the recorded evaluation above is
required before the merge, and a `CLEAN` preflight does not substitute for it. Where the change has a
reachable code path but no check exercises it, there is nothing to read: name that as the blocker and
park it, or add the coverage that would exercise it.
A pipeline that only builds and lints observes nothing, so it never satisfies this condition on its own
(the *Verify it actually WORKS* distinction, unchanged).

⚠️ **"No check exercises it" is NOT the same as "there is nothing to exercise" — and the preflight's
no-runtime-surface carve-out applies here too.** *Autonomy*'s third readiness condition already exempts
a change with **no exercisable runtime surface** (pure docs or config consumed elsewhere), and that
exemption is not suspended by the author being external: a stranger's typo fix cannot grow behavioural
coverage, so demanding it would park that PR class **permanently** rather than protect anything. For
that class the record attests the equivalent **static** evaluation — trace the change to what consumes
it, state that it has no runtime surface and why — on the same author bind. Anything with a reachable
code path still owes the CI reading.

**When a change HAS a reachable code path and no check reaches it, that is a blocker to name — never a
condition to wave.** The honest terminal state is then **parked on a named blocker**: say so on the PR
and ask the contributor for the missing coverage. The two wrong moves are promoting on a build-only
green and reaching for the local execution the guardrail forbids. Writing the missing check
**yourself, on your own branch against `main`**, is legitimate and often the best answer — it is your
code rather than theirs, and once it merges the contribution becomes observable.

**Dependency-automation ownership is a timed state, not an exclusion.** Preserve a positively
self-progressing bot lifecycle, but take over the exact PR when live evidence proves it cannot finish
itself. This is the 2026-08-21 maintainer correction to the earlier 2026-07-16 hands-off rule.

**Nothing here lowers the bar.** The three genuine-readiness conditions, the hygiene pentad, and the
green-review gate are unchanged — this widens **who may drive a PR**, never **what makes one ready**.

**Merge-queue repos — root-cause a stall or kick-out BEFORE re-queuing; never blindly re-`--auto`.**
Some repos gate `main` behind a **GitHub merge queue** (a `Require merge queue` ruleset). On these,
`gh pr merge --auto` *enqueues* rather than merges, `autoMergeRequest` stays `null` even while queued,
and the strategy is set by the queue, so **drop `--squash` and keep the head pin**.
🔴 **A merge queue does NOT widen who may use `--auto`.** The author matrix above is a closed list of
two — `github-actions` and `ksail-bot` — and prescribing `--auto` here unconditionally
would put `devantler`, an external contributor and the classifier-conditioned updater through exactly
the deferred path their author policy forbids. It is also unnecessary: on a queue-gated branch, a PR
whose checks have passed is **added to the queue by a plain merge**, so the enqueue happens either way.
So the three `--auto` authors use
`gh pr merge <n> --repo devantler-tech/<repo> --auto --match-head-commit <sha>`, and **every other
author enqueues with `gh pr merge <n> --repo devantler-tech/<repo> --match-head-commit <sha>`** once
the gates are clear. **Record per-repo
whether a merge queue is in use in that repo's `AGENTS.md ## Maintenance`** (confirm once via `gh api
repos/<owner>/<repo>/rulesets --jq '.[]|select(.name|test("merge queue";"i"))'`), so a run knows the
merge mechanics without re-deriving them. A PR enters the queue, runs the `merge_group` checks, and is
**evicted if any `merge_group` check fails** — so a PR that "was queued" but didn't merge has almost
always been **kicked out by a failed `merge_group` run**, NOT "draining slowly". Before re-queuing,
**always pull the PR's `merge_group` run and root-cause the failure** (`gh run list --repo <r> --event
merge_group --json headBranch,conclusion` → find `pr-<n>` → `gh run view --log-failed`). Re-queuing
without diagnosing just re-hits the same failure (the exact miss the maintainer flagged: re-`--auto`-ing
an own PR while its `merge_group` deploy kept failing on the known platform Cilium-flake — see platform
`#2337`). If the `merge_group` failure is a **known systemic flake**, re-queuing is futile until the
**root cause** is fixed — land/advance that fix first (don't loop the PR through the queue). Only when
the failure is a genuine one-off transient (runner OOM, network) is a clean re-queue the right move.

**Dependency automation is first-responder, not sole owner.** Include exact Renovate/Dependabot PRs,
including major-version bumps, in the liveness sweep. Leave a positively self-progressing current head
alone; deepen and repair one that is unable to merge autonomously, then use the same head-pinned merge
preflight and repository mechanics as any other trusted PR. Do not burn review capacity on an untouched
bot head when the repository's established automation path exempts it; an adaptation commit restores
the semantic-review gate. If the resulting change later breaks `main`, the normal `main` hotfix path
still applies.

For every other actionable PR — whoever authored it — the merge itself is
**low-ceremony**: use the current survey pentad plus a **fresh**
`gh pr view <n> --repo devantler-tech/<repo> --json number,state,isDraft,author,title,headRefOid,mergeStateStatus,statusCheckRollup`
immediately before merging.
🔴 **`title` is in that list because the head pin does NOT cover it.** Editing a PR title changes no
commit, so `--match-head-commit` still succeeds — and the squash subject comes from the title, which
becomes the changelog and release input. An author who edits the title after the routine normalised it
(most reachable on an external PR, where the editor is the party the preflight exists to check) lands a
non-Conventional subject through a merge that passed every other gate. So **re-validate the title
against Conventional Commits in this final read**, not only when you set it.

🔴 **`state` is in that list because every other field reads the same on an ALREADY-MERGED PR as
on a healthy one still computing mergeability.** A merged PR returns `isDraft:false`, the author, a
Conventional title, a real `headRefOid`, a full green `statusCheckRollup` — and
`mergeStateStatus:UNKNOWN`, which also occurs while an open PR's mergeability is being computed.
`UNKNOWN` does not satisfy `CLEAN` or exception (a); an open PR with that value cannot proceed to merge.
Nothing in the seven-field list distinguishes the two, so the run diagnoses a
phantom blocker on work that is already done. Measured twice: `world-at-ruin#740` on 2026-08-20, read
34 minutes after it merged; and `monorepo#3220` on 2026-09-06, read **5h22m** after it merged as
`b7c4b29563`, with 77/77 checks green, zero unresolved threads, a Codex green at that exact head and
every commit `verified=true` — roughly eight calls spent chasing a blocker that did not exist,
including a rulesets read and a per-commit signature check. The REST fields in those merged-PR
observations also stayed unhelpful (`mergeable=null`, `mergeable_state=unknown`, stable across repeated
reads); re-reading mergeability could not identify their terminal state. `state` is decisive where
none of the others is, it is the same field *Merge policy*
already names for confirming a merge landed, and it costs nothing — the eight-field read is accepted
by `gh` unchanged. **Read it first: continue only when `state` is `OPEN`. `MERGED` and `CLOSED`
end the preflight; do not diagnose their mergeability. A failed or missing state read is `UNKNOWN`
and authorizes no action.**

🔴 **The preflight field list CANNOT see review-thread resolution — and an unresolved thread is a
REQUIRED merge rule on every repository here.** `required_review_thread_resolution: true` is set on
**all nineteen** portfolio repositories (2026-08-20 — every repo in the Portfolio map, no
exception), via one of the `pull_request` rules on
`main`, so an unresolved thread blocks the merge exactly like a failing required check. Yet
`mergeStateStatus` reports it only as a bare `BLOCKED`, and **no `gh pr view --json` field carries it
at all** — so the seven-field read above is structurally blind to it.
⚠️ **`reviewThreads` is NOT a valid `gh pr view --json` field** (verified against the live CLI), so
"helpfully" adding it to the preflight would void the **whole** read — the same all-or-nothing failure
the post-merge `merged` field causes, in the one place the merge gate cannot afford to go blind. Read
it over GraphQL, as its own call:

```sh
threads=$(
  set -o pipefail   # WITHOUT this a failed read prints the ALL-CLEAR value: `false | jq -s …` emits 0, exit 0
  gh api graphql --paginate -f owner=devantler-tech -f name=<repo> -F number=<n> -f query='
query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      reviewThreads(first:100,after:$endCursor){
        totalCount
        nodes{isResolved}
        pageInfo{hasNextPage endCursor}
      }}}}' |
    jq -s -r '[.[].data.repository.pullRequest.reviewThreads]
              | "\([.[].nodes[]]|length) \(.[0].totalCount) \([.[].nodes[]|select(.isResolved==false)]|length)"'
) || { echo "thread read FAILED — UNKNOWN, never 0" >&2; exit 1; }
fetched=${threads%% *}; rest=${threads#* }; total=${rest%% *}; unresolved=${rest##* }
[ -n "$fetched" ] && [ "$fetched" = "$total" ] ||
  { echo "thread read TRUNCATED: fetched $fetched of $total — UNKNOWN, never 0" >&2; exit 1; }
```

**Prefer the tested helper that implements exactly this read:**
[`pr-unresolved-threads.sh devantler-tech/<repo> <n>`](../scripts/pr-unresolved-threads.sh)
prints `unresolved=<n> total=<t>` (exit 0 for zero, 1 otherwise) only on a complete read, and
`UNKNOWN …` with exit 2 on a failed, partial or malformed one — never a zero (monorepo#2670). The
run's merge preflight calls it directly. The read-only surveyor pipes the same query into
`pr-unresolved-threads.sh --input -`, a classifier its guard admits by declaration, so the survey's
field (b) and the preflight produce the same count.

**That must read `0` immediately before the merge — not once, earlier, from the survey.** The survey
pentad does carry unresolved threads, but it is a **snapshot taken earlier in the run**, and this
fresh read exists precisely for state that moves after that snapshot — the same reason `title` is
re-validated above. Every review lane re-reviews on each push and can post at any moment: on
monorepo#2927 the blocking review landed **93 minutes after** the PR was promoted. So a survey-time
zero is not evidence at merge time.

🔴 **A FAILED read must never satisfy this gate — that is why the command captures and checks instead
of piping straight to `jq`.** Without `pipefail`, `gh api … | jq -s …` on an auth, network, or API
failure leaves an empty stream, `jq -s` evaluates it as `[]`, prints **`0`**, and exits **`0`** —
reproduced directly (`false | jq -s '[.[]]|length'` → `0`, rc `0`). The all-clear value and the
broken-read value are the same character, so the gate would pass hardest exactly when it can see least.
Treat a non-zero exit as **UNKNOWN, never as zero**, and merge only on a `0` a successful read produced.

🔴 **`--paginate` and the `pageInfo` cursor are REQUIRED, not tidiness — a first-page-only read
silently under-counts.** `reviewThreads(first:100)` returns at most one page, so a long-lived PR whose
threads exceed 100 reports a **partial** count, and the one number this gate depends on reads `0` while
unresolved threads remain. That is the same failure the rule exists to prevent, one level down: a read
that looks authoritative and is not. Note `--slurp` is **not** usable here — `gh` rejects it together
with `--jq` — so the pages are slurped with `jq -s` instead.

🔴 **The truncation check is what makes that number TRUSTWORTHY — the cursor and the page size are two
independent ways to lose threads, and neither loss is visible in the answer.** Measured 2026-08-29
against `platform#3311` (73 threads), varying only those two:

| `first:` | `--paginate` | fetched | `totalCount` | reported unresolved |
|---|---|---|---|---|
| 20 | yes | 73 | 73 | 0 — complete |
| 20 | **no** | **20** | 73 | **0 — over 53 threads never fetched** |
| 50 | **no** | **50** | 73 | **0 — over 23 threads never fetched** |
| 100 | no | 73 | 73 | 0 — complete *only* because 73 < 100 |

So it is the **conjunction** that bites. With the cursor wired a small page is merely slower; without
it, any page below the thread count truncates — and `first:100` survives today only on headroom
(sampling the 60 most recently updated PRs in each of monorepo, platform, ksail, actions and
agent-plugins on 2026-08-28 — **300 PRs — the maximum was 73 and none exceeded 99**). A run that "tidies" the page
size down while dropping `--paginate` moves this from latent to live, and **nothing in the response
distinguishes 53 resolved threads from 53 unfetched ones**: both render as `0`, the value the gate
accepts.
⚠️ **That is why the read above asserts `fetched == totalCount` instead of trusting either flag.**
`totalCount` arrives in the same response at **zero extra cost**, so the gate verifies its own
completeness rather than depending on argv discipline no reviewer can see. Treat a shortfall exactly
like a failed read: **UNKNOWN, never `0`.**
⚠️ **`--repo` is part of the prescription, not an optional convenience** —
none of those fields carries the *base* repository's identity (`headRepositoryOwner`, where it exists,
names the contributor's **fork**), so without the flag the command resolves against whatever checkout
the run happens to be standing in. Across a cross-repo sweep a colliding PR number then reads a
different repository's PR while appearing to satisfy the ownership check. Pinning `--repo` is what
makes owner `devantler-tech` an actual test rather than an assumption.
The result must show `state:OPEN`, `isDraft:false`, owner `devantler-tech`, and
`mergeStateStatus:CLEAN`; the pentad must show zero review findings and a green review from any lane
(CodeRabbit, Codex, Cursor Bugbot) —
or a qualifying clean **local
review round** under *Local review round*, on the same author terms that section sets: available on
your own **and on taken-over** PRs (a sibling lane's, the maintainer's interactive, one of our bots'),
and **never** on an external contributor's — whose commit SHA
equals that same `headRefOid`.

🔴 **On an EXTERNAL PR that list is NOT sufficient — it is missing the one condition that PR class
exists to enforce.** *You own EVERY pull request in the portfolio* makes the recorded CI-based
behaviour evaluation a **merge** precondition for every outside contribution, draft or not, precisely
because a stranger's PR usually arrives non-draft and so never passes through promotion. None of the
fields read above carries it, so a preflight that stops at `isDraft:false` + `CLEAN` + findings +
review state merges exactly the PR nobody has observed. So for an external author, additionally
require a **current-head evaluation record** — a comment naming the **CI run you read** and
**what behaviour it demonstrated** — whose commit SHA equals that same `headRefOid`, and re-record it
after any push, since a new head stales it exactly as it stales a green review. **Build-and-lint-only
CI never satisfies it**, and a `CLEAN` preflight never substitutes for it: where a check *could*
exercise the change but none does, there is nothing to read, so **park the PR on that named blocker**
and ask for the missing coverage — or add it yourself on your own branch against `main`.
⚠️ **"No check exercises it" and "there is nothing to exercise" are different, and conflating them
makes a whole PR class unmergeable forever.** *Autonomy*'s third readiness condition already carves
out a change with **no exercisable runtime surface** — pure docs or config consumed elsewhere — and
that carve-out is not suspended by the author being external; a stranger's typo fix cannot grow
behavioural coverage, so demanding it would park the PR permanently rather than protect anything.
For that class, record the equivalent **static** evaluation instead: trace the change to what
consumes it, state that it has no runtime surface and why, and name that reading in the record. The
record and its author bind are unchanged — what changes is what the record may attest. Reserve this
for changes with genuinely nothing to run: anything with a reachable code path owes the CI reading.
🔴 **Two things about that record are load-bearing on THIS PR class specifically, because the author
is the one party the record is protecting against.**
**First, bind it to an authorized author, because the disclosure prefix is **NOT** authentication.**
It is a
public convention, reproduced verbatim by CodeRabbit and typeable by anyone, so a record admitted on
the strength of that prefix lets the **external contributor manufacture their own merge
precondition**: they post a disclosed comment asserting a run demonstrated their change, and the one
condition this paragraph exists to impose is satisfied by the person it exists to check. Require
**author exactly `devantler`** — the agent/maintainer account — and note that the sibling-ambiguity
that weakens exact-author matching elsewhere does **not** apply here, because the external
contributor is by construction not that login.
**Second, read the run itself — a record is a claim, not evidence.** Verify against the API that the
cited run **exists**, that its `conclusion` is `success`, and that the commit it ran against equals
`headRefOid`; a comment can name a run that failed, that ran on another head, or that never existed.
Only after the run has been read does its named behaviour count. That is **sufficient
evidence** — then run the merge. **Two documented exceptions to `CLEAN`, and only these two:**
(a) a `mergeStateStatus` that says `UNSTABLE`/`BLOCKED` while **every** check-run and status on the
head is `success`/`skipped` is simply **stale** — GitHub recomputes it lazily (measured on
`actions#661`: 120/120 green, UNSTABLE, and `PUT /pulls/<n>/merge` succeeded first try), so re-read
it once and then let the merge API be the authority, since it enforces every real rule and refuses
cleanly if one applies; and (b) the **review provider's own quota status** — a
`CodeRabbit / failure — Review rate limit exceeded` context — which reports service state rather
than a verdict and is excluded per *Local review round*. Anything else non-green is a real blocker.

🔴 **Exception (a) requires the unresolved-thread count above to read `0` FIRST — unresolved threads
produce precisely the signature it tells you to dismiss.** `BLOCKED` with every check-run and status
`success`/`skipped` is exactly what an unresolved thread looks like, because no check expresses it; so
read as written, (a) classifies a **real blocker, never staleness** as staleness, on a rule that is
live in every repository here. Measured on monorepo#2927 at head `cc7ac05b` (2026-08-20): `MERGEABLE`,
`BLOCKED`, **zero** failing checks, **zero** open code-scanning alerts repo-wide (unfiltered control),
no `CHANGES_REQUESTED` — and **two** unresolved threads. Promoted 05:59:20Z; the blocking review landed
93 minutes later, after promotion. (a) still holds for genuine lazy recomputation — it is scoped to a
head whose threads are already resolved, not widened.

🔴 **Exception (a) also requires the head's REQUIRED gate set to be complete — a gate that never
reported wears the same all-green costume** (#2730). `statusCheckRollup` lists what ran, never what
should have run: platform#2704 carried 16 of 27 checks because its head predated 12 required
workflows, and ksail#6645's required workflow failed before creating a job, so no check-run existed.
Before reading `BLOCKED` as stale, compare the head against the branch's rulesets and classic
protection instead of the rollup:

```sh
.claude/scripts/required-gate-completeness.sh --repo devantler-tech/<repo> --base <baseRefName> --head <headRefOid>
```

- **Exit `0` (`COMPLETE`)** is the only reading under which (a) applies.
- **Exit `1`** names each `MISSING`, `FAILED` or `PENDING` gate. That gate is the blocker, and it is
  never stale. A head missing a required check does not satisfy the promotion gate's check condition.
- **Exit `2` (`UNKNOWN`)** never reads as stale either. That includes an active `code_quality` rule,
  which is always `UNVERIFIED` because no readable surface reports its analysis for a head. The merge
  API may still decide, but diagnose a refusal or a no-op from the gate lines, starting with the
  `code_quality` setup state they name (monorepo#3404).

**A required workflow MISSING because the head predates it is fixed by updating the branch**, which
runs every workflow again at a new head:

```sh
gh api --method PUT repos/devantler-tech/<repo>/pulls/<n>/update-branch -f expected_head_sha=<headRefOid>
```

It merges the base and never rewrites history. On another lane's PR it is the repair push *Autonomy*
already permits once the active-work test shows the PR unowned. On an external contributor's PR it
is the same API call and runs nothing locally. Every push stales the green review, so re-secure it at
the new head.
Otherwise `CLEAN` is authoritative for required checks: don't re-derive required
checks from the rollup, don't re-fetch branch protection on every merge (it's confirmed **once per
repo per session**), and don't bundle the evidence and the merge into one chained command. Driving a
promoted, CLEAN PR to merge is the **expected, mandated** behaviour, not a risk to
re-weigh each time. In the rare case a merge is still refused, **don't burn the run** re-emitting
variant evidence or retrying — leave the PR green with threads resolved and surface it to the
maintainer as a one-click; that is the uncommon fallback, not the default.

🔴 **DIAGNOSE the refusal before escalating it — a refusal is not self-explaining, and the contract
above sends you straight past the most likely cause.** A `the base branch policy prohibits the merge`
refusal with every check green is **most often unresolved threads**, which is ordinary agent-fixable
hygiene rather than anything the maintainer can help with. Read the unresolved-thread count above
first, and escalate only once you have named a cause you genuinely cannot act on. Recording an
undiagnosed refusal as "maintainer-gated" is worse than losing the run it happened in: per *You own
EVERY pull request in the portfolio*, no undefined permanent-sounding gate may park a PR — and once
that label reaches durable memory it teaches every later run, in every lane, to skip the same
completable PR.

🔴 **`gh pr merge` is NOT the merge API — it checks `mergeStateStatus` itself and refuses before it
ever calls the endpoint, so exception (a) cannot be reached through it** (#2710). Measured on
`.github#138` at head `7c2e2b38` (2026-08-06): `gh pr merge` refused with *"the base branch policy
prohibits the merge"* on two consecutive ticks, while `PUT …/pulls/138/merge` merged the same head at
the first attempt, seconds later. **That refusal text names no rule**: it is not evidence of any
specific policy and never seeds an issue on its own (it cost that run a wrong one, #2709). So when
`gh pr merge` refuses a PR whose unresolved-thread count read `0` and whose every check-run and status
at the head is `success`/`skipped`, re-read `mergeStateStatus` once, and if it is still not `CLEAN`,
call the endpoint the contract already names as the authority:

```sh
gh api --method PUT repos/devantler-tech/<repo>/pulls/<n>/merge -f merge_method=squash -f sha=<headRefOid>
```

`sha` is the endpoint's own head pin — it refuses when the head has moved, exactly as
`--match-head-commit` does — so never drop it. **Its response decides:** merged, or a refusal that
names the unmet requirement, which is then diagnosed like any other. The fall-through is **bounded to
that pentad-clear case**: never for a PR with a failing or pending required check, an unresolved
thread, or any other gate above unmet (every precondition in this section still applies, the
external-contributor evaluation record included), and never on a merge-queue repository, where the
queue owns the merge and `gh pr merge` only enqueues.

🔴 **A merge command's exit `0` is not a merge.** On platform#2704, `gh pr merge` exited `0`, printed
nothing and did nothing, because required checks were missing (#2730). So the confirmation read below
is part of every merge. Unless `state` reads `MERGED`, or the PR is in the merge queue on a
merge-queue repository, the merge failed: run the completeness check above and diagnose it. Never
record it as merged.
**Confirming the merge landed: `gh pr view <n> --repo devantler-tech/<repo> --json state,mergedAt` —
there is NO `merged` field.** This read was unprescribed territory, and the improvisation it invited
costs more than one value: `gh` rejects the **whole** `--json` request when any single field is unknown,
so the common `state,merged,mergedAt,mergeCommit` set returns *nothing* and the run cannot tell whether
its own merge succeeded — blind at the top of *The work-selection ladder*. `merged` exists on **none**
of `gh pr view`, `gh pr list`, `gh search prs`. Read `state` (`MERGED`), adding `mergedAt` or
`mergeCommit` only when you need the timestamp or the squash sha. ⚠️ **The whole command is the
prescription, not the field list** — field vocabularies are per-subcommand, so `gh search prs` rejects
`mergedAt` outright (verified) and `state` does not mean the same thing on every surface. (Measured
2026-07-29 by distinct sessions: 23 of 204 hit `Unknown JSON field: "merged"`, up from 8 of 211 — and
up ~3.5× **per merge**, so not an artifact of the densified cadence.)
**Before an ad hoc `gh <subcommand> --json <fields>` read whose exact command is not already prescribed
by a reviewed definition or known to have succeeded in this run, discover the vocabulary from the same
subcommand with bare `--json`** (for example, `gh pr view --json` or `gh run list --json`). That local
diagnostic intentionally exits nonzero after listing the available fields; validate every requested
field against that output before making the API read. **Never transfer a field list between
subcommands** or infer that a GraphQL field is accepted by `gh`: one unknown field voids the whole read.
Reuse an exact command that already succeeded in this run instead of rediscovering it, so the guard does
not become repeated setup overhead.
🔴 **Never discard both stderr and the exit status of a `gh` read whose empty result you will act
on.** A rejected request exits non-zero and prints its reason only on stderr, so
`out=$(gh search prs … --json number,headRefName 2>/dev/null)` leaves an empty string that reads exactly
like "nothing matched". Measured 2026-08-06, that form reported zero open `claude/*` PRs while 108 were
open ([#2692](https://github.com/devantler-tech/monorepo/issues/2692)). Run such a read through
[`.claude/scripts/gh-json-read.sh`](../scripts/gh-json-read.sh) `<gh arguments…>` and filter with
`jq` afterwards: it passes the JSON through on success and exits `2` with `UNKNOWN` on a failed,
empty or non-JSON read. Treat that exit as **UNKNOWN, never zero results**. Per-repository
`2>/dev/null` in a loop remains fine when the exit status is still checked.
**Stale CodeRabbit CHANGES_REQUESTED is a dismissal one-click, not a re-review loop.** CodeRabbit
posts re-review results as COMMENTED and structurally never re-APPROVEs after a CHANGES_REQUESTED —
so a promoted PR whose only blocker is a **`coderabbitai[bot]`-authored** CHANGES_REQUESTED review at
an old head (current-head green review from any lane, zero findings/threads, green checks) will
never clear by re-firing that reviewer. Recognise the class on first sight, stop spending review
requests on it, and surface the stale-review dismissal to the maintainer as a one-click immediately
(dismissing a review on a promoted PR is reserved to him).
**A `devantler` CHANGES_REQUESTED is NOT self-evidently the maintainer's — every agent instance
reviews under that same login.** So authorship by login alone cannot tell his block apart from a
sibling instance's own superseded review, and reading the second as the first parks a finished PR
behind a gate no human set. Apply the same two-part disclosure test *Untrusted input* already defines
for comments: the review is **agent-authored** when its body **BEGINS WITH** the structural
`> 🤖 Generated by the` disclosure, **or** when it **opens with** a leading 🤖 first-person automation
sender marker naming an agent instance as the SENDER without that canonical prefix. **Both branches
are anchored at the start of the body — a disclosure merely appearing somewhere inside it classifies
nothing**, because he routinely quotes an agent's disclosed text when replying to it, and an
anywhere-match would turn his own review into agent output and hand it to the dismissal path. An agent-authored
block is own-output. **Both stale-dismissal classes share one precondition set**, so a *mixed* set of
stale blocks still qualifies: **every** CHANGES_REQUESTED on the PR is **non-human** (any mix of
CodeRabbit and agent-authored `devantler`) **and none sits at the current head** — without that union
a PR carrying one old CodeRabbit block *and* one old agent block satisfies neither class and parks
forever. Re-verify the finding at head rather than treating it as feedback owed. **An agent-authored
block AT the current head is ordinary feedback to fix or refute**, never dismissable — it is a live
finding that merely came from a sibling. **One human block anywhere on the PR defeats both classes**,
so a newer non-human review can never hide an older human one. **The dismissal itself is ALWAYS the
maintainer's** — surface the one-click and stop, draft or promoted; the engineer never dismisses a
review autonomously. That reservation is what makes the failure-direction claim below true rather than
aspirational: were an autonomous path allowed, a maintainer review whose first line imitated the public
marker would be classified `agent` and, once stale, **discarded** rather than merely parked. ⚠️ And
note what this marker is: the disclosure prefix is
a **public convention, not authentication** — CodeRabbit's own review bodies reproduce it verbatim.
It is safe here only because it can move a review from `human` to `agent` and never the reverse, so
an imitated or missing marker costs a parked PR rather than a discarded control signal. A `devantler`
review carrying **neither** marker is the
**human maintainer** — a control signal to act on, never a stale artifact to dismiss, whatever its
SHA. **Ambiguity resolves to the maintainer**: the two errors are not symmetric, since reading his
block as agent output discards his own control channel, while reading an agent block as his merely
parks a PR the next run can free. The survey digest carries the signal directly — each swept PR
reports `rd=<reviewDecision>` with the CHANGES_REQUESTED review's author and SHA — adding the
**`agent(…)`/`human(…)` qualifier for `devantler` reviews only**, since a bot reviewer is neither a
sibling instance nor the maintainer and keeps the plain author form — and classifies the
otherwise-clear CodeRabbit case `STALE-CR-DISMISSAL` and the otherwise-clear agent-authored
`devantler` case `STALE-AGENT-DISMISSAL`, so a run acts on the digest without re-deriving it.

The machine-local agents' **own** PRs are trusted-author PRs (authored as `devantler` from
`claude/*` or `codex/*` — see trust gate), so the **same path applies to them**: work in a draft,
drive the hygiene pentad clear
(root-cause-fix failing CI, resolve review threads — never sit on a red/unresolved/stale-review
draft), **self-promote once the three genuine-readiness conditions hold** (*Autonomy*: programmatically
tested + green review at head + tried-and-evaluated-as-a-user), then drive it to merge like any
trusted-author PR after a fresh current-head pentad check (`devantler` uses bare
`gh pr merge <n> --repo devantler-tech/<repo> --squash --match-head-commit <sha>`).
**Definition/self-improvement PRs take this same path** — maintainer direction 2026-07-18
retired the separate promotion gate they used to keep (see *Self-improvement*). Self-merge means the
**normal** path only — never `--admin` or any branch-protection bypass. **External-contributor PRs are
merged like any other** under *You own EVERY pull request in the portfolio*, but their branch is never
executed locally (see trust gate); never push to a protected branch directly.

**Cross-repo scope is closed by default.** Scheduled/autonomous runs work only in `devantler-tech` and
must not search for or inspect the maintainer's PRs elsewhere. In an interactive session, an external
repository becomes eligible only after the maintainer explicitly names it and confirms in the current
conversation that it is unrelated to professional work. After that confirmation, work remains limited
to the specifically authorised task; `devantler` authorship may satisfy the author trust check but
never expands repository scope. Existing PR fixes, read-only review, branch execution, and metadata
inspection all require the same boundary clearance. Never merge outside `devantler-tech`; leave an
authorised upstream PR green with threads resolved for its maintainer.

**Ask the maintainer before creating ANY upstream issue or PR — `devantler-tech` is exempt.** Only
after the professional-work boundary has been explicitly cleared may an external contribution even be
prepared or inspected. Creating its issue or PR then needs a second, explicit approval via the ask
tool. Approval to inspect or fix an existing PR is not approval to create a new artifact. If either
confirmation is missing, do nothing outside the portfolio.

**Respect each upstream project's contribution policy — check it BEFORE opening anything.** Before
creating a PR *or* issue on a non-`devantler-tech` (third-party) repo — **once both the professional
boundary and creation gate above are cleared** — check that project's stated
contribution policy, **in particular whether it accepts AI-assisted / AI-generated contributions**
(read its `CONTRIBUTING`, `README`, PR/issue templates, code of conduct). If the project **prohibits or
discourages** AI contributions — or the policy is **unclear** — do **NOT** open the PR/issue yourself:
prepare and verify the work locally on a branch, then **hand it to `devantler` to submit under his own
name**, and surface it in the report. This refines *contribute-upstream-don't-fork* — the **prepare**
step is yours, but the **submit** step is the maintainer's wherever a project bans AI contributions.
(Evidence: `zizmorcore/zizmor` — and its in-repo crates `github-actions-models` / `yamlpath` — **bans AI
PRs**; opening one there was a misstep. `rhysd/actionlint` has **no** such policy, so AI PRs are fine
there.) This never loosens any other guardrail; it only adds a pre-flight check.

## Dependency-automation and programmed bot PRs

**Dependency-automation PRs are conditional operate work.** Dependency-automation issues remain
**AUTOMATION-OWNED (NO-ACTION).** Maintainer direction 2026-08-21 supersedes the PR half of the
2026-07-16 hands-off rule; the issue half confirmed 2026-07-21 via #2349 is unchanged. Match only the
exact app identities: org-search/REST surfaces expose `renovate[bot]` and `dependabot[bot]`; deeper
GraphQL / `gh issue view` surfaces may expose `app/renovate` and `app/dependabot`. Do not key either
classification on the unreliable search `is_bot` field, titles, branch names, dependency labels, or
commit provenance.

**Issues stay out completely.** A Dependency Dashboard is a live control surface owned by the bot
(for example `platform#313`); never select, triage-as-work, edit, or close an issue authored by one of
those exact identities. Closing it changes dependency automation's behaviour.

**PRs get a first attempt from repository automation, not permanent immunity from engineering.** A
dependency PR is **self-progressing only while** current evidence proves one of these states at its
exact head: a check/update job is pending inside its normal execution envelope; a bot update/rebase
request is actively being served inside its normal schedule; auto-merge or a merge-group is armed and
still in flight; or the current head has just become green and remains inside the repository
automation's ordinary merge window. The author identity alone proves none of them. A missing or failed
join is `QUERY-UNKNOWN` for that PR, never `NO-ACTION` and never mutation clearance.

A dependency PR is **unable to reach merge without a new agent action** — and therefore ordinary
rung-one work — when current evidence shows any of these: a required check failed, was cancelled, or
never dispatched after its expected window; the branch is DIRTY/conflicting or behind with no live bot
update; the exact head is green but auto-merge was never armed or did not advance inside the normal
window; a merge-group was evicted or failed; or the ecosystem is pinned at its configured open-PR
limit by PRs in those states. Silence alone is not a stall, and an actively pending check is not a
failure. Queue-wide creation/merge history remains useful corroboration, but it is no longer required
when one PR's exact evidence already proves that it cannot finish itself.

The survey emits `AUTOMATION-OWNED (SELF-PROGRESSING)` only with the positive evidence and timestamp
that justify it. It deepens every suspected or expired bot PR through the same current-head checks,
conflict, queue, and control joins as other rung-one work and emits `NEEDS-FIX`, `MERGE-READY`,
`ACTIVELY-OWNED`, or `QUERY-UNKNOWN` normally. A stalled bot PR counts against `nothing_on_fire` and
blocks issue descent until repaired, merged, or parked on a named live blocker.

Repair the root cause with the least invasive action that can finish the exact head: diagnose before
retrying; rerun only a demonstrated transient once; request the bot's update/rebase where that can
succeed; push a minimal adaptation commit to the trusted bot branch when the dependency change itself
needs it; and arm or execute the repository's head-pinned merge path when readiness holds. An untouched
bot-generated head keeps the repository automation's existing no-agent-review path. Any agent-authored
adaptation commit restores the ordinary current-head semantic-review gate before merge. Always
convert the PR to draft before the first adaptation push, disable any existing auto-merge request,
and confirm both states. Draft state is the durable fence: repository automation can re-arm
auto-merge after a push. Promote from draft and re-arm only after the adapted head satisfies that
review gate. Major-version
bumps are included; difficulty changes the work, not ownership. If a merged dependency bump breaks
`main`, repair that resulting breakage normally as well.

**Carve-out — trusted programmed bot PRs need NO review.** Two suite-owned paths are intentionally
gated by required CI and auto-merge rather than an AI review:
- **Programmed agent-skills updater PRs** (maintainer direction 2026-07-23): the shared
  `update-agent-skills` workflow's exact `deps/agent-skills-update` branch and
  `chore(deps): update agent skills` title in `platform` and `ksail`, authored by
  those repositories' exact updater App and changing only their generated installed-skill roots —
  **and only where every changed skill is owned by the reviewed suite upstream** (see below).
- **Programmed release PRs** (maintainer direction 2026-07-13, ksail#6095; widened 2026-07-18):
  every product's Homebrew-tap cask PR, including World at Ruin's CD-generated
  `chore(cask): update world-at-ruin to vX.Y.Z` PRs on `goreleaser/world-at-ruin`, plus KSail release
  version bumps.

**`agent-plugins` updater PRs require semantic review.** Bundled skills are executable agent
instructions sourced from several upstreams, so path and commit provenance prove who produced an
update but cannot prove that its prose preserves authority boundaries. The exact classifier returns
3 for a genuine generated marketplace update: that state makes the App trusted and actionable but
does not grant the no-review carve-out. Only exit 0 grants the carve-out described above.

🔴 **An installed-skill root holds copies from SEVERAL upstreams, so its path proves where a file
landed and never who wrote it.** `platform` and `ksail` install third-party skills alongside
suite-owned ones, so actor, branch, title, path and commit provenance together still cannot tell a
reviewed suite change from a third-party instruction change riding the same generated PR. That gap is
not hypothetical: the `gh-stack` update carried an unconditional whole-stack merge instruction that
only semantic review caught, and every mechanical signal on that PR was valid.

🔴 **Do NOT resolve that ownership from the skill's own `metadata.github-repo`** — that is the obvious
design and it is self-attesting. There is no lockfile and no install manifest: the **only** record of a
skill's origin is frontmatter inside the copied `SKILL.md`, authored by the very upstream it names and
copied verbatim by the updater. A third-party release that sets
`metadata.github-repo: https://github.com/devantler-tech/agent-skills` alongside an unsafe instruction
would then be read back as proof of our ownership and skip review — the same hole one level down.

Authorization comes instead from
[`.claude/skill-ownership-allowlist.tsv`](../skill-ownership-allowlist.tsv), a reviewed,
version-controlled list kept **outside** the skills, mapping `<repo>` + `<installed skill root>` to the
upstream that owns its content. Every changed root must be listed for that repository, or the PR
returns **3**. Absence is the default, so a newly installed skill and a third-party one are treated
alike until someone deliberately adds a row through the normal review path.

The classifier's eighth argument — a JSON object mapping each changed root to the
`metadata.github-repo` read at the PR head — is a **corroborator, never an authorization**. Supplying
it can only withdraw the carve-out, never grant it: it catches an upstream handover, where a skill we
still allowlist has quietly started declaring someone else. It is **required on this arm** and
omitting it returns **3** — a tripwire the caller may skip is one that never fires, so a missing map
is unproven ownership rather than permission. The other arms take seven arguments and never consult
it. Read it with

```sh
# `--jq .content | base64 -d` also works, but BSD and GNU base64 spell the decode flag differently
# (`-D` vs `-d`), so ask the API for the raw file instead.
gh api "repos/devantler-tech/<repo>/contents/<skill-root>/SKILL.md?ref=<head>" \
  -H "Accept: application/vnd.github.raw" |
  yq --front-matter=extract '.metadata.github-repo // "null"'
```

and expect **3** whenever it disagrees with the allowlisted upstream — including a prefix-extended
`agent-skills-v2`-style lookalike, since the comparison is exact. The PR is the unit, so one unproven
skill sends the whole PR to semantic review.

Apply either exemption only when `.claude/scripts/programmed-bot-review-exemption.sh` validates the
exact repository, PR actor, branch, title, current-head commit provenance, changed-file boundary, and
— for installed-skill updates — that per-skill ownership map.
Never infer it from the title alone. Qualifying PRs run through required CI and auto-merge; do **not**
request CodeRabbit, Codex, Cursor Bugbot, or a local review, chase ancillary reviewer output, or count
a missing review as a hygiene gap. Their checks, threads, and conflict state still gate auto-merge.
Any adaptation commit or out-of-bound file revokes the exemption and restores the normal review gate.
