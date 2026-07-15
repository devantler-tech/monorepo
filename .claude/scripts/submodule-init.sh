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
#   .claude/scripts/submodule-init.sh --all      # init + repair + probe every submodule (first clone)
#   .claude/scripts/submodule-init.sh --check    # non-destructive probe of every initialised submodule
#
# `--check` never modifies submodule content, tracked files, or other sessions' worktrees, but it is
# NOT strictly read-only: to prove isolation empirically it adds and then removes a throwaway,
# uniquely-named probe worktree (and prunes its own admin entry). That empirical add/remove is the
# whole point — it catches a dangling `core.worktree` a config read alone would miss.
set -euo pipefail

die() {
  printf 'submodule-init: %s\n' "$1" >&2
  exit 1
}

warn() { printf 'submodule-init: %s\n' "$1" >&2; }

# NEVER compute a submodule's gitdir — ask git. Run from a linked superproject worktree (the documented
# execution model for agent runs), git puts each submodule's gitdir under
# `.git/worktrees/<super-wt>/modules/<path>`, NOT under `.git/modules/<path>` — and that is where the
# stray `core.worktree` lands too. Any assumed path is wrong exactly where this script matters most.
super_root=$(git rev-parse --show-toplevel) || die 'not inside a git repository'
cd "$super_root"

# The gitdir git is ACTUALLY using for this submodule.
module_dir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }

# The tree this submodule is checked out in is simply its own absolute path. Do NOT derive it from
# `rev-parse --show-toplevel`: that is computed FROM `core.worktree`, so in the broken case it returns
# the checkout the stray value points at — and repair would then pin the collision back in.
module_tree() { (cd "$1" 2>/dev/null && pwd -P); }

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
  [ "$top" = "$abs" ]
}

# Move the stray shared core.worktree into each worktree's own per-worktree config. Idempotent.
repair() {
  local path=$1
  local mdir tree
  mdir=$(module_dir "$path")
  tree=$(module_tree "$path")
  { [ -n "$mdir" ] && [ -d "$mdir" ] && [ -n "$tree" ]; } ||
    die "git does not report a gitdir for '$path' (not an initialised submodule?)"

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

  # Resolve both sides to physical paths (/tmp vs /private/tmp, symlinked checkouts) before comparing.
  local got want rc=0
  got=$(git -C "$probe_dir" rev-parse --show-toplevel 2>/dev/null) || got=''
  [ -n "$got" ] && got=$(cd "$got" 2>/dev/null && pwd -P)
  want=$(cd "$probe_dir" && pwd -P)

  if [ -z "$got" ]; then
    warn "$path — ISOLATION BROKEN: git cannot resolve a worktree created there (dangling core.worktree). Do not edit it."
    rc=1
  elif [ "$got" != "$want" ]; then
    warn "$path — ISOLATION BROKEN: a worktree there resolves to '$got', not its own path ('$want'). Do not edit it — parallel sessions would collide."
    rc=1
  fi

  git -C "$path" worktree remove --force "$name" >/dev/null 2>&1 || true
  git -C "$path" worktree prune >/dev/null 2>&1 || true
  rm -rf "$probe_dir"

  [ "$rc" -eq 0 ] && printf 'submodule-init: %s — isolated ✓\n' "$path"
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
    repair "$path"
  fi
  probe "$path" || die "repair did not restore isolation for '$path' — do not edit it"
}

[ $# -gt 0 ] || die 'usage: submodule-init.sh <submodule-path>... | --all | --check'

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
  *)
    for path in "$@"; do init_repair_probe "$path"; done
    ;;
esac
