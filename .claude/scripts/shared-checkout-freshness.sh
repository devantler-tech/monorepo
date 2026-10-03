#!/usr/bin/env bash
# Report whether the shared checkout is on the current reviewed revision, and say so when it
# is frozen behind it.
#
# Why this exists (#3331): a dispatch worktree is created from the shared checkout's local
# HEAD, not from the remote. On 2026-09-12 the shared checkout stopped advancing because it
# held a local edit to a file that incoming commits also changed, so the fast-forward was
# refused. Nothing reported that. For a week, 41 of 182 Codex dispatches booted from a base
# up to 7 commits old, and every missing commit changed the agent definition. The pre-flight
# sync only says when to fast-forward; a checkout that cannot be fast-forwarded was skipped
# silently. This check turns that state into a finding with the paths that cause it.
#
# It reads only. It never merges, resets, stashes or discards anything: the blocking edit
# belongs to whoever made it (git safety).
#
# Usage: shared-checkout-freshness.sh [--repo-dir <dir>] [--branch <name>] [--remote <name>]
#                                     [--no-fetch]
#   --repo-dir  any directory inside the repository; default the checkout holding this script.
#               The check always judges the repository's MAIN worktree, whichever linked
#               worktree it is called from.
#   --branch    the default branch; default main
#   --remote    the remote that holds it; default origin
#   --no-fetch  judge against the remote-tracking ref as it stands, without fetching first
#
# Output: one line on stdout, starting with the verdict.
#   CURRENT     the shared checkout's HEAD is the remote branch's head
#   BEHIND      it is behind, and a fast-forward would succeed (the line gives the command)
#   FROZEN      it is behind, and local changes to the listed paths would refuse the
#               fast-forward — the condition this check exists to surface
#   OFF-BRANCH  it is behind, and it has another branch (or a detached HEAD) checked out,
#               so merging there would not move the default branch
#   AHEAD       it holds commits the remote branch does not
#   DIVERGED    it is both behind and ahead
#
# Exit codes: 0 CURRENT · 1 any other verdict (a finding to act on or report) · 2 UNKNOWN
# (usage error, not a repository, a failed fetch, or an unreadable ref or status). 2 is never
# "current": a read that failed has not shown the checkout is fresh.
#
# Limit: changes inside submodules are ignored on purpose. The shared checkout carries
# permanent submodule-pointer drift, and a fast-forward does not check out submodule contents.
set -euo pipefail

prog='shared-checkout-freshness'
finished=0
tmp=''
# Bash 3.2 reports $? as 0 to an EXIT trap after a `set -u` abort, so completion is recorded
# explicitly (the disk-preflight.sh pattern). Any exit that did not reach the end is UNKNOWN.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
on_exit() {
  local rc=$?
  [ -z "$tmp" ] || rm -rf -- "$tmp"
  if [ "$finished" != 1 ] && [ "$rc" -ne 2 ]; then
    printf '%s: aborted before finishing — UNKNOWN\n' "$prog" >&2
    rc=2
  fi
  exit "$rc"
}
trap on_exit EXIT

unknown() { printf '%s: UNKNOWN — %s\n' "$prog" "$1" >&2; exit 2; }
usage='usage: shared-checkout-freshness.sh [--repo-dir <dir>] [--branch <name>] [--remote <name>] [--no-fetch]'

repo_dir=''
branch=main
remote=origin
fetch=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir | --branch | --remote)
      [ "$#" -ge 2 ] || unknown "$1 needs a value; $usage"
      case "$1" in
        --repo-dir) repo_dir=$2 ;;
        --branch) branch=$2 ;;
        --remote) remote=$2 ;;
      esac
      shift 2
      ;;
    --no-fetch) fetch=0; shift ;;
    *) unknown "unexpected argument '$1'; $usage" ;;
  esac
done
# Both names are interpolated into refspecs, so hold them to a plain ref-name alphabet.
case "$branch" in '' | -* | *[!A-Za-z0-9._/-]* | *..*) unknown "invalid branch name '$branch'" ;; esac
case "$remote" in '' | -* | *[!A-Za-z0-9._-]*) unknown "invalid remote name '$remote'" ;; esac

if [ -z "$repo_dir" ]; then
  repo_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) \
    || unknown "cannot resolve the script directory"
fi
[ -d "$repo_dir" ] || unknown "not a directory: $repo_dir"

# The first entry of the worktree list is always the main worktree. That is the checkout new
# dispatch worktrees are created from, so it is the one to judge.
listing=$(git -C "$repo_dir" worktree list --porcelain 2>/dev/null) \
  || unknown "not a git repository: $repo_dir"
shared=$(printf '%s\n' "$listing" | sed -n '1s/^worktree //p')
[ -n "$shared" ] && [ -d "$shared" ] || unknown "cannot resolve the main worktree of $repo_dir"

