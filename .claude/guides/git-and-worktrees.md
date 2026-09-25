# Worktrees and git safety

> Part of the devantler-tech agent contract. [`AGENTS.md`](../../AGENTS.md) is the always-on core
> and indexes every guide; this guide carries the full rules for per-run worktrees, submodule
> isolation, checking out a PR head safely, and branch hygiene. Read it before creating a worktree,
> initialising a submodule, checking out a commit or pushing.

## Execution model — per-run worktrees
Each run works in **throwaway git worktrees**, never a shared main checkout, so it can't collide with
the maintainer's parallel sessions. For each repo touched, create the worktree **through the claim
helper** (not a bare `git worktree add`) so the directory carries an ownership marker:

```sh
.claude/scripts/worktree-claim.sh add <repo_path> .claude/worktrees/maint-<runid> \
  <lane>/<area>-<desc>-<issue> <session-owner-token>
```

(The `<session-owner-token>` is **unique to one runtime invocation** and stable only for renewals
within that run: derive it as `<lane>-<trusted-runtime-run-or-thread-id>`. Never use a stable agent,
schedule, or lane slug, because overlapping ticks would then impersonate the same owner. `<lane>` is
YOUR instance's namespace from the registry; the trailing issue
number is what makes a pre-PR claim matchable — see *Claim protocol*; for the legitimate
**issue-less** flows the contract allows, a hotfix or a trivial obvious fix, there is no number to
append, so use plain `<lane>/<area>-<desc>` — those go straight to a PR, so the PR body is the
discoverable signal and no claim window applies.) 🔴 **In a harness session the worktree path is
anchored at YOUR session worktree** (`git rev-parse --show-toplevel`), never at the shared checkout
that contains it: the session write guard refuses every Edit/Write under the shared checkout outside
`.claude/worktrees/<your-slug>`, so `<shared>/.claude/worktrees/maint-<runid>` or a shared submodule's
`.claude/worktrees/` builds a tree the run cannot edit. The helper refuses both, and refuses a
`<repo_path>` that is not its own repository's root — an uninitialized submodule — so populate it with
`submodule-init.sh` first (monorepo#2755). The helper also refuses a populated submodule whose `origin`
is not exactly the URL `git submodule sync` writes for it, and reads that URL only from a superproject
that is still the git working tree holding the submodule's git directory. It also refuses one that a setting applying
only to that repository sends elsewhere: a `pushurl`, a URL rewrite, `core.sshCommand`, `core.gitProxy`,
an HTTP proxy, `http.curloptResolve` or `http.extraHeader` (including through a global `includeIf`), or
a custom `receivepack`, `uploadpack` or `vcs` transport. A plain push from the checked-out branch must
go to `origin` too. A linked worktree of a `--separate-git-dir` clone is refused, because nothing in
that clone's git directory proves where its main checkout is, even a `core.worktree`, so nothing shows
whether a superproject registers it; run the helper from the clone's own checkout instead. The
helper checks the new worktree too before claiming it, and removes that worktree when refused. Fix an
origin or redirect refusal with `git -C <superproject> submodule sync -- <path>` and by removing that
setting (monorepo#3010). A registered submodule path that is a symlink is refused too, because git
never checks a submodule out through one; replace the symlink with the real checkout by removing it
and running `submodule-init.sh`. Work
there, open the PR, then
`git -C <repo_path> worktree remove` to clean up (`<repo_path>` is a local filesystem path such as
`applications/ksail` — `git -C` takes a path, not an `<owner/repo>` slug; use the slug only for `gh`
commands). **Immediately before editing any worktree this session did not create**, atomically
reserve it with `.claude/scripts/worktree-claim.sh acquire <wt> <session-owner-token>`: exit 3 means a
**live foreign claim** (marker owner ≠ you, `created_at` within ~2h — the same window as an issue
claim) or, on a worktree carrying no marker, **a live process working inside it** → stand down and
pick another lane. A harness session never writes a marker, so a missing one proves nothing on its
own; when `lsof` cannot answer, the claim fails closed (#2724). **Only exit 0 authorizes editing;
every non-zero status (exit 3 or an acquisition/validation failure) means stand down.** `check` is
read-only diagnosis and does not reserve the worktree. Renew a long-running claim by calling
`acquire` with the same owner at least hourly. A stale marker must not park a worktree permanently
(#2284). **Submodule worktree isolation breaks whenever a submodule is initialised** — a
stray shared `core.worktree` makes `git worktree add` resolve back into the main checkout, silently
collapsing every parallel session into one physical tree.

**A fresh worktree is a fresh COPY — `Read` a file THERE before your first edit of it.** Reading a file
in the main checkout does **not** count as having read the worktree's copy: it is a different file on
disk and the read record does not carry across, so the edit is refused with *"File has not been read
yet"* and the run pays a wasted round-trip. Knowing a file's contents is not the same as having read it
*where you are about to edit it*. That is the observed behaviour and the whole of it — the exact key
the runtime tracks is **not** established, so do not reason from an assumed one. Measured
2026-07-14→21 on the Claude instance (the only lane whose tool errors are attributable — the sibling
runtimes record no error flag, so this is scoped to that lane rather than asserted for all three):
**134 such refusals, 73 of them under this monorepo; 126 were on a path never read in that session,
and 102 of those — 81% — were inside a `.claude/worktrees/` path.** The repeat targets are exactly the
files an agent is surest it already knows: `AGENTS.md`, `SKILL.md`, `MEMORY.md`, `ci.yaml`,
`kustomization.yaml`. It is the single largest tool-error signature in both the 1-day and 7-day
windows. So after `worktree add`, the first touch of each file is a `Read` at the **worktree** path —
and the same applies to `Write` over a file that already exists there.

**`git submodule update --init <path>` is what (re-)introduces it** — reproduced 2026-07-14 on a
submodule that was verified fixed: the key was absent before the command and present after. This is why
"the fix does not stay fixed" (`applications/ksail` regressed 2026-07-14, silently colliding three live
worktrees — two of them the sibling agent's; `templates/platform-tenant-template` regressed the same day).
The init command is *required* to populate a submodule, so **initialising and repairing are one
operation, never two**:

```sh
.claude/scripts/submodule-init.sh <path>            # init at the pinned commit + repair + probe (fail-closed)
.claude/scripts/submodule-init.sh --advance <path>  # after a pin-bump pull: move a populated checkout to HEAD's gitlink
```

Use it instead of a bare `git submodule update --init <path>` (never `--remote`), and use `--advance`
instead of `git submodule update -- <path>` when a pin bump has landed and the checkout is still on
the old commit — plain `update` rewrites shared `core.worktree`. `--advance` refuses a dirty tree or
a checkout ahead of the pin. If you do run a bare
init — or inherit a tree someone else initialised — **probe before you trust it**: confirm
`git -C <wt> rev-parse --show-toplevel` returns the worktree's **own** path, not a `.git/modules/<name>`
path, and repair it in place before editing anything. The diagnosis, the regression watch, and the
verified per-submodule fix are in
[`.claude/worktree-isolation.md`](../worktree-isolation.md). If a repo's working area is
unexpectedly dirty or you can't get an isolated tree, do GitHub-API-only work (triage/comment) there.

🔴 **`submodule-init.sh` leaves you on the GITLINK PIN, so a NEW product work branch cut from it is
based on the pin — not on the product's `main`.** That is correct behaviour for the helper, and the
plugin-definition rules depend on it: reading a reviewed definition **at the pinned revision** is the
whole point there, and it is **unchanged**. But a *product* work branch wants the product's current
tip, and the pin lags it by however long it has been since a bump merged.

**The failure is silent, and every local measurement agrees with itself.** Measured 2026-08-18: a run
selected the oldest open Security issue, cut a branch from the pin, fixed a `checkov` finding, and
drove it to a draft PR with RED/GREEN, a negative control and a build — for work that had **merged
nine hours earlier**. The pin was 6 commits behind and one of those six was the fix. `checkov`
genuinely reported the finding at the pin, and the repository's own scan script agreed **because it
also ran at the pin**. Nothing in the scan, the controls, or the build could have revealed it: they
were all correct about a tree that is not the one the PR merges into. The only signal was
`mergeStateStatus: DIRTY`, after the whole claim → build → validate → PR cycle was spent
([#2891](https://github.com/devantler-tech/monorepo/issues/2891)).

⚠️ **It degrades exactly when dependency automation is unhealthy** — pins move by bump PRs, so a
stalled ecosystem ([#2779](https://github.com/devantler-tech/monorepo/issues/2779) records six days)
freezes every pin and widens this for every submodule at once.

So **before building a new slice in a submodule, ask how stale the pin is** — a fetch and a
`rev-list`, seconds:

```sh
.claude/scripts/submodule-pin-currency.sh <path>   # 0 CURRENT · 1 BEHIND (prints the tip to branch from) · 2 UNKNOWN
```

On `BEHIND`, base the new branch on the product's own default branch rather than the checked-out pin
(the script prints the exact revision). ⚠️ **`2` is UNCHECKED, never CURRENT** — report it and resolve
what it names rather than proceeding as if the pin were fresh. This is about **new work branches
only**: an existing branch is landed on its own `headRefOid` per *Git safety*, and a pinned definition
is still read at the gitlink.

## Git safety
Never `git reset --hard`, `git stash`, force-push, or discard changes you did not author. Never
`git add -A` / `git add .` — stage only files you edited. Never stage submodule-pointer bumps unless
a task explicitly calls for it. Leave every checkout/worktree clean when done.

🔴 **Never make an unsigned commit on a real branch.** Both known paths were scheduled runs' own tool
calls ([#3322](https://github.com/devantler-tech/monorepo/issues/3322)):
`-c commit.gpgsign=false` belongs **only** in a throwaway fixture repository, never on a commit in a
worktree you will push; and never author a work-branch commit through the REST contents API
(`gh api --method PUT …/contents/…`), which creates an unsigned commit. Run
[`unsigned-push-guard.sh <repo-dir>`](../scripts/unsigned-push-guard.sh) as its own call
immediately before `git push`, and do not push on a non-zero exit. It sees only local commits, so the
contents-API rule has no mechanical backstop yet.

🔴 **Name a fetch refspec's source in full: `+refs/heads/main:refs/remotes/origin/main`, never
`main:refs/remotes/origin/main`.** This host sets `fetch.prune=true` globally. With pruning on, a
short source does not match the remote's `refs/heads/*`, so git deletes the destination ref. Depending on
the git version and the ref's state, the fetch then exits 1 with `cannot lock ref`, or exits 0 with
the ref gone, and the next run recreates it. So neither the exit status nor a retry proves the ref is
intact, which is why the short form looks like a working fallback. It does the same
against a URL remote. A plain `git fetch origin main` does not delete the ref either, but it updates
`refs/remotes/origin/main` only through the configured `remote.origin.fetch` mapping. Without that
mapping it writes only `FETCH_HEAD`, so use the full refspec whenever you read the ref. Measured 2026-09-18 to 2026-09-25:
13 of 536 Codex sessions deleted `origin/main` this way ([#3596](https://github.com/devantler-tech/monorepo/issues/3596)).
`drifted-lane-escalation-contract.test.sh` pins the git behaviour.

**The permitted way to put a worktree on a specific commit is
`git --no-replace-objects -C <wt> checkout --no-overwrite-ignore --detach <sha>`, issued as its OWN
call after the `fetch`.** Both global protections are load-bearing: `--no-overwrite-ignore` stops the
command from silently overwriting ignored files, while `--no-replace-objects` prevents a shared
`refs/replace` entry from making the requested SHA materialize a different commit tree even though
`HEAD` still prints the expected value (both fixture-verified). This covers the **superproject**;
submodules need more than a flag and are handled separately below.
When that commit is a PR's head, `<sha>` is its
**`headRefOid`** — the same value *Merge policy* pins the merge to, so the worktree you evaluate and
the commit you merge are provably the same one. A ban that never names the alternative is exactly the
DevEx tax *Security hardening without a DevEx tax* forbids, and the vacuum gets filled by something
worse: durable memory came to prescribe `fetch` + `reset --hard FETCH_HEAD` for putting a fresh maint
worktree onto a PR head — a command the runtime denies outright — so every compliant run reached for
something that could never run (measured across one day's session corpus: 3–4 denied calls over three
separate ticks). Memory is also **per-lane**, so correcting one lane's notes leaves the siblings
reaching for the same denied form; that is why this belongs in the shared contract.
🔴 **Issue the `fetch` and the `checkout` as SEPARATE calls — a denied COMPOUND call rolls back the
whole chain**, so the `fetch` never runs either and the follow-up fails on a missing `FETCH_HEAD`.
That reads like a broken gitdir rather than a refusal, which sends the run to diagnose the wrong
thing — the denial costs a misdiagnosis on top of the wasted call.
🔴 **CHECK THE WORKTREE IS CLEAN FIRST — `checkout --detach` does NOT reliably refuse a dirty one, and
assuming it does is how you silently adopt another instance's uncommitted work.** Measured on a
two-commit fixture, both arms: it **aborts and preserves** only when the modified path **differs**
between HEAD and the target; when the dirty path is **identical** in both commits, git **carries the
edit along and succeeds** — leaving you on the target commit with someone else's work still in the
tree, and nothing in the output saying so. Run `git -C <wt> status --porcelain` as its own call;
require exit 0 and empty output before detaching. If it fails or prints anything, that is a live claim
by another writer: do GitHub-API-only work per *Execution model* and never detach over it.
⚠️ **`status` alone is not sufficient, because the INDEX CAN HIDE a foreign edit.** A tracked file
carrying `assume-unchanged` or `skip-worktree` is omitted from `status --porcelain` entirely —
fixture-verified: an empty status, followed by a successful checkout that carried another writer's
edit straight onto the target commit. Run
`(set -o pipefail; git -C <wt> ls-files -v | awk '$1 ~ /^[a-z]$/ || $1 == "S"')`; require the whole
command to exit 0 and print nothing (a lowercase flag or `S` marks exactly those bits).
[`worktree-cleanup.sh`](../scripts/worktree-cleanup.sh) already makes this check for the same
reason — treat an empty `status` as authorization to detach only once this one is clear too.
🔴 **CHECK AGAIN AFTER DETACHING — the target can leave residue that did not exist in its tree.**
After detaching, repeat `git -C <wt> status --porcelain`; require exit 0 and empty output. Run
`git -C <wt> clean -ndx` as its own read-only call; require exit 0 and empty output. The latter is a
dry run, never permission to clean: any line, including a skipped nested repository, means untracked
or ignored material remains and evaluation stops. This specifically closes the removed-submodule
case: non-recursive checkout can warn that it could not remove an initialized submodule directory,
leave that old code behind, and then make `submodule status --recursive` pass vacuously because the
target commit no longer declares the gitlink. Builds must not consume code absent from the reviewed
tree.
🔴 **`--detach` moves the SUPERPROJECT ONLY, so after detaching you are NOT necessarily on the PR's
code — DETECT that before evaluating anything.** Fixture-verified: on a PR that changes a gitlink, HEAD
lands on the target while the submodule still holds its **previous** content, and `status` shows
nothing but a leading space followed by `M <sub>`. You would be reviewing **different code from the
`headRefOid` you believe you are on**, and since a large share of PRs here are submodule bumps that is
the common case rather than an edge one. Run `git -C <wt> submodule status --recursive` and require it
to exit 0 and every output line to begin with a space. Reject a leading `+` (gitlink mismatch), `-`
(not initialised), or `U` (unmerged) before evaluating the reviewed commit. This marker check proves
only that each populated submodule is on its recorded gitlink; it does not prove that files inside an
initialised submodule are clean.
🔴 **Do NOT reach for `--recurse-submodules` to fix that — it is unsafe in this repo's mandated
throwaway-worktree flow, measured.** Where a submodule is initialised in the main checkout but empty in
the linked worktree, both pre-checks above pass and the recursive checkout then writes a `mod/.git`
pointing at a nonexistent gitdir and **exits 128** (`could not reset submodule index`), leaving that
submodule unusable. It also cannot **fetch** a target gitlink absent from the local object database —
the ordinary dependency-bump case — so it exits non-zero having already moved the superproject, leaving
the tree half-switched; it silently **skips** a submodule the target commit introduces, exiting 0 with
a clean status over a directory containing no code; and its `--no-overwrite-ignore` protection **does
not propagate**, so foreign ignored work inside a populated submodule is destroyed while both
top-level checks read clean.
⚠️ **Bare init mode is not the answer for a populated mismatch; `--advance` is deliberately scoped.**
`submodule-init.sh <path>` still repairs isolation *only* when `<path>` is already populated and
never moves that checkout. `submodule-init.sh --advance <path>` is the permitted top-level pin-bump
path: it refuses dirty, hidden-index, ahead-of-pin, replacement-object and ignored-overwrite hazards,
moves only the named checkout, and fails closed when an initialised nested submodule no longer matches
the new pin, contains tracked dirt or hidden index flags, or resolves outside its own physical
worktree. It never recursively initialises additions or advances nested submodules for you. It also
refuses when untracked material
remains after checkout or when an ignored embedded repository remains — including a removed nested
submodule the non-recursive checkout could not delete. Ordinary ignored artifacts that do not overlap
target paths are preserved.
🔴 **A post-checkout refusal does NOT roll back.** The nested, isolation, and residue gates run after
the detach, so a non-zero exit can leave the named checkout already on the new pin. Treat the refusal
as "do not use this tree yet", not "nothing changed": handle the reported condition, re-run
`--advance`, and require exit 0 before evaluating anything.
📌 **Landing a worktree on a PR head *including newly introduced or mismatched nested submodules*
therefore still needs a complete procedure — fetch, initialise additions, repair isolation, advance
each populated checkout, then probe — not a recursive checkout flag. That is
[#2833](https://github.com/devantler-tech/monorepo/issues/2833).** Until it exists, detect those
conditions and stop; never paper over them with a flag that fails closed at exit 128 or, worse, fails
open with a clean-looking status.
⚠️ **The pre-check cannot see IGNORED paths, and checkout overwrites them by default — which is why
`--no-overwrite-ignore` is in the command above.** `git checkout` documents `--overwrite-ignore` as
the default and `status --porcelain` never lists ignored files, so when the target commit starts
tracking a path that is ignored at your current HEAD, an empty pre-check is followed by a **silent
overwrite** of whatever was there (fixture-verified, including that the flag aborts instead). The
window is narrow, but it is exactly the case the pre-check is blind to, so the default is the unsafe
one and the flag is what makes the prescribed form safe by default.
⚠️ **It remains a strictly safer swap, never a loosening — the guard is untouched and needs no
widening.** On a clean worktree it lands on exactly that commit, the same outcome the banned form
would have produced, and wherever it *does* refuse it preserves what `reset --hard` would have
destroyed. It is never weaker than the banned form; the abort is simply a partial backstop rather than
the check itself, which is why the cleanliness test above is the operative rule.

**Worktree hygiene is SCHEDULED, not per-run — never rely on a session to remove its own worktree.**
The harness creates a per-session worktree at `<repo>/.claude/worktrees/<slug>`, and the owning
session **structurally cannot remove it**: that directory is the session's own working directory, and
sessions routinely end abruptly (crash, timeout, closed window) with no teardown. So the sweep must
come from **outside** any session. It does, via the `tech.devantler.worktree-cleanup` LaunchAgent
(runtime-local, `~/Library/LaunchAgents/`), which runs
[`.claude/scripts/worktree-cleanup-all.sh [apply|dry-run] [min_age_hours]`](../scripts/worktree-cleanup-all.sh)
every 6 hours and at login across the monorepo and every submodule discovered from `.gitmodules`.
Per-repo safety lives in [`worktree-cleanup.sh`](../scripts/worktree-cleanup.sh) and is
**fail-closed**: it KEEPs any worktree that is a **live process CWD**, is **locked**, is **younger
than `min_age_hours`**, holds **commits not reachable from any remote** (one
`git rev-list --not --remotes` test covering both an unpushed branch and an orphan detached HEAD), or
has **uncommitted work**. Two things are treated as noise rather than work: **unstaged** submodule
gitlink drift — and only once that submodule is itself proven clean and pushed (a *staged* gitlink is
authored intent living solely in that worktree's index, so it always counts as work) — and the stray
tool dirs `?? .codex/` / `?? .agents/`, which are filtered unconditionally. Every removal is recorded to a
restore manifest **outside the repo** (`~/.claude/worktree-cleanup-manifests/`) before it happens, and
any infrastructure failure aborts rather than reaping. **Do not add a per-run worktree sweep** to
compensate; a session removing its *own* worktree is exactly the thing that cannot work.
Measured 2026-07-29, the run that introduced this: **124 leaked monorepo worktrees, ~15.7 GB across
`.claude` and `.codex`, disk at 99%, and new sessions failing to start** for want of 5.4 GB. Because a
branch checked out by a worktree is permanently in `branch-cleanup.sh`'s keep-set, the same leak had
also pinned **84 of 422** local `claude/*` branches — so leaked worktrees silently disable branch
cleanup too, and this sweep is what unblocks it.

**End-of-tick branch hygiene — reap spent branches and return to the default branch, EVERY run**
(maintainer direction 2026-07-16: *"You never clean up old branches locally or on the remote. I expect
you to always clean up and switch back to the default branch after a tick."*). Left unswept, every run's
worktree branch survives it: the first sweep found **~1,140 spent branches** (monorepo alone had **589**
local; `.github` had **35** stale remote). Run
[`.claude/scripts/branch-cleanup.sh <repo_path> <repo-name> <manifest> [apply|dry-run] [namespace]`](../scripts/branch-cleanup.sh)
for each repo touched. **If you created an EXTRA worktree of your own during the run — one you are not
running inside — remove that first**, because a branch still checked out by a worktree sits in the
keep-set and would be spared. **Your own SESSION worktree is the exception and needs no action here:**
you cannot remove the directory you are running in, and per *Worktree hygiene is SCHEDULED* above the
LaunchAgent reaps it (and frees its branch for a later sweep) once it is idle and aged. Expect your own
session branch to survive the tick that spent it; that is the scheduled sweep's job, not yours.
**`<repo-name>` is the BARE repository name** (`monorepo`, `platform`) — the script prepends
`devantler-tech/` itself. It is **not** your session/worktree slug and **not** `owner/repo`; both are
rejected, and passing the owner-qualified form is the likelier mistake because the first rejection
names the origin.
**Native compatibility adapter:** this host's `branch-cleanup.sh` accepts only the `claude` namespace.
It does not grant cleanup authority over another registered instance; that instance uses its own
verified native cleanup path. Apply-mode cleanup holds the shared branch-operation lock
([`branch-op-lock.sh`](../scripts/branch-op-lock.sh)) for the whole pass so it cannot overlap a
harness worktree operation — `worktree-add.sh`, `worktree-remove.sh`, and `worktree-claim.sh add`,
which holds the same lock across its entire creation path (branch resolution, the pinned-tip lookup,
and the `git worktree add` itself); dry-run skips the lock. Stale-lock recovery is same-host dead PID or
age ≥ 600s — if a live holder is wedged past that, confirm no agent holds it and `rm -rf` the lock
directory under the repo's `git-common-dir`.

**🔴 Deleting a remote branch CLOSES its open PR — so the keep-set is the whole safety property:**
- **KEEP:** the head of an **OPEN PR**; any branch **checked out by a worktree**; the default branch;
  the maintainer's **interactive random-slug** branches `claude/<adjective>-<name>-<6hex>` (HANDS-OFF —
  never reaped even with a merged/closed PR, since they were never this routine's per-run worktree),
  **except locally when its tip is an ancestor of the published default branch**: such a branch holds no
  work of its own and `git branch <name> <sha>` recreates it, so it is reaped and recorded like any other; and
  anything outside the **selected namespace's** prefix (one invocation never crosses into another lane —
  never sweep another instance's namespace through this native adapter).
- **`git branch --merged main` is USELESS here** — the portfolio **squash-merges**, so a merged branch's
  commits are never in `main`. For the same reason `commits-not-in-main > 0` does **NOT** mean unmerged
  work. **The PR state is the only authoritative signal** — never infer merge status from the commit graph.
- **Local:** `claude` namespace only — delete anything outside the keep-set (`-D`; `-d` cannot see
  squash-merges). Other instances use their declared native cleanup path.
- **Remote:** delete only on **positive evidence** — an associated **MERGED/CLOSED PR whose recorded
  head SHA equals the branch's CURRENT SHA** (a re-pushed branch is a new incarnation the old PR does
  not account for → keep). Apply this same evidence gate on every native cleanup path. **No-PR branches are never
  deleted, only reported as candidates** — commit time is NOT push time, so "old commits" can be a
  live session that just pushed; age alone is not evidence. Deletes are **CAS-guarded**
  (`--force-with-lease` pinned to the evidence SHA) and the open-PR keep-set is **re-fetched
  immediately before the delete loop**.
- **Fail closed on infrastructure:** a failed `git fetch`, open-PR query, or manifest write ABORTS the
  sweep — an empty keep-set from a failed query would otherwise delete every open PR's branch.
- **Write a manifest** (`repo → branch → sha → evidence`) before deleting so any branch is restorable
  from its SHA; the write is verified — no restore record, no deletion.
- Reap only **your own** per-run worktree — another session's worktree directory may be live.

**Two-writer branches — another instance may be on the same PR right now.** More than one agent
instance sweeps the same PR dashboard (and instances can overlap inside one hour), so any shared
branch (`claude/*`, a bot branch you push fixes to) — and even a not-yet-opened artifact like a
weekly distil PR — can move or appear under you mid-run (4 sightings, incl. two instances authoring
the same definition PR minutes apart). Discipline, every time: (1) **before building a fix or a new
artifact for a swept concern**, re-check the live state — newest commits, newest comments, open PRs
on the same theme; a fresh sibling push or disclosed reply means that lane is owned this hour —
verify against the NEW head and prefer contributing to the existing artifact over duplicating it;
(2) **fetch immediately before every push** to a shared branch and integrate with a **merge, never a
force-push**; (3) on generated-file conflicts, take the incoming side and **re-run the generator**
(`checkout --theirs` + regenerate) rather than hand-merging generated output. **A
`File has been modified since read` (or equivalent) tool error on a path inside a per-run worktree
is a collision signal, not editor noise** (#2284): re-diff before assuming it is your own churn, and
**never** `git checkout` / overwrite the contended path — that destroys uncommitted work belonging
to another instance. Prefer standing down and picking a different lane over writing through.

**Temporary clones go through the safe-clone primitive — credentials never live in remote URLs.**
Every autonomous temporary clone uses [`safe-clone.sh`](../scripts/safe-clone.sh)
(`.claude/scripts/safe-clone.sh <owner>/<repo> <dest>`): it guards the effective git config against
credential-bearing rewrites (`insteadOf`/`pushInsteadOf`), auth `extraHeader`s, and credentialed
proxies before cloning (the environment is deliberately NOT scrubbed — `gh auth git-credential`
needs `GITHUB_TOKEN`/`GH_TOKEN`),
forces the canonical credential-free `origin` URL, routes auth through `gh auth git-credential`,
and fail-closed-verifies that no HTTP(S) remote carries URL userinfo and no effective-config
`insteadOf` rewrite embeds a credential — deleting (clone mode) or flagging (`--check`) anything
unsafe with **redacted** output only. On any clone the helper did not create, run
`safe-clone.sh --check <dir>` **before** any output-producing remote or trace diagnostic
(`git remote -v`, `GIT_TRACE*`, `git config --list`, `git remote get-url`); if the guard fails,
sanitize (`--sanitize <dir>`) or delete the clone — and treat the credential as leaked (surface
rotation to the maintainer) — **never** print a remote URL or config listing first. (Born of the
2026-07-10/12 incidents where a token embedded in clone remotes and in a global `insteadOf` key
reached durable task output — monorepo#2132.)
