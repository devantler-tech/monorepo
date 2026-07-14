#!/usr/bin/env bash
# Initialise a submodule at its pinned commit AND keep per-session worktree isolation intact.
#
# Why this exists: `git submodule update --init <path>` writes a `core.worktree` key into the
# submodule's SHARED config (.git/modules/<name>/config). `core.worktree` is a per-worktree setting,
# so every worktree later created with `git worktree add` inherits it and resolves back into the main
# checkout — silently collapsing all parallel agent sessions into one physical tree. That is why the
# isolation fix never stays fixed: the init command re-breaks it.
#
# This script makes init + repair a single operation, then PROBES that isolation actually holds and
# fails closed if it does not.
#
# Usage:  .claude/scripts/submodule-init.sh <submodule-path> [<submodule-path>...]
#         .claude/scripts/submodule-init.sh --check              # probe every initialised submodule
set -euo pipefail

die() {
  printf 'submodule-init: %s\n' "$1" >&2
  exit 1
}

repo_root=$(git rev-parse --show-toplevel) || die 'not inside a git repository'
cd "$repo_root"

# Move the stray shared core.worktree into the main worktree's own per-worktree config, and pin each
# existing linked worktree to its real path. Idempotent.
repair() {
  local path=$1
  local module_dir=".git/modules/$path"
  [ -d "$module_dir" ] || die "no gitdir for '$path' (is it a submodule?)"

  git config -f "$module_dir/config" extensions.worktreeConfig true
  git config -f "$module_dir/config.worktree" core.worktree "$repo_root/$path"
  git config -f "$module_dir/config" --unset-all core.worktree 2>/dev/null || true

  # Existing linked worktrees inherited the stray value — pin each to the path it actually lives at.
  local wt gitdir tree
  for wt in "$module_dir"/worktrees/*/; do
    [ -d "$wt" ] || continue
    [ -f "$wt/gitdir" ] || continue
    gitdir=$(cat "$wt/gitdir")
    tree=$(dirname "$gitdir")
    git config -f "$wt/config.worktree" core.worktree "$tree"
  done
}

# Fail closed: a submodule is only isolated if a throwaway worktree reports its OWN path as the
# toplevel. Compare resolved absolute paths — never match on a symptom substring.
# Returns non-zero (rather than exiting) so callers can probe every submodule before deciding.
probe() {
  local path=$1
  local probe_dir="$path/.probe-iso"

  rm -rf "$probe_dir"
  if ! git -C "$path" worktree add --detach "$(basename "$probe_dir")" >/dev/null 2>&1; then
    printf 'submodule-init: %s — could not create probe worktree\n' "$path" >&2
    return 1
  fi

  # Resolve both sides to physical paths (/tmp vs /private/tmp, symlinked checkouts) before comparing.
  local got want
  got=$(git -C "$probe_dir" rev-parse --show-toplevel) || got=''
  [ -n "$got" ] && got=$(cd "$got" && pwd -P)
  want=$(cd "$probe_dir" && pwd -P)

  git -C "$path" worktree remove --force "$(basename "$probe_dir")" >/dev/null 2>&1 || true
  git -C "$path" worktree prune >/dev/null 2>&1 || true

  if [ "$got" != "$want" ]; then
    printf "submodule-init: %s — ISOLATION BROKEN: a worktree there resolves to '%s', not its own path ('%s'). Do not edit it — parallel sessions would collide.\n" \
      "$path" "$got" "$want" >&2
    return 1
  fi

  printf 'submodule-init: %s — isolated ✓\n' "$path"
}

initialised_paths() {
  git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}' | while read -r p; do
    [ -d ".git/modules/$p" ] && printf '%s\n' "$p"
  done
}

[ $# -gt 0 ] || die 'usage: submodule-init.sh <submodule-path>... | --check'

# --check is READ-ONLY: it reports isolation as it stands, so it can actually fail. Repairing first
# would make the check vacuous (it could never detect a broken submodule).
if [ "$1" = '--check' ]; then
  broken=0
  while read -r path; do
    if probe "$path"; then :; else broken=1; fi
  done < <(initialised_paths)
  [ "$broken" -eq 0 ] || die 'one or more submodules are NOT isolated — run submodule-init.sh <path> to repair before editing them'
  exit 0
fi

for path in "$@"; do
  path=${path%/}
  git submodule update --init "$path"
  repair "$path"
  probe "$path" || die "repair did not restore isolation for '$path' — do not edit it"
done
