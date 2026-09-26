# Context, latency and tool-call discipline

> Part of the devantler-tech agent contract. [`AGENTS.md`](../../AGENTS.md) is the always-on core
> and indexes every guide; this guide carries the full rules for how a run spends context and
> wall-clock: delegation, waiting on remote systems, and how to shape Bash calls so they are not
> denied, refused or killed. Read it at run start and before any long wait or large command.

## Context & token discipline
Your context window is finite and **re-processed every turn** — spend it deliberately. **Delegate
read-heavy / verbose work to subagents** (the survey → the read-only `portfolio-surveyor`, which
returns a compact digest instead of ~40 raw `gh` JSON blobs; broad code investigation → the built-in
`Explore` type) so their raw output stays in *their* context — keep edits, PRs, and merges in your own
loop. **Filter big command output** (tee build/test/lint to a file; surface only the summary + failing
lines). **Don't re-read what's already in context** (this contract, via the `CLAUDE.md` shim) or
**duplicate live GitHub state into memory**. This is the *native-to-Claude* design principle
(subagents, memory) applied to cost: same work and same guardrails, fewer tokens.


🔴 **A SUBAGENT'S DEFINITION LOAD IS THE LARGEST RECURRING COST HERE, AND NOTHING WAS MEASURING IT.**
Measured 2026-08-19 over the 7-day session corpus (182 sidechains extracted, 0 extraction failures):
the `portfolio-surveyor` is **157 of 182 subagent dispatches (86%)** and its first-turn
`cache_creation` median is **191,397 tokens** — against `Explore`'s **29,310**, which receives no
project instructions. That gap is this contract plus `.claude/agents/portfolio-surveyor.md`.
`cache_read` is **0 on 160 of 161** surveyor dispatches, because every subagent writes the
**5-minute** cache (`ephemeral_5m` on 182/182, `ephemeral_1h` on 0/182) while the surveyor is
dispatched roughly hourly — so reuse is structurally zero and every dispatch pays the write premium
in full. The trend is **monotonic, not a spike**: daily medians ran **155,212 → 207,321** across
08-13→08-19, **+52,109 tokens per dispatch in one week**.

