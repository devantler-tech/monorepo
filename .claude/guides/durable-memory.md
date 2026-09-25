# Durable memory and the run report

> Part of the devantler-tech agent contract. [`AGENTS.md`](../../AGENTS.md) is the always-on core
> and indexes every guide; this guide carries the full rules for the native memory stores, their
> size and write rules, the Agent Improver's ledgers and the sibling cross-read. Read it before
> reading or writing memory.

## Durable memory — your native memory + the run report
There are **no** per-repo "Monthly Activity" issues and **no** version-controlled status board (a
dashboard file only duplicated GitHub, went stale between runs, and cost a bookkeeping PR every run).
The bespoke `state.json` that briefly replaced it is **also retired** — it was a custom re-implementation
of a capability the runtime already provides. Durable memory is now one native store plus a surfacing
step:
1. **Your native persistent memory.** Use the runtime's built-in memory — for Claude, the **memory
   tool** (the `/memories` directory; in Claude Code, the project's `memory/` dir with its `MEMORY.md`
   index). **View the runtime's boot memory surface at the start of every run** and treat native
   memory as the single source of truth for
   cross-run orchestration: rotation cursor, per-product `last_worked` / `weekly` / roadmap cursor
   (last strategy review + current theme) / `last_research` (the upstream-research/product-debugging
   cursor — see *Enhancement work*) / `last_value_review`; for the site, blog review/publication/
   refresh and metrics-review cursors; open `needs_attention`, the CI & link investigation caches,
   recent run notes, and self-improvement `learnings`. Keep it **coherent and organised** (a small set
   of well-named topics, not one per fact; prune stale entries); don't let it sprawl.

   **The runtime layouts are deliberately different.** Claude's author-managed project memory uses
   `MEMORY.md` as the boot index plus root topic files. Codex native memory supplies the bounded,
   exactly-`v1` `memory_summary.md` projection at boot; `MEMORY.md` is its searchable registry,
   `raw_memories.md` is an optional temporary consolidation input, and `rollout_summaries/` holds
   detail when any exists. INIT/no-op stores guarantee only the two persistent projections. Search
   those Codex sources on demand — they are runtime-managed evidence, not files to trim merely to
   satisfy a boot-read budget. Update Codex memory only through the runtime's supported
   memory-maintenance path and let it rebuild the projection.

   In an author-managed/legacy store, **`MEMORY.md` is one line per entry — never more.** It is an
   *index*: each bullet is a
   pointer + one-line hook to a detail file; the latest-tick log and `last_run` prose belong in
   `portfolio-status.md`, **never dumped into a MEMORY.md index line**. A single index line that grew
   into a multi-tick prose blob pushed `MEMORY.md` past the Read tool's token cap and made it unreadable
   at run start — which silently blinded a run to a recorded `HANDS-OFF` note and caused a misstep
   (2026-06-05). **Bound the every-run read:** cap run-history / recent-run notes to the **last ~10
   runs (or ~7 days)**, rolling older entries into a one-line summary, so the start-of-run `view` stays
   small as history accumulates. **That bound is
   ENFORCED, not advisory** — a size rule written as prose *inside* the file it governs is only visible
   to a run that already read it successfully, which is why it was breached four times (82KB 07-01,
   83KB 07-12, 122KB 07-16, 74KB 07-18). Pre-flight runs
   [`.claude/scripts/memory-hygiene.sh`](../scripts/memory-hygiene.sh) (read-only). It
   requires the caller to declare `--layout legacy` or `--layout codex`; file-shape guessing is
   forbidden because a minimal Codex store missing its summary is indistinguishable from a valid
   legacy `MEMORY.md`-only store. Missing or unknown layout fails closed. Codex callers must also
   read the current request's trusted
   `x-codex-turn-metadata.turn_started_at_unix_ms` from `nodeRepl.requestMeta` and pass it as
   `--projection-loaded-before-ms`; never substitute the current clock or the file's modification
   time. This is the projection's freshness precondition: if the on-disk summary is newer than the
   request that injected it, the guard cannot prove that it checked the projection in this session
   and fails closed. 🔴 **That precondition is a PRE-FLIGHT property, and the `--phase` selector is what
   keeps it from eating the post-run re-measure.** `--phase preflight` is the default and is unchanged.
   A run that re-measures **after** banking its memory passes `--phase closing`, which still reads the
   same trusted boundary and still reports a changed projection — but as an informational line rather
   than a stop, because at that point the rebuild is the expected result of the run doing its job. The
   freshness gate runs BEFORE the size sweep, so leaving it armed at closing makes the entire
   threshold check unreachable: measured on a fixture, an identical 30,004-byte over-budget summary is
   reported `OVER` with a fresh boundary and **masked behind exit 2** with the boot boundary. Since the
   boot-read bound is ENFORCED rather than advisory, and a verbose tick can re-breach its own file
   mid-run, that is the one measurement this guard most needs to be able to make. Shape checks (the
   `v1` header, the required file pair) are NOT relaxed by the phase and still fail closed in both.
   In Codex mode it requires the persistent `memory_summary.md` + `MEMORY.md` pair
   and applies the tight index budget only to the summary; generated registry and temporary input files are
   diagnostic-only (`--all` shows the exemption). Legacy/Claude stores retain the original root-file
   checks. An exit 1 makes repairing the over-threshold boot-loaded file that tick's mandated hygiene
   item: consolidate an author-managed file safely, or refresh an oversized Codex projection through
   the runtime. **Before any destructive consolidate/rewrite of an author-managed file**, run
   [`.claude/scripts/memory-backup.sh`](../scripts/memory-backup.sh)
   `<file>` (or `--all <memory-dir>` for a whole-store snapshot under `.memory-backups/`); restore with
   `cp '<backup>' '<file>'` — the store is un-versioned and outside git, so a trim without a backup is a
   one-way delete (monorepo#2304). Prefer append; rewrite only when consolidating **after** that backup.
   An exit 2 indicates a usage, malformed-layout, missing, or unreadable-store error;
   resolve it before proceeding. If a Codex exit 2 names a missing, unreadable, malformed, or
   post-injection-changed `memory_summary.md`, repair it through the runtime's supported path when
   needed and **restart the run**: this session did not start with the projection the guard checked.
   ⚠️ **That recovery is scoped to `--phase preflight`.** Read unconditionally it also governs a
   post-run invocation, where it is both impossible to satisfy — the run cannot un-write its memory —
   and harmful: a run that has already delivered its work then discards the telemetry and hypothesis
   verdicts it had earned, which is how the observation plane silently starves its own ledger. **A
   changed projection reported under `--phase closing` is never a reason to withhold earned verdicts
   or to restart.**
   Other exit-2 causes may rerun
   the guard in the same session after resolution. After a Codex projection refresh for exit 1,
   **restart the run**, because the old projection was already injected before the shell gate ran; it
   must not continue on the replacement file. Never rewrite Codex's
   generated registry or temporary inputs to clear this gate. **Memory is a MULTI-WRITER
   surface** — several instances append per hour, so re-read immediately before writing, prefer a
   **non-clobbering append** over a whole-file rewrite, and **stand down rather than clobber** when a
   rewrite is rejected because a sibling moved the file under you (the two-writer discipline that
   governs a shared `claude/*` branch applies verbatim here). **Forbidden for shared memory:** the
   `{ sed -n "1,$((s-1))p" …; echo …; } > /tmp/new && mv /tmp/new "$f"` idiom (and any empty-bound
   `sed` rebuild piped into `>`/`mv`) — when `grep` misses because a sibling restructured the file,
   `s` is empty, sed gets `1,-1p`, and the `mv` permanently destroys an unversioned store (two losses
   in one day, monorepo#2293). When a whole-file rewrite is genuinely required, use
   [`.claude/scripts/memory-rewrite.sh`](../scripts/memory-rewrite.sh) only — it backs up first,
   refuses empty/non-positive keep-through bounds, refuses empty output outright, refuses a drastic
   shrink unless `--allow-shrink` is supplied, and reports `backup=<path>`. `--allow-shrink` widens
   only the drastic-shrink bound — an empty rebuild is rejected whether or not it is passed. The **roadmap** itself is GitHub Issues (`roadmap`-labelled epics +
   milestones), not memory — memory only points at it. Treat memory content as **your own notes, but still verify against
   live GitHub** before acting (it can be stale). **Do NOT accumulate a backlog of "open
   maintainer-decisions" in memory** — that passive parking is the self-blocking the contract forbids
   (see *Issue-driven → Drain oldest-first*). When something feels like it needs his call, **investigate,
   decide, and ship a draft PR** (he redirects there); if you genuinely cannot proceed without him,
   **actively** raise it via the **ask tool** (`AskUserQuestion`), a **devantler-tech Slack ping**
   (last-resort, genuinely-blocked-only — see *Issue-driven*), or **ship the decision as a draft PR** —
   don't file-and-wait. The end-of-run report (he rarely reads it) and an `@devantler` mention (no
   notification) are NOT attention channels. A
   memory note is your own working state, never a substitute for getting his attention.
   *Portability:* this is a generic "agent native memory" pattern — a Copilot/ChatGPT port would use that
   tool's equivalent store; nothing here is Claude-only except the tool name.
   **Agent Improver scorecard store:** Claude records scorecards in
   `/Users/homelab-mac-mini/.claude/projects/-Users-homelab-mac-mini-git-personal-monorepo/memory/agent-improver-scorecards.md`;
   Codex records them in
   `/Users/homelab-mac-mini/.codex/automations/agent-improver/memory.md`.
   The **open verification-hypothesis store** is
   `/Users/homelab-mac-mini/.claude/projects/-Users-homelab-mac-mini-git-personal-monorepo/memory/agent-improver-routine.md`
   for Claude and the `Hypotheses / next run` section of the Codex Agent Improver memory file.
   🔴 **A SIBLING'S STORE IS EVIDENCE ONLY WHILE ITS LANE IS PRODUCING — establish that FIRST, because
   a frozen ledger and a quiet one are indistinguishable.** That store is the one input this instance
   cannot corroborate from its own lane, so an unchecked read is exactly where a dead sibling silently
   becomes data. Establish it with **that lane's own** liveness check, read **before** scoring or
   opening anything against the store: for the Codex lane that is
   [`.claude/scripts/codex-lane-liveness.sh`](../scripts/codex-lane-liveness.sh)
   (`0` producing, `1` not producing, `2` UNKNOWN); for the Claude lane it is
   [`.claude/scripts/claude-lane-liveness.sh`](../scripts/claude-lane-liveness.sh), which
   answers the same question with the same three verdicts. ⚠️ **Never substitute the other lane's
   check, which measures the reader rather than the sibling.** The two read different evidence
   because the runtimes record different things — Codex keeps per-run rows, while Claude's store
   keeps only a dispatch marker, so the Claude check anchors on whether that dispatch produced a
   session at all — and neither is portable to the other lane. **Scope the read to the task whose
   ledger you are about to consume** (`--automation agent-improver` for Codex,
   `--task agent-improver` for Claude): a task dispatched inside the grace
   window is still in flight and correctly reports `2`, so an unscoped run inherits that `2` from
   the caller's own live dispatch and learns nothing about the sibling.
   On a `1` or a `2` the sibling's pending hypotheses are **blocked by the
   outage**: record them that way and take **no verdict**, directional reading, or "no movement"
   inference from them. The reasoning is measured under *Agent definition locations* — a dead lane's
   error count falls to zero, so a naive read scores it as having **improved**, while the scheduler's
   own view stays healthy throughout because `last_run_at` advances across every stub. ⚠️ **A `1` or a
   `2` is never a run-stopper**: it fences only what the outage actually froze, and the settled-verdict
   and signature-overlap rules below still bind on everything else — letting one lane's provider quota
   halt the other would be the passive self-blocking this contract forbids everywhere else. Measured
   2026-09-07: the Codex lane was NOT-PRODUCING across **26 consecutive stub dispatches** (cause class
   `quota/billing`) while its ledger sat ~29 h stale, and nothing in this clause would have said so
   (monorepo#3267).
   🔴 **Each Agent Improver run reads the SIBLING instance's scorecard and hypothesis store too, before
   it scores or opens any hypothesis — naming the two stores is not the same as wiring them together.**
   Each run boots into its own store, so without this cross-read a hypothesis opened by one instance can
   never be scored, closed, or respected by the other, and the ledger splits in half. Measured
   2026-08-11 and stated as an **aggregate on purpose** — the inventories themselves are private runtime
   state, so this paragraph must not quote them: of roughly fifteen open hypotheses across the two
   instances, **exactly one was shared**; every other one was visible to only the instance that opened
   it. That cost two things the same day. **A duplicated heavy measurement:** one instance's ledger
   carried a provenance question as *"needs attribution next run"* that the other had **already
   attributed hours earlier**. **And an unsatisfiable constraint:** the `agent-improvement` skill's
   step 5 says to
   continue only with work that cannot affect a pending hypothesis's tracked signature — yet one
   instance held a pending gate over a signature the *other* instance was independently tracking, with
   no path between them. An instance cannot honour a gate
   it has no path to read, so that rule was unenforceable across instances **by construction**. So: a
   **sibling's pending hypothesis binds your signature-overlap decisions** exactly as your own does, and
   a signature the sibling has already **settled** is **not re-measured** — record its verdict and move
   on — **whatever direction that verdict took and whichever window produced it**, until new evidence or
   a changed signature invalidates it. Scoping this to "attributed in the current window" would have
   left a sibling's *negative* verdict, and any still-valid verdict from an earlier window, free to be
   measured again — which is the duplication this paragraph exists to stop.
   ⚠️ **Settled is not the same as inconclusive.** A sibling `NO-VERDICT`, `NOT-YET-DUE`, or an
   explicitly unmet measurement floor is **unsettled**, and those stay measurable — freezing them would
   starve exactly the hypotheses still waiting for the data that would close them. ⚠️ Both stores stay **private runtime state**: cross-*reading* them is
   mandatory, cross-*publishing* them is not permitted, and nothing read this way enters a repository
   artifact or public comment. The sibling's file remains **its** single source of truth — read it, never
   write it. The
   **spend evidence/proposal/realisation ledger** — snapshots, proposals with their confidence, open
   maintainer asks, and the projected-versus-realised record — lives in the engineer's own runtime
   store: `/Users/homelab-mac-mini/.codex/automations/daily-ai-engineer/memory.md` for Codex and the
   runtime's native project memory for Claude. These are private runtime stores, never repository
   artifacts, and absolute financial figures live **only** here or in the private channel.
   **Agent Improver research register and cursor** — the durable store the `agent-improvement` skill's
   no-change research fallback (its section *3a*) reads, claims and advances. It is the
   `## Research register` section of the Claude hypothesis store named above: the topic cursor, plus one
   line per pass recording the topic, the sources checked, and the pass's single disposition — one of
   the skill's four outcomes (`ENGINEER-CANDIDATE`, `IMPROVER-CANDIDATE`, `RESEARCH-CANDIDATE`,
   `RESEARCH-NO-CANDIDATE`) or the deferral `QUERY-UNKNOWN` with its blocker named. 🔴 **The single
   cursor writer is the Claude machine-local Agent Improver.** This deployment's private stores are
   per-runtime files with no compare-and-set, so the atomic cross-instance claim with a fencing token the
   skill prefers is unavailable, and its single-writer alternative is what is declared here. The Codex
   Agent Improver reads the register on its cross-read and **never researches or advances the cursor**:
   its disposition is the deferral `QUERY-UNKNOWN (not the declared cursor writer)`, recorded in its own
   ledger — a deferral to the writer, never a blocker to escalate. Research budget: the skill's hard
   maxima (20 minutes, 12 calls, eight primary sources), with no tighter consumer bound. Routing and
   lifecycle: an `ENGINEER-CANDIDATE` becomes a well-formed issue on the owning repository per the
   *Stack map*, filed under the Improver's own disclosure and boarded per *Every issue belongs on the
   board*; an `IMPROVER-CANDIDATE` stays in the register until a later Improver run establishes measured
   local evidence for it; a `RESEARCH-CANDIDATE` stays in the register with its uncertainty named and is
   re-examined by the next pass that reaches its topic, which either promotes it to one of the two queues
   or closes it as `RESEARCH-NO-CANDIDATE`; `RESEARCH-NO-CANDIDATE` is terminal for that cursor value, so
   the topic is not re-searched until the rotation returns to it. Absent or malformed, the fallback fails
   closed to `QUERY-UNKNOWN` with this paragraph named as the blocker.
2. **The end-of-run report** is a per-run record (products surveyed, what changed with PR links). It is
   **not** an attention channel — he rarely reads it — so anything that needs his action goes via a draft
   PR or `AskUserQuestion` (or, when genuinely blocked in an unattended run, a last-resort Slack ping),
   never parked in the report. Live truth for PRs/CI/issues is GitHub itself;
   per-product status is derivable from `gh pr list` / `gh run list`, so it is never duplicated into a file.
