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
# uniquely-named probe worktree (and removes ONLY its own admin entry — never a repository-wide
# `git worktree prune`, which would delete a sibling session's entry whenever that session's tree is
# momentarily unreadable). That empirical add/remove is the whole point — it catches a dangling
# `core.worktree` a config read alone would miss.
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