if [ "$fetch" = 1 ]; then
  git -C "$shared" fetch --quiet "$remote" "+refs/heads/${branch}:refs/remotes/${remote}/${branch}" \
    2>/dev/null || unknown "cannot fetch ${remote}/${branch}"
fi

base=$(git -C "$shared" rev-parse --verify --quiet 'HEAD^{commit}') \
  || unknown "cannot read HEAD of $shared"
upstream=$(git -C "$shared" rev-parse --verify --quiet "refs/remotes/${remote}/${branch}^{commit}") \
  || unknown "cannot read ${remote}/${branch} in $shared"
# Empty for a detached HEAD, which is a state to report rather than a failed read.
checked_out=$(git -C "$shared" symbolic-ref --quiet --short HEAD || true)

short() { printf '%s' "${1:0:8}"; }
finish() { # <rc> <line>
  printf '%s: %s\n' "$prog" "$2"
  finished=1
  exit "$1"
}

if [ "$base" = "$upstream" ]; then
  finish 0 "CURRENT — $shared is at ${remote}/${branch} ($(short "$upstream"))"
fi

behind=$(git -C "$shared" rev-list --count "${base}..${upstream}") \
  || unknown "cannot count commits between $shared and ${remote}/${branch}"
ahead=$(git -C "$shared" rev-list --count "${upstream}..${base}") \
  || unknown "cannot count commits between ${remote}/${branch} and $shared"
case "$behind$ahead" in '' | *[!0-9]*) unknown "unreadable commit counts for $shared" ;; esac
where="$shared ($(short "$base")) vs ${remote}/${branch} ($(short "$upstream"))"

if [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
  finish 1 "DIVERGED — behind $behind and ahead $ahead: $where"
fi
if [ "$ahead" -gt 0 ]; then
  finish 1 "AHEAD — $ahead local commit(s) are not on ${remote}/${branch}: $where"
fi
if [ "$checked_out" != "$branch" ]; then
  finish 1 "OFF-BRANCH — behind $behind with '${checked_out:-a detached HEAD}' checked out, not '$branch': $where"
fi

# Behind only. A fast-forward is refused when a locally changed or untracked path is also a
# path the incoming commits change, so the blocking set is the overlap of the two lists. Both
# are read NUL-delimited, so a path holding spaces or newlines cannot split or merge entries.
# Untracked files are listed one by one: a collapsed `dir/` entry would never equal an incoming
# `dir/file`. The status read takes no optional lock, so it cannot disturb a session working there.
tmp=$(mktemp -d) || unknown "cannot create a temporary directory"
git -C "$shared" diff --name-only -z "$base" "$upstream" > "$tmp/incoming" \
  || unknown "cannot list the paths changed between $shared and ${remote}/${branch}"
incoming=()
while IFS= read -r -d '' path; do incoming+=("$path"); done < "$tmp/incoming"
[ "${#incoming[@]}" -gt 0 ] || unknown "no changed paths between $(short "$base") and $(short "$upstream"), although they differ"

# Ask git for the status of the incoming paths only, as literal pathspecs. The shared checkout
# holds thousands of untracked files, and only the ones an incoming commit touches can block.
xargs -0 git -C "$shared" --no-optional-locks --literal-pathspecs status --porcelain=v1 -z \
  --ignore-submodules=all --untracked-files=all -- < "$tmp/incoming" > "$tmp/dirty" \
  || unknown "cannot read the working tree status of $shared"

blocking=()
is_incoming() {
  local candidate=$1 entry
  for entry in "${incoming[@]}"; do
    [ "$entry" = "$candidate" ] && return 0
  done
  return 1
}
while IFS= read -r -d '' entry; do
  status=${entry:0:2}
  path=${entry:3}
  if is_incoming "$path"; then blocking+=("$path"); fi
  # A rename or copy entry is followed by its source path as a separate field.
  case "$status" in
    *R* | *C*)
      IFS= read -r -d '' source_path || unknown "truncated rename entry in the status of $shared"
      if is_incoming "$source_path"; then blocking+=("$source_path"); fi
      ;;
  esac
done < "$tmp/dirty"

if [ "${#blocking[@]}" -eq 0 ]; then
  finish 1 "BEHIND — $behind commit(s), and a fast-forward would succeed: $where; run: git -C '$shared' merge --ff-only ${remote}/${branch}"
fi

shown=''
limit=5
count=0
for path in "${blocking[@]}"; do
  count=$((count + 1))
  [ "$count" -le "$limit" ] || break
  shown="${shown}${shown:+, }$(printf '%q' "$path")"
done
if [ "${#blocking[@]}" -gt "$limit" ]; then
  shown="$shown, and $((${#blocking[@]} - limit)) more"
fi
finish 1 "FROZEN — behind $behind commit(s), and local changes to ${#blocking[@]} path(s) refuse the fast-forward: $shown; $where. Do not discard them: report this, and read the definition at ${remote}/${branch} until their owner resolves them"
