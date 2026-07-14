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
#   .claude/scripts/submodule-init.sh --check    # read-only: probe every initialised submodule
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

# The gitdir git is ACTUALLY using for this submodule, and the tree it is checked out in.
module_dir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }
module_tree() { git -C "$1" rev-parse --show-toplevel 2>/dev/null; }

# A submodule is only its own repository if git, run inside it, reports IT as the toplevel. If the
# submodule is deinitialised (empty dir) git walks UP to the superproject and every check below would
# silently pass against the wrong repo — a fail-open. Refuse instead.
assert_is_submodule_root() {
  local path=$1 abs top
  [ -d "$path" ] || return 1
  abs=$(cd "$path" && pwd -P)
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

  if ! assert_is_submodule_root "$path"; then
    warn "$path — NOT a populated submodule root (deinitialised, or git resolves it to the parent repo); refusing to probe"
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
initialised_paths() {
  local p
  while read -r p; do assert_is_submodule_root "$p" && printf '%s\n' "$p"; done < <(all_paths)
}

init_repair_probe() {
  local path=${1%/}
  git submodule update --init "$path"
  repair "$path"
  probe "$path" || die "repair did not restore isolation for '$path' — do not edit it"
}

[ $# -gt 0 ] || die 'usage: submodule-init.sh <submodule-path>... | --all | --check'

case "$1" in
  # READ-ONLY. It must NOT repair first: a check that fixes what it is checking can never fail.
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
