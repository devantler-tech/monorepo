#!/usr/bin/env bash
# Initialise submodules at their pinned commit AND keep per-session worktree isolation intact.
#
# Why this exists: `git submodule update --init <path>` writes a `core.worktree` key into the
# submodule's SHARED config. `core.worktree` is a per-worktree setting, so every worktree later
# created with `git worktree add` inherits it and resolves back into the main checkout — silently
# collapsing all parallel agent sessions into one physical tree. That is why the isolation fix never
# stays fixed: the init command re-breaks it.
#
# This script makes init + repair a single operation, then PROBES that isolation actually holds and
# fails closed if it does not.
#
# Usage:
#   .claude/scripts/submodule-init.sh <submodule-path> [<submodule-path>...]
#   .claude/scripts/submodule-init.sh --all           # init + repair + probe every submodule (first clone)
#   .claude/scripts/submodule-init.sh --check         # non-destructive probe of every initialised submodule
#   .claude/scripts/submodule-init.sh --advance <path>  # move a populated checkout to HEAD's recorded pin
#
# `--check` never modifies submodule content, tracked files, or other sessions' worktrees, but it is
# NOT strictly read-only: to prove isolation empirically it adds and then removes a throwaway,
# uniquely-named probe worktree (and removes ONLY its own admin entry — never a repository-wide
# `git worktree prune`, which would delete a sibling session's entry whenever that session's tree is
# momentarily unreadable). That empirical add/remove is the whole point — it catches a dangling
# `core.worktree` a config read alone would miss.
#
# `--advance` is the isolation-safe way to follow a pin bump after `git pull` on the superproject.
# Plain `git submodule update` (with or without `--init`) rewrites shared `core.worktree`; this mode
# checks out the recorded gitlink directly, then repair + probe. It refuses a dirty tree or a
# checkout that is ahead of the pin, so it cannot discard uncommitted or unpushed work. It does not
# move nested submodules; it validates every initialized nested checkout's pin, dirt, and isolation.
set -euo pipefail

die() {
  printf 'submodule-init: %s\n' "$1" >&2
  exit 1
}

warn() { printf 'submodule-init: %s\n' "$1" >&2; }

# The gitdir git is ACTUALLY using for this submodule.
module_dir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }

# The tree this submodule is checked out in is simply its own absolute path. Do NOT derive it from
# `rev-parse --show-toplevel`: that is computed FROM `core.worktree`, so in the broken case it returns
# the checkout the stray value points at — and repair would then pin the collision back in.
module_tree() { (cd "$1" 2>/dev/null && pwd -P); }

# Do two paths name the SAME directory? Compare filesystem IDENTITY (device+inode, via `-ef`), never
# the spelling.
#
# Two independent reasons the spellings legitimately differ, and BOTH are load-bearing:
#
# 1. CASE, and this is shell-specific — measured, because the wrong shell hides it. Under **bash**
#    (this script's shebang, 3.2.57 on the host) `pwd -P` resolves symlinks but does NOT fold case:
#    `cd alpha/beta && pwd -P` prints the typed `alpha/beta`. Under **zsh** the same command prints
#    the on-disk `Alpha/Beta`. So on a case-insensitive volume (APFS, the host default) a worktree
#    recorded as `.Codex/…` stays `.Codex/…` here while git reports `.codex/…` — one inode, two
#    strings, and the old `[ "$got" != "$want" ]` fired. Traced live on `libraries/agent-plugins`:
#      got  = …/.codex/worktrees/agent-plugins-claude-desktop-83   (git, lowercase)
#      want = …/.Codex/worktrees/agent-plugins-claude-desktop-83   (bash pwd -P, case preserved)
#    Reproducing this in zsh shows both sides folded and NO mismatch — verify in bash, not the
#    interactive shell.
# 2. An unreadable worktree makes BOTH sides empty (`-d` passes, `cd` and `git -C` both fail), and
#    `[ "" = "" ]` is TRUE — so without the emptiness guard below this returns "same directory" and
#    `--check` reports an unverifiable worktree as isolated. That fail-open predates this helper.
#
# A false positive here is a safety regression, not just noise: it blocks edits to a safe tree AND
# trains the reader to discount the warning that flags a real collision. So fail CLOSED — an empty or
# non-existent path is never "the same directory".
same_dir() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  [ "$1" = "$2" ] && return 0
  [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ]
}