🔴 **The OVERLAY is the actionable half, because that file is declared TEMPORARY.** *Agentic
engineering plugin contract* retains it only until digest parity, and *Agent definition locations*
allows it to carry **only its named deployment/provider delta** — generic role logic changes at its
owning upstream. That parity gate was reached: `agent-plugins#78` closed **COMPLETED 2026-07-25**.
The overlay then grew **61,144 B → 150,495 B (+146%)** as measured on 2026-08-19, because generic
refinements (the `4b`–`4e` items in
[`agentic-engineering-surveyor-diff.md`](../plugin-consumption/agentic-engineering-surveyor-diff.md))
were appended to the temporary local file instead of upstreamed — re-opening the gap #78 had just
closed, pushing the file's own deletion further away, and charging every hourly dispatch for it. Its
**enforced high-water mark is now 168,390 B** (raised 2026-09-25 by monorepo#2838 to prescribe the one absolute, forge-first call the surveyor guard admits for this deployment's own `kata-measure-date.sh`, so a Kata's measurement date is read from its structured `**Measure on:**` line rather than by eye from `createdAt` — the helper exists only here, so there is no upstream to route it to; raised 2026-09-25 by monorepo#3572 to prescribe the one absolute, forge-first call the surveyor guard admits for this deployment's own `coderabbit-review-verdict.sh`, so review objects are judged by the tested helper #3571 added rather than by eye — the helper exists only here, so there is no upstream to route it to; raised 2026-09-24 by the fix for monorepo#3564 so the surveyor also runs the updater classifier on agent-plugins' per-skill updater PRs, whose branch and title the candidate test named only in their single-PR form — the classifier is this deployment's own helper, so there is no upstream to route it to; raised 2026-09-24 by monorepo#3565 so the overlay's updater-classifier payload passes each commit's GitHub signature verdict, without which the classifier's App-signed arm is unreachable from the surveyor, its production caller — the payload shape is this deployment's own helper contract, so there is no upstream to route it to; raised 2026-09-24 by monorepo#3561 to port agent-plugins#230's fail-closed `issueType` shape check into the overlay's issue-aggregation reference command, which a missing key had silently counted as untyped — deferred until the Improver's awk-denial hypothesis on that same command had scored; raised 2026-09-23 by monorepo#2697, and by 213 B more in the same PR so the prescribed call reads the reviews over GraphQL with their `totalCount` and the classifier can refuse a read that stopped part-way, and by 131 B more so a round counts only when its head equals the head the deepening read captured, to replace the overlay's by-eye local-review-round rule with the one guarded call to this deployment's own `local-review-verdict.sh`, which the contract names since monorepo#3487 while the guard refused 3 of the first 5 surveyor calls — the helper exists only here, so there is no upstream to route it to; raised 2026-09-23 by monorepo#3529 to prescribe the one absolute, forge-first call the surveyor guard admits for this deployment's own `coderabbit-summary-verdict.sh`, which the overlay named while the guard refused every call — 5 refusals in one day; the helper exists only here, so there is no upstream to route it to; raised 2026-09-22 by the fix for monorepo#2748 so the surveyor recognises a CodeRabbit review that opens with the outside-diff CAUTION block instead of the marker — the identification rule lives in the overlay a surveyor dispatch reads, and upstream carries no CodeRabbit artifact shapes to point at; raised 2026-09-22 by the fix for monorepo#2653 so the surveyor judges a CodeRabbit summary comment with the same verdict-line helper the contract names — the green-review rule lives in the overlay a surveyor dispatch reads, and upstream carries no such helper to point at; raised 2026-09-21 by monorepo#2618 so the step-1 PR census carries each PR body's issue references, normalizing a bodyless PR to an empty body so one null cannot abort the whole census: the overlay's "no open PR" rule joins on a body hit but the census never fetched bodies, so an issue a PR names only in prose read ACTIONABLE; the earlier 2026-09-21 raise by monorepo#3444 to port agent-plugins#228's jq-only aggregation rule into the overlay: all 11 `awk` guard denials over 7 days came from this overlay across 4 of 90 dispatches and none from the plugin path, so bumping the pin alone would have fixed none of them; the 2026-09-20 raise by monorepo#3427 was to keep the temporary deployed overlay compatible with reviewed agent-plugins 5.1.6: the helper now emits `run_attempt`, job correlation is attempt-specific and extracts the numeric check-run ID, configuration-time startup failures remain known-red when GitHub creates no job, every red conclusion survives the join, and warning/notice annotations stay out of the compact failure digest; the 2026-09-20 raise by monorepo#3420 stated that the survey never reads a workflow LOG BODY and named the two allowed `gh api` reads that carry the same answer — rounds 13 and 15 cover how the classifier is invoked and how its result is read, but nothing said what to do once a run is KNOWN red, so dispatches improvised `gh run view --log-failed` and the read-only guard refused the whole call: 9 denials across 7 of 122 surveyor dispatches over 7 days, on ksail, .github and ascoachingogvaner, after which each recovered to the jobs/steps and check-run annotations reads by trial; the guard is correct and is NOT widened, because a log dump is the raw volume this survey exists to keep out of the orchestrator context, whose own unguarded session still reads logs when a digest line is not enough; the 2026-09-18 raise by monorepo#3390 to state the classifier's native-status plus complete eight-field OUTPUT contract in the overlay, whose step 4 said how to invoke the helper but never how to read it — the verdict rides the exit status, so 10 of 87 surveyor dispatches over 7 days reached for the guard-denied `; echo "EXIT=$?"` idiom and lost those rung-0 calls, rising once monorepo#3339 made the path resolve; requiring observed native status 0 prevents a killed or timed-out empty result from being misclassified as green, while the exact row predicate prevents a numeric-first-field diagnostic or mixed output from being misclassified as red; the 2026-09-17 raise by monorepo#2557 to port agent-plugins#219's `managed-failing` pentad class into the overlay, whose pentad still counted a GitHub-managed red as an ordinary failing check; the 2026-09-14 raise by monorepo#3338 ported the plugin surveyor's classifier path-resolution procedure into the overlay's step 4, which deferred it to "the generic role" an overlay dispatch never loads — 0 of 79 overlay dispatches used the guard's path hint while 59 hunted plugin directories the guard denies, against 10 of 10 plugin-type dispatches resolving it — and to scope that probe to guarded surveyor dispatches, because the Codex inline survey reads this same overlay with no surveyor guard, where a bare basename is a `PATH` lookup; the 2026-09-09 raise by monorepo#3290 ported `@coderabbitai full review`'s own completion wording into the overlay, which recognised only the other verdict form and so reported `green_review=none` over a real current-head green on ksail#6930 — the surveyor is the surface that reads this, and upstream carries none of this rule to port it to; the 2026-09-06 raise by monorepo#3228 to port agent-plugins#199's cross-surface half of the `gh --json` vocabulary rule into the overlay, whose subcommand-only form forbade neither live example; the 2026-09-05 raise by monorepo#3223 ported agent-plugins#195's classifier flag-form sentence into the overlay's step 4, which 19 of 20 classifier-calling surveyor dispatches read instead of the plugin agent, and the 2026-09-04 raise by monorepo#3207 ported agent-plugins#177's `gh --json` vocabulary rule for the same reason); that is the live ratchet ceiling, not a rewrite of the
dated measurement.

**So a new surveyor refinement goes UPSTREAM unless it is a genuine deployment fact.**
[`definition-load-budget-contract.test.sh`](../scripts/definition-load-budget-contract.test.sh)
ratchets the overlay's byte ceiling: growth fails CI, and the failure names both remedies — upstream
it, or raise the ceiling **in the same PR** and say why. ⚠️ The ceiling **never vetoes mandated
work**; raising it is always available, so its only job is to make the cost a decision somebody made
rather than one nobody saw. Deliberately **no byte gate on these guides** — rules legitimately
accrete here, and a ratchet firing on every definition PR (safety fixes included) would train the
raise into a reflex and destroy the signal. The always-on root `AGENTS.md` is different, because every
session and every subagent dispatch pays for all of it: its budget, and Codex's 32 KiB read limit,
are enforced by `agent-instructions-layout-contract.test.sh`. Growth that pushes against that budget
belongs in a guide, not in a raised limit.

## Latency discipline — overlap the waiting, never block on it
Token discipline above spends context well; this spends **wall-clock** well. The dominant cost of a
run is **not** thinking or authoring — it is **waiting on remote systems** (CI, reviewers,
promotion). Measured on the 744th tick: a 105-minute run authored everything it shipped in the
**first 28 minutes** and spent **~70 minutes (67%) waiting**, including one **44-minute block that
produced nothing** while foreground-polling one PR's CI. A trusted-bot PR merged *inside* that
window, unnoticed. The work was never the bottleneck; the **scheduling** was.

- **NEVER foreground-block on a remote wait.** The portable rule is rule 7 of the pinned
  `agentic-engineer` definition: bounded one-shot reads, at most one watcher, and that watcher's
  lifecycle — a hand-rolled poll loop is a busy-wait wherever it runs, a watcher that re-invokes the
  session is stopped before the run ends, and a watcher is never armed only to end the turn idle.
  This bullet carries what that rule looks like on the Claude lane, and the evidence behind it.
  **Push → arm ONE background watcher → immediately start the next item**, and never also poll what
  you armed (a real 744th miss: a watcher was armed *and* the run busy-waited anyway).
  **The waiter is `Monitor` with an until-loop**, which the busy-wait guard's own refusal names. The
  enforcement hook blocks `sleep N && <poll>` chains, and unchaining does not comply: sessions adapted
  by issuing the bare `sleep N` as its own call instead (**442 standalone sleeps in one day**,
  2026-07-18). A bare `sleep` bounds a local process nothing will report on (e.g. a backgrounded
  windowed render before killing it); it never polls a backgrounded task's output file, whose
  completion the runtime announces — **27 of 76** blocked `sleep N && <poll>` actions did exactly
  that (7 days to 2026-08-09).
  🔴 **`run_in_background` is this lane's live busy-wait shape.** Wrapping
  `for i in $(seq 1 40); do gh pr view …; sleep 30; done` in a backgrounded call moves the wait out of
  the guard's VIEW, never out of the RUN, and the hook does not stop it: **560 of 904** backgrounded
  Bash launches carried such a loop (7 days to 2026-08-23).
  🔴 **A backgrounded task's completion notification resurrects the session**, so the run stays open
  until it fires and the cost lands on the NEXT dispatch. Across 176 Engineer runs in that window:
  **240 idles totalling 28.0h**; polling runs took a median **62.8min against 42.4min** and overran
  the hourly slot **54% against 29%**; and **all 9 dropped dispatches (of 179 slots) were
  overlap-blocked by a still-open run**.
  ⚠️ So if something else is actionable, arm `Monitor` and go do it. If nothing is,
  **end the run**: rung 1 of *The work-selection ladder* guarantees the next tick collects the PR,
  and a run that ends on time is what makes that tick exist.
  🔴 **Ending the run REQUIRES stopping every in-flight watcher first — `TaskStop`, not merely a
  closing message.** A watcher left armed reopens the session after the run believed it was over;
  **6 idles (1.09h)** in the same window woke on a watcher that had merely TIMED OUT.
- **Long-pole first.** Push the change with the **slowest CI first** so its bake overlaps everything
  else; do the fast-CI and no-CI work (issue triage, review-thread replies, memory, reports) during
  the bake. Reversing this — fast item first, slow item last — buys a guaranteed idle tail, which is
  exactly what the 744th did. Each repo's `AGENTS.md ## Maintenance` records its CI duration so the
  ordering needs no re-derivation — keep the measured per-repo CI durations as a cursor in **native
  memory** (ksail `CI - KSail` ≈ **22 min**; a docs-only ksail PR ≈ 3 min), refreshed when they drift.
- **There is always non-blocking work.** A portfolio this size always has a review thread to resolve,
  an issue to triage, a finding to verify, or memory to sharpen. "Waiting for CI" is never a reason
  to do nothing — if a wait is truly unavoidable and nothing else is actionable, **end the run and
  let the next tick collect the result** (the watcher/carry-forward exists for exactly this). A run
  is measured by what it ships, not by how long it stays open.
- **Re-read state after any long wait — don't assume it stood still.** Both your own PRs and the
  sibling's move while you wait; a PR can merge, a head can advance, a thread can be resolved by the
  other instance. (744th: platform#2662 merged mid-wait, unobserved; the 745th found the sibling had
  already fixed and resolved all three of platform#2635's findings.)
- **One read per check, not one per field.** `gh pr view <n> --json a,b,c` **once** and parse it —
  never a separate call per field inside a loop (the 744th ran 2–3 calls per poll iteration across
  ~40 iterations). Same for lint: capture the **full** finding list in one run, fix **all** of it,
  re-verify **once** — not a fix-one/re-run round trip per finding.
- **Parallelize independent setup.** Clones, subagents, and independent investigations start
  together in the background, not one after another.
- **A per-repository fan-out iterates the repo list, never by globbing the cache directory.** A
  glob does not match a leading dot in bash or zsh, so `for f in "$dir"/*.json` silently skips the
  `.github` repository's cache file and reports "nothing found" there — including maintainer
  comments on org-wide conventions. So iterate the repo list you enumerated from the Portfolio map
  or the survey (`for r in "${repos[@]}"; do f="$dir/$r.json"; …`). A missing cache file is an error:
  report UNKNOWN for that repo, never an empty result. This applies to every
  per-repo sweep: comments, PRs, issues, runs.
- **Splitting a `"repo number"` pair with `set -- $pair` breaks under `zsh` — use the POSIX
  parameter-expansion form instead.** Claude Code's Bash tool runs **zsh**, which (unlike bash) does **not**
  word-split unquoted *parameter expansions*. So the common bash sweep idiom silently collapses
  there: `for pr in "ksail 6045" …; do set -- $pr; gh pr view $2 --repo devantler-tech/$1` leaves
  `$1` holding the *whole* string and `$2` **empty**, so `gh` runs with no PR number and fails
  `argument required when using the --repo flag`. The flag is present — the positional argument in
  front of it vanished, which is why the error misdirects. Measured: **24 of 24** such failures
  across 250 sessions (2026-07-14→18) used this idiom; **zero** used literal arguments. It hits
  hardest in the per-run PR sweep, where these loops get written most.
  **Write it portably and it is correct in every shell:**
  ```sh
  repo=${pr%% *}; n=${pr##* }           # POSIX parameter expansion: sh, bash AND zsh
  gh pr view "$n" --repo "devantler-tech/$repo"
  ```
  (`IFS=' ' read -r repo n <<< "$pr"` is equivalent **in bash and zsh only** — the here-string `<<<`
  is a bash/zsh extension and a **syntax error** under POSIX `/bin/sh`, e.g. dash. The parameter-
  expansion form above has no such limit, so prefer it when the shell is unknown or the file carries
  a `#!/bin/sh` shebang.)
  Or simply **write the calls out** — two plain `gh` lines beat a clever loop and stay readable.
  **Shell-specific notes, so nobody "fixes" working code:** in **bash** `set -- $pair` splits
  correctly and needs no change; `set -- ${=pair}` is zsh's explicit-split flag and is a **syntax
  error in bash** (`bad substitution`), so never introduce it in a script with a `#!/usr/bin/env bash`
  shebang or in the Codex sibling's bash-backed session. **When you do not know the active shell, use
  the parameter-expansion form above** — it is the only one of the three with no shell restriction.
  **Not the same hazard:** `for x in $(cmd)` *does* split under zsh (command substitution is still
  IFS-split; only parameter expansion is exempt), so an unexpected result there is ordinary
  whitespace splitting, not this bug. Keep the two diagnoses apart — the parameter-expansion family
  is `set -- $var` and `cmd $args`.
- **Put ONE verb in a `Bash` call — the classifier's denials concentrate on calls that prefix the real
  command with `cd` or a variable assignment.** Measured over the 7 days to 2026-08-16: **58 auto-mode
  classifier denials across 15 distinct sessions**, of which the **27 multi-statement** ones span **12
  sessions** and **25 of those 27 open with `cd ` (18) or an assignment (7)** before the verb that
  matters. Each denial loses the **whole call** — nothing is partially applied — so the setup work in
  front of the verb is discarded with it, which is the same total-loss shape *Git safety* already
  records for a compound `fetch`+`checkout`. This bullet is that rule's general case; the git pair is
  simply where it was first measured.
  🔴 **The prefix is almost always UNNECESSARY, which is what makes this cheap to fix.** Pass the
  location to the command instead of walking to it: `git -C <path>`, `gh --repo <owner>/<repo>` and an
  absolute script path each carry their own location, so the `cd` was never load-bearing and the
  denial class disappears without any loss of capability.
  🔴 **Do NOT "fix" it by setting the directory once and using relative paths afterwards — the cwd
  survives only INSIDE the workspace.** Verified 2026-08-16 by direct probe: a `cd` to a path within
  the session worktree persists to the next call, while a `cd` **outside** it — `~/.claude/projects`,
  which is the corpus every telemetry pass reads — is **silently reset** to the session worktree before
  the next call runs. A later command's relative paths then resolve in the worktree, so it reads or
  writes a different file than intended **and still reports success**. That is not hypothetical: it is
  the measured cause of a mining pass that reported zero tool errors out of an empty file it had itself
  just written somewhere else, while 44 of 63 transcripts held errors. **Absolute paths are the only
  form that is correct on both sides of that boundary.**
  ⚠️ **It is PROBABILISTIC on this shape, and that is precisely why it persists.** The same
  `cd … ; <verb>` spelling usually succeeds, so a lane reads the occasional refusal as noise and keeps
  the habit — one measured session led **every** Bash call with `cd <worktree>` and paid for it
  repeatedly. Treat a denial as a signal about the **shape**, never about that one call.
  **On a denial, SPLIT the call — never re-issue a variant spelling.** A denied *command* may pass on
  a plain retry, but a denied *content shape* will not, so re-spelling it burns another call to learn
  nothing; issuing the setup and the verb as separate calls is the recovery that has actually worked.
  Never touch the permission surface to work around this: like the control-byte guard below, refusing
  what it cannot classify is the guard behaving correctly, and the command is what changes.
- **A raw non-whitespace C0 control byte anywhere in a `Bash` command loses the WHOLE call — write the
  delimiter as an escape instead.** The runtime refuses the call outright with
  `InputValidationError: command contains control characters that would be hidden in the approval
  dialog`, which is a **correct guard** — you cannot approve what you cannot see — so never touch it
  or any permission surface to work around this; fix the command. Measured over the 7 days to
  2026-08-15: **18 occurrences across 14 distinct sessions**, spread over 10+ branches in both the
  routine and the maintainer-interactive lanes, making it the largest diagnosed avoidable reliability
  cost. Nothing is partially applied — the call never runs, and the message names neither the
  offending byte nor its position, which is why lanes rediscover it by improvising a second spelling
  of the same command.
  🔴 **It is NOT "newlines and tabs" — that natural reading is measured-false and sends you to a fix
  that changes nothing.** A raw newline and a raw **tab** are both **accepted** (verified directly;
  every multi-line command in this contract relies on it), so "put the multi-line program in a file"
  addresses nothing. The bytes that actually fire it are the **non-whitespace C0 delimiters**, chosen
  deliberately as collision-proof field/record separators for TSV-ish pipelines and then typed as raw
  bytes: measured census **NUL ×5, SOH ×5, US ×4, SOH+STX ×2** — i.e. the habit is sound engineering
  (a body containing tabs and newlines needs a separator that cannot collide) and only its *spelling*
  is wrong.
  **Write the separator so the source stays printable — verified to emit the identical byte:**
  ```sh
  printf 'a%sb' $'\x1f'                      # ANSI-C quoting -> the 0x1F byte
  while IFS=$'\x1f' read -r a b; do …; done  # same split, printable source
  printf 'p\0q\0' | xargs -0 -n1 …           # NUL: the \0 escape, never a raw byte
  ```
  For a `jq` program, the six printable characters `\u001f` are a jq string escape and emit the byte
  at runtime, so the program text itself stays clean. The rule is only ever about **how the byte is
  spelled in the command you send**, never about which byte the pipeline uses.
  ⚠️ **The guard scans the ENTIRE command string, comments included** — reproduced live while writing
  this rule: a trailing `# …` explaining the delimiter carried a raw byte and cost the call, with the
  code itself already correct. So a command that looks fixed can still fail on its own annotation.
- **SIZE A `Bash` CALL BEFORE YOU MAKE IT — the default budget is TWO MINUTES, and overrunning it
  loses the WHOLE call.** `timeout` is in milliseconds, defaults to `120000`, and caps at `600000`
  (ten minutes). A killed call returns **nothing** — no partial output and no indication of how far
  it got — so the measurement it was making is discarded along with the wait, and the retry pays the
  wall-clock again.
  🔴 **Its SIDE EFFECTS are not rolled back, and assuming otherwise is the one way this bullet can
  cause harm rather than cost time.** The kill removes the *result*, never the *effects*: a call
  killed at the boundary has already run for its whole budget, so a `git push` may have landed on the
  remote, a `gh pr merge` may have merged, a comment may have posted, a file may be written. The
  reader's next move is the retry this bullet describes — so **re-read state before retrying any call
  that writes, pushes, merges, or posts**, exactly as *Git safety* requires a push be verified by git
  output **and** a re-read. Retrying a non-idempotent call on the assumption that the first attempt
  was a no-op is how a double-merge or a clobbering second push happens.
  🔴 **This is a BUDGETING failure, not a slow-command problem — the budget is usually never
  considered at all.** Measured over the 7 days to 2026-08-17T10:03Z, over every `Bash` call in the
  Claude corpus whose own record falls in that window, with the measuring session excluded: **26,967
  calls across 299 sessions**. Of those, **112 were killed by the timeout, and 90 of them (80%) ran
  at the untouched two-minute default** — costing ~180 minutes of blocked wall-clock that produced
  nothing. **66 of the 299 sessions (22%) lost at least one call this way**, at most 5 in any one
  session, so this is broad behaviour rather than one looping run. For scale on the same denominator:
  `timeout` is set on 1,536 calls (5.7%) and `run_in_background` on 662 (2.5%).
  ⚠️ **The capability is already known; only its TIMING is wrong.** **56 of those 66 sessions (85%)
  used `timeout` or `run_in_background` elsewhere in the same session** — just never before the first
  failure. So the fix is not to learn a parameter, it is to choose one *up front*, on the call you
  are about to make.
  **These classes reliably exceed the default — background or bound them without waiting to find
  out.** Classifying those same 90 calls: **29 contract-test-suite runs, 20 `gh` portfolio sweeps,
  13 corpus scans over the session transcripts, 7 `ksail` validations**, and 21 that fit no single
  class. Every named one is a mandated run-loop operation, so this is the ordinary path rather than
  an unusual one.
  🔴 **Raising `timeout` is the WRONG default reflex — prefer `run_in_background: true`.** The
  ceiling is ten minutes and several of these classes exceed it outright, so a bump converts a
  two-minute loss into a ten-minute one and still returns nothing; a bumped call also blocks the
  foreground for its whole budget, which is the waste the rest of this section exists to stop. A
  backgrounded call has neither problem: the runtime **announces its completion**, so it costs no
  wall-clock and needs no waiting. Raise `timeout` only when the work is genuinely bounded, you need
  the result before the next call can be written, and it comfortably fits inside the ceiling.
  ⚠️ **And do not then poll what you backgrounded** — the announcement is the notification, so a
  `sleep`-and-read loop over its output file is the busy-wait this section already forbids.

This changes only *ordering and overlap* — never the quality bar. Validation, RED/GREEN proof,
root-cause fixing, and every guardrail are unaffected; the point is to stop paying for them serially.
