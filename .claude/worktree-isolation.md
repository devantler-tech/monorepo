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
shippable output is this documented, verified procedure plus the diagnosis below, applied per submodule
incrementally as each is verified.

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
  not enough** — if the stray shared `core.worktree` remains, it is still inherited (see `platform`,
  `go-template` below: flag on, still broken).

## Diagnosis (captured 2026-06-17 on the scheduled clone `~/git-personal/monorepo`)

`BROKEN` = stray `core.worktree` present in the shared `.git/modules/<name>/config`.

| Submodule | shared `core.worktree` | `extensions.worktreeConfig` | State |
|---|---|---|---|
| `applications/ksail` | set | unset | ❌ broken |
| `applications/ascoachingogvaner` | set | unset | ❌ broken |
| `github/devantler-tech/github-actions/actions` | set | unset | ❌ broken |
| `github/devantler-tech/github-actions/reusable-workflows` | set | unset | ❌ broken |
| `homebrew-formulas` | set | unset | ❌ broken |
| `libraries/agent-plugins` | set | unset | ❌ broken |
| `libraries/agent-skills` | set | unset | ❌ broken |
| `templates/dotnet-template` | set | unset | ❌ broken |
| `templates/platform-template` | set | unset | ❌ broken |
| `platform` | set | **true** | ❌ broken (flag set, but stray value still inherited) |
| `templates/go-template` | set | **true** | ❌ broken (flag set, but stray value still inherited) |
| `templates/gitops-tenant-template` | ~~set~~ → **unset** | true | ✅ **fixed 2026-06-17** (verified, see below) |
| `projects/ksail` | unset | true | ✅ correct — but this is the **stale** old ksail module path (pre-rename to `applications/ksail`), not an active submodule |

> **Correction to #1838's hypothesis:** the issue assumed `applications/ksail` was the cleanly-isolated
> example. It is not — the *live* `applications/ksail` module carries the stray `core.worktree`. The
> correctly-configured module the maintainer observed is the **orphaned `projects/ksail`** gitdir left
> from the old layout. In practice **every active portfolio submodule was broken** before this fix.

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
rtk proxy git -C "$P" worktree add .probe-iso -b probe/iso   # add a throwaway worktree
rtk proxy git -C "$P/.probe-iso" rev-parse --show-toplevel    # MUST print …/$P/.probe-iso, NOT …/.git/modules/…
rtk proxy git -C "$P" worktree remove --force .probe-iso      # clean up
rtk proxy git -C "$P" branch -D probe/iso
rtk proxy git -C "$P" worktree prune
```

A fixed submodule prints the probe's **own** path; a broken one prints a path under
`.git/modules/<name>`.

**Verified 2026-06-17 on `templates/gitops-tenant-template`:** before the fix a probe worktree's
`show-toplevel` resolved to `…/.git/modules/templates/gitops-tenant-template`; after the fix it resolves
to `…/templates/gitops-tenant-template/.probe-iso` (its own tree), and the main checkout still resolves
correctly. This submodule is left fixed.

## Rollout status

- ✅ `templates/gitops-tenant-template` — fixed & verified (2026-06-17).
- ⏳ All other active portfolio submodules in the table above — **apply the procedure incrementally**,
  one at a time, verifying each. Skip a submodule that currently has a parallel linked worktree (check
  `rtk proxy git -C <path> worktree list` — a random-slug `.claude/worktrees/<adj>-<name>-<hex>` entry
  means a live session) until it is quiet, to avoid disrupting an in-flight session.
- The stray `core.worktree` originates from how these submodules were first initialized; new submodules
  should be configured with `extensions.worktreeConfig=true` and **no** shared `core.worktree` from the
  start.
