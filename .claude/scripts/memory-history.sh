#!/usr/bin/env bash
# memory-history.sh — keep a local-only git history of an agent memory store (monorepo#5050).
#
# The durable memory stores live outside every checkout and had no history, so a bad rewrite was a
# one-way delete and custom backup tooling grew around that. A plain git repository gives diff,
# log and restore. Its git directory lives OUTSIDE the store, so the runtimes that read the store
# never see a `.git` entry; every command passes --git-dir and --work-tree explicitly.
#
# The repository must NEVER get a remote: the stores hold private data. Every command refuses a
# repository that has one. Commits are local, unsigned and run without hooks, so an unattended run
# never waits on a signing prompt.
#
# Usage:
#   memory-history.sh init   --store DIR --git-dir DIR --layout claude|codex
#   memory-history.sh commit --git-dir DIR [--message TEXT]
#   memory-history.sh git    --git-dir DIR -- <git arguments>     (log, diff, show, restore …)
#
# Layouts choose what is tracked:
#   claude  every file except the backup artifacts the older helpers leave behind;
#   codex   only <automation>/memory.md, never the large run artifacts beside it.
#
# Exit codes: 0 done (commit prints the new sha, or "unchanged"), 1 refused (a remote exists, or the
# store or git directory is not what the command expects), 2 usage error or a failed git command.

set -euo pipefail

usage() {
  sed -n '12,15p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

refuse() {
  echo "memory-history: REFUSED — $*" >&2
  exit 1
}

die() {
  echo "memory-history: UNKNOWN — $*" >&2
  exit 2
}

command_name="${1:-}"
[ -n "${command_name}" ] || usage
shift

store=''
git_dir=''
layout=''
message=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --store) [ "$#" -ge 2 ] || usage; store="$2"; shift 2 ;;
    --git-dir) [ "$#" -ge 2 ] || usage; git_dir="$2"; shift 2 ;;
    --layout) [ "$#" -ge 2 ] || usage; layout="$2"; shift 2 ;;
    --message) [ "$#" -ge 2 ] || usage; message="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ -n "${git_dir}" ] || usage

# Every git call: this repository only, no hooks, no signing, no pager.
hgit() {
  git --git-dir="${git_dir}" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    -c tag.gpgsign=false -c core.pager=cat "$@"
}

require_no_remote() {
  local remotes
  remotes="$(hgit remote)" || die "cannot list remotes of ${git_dir}"
  [ -z "${remotes}" ] || refuse "${git_dir} has a remote (${remotes//$'\n'/ }); this history must stay local"
}

require_repo() {
  if [ ! -d "${git_dir}" ] || ! hgit rev-parse --git-dir >/dev/null 2>&1; then
    refuse "${git_dir} is not an initialised memory history (run init first)"
  fi
  require_no_remote
  [ -d "$(hgit config core.worktree)" ] || refuse "the store recorded in ${git_dir} is missing"
}

case "${command_name}" in
  init)
    [ -n "${store}" ] && [ -n "${layout}" ] || usage
    [ -d "${store}" ] || refuse "store is not a directory: ${store}"
    store="$(cd "${store}" && pwd -P)"
    # Compare physical paths, so a symlinked prefix cannot hide a git directory inside the store.
    mkdir -p "$(dirname "${git_dir}")"
    git_dir="$(cd "$(dirname "${git_dir}")" && pwd -P)/$(basename "${git_dir}")"
    [ ! -e "${store}/.git" ] || refuse "${store} already holds a .git entry; keep git metadata outside the store"
    case "${git_dir}" in
      "${store}" | "${store}"/*) refuse "the git directory must live outside the store" ;;
    esac
    if [ -e "${git_dir}" ]; then
      require_repo
      [ "$(hgit config core.worktree)" = "${store}" ] ||
        refuse "${git_dir} already tracks another store"
      echo "memory-history: already initialised: ${git_dir}"
      exit 0
    fi
    mkdir -p "$(dirname "${git_dir}")"
    git init -q --bare "${git_dir}" || die "git init failed for ${git_dir}"
    hgit config core.bare false
    hgit config core.worktree "${store}"
    hgit config user.name 'agent memory history'
    hgit config user.email 'agent-memory-history@localhost'
    hgit config commit.gpgsign false
    case "${layout}" in
      claude)
        printf '%s\n' '/.memory-backups/' '/.memory-archive-backup-*/' '/.memory-rewrite-recovery*' \
          '*.bak*' >"${git_dir}/info/exclude"
        ;;
      codex)
        printf '%s\n' '/*' '!/*/' '/*/*' '!/*/memory.md' >"${git_dir}/info/exclude"
        ;;
      *) rm -rf "${git_dir}"; usage ;;
    esac
    hgit add -A || die "cannot stage ${store}"
    hgit commit -q -m "memory-history: initial snapshot" || die "initial commit failed"
    echo "memory-history: initialised ${git_dir} for ${store} ($(hgit ls-files | wc -l | tr -d ' ') files)"
    ;;
  commit)
    require_repo
    attempt=0
    # Several lanes write memory; a sibling's commit can hold the index lock for a moment.
    until hgit add -A 2>/dev/null; do
      attempt=$((attempt + 1))
      [ "${attempt}" -lt 5 ] || die "cannot stage the store (index lock held?)"
      sleep 1
    done
    if hgit diff --cached --quiet; then
      echo "memory-history: unchanged"
      exit 0
    fi
    attempt=0
    until hgit commit -q -m "${message:-memory-history: run snapshot}" 2>/dev/null; do
      attempt=$((attempt + 1))
      [ "${attempt}" -lt 5 ] || die "commit failed"
      sleep 1
      hgit diff --cached --quiet && { echo "memory-history: unchanged"; exit 0; }
    done
    hgit rev-parse HEAD
    ;;
  git)
    require_repo
    [ "$#" -gt 0 ] || usage
    case "$1" in
      -* | remote | push | fetch | pull | clone | submodule | ls-remote) refuse "network and remote commands are not allowed here" ;;
    esac
    hgit "$@"
    ;;
  *) usage ;;
esac
