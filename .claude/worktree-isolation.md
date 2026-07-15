# Submodule git-worktree isolation — diagnosis & repeatable fix

> Reference for the autonomous engineer **and** the maintainer. Resolves monorepo issue
> [#1838](https://github.com/devantler-tech/monorepo/issues/1838) (Theme 3 of the strategy epic
> [#1813](https://github.com/devantler-tech/monorepo/issues/1813)).

Per-session `git worktree add` isolation is **inconsistent across the submodules** of this monorepo.
Some resolve a `git worktree add` into an isolated working tree (correct); most resolve it back into
the **shared main checkout**, so two sessions' uncommitted changes interleave in one physical directory
and a commit can silently land on the wrong branch. Routine work then has to fall back to a throwaway
clone or GitHub-API-only mode, and it risks colliding with the maintainer's parallel interactive
sessions if that fallback is missed.

This is a **per-machine git-config** condition, not a version-controlled defect in this repo — so the
shippable output is this documented, verified procedure plus the diagnosis below. It was rolled out
across **all** active submodules on `~/git-personal/monorepo` on 2026-06-25; it re-applies to any fresh
clone, where the condition recurs.

## Root cause

A submodule's git directory lives at `<repo>/.git/modules/<name>/`. The breakage is a stray
**`core.worktree`** key in that **shared** `.git/modules/<name>/config`:

- `core.worktree` is a **per-worktree** setting — it tells one working tree where its files live.
- When it sits in the **shared** config, **every** linked worktree created by `git worktree add`
  **inherits the same value**, which points at the *main* checkout. So the new worktree gets an
  isolated gitdir (`.git/modules/<name>/worktrees/<id>/`) but its `core.worktree` still resolves to the
  main checkout — `git rev-parse --show-toplevel` from inside it returns the main tree (or the
  `.git/modules/<name>` dir), not its own path. That is the collision.
- The correct layout requires **`extensions.worktreeConfig = true`** *and* `core.worktree` moved **out**
  of the shared config into each worktree's own `config.worktree` (the main worktree's lives at
  `.git/modules/<name>/config.worktree`; each linked worktree's at
  `.git/modules/<name>/worktrees/<id>/config.worktree`). **Setting the `worktreeConfig` flag alone is
  not enough** — if the stray shared `core.worktree` remains, it is still inherited (as `platform` and
  `go-template` were before 2026-06-25: flag on, yet still broken until the stray value was removed).

## Diagnosis & rollout (swept 2026-06-25 on `~/git-personal/monorepo`)

`BROKEN` = stray `core.worktree` in the shared `.git/modules/<name>/config`, inherited by every linked
worktree. The 2026-06-25 sweep found **every active submodule broken** except the two already isolated
(`templates/gitops-tenant-template`, fixed 2026-06-17, and `projects/ksail`) and **fixed +
probe-verified all of them** — repairing live linked worktrees in place (see *Live linked worktrees*
below). Current state:

| Submodule | shared `core.worktree` | `extensions.worktreeConfig` | State |
|---|---|---|---|
| `applications/ascoachingogvaner` | ~~set~~ → unset | true | ✅ fixed & verified 2026-06-25 |
| `applications/ksail` | ~~set~~ → unset | true | ⚠️ **REGRESSED 2026-07-14** — re-fixed & verified (see *Regression watch*) |
| `applications/unifi` | ~~set~~ → unset | true | ✅ fixed & verified 2026-06-25 |
| `github/devantler-tech/.github-public` | ~~set~~ → unset | true | ✅ fixed & verified 2026-06-25 |
| `github/devantler-tech/github-actions/actions` | ~~set~~ → unset | true | ✅ fixed & verified 2026-06-25 |
| `github/devantler-tech/github-actions/reusable-workflows` | ~~set~~ → unset | true | ✅ fixed & verified 2026-06-25 |
| `github/personal/.github-public` | ~~set~~ → unset | true | ✅ fixed & verified 2026-06-25 |
| `github/personal/profile` | ~~set~~ → unset | true | ✅ fixed & verified 2026-06-25 |
| `templates/dotnet-template` | ~~set~~ → unset | true | ✅ fixed & verified 2026-06-25 |
| `templates/platform-template` | ~~set~~ → unset | true | ✅ fixed & verified 2026-06-25 |
| `platform` | ~~set~~ → unset | true | ✅ fixed 2026-06-25 — **6 live worktrees repaired in place** |
| `templates/go-template` | ~~set~~ → unset | true | ✅ fixed 2026-06-25 — **1 live worktree repaired in place** |
| `templates/gitops-tenant-template` | ~~set~~ → unset | true | ⚠️ **REGRESSED 2026-07-14** — re-fixed & verified (see *Regression watch*) |
| `projects/ksail` | unset | true | ✅ already isolated — **active, do not delete** (see below) |

> **`projects/ksail` is ACTIVE — never treat it as orphaned.** An earlier revision of this doc called it
> "the **stale** old ksail module path … not an active submodule." **That was wrong and dangerous.** It
> is a *second, live* checkout of `devantler-tech/ksail` — separate from the monorepo submodule at
> `applications/ksail` — that the maintainer uses for parallel interactive sessions. The global
> `~/.claude/CLAUDE.md` names `projects/ksail` as an active submodule, and on 2026-06-25 its gitdir held
> **~23 live linked worktrees, 240+ branches, a stash, and unpushed commits**. It is absent from the
> tracked `.gitmodules` (de-registered there) but very much in use locally; deleting its gitdir breaks
> every one of those sessions. See *Orphaned gitdirs* for the verification that prevents this.

### Re-generate the table for any submodule

```sh
cd ~/git-personal/monorepo            # (or the relevant clone)
for cfg in $(find .git/modules -name config -path '*modules*'); do
  d=$(dirname "$cfg"); name=${d#.git/modules/}
  cw=$(git config -f "$cfg" --get core.worktree); [ -z "$cw" ] && cw='(unset)'
  wt=$(git config -f "$cfg" --get extensions.worktreeConfig); [ -z "$wt" ] && wt='(unset)'
  printf '%-55s core.worktree=%-8s worktreeConfig=%s\n' "$name" "$cw" "$wt"
done
```

> RTK note: this CLI proxy mangles `git worktree add`/`remove`/`list` — prefix those with
> `rtk proxy git worktree …`. Plain `git config` reads are unaffected.

## Repeatable fix (per submodule, forward-only)

Apply per submodule, in this **additive-first order** so the main worktree is never momentarily without
a resolvable `core.worktree` (safe even while parallel sessions hold the shared checkout). Let
`M=.git/modules/<name>` and `ABS` = the absolute path to the submodule's **main** checkout
(e.g. `~/git-personal/monorepo/templates/gitops-tenant-template`):

```sh
# 0. (optional) back up, so the change is trivially reversible
cp "$M/config" /tmp/$(basename "$M")-config.bak

# 1. enable per-worktree config if not already
git config -f "$M/config" extensions.worktreeConfig true

# 2. ADDITIVE: pin the MAIN worktree's path in its own per-worktree config first
git config -f "$M/config.worktree" core.worktree "$ABS"

# 3. remove the stray SHARED value (now safe — main resolves via config.worktree)
git config -f "$M/config" --unset core.worktree
```

### Verify (acceptance criterion — do this after each fix)

```sh
P=<submodule-working-path>            # e.g. templates/gitops-tenant-template
rtk proxy git -C "$P" worktree add --detach .probe-iso        # throwaway, no branch to clean up
git -C "$P/.probe-iso" rev-parse --show-toplevel              # MUST print …/$P/.probe-iso, NOT …/.git/modules/…
rtk proxy git -C "$P" worktree remove --force .probe-iso      # clean up
rtk proxy git -C "$P" worktree prune
```

A fixed submodule prints the probe's **own** path; a broken one prints **anything else** — either a
path under `.git/modules/<name>` or the shared main checkout itself (whatever the stray
`core.worktree` points at). Test for exact equality with the worktree's own absolute path; do not
match on a symptom string.

**Verified 2026-06-17 on `templates/gitops-tenant-template`:** before the fix a probe worktree's
`show-toplevel` resolved to `…/.git/modules/templates/gitops-tenant-template`; after the fix it resolves
to `…/templates/gitops-tenant-template/.probe-iso` (its own tree), and the main checkout still resolves
correctly. This submodule is left fixed.

## Regression watch — the fix is NOT permanent (PROBE EVERY TIME)

**The 2026-06-25 sweep does not stay fixed.** On **2026-07-14** `applications/ksail` was found **broken
again**: the stray `core.worktree = ../../../../applications/ksail` was back in the shared
`.git/modules/applications/ksail/config` (with `extensions.worktreeConfig` still `true` — so the flag
survived, but the stray value returned and was being inherited again). `templates/gitops-tenant-template`
was found broken again the **same day**. A green row in the table above is therefore a record of *a* fix,
**not** a guarantee of current state.

### The culprit: `git submodule update --init` (reproduced 2026-07-14)

The "routine submodule operation" that rewrites the key is **`git submodule update --init <path>`** —
the very command the contract tells agents to use to populate a submodule. Reproduced on a submodule
that had just been verified fixed:

```
$ git config -f .git/modules/templates/dotnet-template/config --get core.worktree
(unset)
$ git submodule update --init templates/dotnet-template
$ git config -f .git/modules/templates/dotnet-template/config --get core.worktree
../../../../templates/dotnet-template          # ← back, and inherited by every future worktree
```

So the loop is: agent initialises a submodule → isolation silently breaks → the next `git worktree add`
in that submodule resolves into the shared main checkout → parallel sessions collide. **Initialising and
repairing must therefore be one operation**, which is what
[`.claude/scripts/submodule-init.sh`](scripts/submodule-init.sh) does (init → repair → fail-closed
probe). `submodule-init.sh --check` probes every initialised submodule and exits non-zero if any is
not isolated. The probe is non-destructive — it never modifies submodule content, tracked files, or
other sessions' worktrees — but not strictly read-only: it adds and removes a throwaway probe
worktree to catch a dangling `core.worktree` a config read alone would miss.

What made it dangerous is that it fails **silently**: a `git worktree add` still succeeds, and the
worktree looks real. Three live linked worktrees — including **two belonging to the parallel sibling
agent** — were all resolving into the *shared main checkout*, i.e. actively colliding, with nothing
surfacing it. That is precisely the condition that makes one session's commit land on another's branch.

**So: never trust the table — probe.** Before you edit anything in a freshly-added submodule worktree,
assert it resolves to its own path:

```sh
# Canonicalise first: `rev-parse --show-toplevel` prints an ABSOLUTE path, so comparing it against a
# relative $WT (the form you normally pass to `git worktree add`) would flag a healthy worktree broken.
WT=$(cd "<path to the worktree you just added>" && pwd -P)
TOP=$(git -C "$WT" rev-parse --show-toplevel)
if [ "$TOP" != "$WT" ]; then
  echo "NOT ISOLATED: resolves to $TOP, not $WT — do not edit; repair first" >&2
  exit 1   # fail CLOSED: never fall through into a colliding worktree
fi
```

**Any** resolved path other than `$WT` is broken — the exact-equality test is the criterion, not a
particular symptom string. Two shapes both occur: it may print a path under `.git/modules/<name>`, **or
it may print the shared main checkout itself** (e.g. `…/applications/ksail`) — that is what the stray
`core.worktree` actually pointed at in the 2026-07-14 regression, so matching only on `.git/modules`
would have *missed* the live collision. If it is broken, apply the *Live linked worktrees* procedure
below (it repairs the existing worktrees in place, including any the sibling agent is holding),
re-probe, and only then start work. Record the regression in the table.

### Live linked worktrees — repair in place (don't skip)

A submodule that is broken **and** in active use (random-slug `.claude/worktrees/<adj>-<name>-<hex>`
entries in `git worktree list`) can be repaired **without** waiting for the sessions to go quiet — the
earlier "skip live ones until quiet" guidance is **superseded**. Such live worktrees have **no own
`core.worktree`**, so they inherit the stray shared value and resolve to whatever it points at — the
shared **main checkout** or a `.git/modules/<name>` path (either way, an active collision). Pin each
one's own path **before** removing the shared value, so no worktree is ever left without a resolvable
`core.worktree`:

```sh
M=<abs path to .git/modules/<name>>; ABS=<abs path to submodule main checkout>
git config -f "$M/config" extensions.worktreeConfig true
git config -f "$M/config.worktree" core.worktree "$ABS"               # pin the MAIN worktree
# Pin EACH live linked worktree. Enumerate them from the gitdir — NOT by globbing
# $ABS/.claude/worktrees/*, which misses worktrees living anywhere else (the 2026-07-14 sweep found a
# sibling-agent worktree under /private/tmp that such a glob would have skipped, leaving it broken).
for wtdir in "$M"/worktrees/*/; do
  wtpath=$(dirname "$(cat "$wtdir/gitdir")")                          # .../<worktree>/.git -> <worktree>
  [ -d "$wtpath" ] || continue
  git config -f "$wtdir/config.worktree" core.worktree "$wtpath"
done
git config -f "$M/config" --unset core.worktree                       # now safe to drop the shared value
```

Once every worktree resolves via its **own** per-worktree config, dropping the shared value changes
nothing for any of them — it only stops *new* worktrees inheriting the bad value. This is strictly an
improvement even mid-session: an actively-colliding worktree starts resolving to its own tree on its
next git command. **Verified 2026-06-25** on `platform` (6 live worktrees) and `templates/go-template`
(1) — all resolved to their own trees afterwards, with no session disruption.

### Orphaned gitdirs — verify before deleting

A `.git/modules/<name>` that is absent from the tracked `.gitmodules` is **not automatically safe to
delete**. "Not in `.gitmodules`" only means *de-registered there* — the gitdir can still be a live local
workspace. **Before removing any gitdir, confirm all of:**

1. **No live worktrees** — `rtk proxy git --git-dir=<M> worktree list` shows only the main entry (no
   `.claude/worktrees/*`).
2. **No unpushed commits** — `git --git-dir=<M> log --branches --tags --not --remotes --oneline` is empty.
3. **No stash** — `git --git-dir=<M> stash list` is empty.
4. **Not named active anywhere** — cross-check the global `~/.claude/CLAUDE.md` (it names `projects/ksail`
   as an active second checkout) and any **working tree** still on disk at the old path.

Always **back up the gitdir** first (`tar -czf <bak> -C .git/modules <name>`) before `rm -rf`, and if a
stale working tree exists at the old path, back up and remove it (and its `.git/config` `[submodule …]`
section) too. **Cautionary tale (2026-06-25):** `projects/ksail` was wrongly annotated "stale/orphaned"
in this doc and removed — it actually had ~23 live sessions, and was only recoverable because of the
pre-removal backup. The genuinely-orphaned gitdirs cleanly removed that day (de-registered renames /
leftovers with **zero** live worktrees) were: `dotfiles`, `github/devantler-tech/.github-private`,
`homebrew-formulas` (→ `homebrew-tap`), `libraries/plugins` (→ `agent-plugins`), and `libraries/skills`
(→ `agent-skills`).

## Rollout status

- ✅ **All active submodules fixed & probe-verified (2026-06-25)** — every initialized submodule on
  `~/git-personal/monorepo` now has `extensions.worktreeConfig=true` and **no** shared `core.worktree`,
  so `git worktree add` resolves to an isolated tree. `templates/gitops-tenant-template` was done first
  (2026-06-17); the rest, including `platform` (6 live worktrees) and `templates/go-template` (1),
  followed on 2026-06-25 via the live-worktree repair above.
- ⚠️ **The fix DOES NOT survive a submodule re-init — regresses silently (found 2026-07-09, run 656th).**
  A stray `core.worktree` had reappeared in the shared config on **9** submodules: `github/devantler-tech/
  github-actions/actions`, `platform` (15 live worktrees this time — repaired in place, zero disruption),
  `templates/gitops-tenant-template`, `templates/go-template` (1 live worktree), `libraries/agent-skills`,
  `libraries/provider-upjet-unifi` (1 live worktree), `applications/fleet-gitops`,
  `applications/wedding-app`, `github/devantler-tech/maintenance`. Root cause: `git submodule update
  --init` (or a deinit/reinit cycle) recreates the gitdir's `config` from git's default template, which
  always writes `core.worktree` into the shared file — the per-machine fix from 2026-06-25 doesn't persist
  through that. All 9 re-fixed + probe-verified 2026-07-09 via the same additive-first / live-worktree
  procedure above (`homebrew-tap` was checked and found genuinely clean — never had the stray value).
  **Actionable takeaway: don't trust this table as current — re-run the diagnostic snippet above before
  relying on any submodule's isolation, especially right after a fresh `git submodule update --init`.**
- ✅ **Orphaned gitdirs pruned (2026-06-25)** — de-registered leftovers removed per *Orphaned gitdirs*
  (with backups): `dotfiles`, `github/devantler-tech/.github-private`, `homebrew-formulas`,
  `libraries/plugins`, `libraries/skills` (plus their stale working trees and `.git/config` sections).
  `projects/ksail` was **kept** — it is an active second checkout, not an orphan.
- This is **per-machine** state: a fresh clone reproduces the stray `core.worktree`, so the procedure
  above still applies there. New submodules should be initialized with `extensions.worktreeConfig=true`
  and **no** shared `core.worktree` from the start.
