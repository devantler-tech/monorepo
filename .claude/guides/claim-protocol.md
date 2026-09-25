# Claim protocol and writer namespaces

> Part of the devantler-tech agent contract. [`AGENTS.md`](../../AGENTS.md) is the always-on core
> and indexes every guide; this guide carries the full rules for how an issue is claimed before
> building, how the shared `agent-claim/<issue>` ref arbitrates races, and which branch namespace
> each instance writes. Read it before claiming, taking over or abandoning any issue.

## Claim protocol — reserve the lane before you build
This brain runs as **several instances at once**, all executing *The work-selection ladder* over the
same backlog. Two sessions surveying minutes apart will reliably pick the same issue —
convergence is the **expected** behaviour of the selection rule, not bad luck.
🔴 **The ladder makes this WORSE at rungs 2–3, and deliberately so — claim harder there.** Sorting by
severity narrows the target pool from "the oldest of ~368 open issues" to "one of **18** open
`type:"Security"` issues" (counts measured 2026-07-25), so every instance aims at the same handful
instead of spreading across the age curve. Rung 1 pulls the other way — an own draft is owned by
exactly one lane, so PR work barely collides — but the moment a run descends to rung 2 the collision
odds jump. Before the lane-neutral ref delivered by
[monorepo#2302](https://github.com/devantler-tech/monorepo/issues/2302), rule 4 had no cross-lane
arbitration: each lane could push its own branch successfully, and an open PR appeared only at the
**end** of a build. **The shared ref closes that historical hole before a build starts** — on rungs
2–3, acquire it without exception and scan it plus **all three** lane namespaces. The evidence for
why that protection is mandatory remains: measured on `world-at-ruin` (2026-07-18), **six
end-to-end builds
discarded in ~24 hours** — #66 built to completion twice over, #81 lost after a full build with a
committed golden and five negative controls, #86 lost 12 minutes after filing, #88 lost by **52
seconds**, #96 lost by **135 seconds**. Every one was correct, validated work; only the coordination
failed. So, on every **in-scope `devantler-tech`** repo — claiming is a *write* action (a shared ref,
then an assignment where supported and a pushed lane branch), so the *Professional-work repository
boundary* below still wins outright: never
claim, probe, or push anywhere that boundary has not been cleared, and nothing here licenses a first
touch of an unconfirmed repo:

**Cross-lane arbitration uses a lane-neutral ref.** Each instance still writes its own work-branch
namespace (resolved from the instance registry), so a race settled only on the work-branch name is never
arbitrated across lanes. The durable claim is therefore `agent-claim/<issue>` — a single shared ref
every instance derives from the issue number alone — acquired **before** the lane-specific work
branch via [`.claude/scripts/agent-claim.sh`](../scripts/agent-claim.sh) (RED/GREEN coverage of
the fifteen proven traps live in `agent-claim.test.sh`).

1. **Check four signals before selecting, not one:** open PRs, remote `agent-claim/<issue>` tips,
   remote work branches in every registered namespace, and issue assignees. An assignee
   here means "an instance has claimed this", **not** "the human maintainer took it" — every instance
   uses its registered assignment identity (see *Trust gate*). Current instances share `devantler`,
   so that login cannot distinguish one instance from another or from the maintainer. Read it as a claim, never as a hands-off signal, and never let
   it park an issue past the expiry below. The `agent-claim/<issue>` tip is the **cross-lane** signal;
   lane work branches remain useful for within-lane discovery and for instances whose verified
   capabilities do not include assignment.
   **Match on the issue NUMBER or a normalised stem — never the literal branch name.** On
   #96 two sessions collided on `claude/war-armour-…` versus `claude/war-armor-…`: the repo's code is
   American, the issue's title British, so each session derived a different stem from a different part
   of the same issue and neither's exact-name scan could see the other. Grepping open PR *bodies* for
   the **`#<issue>` reference — with the hash, not the bare digits** — is spelling-proof:
   `gh pr list -R <o>/<r> --state open --search '"#<issue>" in:body'`. `-R` scopes the *PR list* to
   this repo, but a body can still name a **foreign** issue as `other-owner/other-repo#<issue>` — that
   is not a claim on *this* repo's issue. Keep a hit only when the body references **this** repo's
   issue: a `Fixes`/`Closes`/`Resolves #<issue>`, an explicit `<o>/<r>#<issue>`, or a bare `#<issue>`
   that is **not** solely a foreign `owner/repo#<issue>`. A bare digit match (no hash) still matches
   benchmark counts and dates and must never be used — that would hide the oldest actionable issue
   behind an unrelated PR.
2. **Claim before you build, not after — lane-neutral ref FIRST.** The moment you select an issue:
   (a) **acquire `agent-claim/<issue>`** with the helper and retain the full SHA it prints
   (`claim_sha="$(.claude/scripts/agent-claim.sh acquire <issue> --repo-dir <product-path>)"`)
   — this is the cross-lane race; a LOST (exit 1) means stand down under rule 5, while exit 2 with no
   competing tip is a capability/service failure to record rather than an invented winner; (b)
   **immediately recheck for an open PR whose body references `#<issue>`**. The previous holder may
   have opened its draft and retired the shared tip while this acquire was fetching; if a matching PR
   now exists, retire only your acquired tip (`.claude/scripts/agent-claim.sh retire <issue> "$claim_sha" --repo-dir
   <product-path>`) and stand down. Then (c)
   self-assign it when your identity can
   (**if the registered identity is already assigned, remove and re-add**, because the add is a no-op for an
   existing assignee and would leave your lease carrying the *old* timestamp); and (d)
   **immediately before pushing the lane branch or opening its draft PR** — and **again after any
   resumed pause** — **atomically renew the retained SHA** and replace the ownership token with
   `claim_sha="$(.claude/scripts/agent-claim.sh renew <issue> "$claim_sha" --repo-dir
   <product-path>)"`. The compare-and-swap both proves ownership and refreshes the two-hour lease; a
   failed renew means a takeover won or ownership is unknown, so abandon under rule 5 without pushing
   or opening a competing PR. Then
   (e) push the
   lane-specific work branch **with the issue number in its name** —
   `<lane>/<area>-<desc>-<issue>` (e.g. `claude/war-foliage-spatial-hash-109`,
   `codex/agent-claim-ref-2302`). Only **then** harden (tests, ablations, docs, comments). Opening
   the **draft PR after the first real commit** is stronger still and is the recommended default —
   and **retires the `agent-claim/<issue>` tip** (rule 3). A pre-flight scan with no claim tip, no
   branch and no PR is **not** a claim. Before a PR exists there is no body to grep, so a bare
   `<lane>/<area>-<desc>` leaves a rival only the normalised-stem match that #96 proved fragile; the
   number is the one token that cannot be spelled two ways.
   🔴 **`--repo-dir` is REQUIRED whenever the issue belongs to a submodule, and issue numbers are
   repository-scoped — so omitting it claims the WRONG issue rather than failing.** The run stands in
   the monorepo checkout when it selects, so a bare invocation pushes `agent-claim/<issue>` to the
   monorepo's `origin`, locking whatever monorepo issue happens to carry that number while the product
   issue you actually selected stays unclaimed and open to a rival. Point every call in the sequence —
   `acquire`, `verify`, `is-stale`, `retire` — at the **same** product path (`applications/ksail`,
   `platform`, …), and **populate that submodule first** with
   [`submodule-init.sh`](../scripts/submodule-init.sh): an uninitialised path has no repository
   to push to, and `git -C` against one silently resolves to the **parent**, which is the same wrong
   claim by another route. Invoke the **root** helper with `--repo-dir` rather than changing into the
   product, since the relative script path does not resolve from there.
3. **Claims expire; retire on PR open; stale takeover is evidence-gated.** A claim carrying no open
   PR after **~2 hours** is stale and may be taken over, so a crashed or abandoned session never
   parks an issue permanently.
   - **Retire on PR open:** the moment the draft PR that references `#<issue>` exists, run
     `.claude/scripts/agent-claim.sh retire <issue> <acquired-sha> --repo-dir <product-path>` so the shared tip cannot lock the issue after
     coordination has succeeded. The acquired SHA is mandatory: a stale holder must never observe and
     delete a takeover winner's replacement tip. An unretired `agent-claim/*` tip is a **permanent
     lock** on an open issue — trap 4 of #2302; retirement is mandatory, not optional hygiene.
     [`agent-claim-sweep.sh`](../scripts/agent-claim-sweep.sh) `--repo <owner>/<repo>
     --repo-dir <product-path> [--apply]` removes only tips whose issue is **closed**,
     compare-and-swap; it never touches an open issue's tip.
   - **Project Board API-only work:** the board has no product checkout, but its roadmap issue lives
     in `devantler-tech/monorepo`. Acquire against the monorepo root, retain the SHA, and retire that
     exact SHA after the board/API mutation is read back and verified. **Atomically renew the retained
     SHA immediately before the board mutation** and replace `claim_sha` with the SHA returned by
     `.claude/scripts/agent-claim.sh renew <issue> "$claim_sha" --repo-dir <monorepo-root>`; if renewal
     fails, stand down without mutating. A controlled failure before mutation also retires; only a
     crashed process leaves a tip for the ordinary lease/takeover path.
   - **Lease clock for the shared tip** is the tip's **committer date** (the helper writes a fresh
     commit at acquire time, so this is wall-clock accurate). Check with
     `.claude/scripts/agent-claim.sh is-stale <issue> --repo-dir <product-path>`.
   - **Lease clock for the assignee** (when your identity can assign) remains the issue's **NEWEST
     `assigned` timeline event** for `devantler` — never a work-branch commit date (those usually
     point at the base commit and would make every fresh claim look long expired):
     ```sh
     lease=$(
       set -o pipefail   # WITHOUT this a failed read prints NOTHING and exits 0, i.e. "never assigned"
       gh api repos/<o>/<r>/issues/<n>/timeline --paginate \
         --jq '.[]|select(.event=="assigned" and .assignee.login=="devantler")|.created_at' | sort | tail -1
     ) || { echo "timeline read FAILED — UNKNOWN, never unassigned" >&2; exit 1; }
     ```
     Filter to **`devantler`**: an issue can carry several assignees, and a later assignment of
     someone else would otherwise set your lease clock. Under `--paginate` each page is a **separate
     JSON array**, so an aggregate like `'[…]|last'` runs *per page* — emit every match as its own
     line and take the max in the shell.
     🔴 **A FAILED timeline read is UNKNOWN — never "unassigned", and never a live claim.** Without
     `pipefail` the pipeline's status is `tail`'s, so a server error prints nothing and exits `0`,
     which reads exactly like an issue nobody assigned. That happened: every assignment-timing
     surface returned HTTP 500 for `platform` alone on 2026-08-12 (#2798). A *successful* empty read
     still means no assignment. On UNKNOWN, decide skip reason (e) from the `agent-claim/<issue>` tip
     alone. An unreadable timeline can never park an issue, because the takeover gates below never
     consult it.
   - **Taking over a stale claim** needs BOTH evidence gates: (1) no open PR whose body references
     `#<issue>`, and (2) the `agent-claim/<issue>` tip past the lease (`is-stale` exits 0). Then
     `.claude/scripts/agent-claim.sh acquire <issue> --takeover --repo-dir <product-path>`. Also unassign-then-re-assign when your identity can
     assign (GitHub's add-assignees endpoint is a no-op for an already-assigned user — a plain
     re-assign creates **no** new `assigned` event). **Always pass `-R <owner>/<repo>`**:
     ```sh
     gh issue edit <n> -R <owner>/<repo> --remove-assignee devantler
     gh issue edit <n> -R <owner>/<repo> --add-assignee devantler
     ```
     **If the dead claim left a remote *work* branch carrying commits**, do not reuse that name:
     start a fresh branch (`<lane>/<area>-<desc>-<issue>-2`) and leave theirs alone — never
     force-push over it. This time-boxing keeps the rule compatible with *"a bare assignee does not
     reserve an issue"*: a claim is a short lease, not a lock.
4. **Make the `agent-claim/<issue>` push DECIDE the race — compare the tip, never the exit status.**
   The residual window is seconds wide but real (that is exactly how #88 and #96 were lost). Every
   instance derives the *same* ref from the issue number, so a bare re-check is not enough — both
   would see "no tip" and both would then believe they claimed it. Settle it on the helper's push:
   - The helper writes a **fresh commit with a portable nonce** (`/dev/urandom` hex; **fail closed**
     when no entropy source is available). A fixed message on a shared parent in the same second
     yields a **byte-identical** commit — reproduced exactly on 2026-07-20 — so both pushes succeed
     and both read the tip as theirs (trap 3). The nonce is the whole defence.
   - Push **without force**, then **verify the remote tip is yours**
     (`.claude/scripts/agent-claim.sh verify <issue> <sha> --repo-dir <product-path>`, or
     `git -C <product-path> ls-remote origin refs/heads/agent-claim/<issue>`). **Compare the tip — never
     judge the race by the push's exit status**, and never through a pipe: `git push … | tail`
     reports `tail`'s status, so a *rejected* push reads as exit 0 (reproduced 2026-07-20, trap 2).
     If the tip is someone else's, **you lost the race** — stand down under rule 5 rather than
     force-pushing over them. Never `--force`/`--force-with-lease` a live claim tip.
   - After you hold the tip, push the lane work branch the same way (real commit, no force, tip
     compare). The shared tip is what closes the cross-lane hole; the lane branch remains the
     per-instance working ref.
5. **On a lost race, ABANDON.** Never duplicate the work, never force-push onto a sibling's branch
   or claim tip, never open a competing PR. Then **use the loss**: two independent implementations of
   one spec are a free **differential-testing oracle**. Diff yours against the winner's and post
   **only findings you have verified** — on w-a-r#88 that surfaced a real integer-overflow gap the
   merged twin shared.
   **How you verify depends on who won, and the trust gate is not relaxed here:** against a
   **trusted/routine-owned** winner, execute the probe on their branch; against an
   **external-contributor** winner, it is **static review ONLY** — never check out, build, run or
   probe their branch, exactly as the trust gate requires, and say plainly in the finding that it is
   reasoned from the diff rather than executed. Likewise, a review you obtained on your own losing PR
   **audits the winner too**: re-check its findings against `main` before discarding them (that is how
   the merged armour guard's membership-vs-mapping gap was found).

**A live claim is a temporary skip — the one addition to the skip test.** *Drain oldest-first* lists
when an older issue may be passed over; a **live claim** — an `agent-claim/<issue>` tip inside the
~2h lease **or** (assigned **and** branched, inside the ~2h window), with no PR yet — now joins it as
skip reason **(e)**, and it is the only one that expires on its own. Without that, an oldest issue
carrying a fresh claim would be both un-takeable and un-skippable — which either stalls the queue or
recreates the duplicate build the protocol exists to prevent. Note it in the report as
claimed-elsewhere and move to the next actionable issue; if it is still tip/branch-only after the
window, it is fair game again (evidence-gated takeover per rule 3). **Nothing else in that test
changes** — in particular, an issue is never skipped merely because it *looks* contested, is large,
or is hard.

## Writer namespaces

The [instance registry](../plugin-consumption/agent-instances.json) allocates one unique branch
namespace to each runtime instance and lists the roles sharing it. Ownership belongs to that instance,
not its model or provider. A role must resolve its exact registered instance before any claim or push;
an absent, duplicated or unsupported mapping leaves mutation unavailable. Registration declares the
intended scope; it does not prove native permission enforcement or activate inference routing.

Roles sharing one instance also share its claim protocol, draft ownership and checkout discipline.
Inspect every branch and open PR in that namespace before selection, including work from the other
role. Changing a model never creates another writer. Spend work needs no separate writer: it remains
part of the Agentic Engineer and retains the Spend contract's independent activation gate.

**`agent-claim/<issue>` is a COORDINATION ref, not a writer lane.** Every instance derives the same
ref from the issue number and acquires it before its work branch. Writer branches carry code and
belong to one instance; the shared coordination ref carries only the helper's empty nonced commit.
Retire that ref when the draft PR opens. Every acquisition, renewal, takeover and retirement goes
through [`agent-claim.sh`](../scripts/agent-claim.sh) and its compare-and-swap guards. Never push
code to it, open a PR from it, or force-push a live tip.

Before selecting, check open PRs, shared claim refs, every registered namespace and issue assignees.
A missing assignment capability does not make branch claims invisible. A failed claim mutation with
no competing tip is a capability/service failure, not a lost race. An unregistered origin has no
writer authority; use the reviewed inline/read-only fallback where its capabilities allow it.