# An UNINITIALISED submodule is an empty directory. Distinguish that (legitimately skip) from a
# populated one (must be checked) — see `probe`, where conflating the two was a fail-open.
is_populated() {
  local path=$1
  [ -d "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]
}

# Does git, run inside the submodule, agree that the submodule IS this directory? If a stray
# `core.worktree` points at another valid checkout — the exact collision this script exists to catch —
# git reports THAT checkout instead. Returning "not a submodule" there would silently drop it from
# `--check`; it must be reported as BROKEN.
resolves_to_itself() {
  local path=$1 abs top
  abs=$(module_tree "$path") || return 1
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  same_dir "$top" "$abs"
}

# Verify every EXISTING linked worktree of this submodule resolves to its OWN physical path. The main
# checkout and a freshly-created probe worktree passing does NOT prove a live session's worktree isn't
# colliding: an interrupted repair or a worktree created against a stray shared `core.worktree` can
# leave one `$gitdir/worktrees/*` entry pinned at the shared checkout, and that session keeps colliding
# while a fresh probe stays clean. `--check` is the trust gate for exactly this parallel-session case,
# so it must enumerate the live worktrees too. Read-only: it only rev-parses other sessions' trees.
# $2 (optional) is THIS probe's own admin dir, excluded by filesystem IDENTITY. It must be an exact
# identity match, never a name pattern: an earlier version skipped any worktree whose PATH contained
# the substring `/probe-iso-`, so a genuinely unverifiable sibling living under a directory merely
# NAMED that way was silently skipped and the submodule reported isolated ✓ — the same fail-open class
# as #2460, one level down. A sibling's admin entry is never excluded.
check_existing_worktrees() {
  local path=$1 skip_admin=${2:-} rc=0 mdir wtadmin wt got want
  # Iterate the LINKED-worktree admin dirs under the submodule gitdir directly, rather than
  # `git worktree list`: the submodule's MAIN checkout legitimately resolves to itself, and so does a
  # colliding linked worktree whose stray `core.worktree` points at the shared checkout — so
  # show-toplevel alone cannot tell them apart. Only linked worktrees live under `$mdir/worktrees/*`;
  # the main checkout is never listed there, so it is excluded without a fragile self-comparison.
  mdir=$(module_dir "$path") || return 0
  [ -d "$mdir/worktrees" ] || return 0
  for wtadmin in "$mdir"/worktrees/*/; do
    [ -f "$wtadmin/gitdir" ] || continue
    # Skip ONLY this probe's own admin dir, by identity — see the header note above.
    if [ -n "$skip_admin" ] && [ -d "$skip_admin" ] && [ "${wtadmin%/}" -ef "$skip_admin" ]; then
      continue
    fi
    # The `gitdir` admin file points at the worktree's own `.git` file; its parent is the worktree.
    wt=$(dirname "$(cat "$wtadmin/gitdir" 2>/dev/null)")
    # A pruned/missing worktree dir cannot host a live colliding session — skip it.
    [ -d "$wt" ] || continue
    got=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || got=''
    [ -n "$got" ] && got=$(cd "$got" 2>/dev/null && pwd -P)
    # An UNSEARCHABLE worktree dir passes `-d` but cannot be entered, so this must not abort or leak
    # to stderr: resolve it to empty and let `same_dir` fail closed below. (It survives `set -e` only
    # because callers invoke this function under `||`, which suspends it — do not rely on that.)
    want=$(cd "$wt" 2>/dev/null && pwd -P) || want=''
    if ! same_dir "$got" "$want"; then
      warn "$path — ISOLATION BROKEN: existing linked worktree '$wt' resolves to '${got:-<unresolvable>}', not its own path. A parallel session there is colliding — do not edit it."
      rc=1
    fi
  done
  return "$rc"
}

# Move the stray shared core.worktree into each worktree's own per-worktree config. Idempotent.
repair() {
  local path=$1
  local mdir tree super_mdir

  mdir=$(module_dir "$path")
  tree=$(module_tree "$path")
  { [ -n "$mdir" ] && [ -d "$mdir" ] && [ -n "$tree" ]; } ||
    die "git does not report a gitdir for '$path' (not an initialised submodule?)"

  # `git -C <dir>` walks UP when <dir> is not itself a repository, so a REGISTERED submodule path that
  # is non-empty but NOT initialised resolves to the SUPERPROJECT's gitdir — and repair would then pin
  # `core.worktree` in the PARENT repository's per-worktree config, redirecting the parent's own main
  # checkout at this directory. `is_populated` cannot catch it: it only asks whether the directory has
  # entries, and one leftover file is enough. A `.git` that exists but points outward reaches the same
  # place by a different route, so test the RESOLVED gitdir rather than the presence of a `.git` entry
  # (an existence check is subsumed by this one and provably never fires on its own). Fail closed: the
  # blast radius is the parent repo and every session sharing it (monorepo#2694).
  # No `|| true` and no silent fallback: `same_dir` fails closed on an empty path, which here would
  # SKIP the guard rather than trip it, so a failed probe must stop the run instead of quietly
  # disabling the check. `errexit` covers a non-zero rev-parse; the emptiness test covers a
  # zero-exit-no-output result.
  super_mdir=$(git rev-parse --path-format=absolute --git-common-dir)
  [ -n "$super_mdir" ] ||
    die "cannot resolve the superproject's gitdir — refusing to repair '$path' rather than skip the parent-escape check"
  if same_dir "$mdir" "$super_mdir"; then
    die "'$path' resolves to the SUPERPROJECT's gitdir ('$mdir'), not its own — refusing to repair, because that would redirect the parent repository's checkout at '$path'. The directory has content but no usable '.git', so nothing here is a real submodule checkout: remove its stray contents, then re-run 'submodule-init.sh $path' to populate it at the pinned commit"
  fi

  git config -f "$mdir/config" extensions.worktreeConfig true
  # Pin the tree this gitdir is actually checked out in — not a path we guessed.
  git config -f "$mdir/config.worktree" core.worktree "$tree"
  git config -f "$mdir/config" --unset-all core.worktree 2>/dev/null || true

  # Existing linked worktrees inherited the stray value — pin each to the path it actually lives at.
  local wt gitdir tree
  for wt in "$mdir"/worktrees/*/; do
    [ -d "$wt" ] || continue
    [ -f "$wt/gitdir" ] || continue
    gitdir=$(cat "$wt/gitdir")
    tree=$(dirname "$gitdir")
    git config -f "$wt/config.worktree" core.worktree "$tree"
  done
}

# Fail closed: a submodule is isolated only if a throwaway worktree reports its OWN path as the
# toplevel. Returns non-zero (never exits) so callers can probe everything before deciding.
probe() {
  local path=$1

  if ! is_populated "$path"; then
    warn "$path — not checked out here; nothing to probe"
    return 1
  fi

  # THE collision, detected directly: the submodule is populated, but git resolves it to a DIFFERENT
  # checkout because a stray `core.worktree` points there. Report it — treating this as "not a
  # submodule" and skipping it (as an earlier version did) silently dropped the one case this whole
  # script exists to catch, and `--check` then exited 0 on a colliding tree.
  if ! resolves_to_itself "$path"; then
    warn "$path — ISOLATION BROKEN: git resolves it to '$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)', not '$(module_tree "$path")'. Another checkout is sharing this working tree — do not edit it."
    return 1
  fi

  # A unique probe dir per invocation: a fixed `.probe-iso` could collide with — and `rm -rf` — a
  # concurrent session's probe or a user's scratch dir. This script exists FOR overlapping sessions.
  local name="probe-iso-$$-${RANDOM}"
  local probe_dir="$path/$name"

  if ! git -C "$path" worktree add --detach "$name" >/dev/null 2>&1; then
    warn "$path — could not create probe worktree"
    return 1
  fi

  # Capture the probe's REAL admin dir up front. `git worktree add` does NOT guarantee the admin dir
  # is named after the worktree: when `worktrees/<name>` already exists it counter-appends (adding
  # `probe-iso-1-2` against an existing entry yields `probe-iso-1-21`, measured on git 2.55.0). Then
  # `worktree remove` matches by PATH and drops the counter-appended one, so removing "$name" by name
  # afterwards would delete a DIFFERENT — possibly live — worktree's entry, destroying exactly the
  # sibling this scoping exists to protect. Resolve it, and remove that.
  local probe_admin=''
  probe_admin=$(git -C "$probe_dir" rev-parse --absolute-git-dir 2>/dev/null) || probe_admin=''

  # Resolve both sides to physical paths (/tmp vs /private/tmp, symlinked checkouts) before comparing.
  local got want rc=0
  got=$(git -C "$probe_dir" rev-parse --show-toplevel 2>/dev/null) || got=''
  [ -n "$got" ] && got=$(cd "$got" 2>/dev/null && pwd -P)
  want=$(cd "$probe_dir" && pwd -P)

  if [ -z "$got" ]; then
    warn "$path — ISOLATION BROKEN: git cannot resolve a worktree created there (dangling core.worktree). Do not edit it."
    rc=1
  elif ! same_dir "$got" "$want"; then
    warn "$path — ISOLATION BROKEN: a worktree there resolves to '$got', not its own path ('$want'). Do not edit it — parallel sessions would collide."
    rc=1
  fi

  # A fresh probe passing does not clear existing live worktrees — enumerate and verify those too.
  # This MUST run BEFORE any cleanup below. `git worktree prune` deletes the admin entry of any
  # worktree whose tree is missing OR merely unverifiable, so pruning first destroyed the very
  # evidence this sweep reads: "no linked worktrees to verify" and "a linked worktree that cannot be
  # verified" became indistinguishable, and the second was reported as isolated ✓ (#2460). The sweep
  # skips this probe's own `probe-iso-*` entry, so running it first is safe.
  check_existing_worktrees "$path" "$probe_admin" || rc=1

  # Clean up ONLY this probe's own entry. A repository-wide `git worktree prune` also deletes a
  # SIBLING session's admin entry whenever that session's tree is momentarily unreadable (restrictive
  # permissions, an unmounted volume, an in-flight chmod) — permanently breaking the parallel session
  # this script exists to protect. `worktree remove` already drops the admin entry on success; the
  # scoped rm is the fallback for when it does not, and it targets the RESOLVED admin dir rather than
  # a name that git may have counter-appended.
  git -C "$path" worktree remove --force "$name" >/dev/null 2>&1 || true
  rm -rf "$probe_dir"
  if [ -n "$probe_admin" ]; then
    case "$probe_admin" in
      */worktrees/*) rm -rf "${probe_admin:?}" ;;
    esac
  fi

  [ "$rc" -eq 0 ] && printf 'submodule-init: %s — isolated ✓\n' "$path"
  return "$rc"
}

# Probe every initialized nested checkout beneath $1. Pin markers alone are insufficient: a nested
# repository can retain the expected HEAD while a stale shared core.worktree redirects commands into
# another session. `submodule foreach` visits initialized checkouts only; uninitialized/mismatched
# entries are rejected separately by the recursive status gate in `advance`.
probe_nested_checkouts() {
  local path=$1 nested_paths nested idx_flags rc=0
  nested_paths=$(git --no-replace-objects -C "$path" submodule foreach --quiet --recursive 'pwd -P') || {
    warn "$path — could not enumerate initialized nested submodules"
    return 1
  }
  while IFS= read -r nested; do
    [ -n "$nested" ] || continue
    idx_flags=$(git --no-replace-objects -C "$nested" ls-files -v 2>/dev/null) || {
      warn "$nested — could not read nested submodule index flags"
      rc=1
      continue
    }
    if grep -q '^[a-zS]' <<< "$idx_flags"; then
      warn "$nested — nested submodule has assume-unchanged/skip-worktree files"
      rc=1
      continue
    fi
    probe "$nested" || rc=1
  done <<< "$nested_paths"
  return "$rc"
}

all_paths() { git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}'; }
# "Initialised" means git actually treats it as its own repository here — again, asked, not assumed.
# Select every submodule that is CHECKED OUT here. Deliberately NOT "every submodule git resolves
# correctly": a colliding submodule resolves elsewhere, and filtering on that would drop it from the
# sweep — the fail-open this script must never have.
initialised_paths() {
  local p
  while read -r p; do is_populated "$p" && printf '%s\n' "$p"; done < <(all_paths)
}

# Is $1 one of the paths declared in .gitmodules? Only these may have their config rewritten.
is_registered_submodule() {
  local p=$1 x
  while read -r x; do [ "$x" = "$p" ] && return 0; done < <(all_paths)
  return 1
}

init_repair_probe() {
  local path=${1%/}
  # Only ever mutate config for a path git actually registers as a submodule. Handed a linked
  # worktree path (or any other populated directory) by mistake, `repair` would rewrite the shared
  # submodule gitdir's `core.worktree` to point THERE — recreating the exact cross-session collision
  # this script exists to prevent. Validate against .gitmodules first and fail closed.
  is_registered_submodule "$path" ||
    die "'$path' is not a registered submodule (see .gitmodules) — refusing to repair"

  if is_populated "$path"; then
    # Already checked out here: only its isolation can be stale, so repair the stray `core.worktree`
    # IN PLACE and stop. Do NOT run `git submodule update` — its checkout update strategy would
    # detach/move this tree back to the pinned gitlink commit, silently discarding a local branch or
    # ahead-of-pin work. Populating is the only thing update is for, and this tree is already
    # populated.
    repair "$path"
  else
    # Fresh (empty) submodule: populate it at its pinned commit, then relocate the `core.worktree`
    # that `git submodule update` writes into the shared config.
    git submodule update --init "$path"
    # It can exit 0 having populated NOTHING — observed 2026-07-26 running from a linked superproject
    # worktree while a sibling worktree already held that submodule: git printed `checked out '<sha>'`,
    # exited 0, and left the directory empty. `probe` below verifies ISOLATION, not content, so it
    # passes vacuously on an empty directory and the script reports `isolated ✓` for a submodule that
    # was never checked out. That is fail-open on this script's PRIMARY job, and it is worse than a
    # loud failure: globs into an empty submodule match nothing, so content checks — including the
    # bundled-skill ownership audit AGENTS.md mandates before editing a synced file — pass vacuously
    # instead of erroring. Assert the post-condition: init mode was ASKED to populate, so an empty
    # tree is a FAILURE here, never the legitimate skip `--check` makes of an uninitialised submodule.
    is_populated "$path" ||
      die "'$path' is STILL EMPTY after 'git submodule update --init' (which exited 0) — do not read or edit it"
    repair "$path"
  fi
  probe "$path" || die "repair did not restore isolation for '$path' — do not edit it"
}

# Move an already-populated submodule checkout to the gitlink recorded at the superproject's HEAD.
# Never uses `git submodule update` — that command writes shared `core.worktree` (see header).
advance() {
  local path=${1%/}
  is_registered_submodule "$path" ||
    die "'$path' is not a registered submodule (see .gitmodules) — refusing to advance"

  is_populated "$path" ||
    die "'$path' is not checked out here — run submodule-init.sh $path to populate it first"

  # Repair and prove isolation BEFORE any other `git -C "$path"` command touches this checkout.
  # A stale shared `core.worktree` redirects that path at another session's worktree, so running
  # `status`/`rev-parse`/`fetch`/`checkout --detach` first would read — and in the checkout's case
  # WRITE — into that other tree before this function ever repaired the configuration.
  repair "$path"
  probe "$path" || die "repair did not restore isolation for '$path' — do not edit it"

  local status
  status=$(git --no-replace-objects -C "$path" status --porcelain --untracked-files=all 2>/dev/null) ||
    die "could not read status for '$path' — refusing to advance"
  if [ -n "$status" ]; then
    die "'$path' has a dirty working tree — commit, stash, or discard local changes before advancing"
  fi

  # `status` cannot see tracked edits hidden by assume-unchanged or skip-worktree. Their presence
  # alone makes detaching unsafe: checkout can carry the invisible bytes onto the target pin.
  local idx_flags
  idx_flags=$(git --no-replace-objects -C "$path" ls-files -v 2>/dev/null) ||
    die "could not read index flags for '$path' — refusing to advance"
  if grep -q '^[a-zS]' <<< "$idx_flags"; then
    die "'$path' has assume-unchanged/skip-worktree files — clear those index flags before advancing"
  fi

  local target head ahead nested_status post_status residue ordinary_residue
  # Superproject HEAD's gitlink for this path — the pin a pin-bump PR just moved.
  target=$(git --no-replace-objects rev-parse "HEAD:$path" 2>/dev/null) ||
    die "no gitlink recorded for '$path' at HEAD"
  head=$(git --no-replace-objects -C "$path" rev-parse HEAD) ||
    die "could not read HEAD of '$path'"

  if [ "$head" = "$target" ]; then
    warn "$path — already at recorded pin $target; validating checkout state"
  else
    # Ensure the pin object exists locally (a fresh pin bump may not have been fetched into the
    # submodule yet). Prefer fetching the exact SHA; fall back to a plain fetch.
    if ! git --no-replace-objects -C "$path" cat-file -e "${target}^{commit}" 2>/dev/null; then
      git --no-replace-objects -C "$path" fetch --quiet origin "$target" 2>/dev/null ||
        git --no-replace-objects -C "$path" fetch --quiet origin 2>/dev/null ||
        true
      git --no-replace-objects -C "$path" cat-file -e "${target}^{commit}" 2>/dev/null ||
        die "recorded pin $target for '$path' is not available locally — fetch the submodule remote first"
    fi

    # Refuse when the checkout has commits that are not reachable from the new pin: advancing would
    # detach past them and look like a silent discard. Dirty trees are already refused above.
    ahead=$(git --no-replace-objects -C "$path" rev-list --count "${target}..HEAD" 2>/dev/null) ||
      die "could not compare '$path' HEAD to recorded pin $target"
    if [ "$ahead" -gt 0 ]; then
      die "'$path' is $ahead commit(s) ahead of the recorded pin — push or otherwise preserve that work before advancing"
    fi

    # Detach onto the recorded pin without `git submodule update` (which rewrites shared core.worktree).
    git --no-replace-objects -C "$path" checkout --quiet --no-overwrite-ignore \
      --no-recurse-submodules --detach "$target" ||
      die "failed to check out recorded pin $target in '$path'"
    repair "$path"
    probe "$path" || die "advance left '$path' unisolated — do not edit it"
  fi
  nested_status=$(git --no-replace-objects -C "$path" submodule status --recursive 2>/dev/null) ||
    die "could not verify nested submodules in '$path' — refusing to report a successful advance"
  if grep -q '^[^ ]' <<< "$nested_status"; then
    die "nested submodule checkout does not match '$path' at $target — advance it separately before use"
  fi
  probe_nested_checkouts "$path" ||
    die "nested submodule isolation is broken for '$path' — repair it from its parent before use"
  post_status=$(git --no-replace-objects -C "$path" status --porcelain \
    --untracked-files=all --ignore-submodules=none 2>/dev/null) ||
    die "could not verify post-advance status for '$path' — refusing to report success"
  if [ -n "$post_status" ]; then
    die "residual files after advancing '$path' to $target — preserve and handle them before use"
  fi
  # Ordinary ignored artifacts are not residue from the pin transition and `--no-overwrite-ignore`
  # already protects any path the target starts tracking. Still detect an embedded repository that
  # the target no longer declares: one force protects it even during a dry run, while two forces
  # reveal it. Comparing the probes distinguishes that hazardous residue from normal caches without
  # deleting either kind, both after a transition and on an already-at-pin retry.
  ordinary_residue=$(git --no-replace-objects -C "$path" clean -nfdx 2>/dev/null) ||
    die "could not inspect ignored residue in '$path' — refusing to report success"
  residue=$(git --no-replace-objects -C "$path" clean -nffdx 2>/dev/null) ||
    die "could not inspect embedded repository residue in '$path' — refusing to report success"
  if [ "$residue" != "$ordinary_residue" ]; then
    die "embedded repository residue after advancing '$path' to $target — preserve and handle it before use"
  fi
  if [ "$head" = "$target" ]; then
    return 0
  fi
  printf 'submodule-init: %s — advanced to %s\n' "$path" "$target"
}

# Stop here when SOURCED, so the self-test can exercise the path-comparison helpers directly. The
# case-only false positive `same_dir` fixes needs a case-insensitive volume, so an end-to-end
# reproduction cannot run on the filesystem CI uses — unit-testing the comparison itself is what
# gives the fix coverage on every platform.
#
# This sits ABOVE every top-level side effect below deliberately: sourcing must not `cd` the caller,
# turn on `errexit`/`pipefail` in the caller's shell, or — from a non-git directory — `die` and take
# the caller's shell down with it. Definitions above are all this needs to export.
#
# In bash, `(return 0 2>/dev/null)` succeeds only when the file is being sourced (the subshell is what
# makes it work); executed, `return` outside a function fails. This idiom is bash-specific — fine
# here, since the shebang pins bash and CI runs the tests under bash.
(return 0 2>/dev/null) && return 0

# NEVER compute a submodule's gitdir — ask git. Run from a linked superproject worktree (the documented
# execution model for agent runs), git puts each submodule's gitdir under
# `.git/worktrees/<super-wt>/modules/<path>`, NOT under `.git/modules/<path>` — and that is where the
# stray `core.worktree` lands too. Any assumed path is wrong exactly where this script matters most.
super_root=$(git rev-parse --show-toplevel) || die 'not inside a git repository'
cd "$super_root"

[ $# -gt 0 ] || die 'usage: submodule-init.sh <submodule-path>... | --all | --check | --advance <path>'

case "$1" in
  # NON-DESTRUCTIVE probe (see the header note): never touches content or other sessions' trees, but
  # not strictly read-only — `probe` adds/removes its own throwaway worktree. It must NOT repair
  # first: a check that fixes what it is checking can never fail.
  --check)
    broken=0
    while read -r path; do probe "$path" || broken=1; done < <(initialised_paths)
    [ "$broken" -eq 0 ] ||
      die 'one or more submodules are NOT isolated — run submodule-init.sh <path> to repair before editing them'
    ;;
  --all)
    while read -r path; do init_repair_probe "$path"; done < <(all_paths)
    ;;
  --advance)
    [ $# -eq 2 ] || die 'usage: submodule-init.sh --advance <submodule-path>'
    advance "$2"
    ;;
  *)
    for path in "$@"; do init_repair_probe "$path"; done
    ;;
esac
