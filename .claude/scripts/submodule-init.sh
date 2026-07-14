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

# Resolve paths from git rather than assuming `<root>/.git/...`. When this runs from a linked
# superproject worktree — which is the documented execution model for agent runs — `.git` is a gitdir
# FILE and `.git/modules` does not exist relative to the worktree, so a hard-coded path would break
# exactly where it matters most.
super_common=$(git rev-parse --path-format=absolute --git-common-dir) ||
  die 'not inside a git repository'
super_main=$(dirname "$super_common") # the superproject's MAIN checkout, from any worktree

# The shared gitdir of a submodule, valid from any superproject worktree.
module_dir() { printf '%s/modules/%s\n' "$super_common" "$1"; }

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
  local mdir
  mdir=$(module_dir "$path")
  [ -d "$mdir" ] || die "no gitdir for '$path' (is it a submodule?)"

  git config -f "$mdir/config" extensions.worktreeConfig true
  # The submodule's MAIN checkout always lives under the superproject's MAIN checkout.
  git config -f "$mdir/config.worktree" core.worktree "$super_main/$path"
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

  if [ "$got" != "$want" ]; then
    warn "$path — ISOLATION BROKEN: a worktree there resolves to '$got', not its own path ('$want'). Do not edit it — parallel sessions would collide."
    rc=1
  fi

  git -C "$path" worktree remove --force "$name" >/dev/null 2>&1 || true
  git -C "$path" worktree prune >/dev/null 2>&1 || true
  rm -rf "$probe_dir"

  [ "$rc" -eq 0 ] && printf 'submodule-init: %s — isolated ✓\n' "$path"
  return "$rc"
}

all_paths() { git config -f "$super_main/.gitmodules" --get-regexp '^submodule\..*\.path$' | awk '{print $2}'; }
initialised_paths() {
  local p
  while read -r p; do [ -d "$(module_dir "$p")" ] && printf '%s\n' "$p"; done < <(all_paths)
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
