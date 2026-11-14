#!/usr/bin/env bash
# memory-history.sh — keep a local-only git history of an agent memory store (monorepo#5050).
#
# Usage:
#   memory-history.sh init   --store DIR --git-dir DIR --layout claude|codex
#   memory-history.sh commit --git-dir DIR [--message TEXT]
#   memory-history.sh git    --git-dir DIR -- log|diff|show|status|ls-files|blame|grep … | restore [--source REV] -- FILE…
#
# The durable memory stores live outside every checkout and had no history, so a bad rewrite was a
# one-way delete and custom backup tooling grew around that. A plain git repository gives diff,
# log and restore. Its git directory lives OUTSIDE the store, so the runtimes that read the store
# never see a `.git` entry; every command passes --git-dir and --work-tree explicitly.
#
# The repository must NEVER get a remote: the stores hold private data. So every command refuses a
# repository with a remote or with configuration that could reach the network or run a program
# (aliases, url rewrites, includes, filters, fsmonitor, ssh command). The `git` passthrough is an
# allow-list of read verbs plus `restore` of named files; nothing can push, serve, bundle, clean
# or reset. Every call ignores the caller's GIT_* environment and the global and system git
# configuration, runs no hooks and signs nothing, so an unattended run never waits on a prompt
# and a hook context cannot redirect it.
#
# Layouts choose what is tracked:
#   claude  every file except the backup and swap artifacts the older helpers leave behind;
#   codex   only <automation>/memory.md, never the large run artifacts beside it.
#
# Exit codes: 0 done (commit prints the new sha, or "unchanged"), 1 refused (a remote or unsafe
# configuration exists, or the store or git directory is not what the command expects), 2 usage
# error or a failed git command.

set -euo pipefail

usage() {
  sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//' >&2
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

# Drop every GIT_* variable the caller may carry (a hook or rebase context sets several of them).
while IFS='=' read -r name _; do
  case "${name}" in GIT_*) unset "${name}" ;; esac
done < <(env)

# Every git call: this repository and work tree only, no global or system configuration, no hooks,
# no signing, no fsmonitor, no line-ending or attribute rewriting, no pager.
hgit() {
  local work_tree=()
  [ -z "${store}" ] || work_tree=(--work-tree="${store}")
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    git --git-dir="${git_dir}" ${work_tree[@]+"${work_tree[@]}"} \
    -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false \
    -c core.fsmonitor=false -c core.autocrlf=false -c core.excludesFile=/dev/null \
    -c core.attributesFile=/dev/null -c core.pager=cat "$@"
}

# require_repo — the git directory is an initialised history of an existing store, with no remote
# and no configuration that could reach the network or run a program. Sets ${store}.
require_repo() {
  local unsafe
  if [ ! -d "${git_dir}" ] || ! hgit rev-parse --git-dir >/dev/null 2>&1; then
    refuse "${git_dir} is not an initialised memory history (run init first)"
  fi
  [ -z "$(hgit remote)" ] || refuse "${git_dir} has a remote; this history must stay local"
  unsafe="$(hgit config --local --name-only --get-regexp \
    '^(remote|alias|url|include|includeif|filter|credential|http|submodule)\.|^(diff|pager|gpg)\.|^core\.(fsmonitor|sshcommand|hookspath|pager|editor|askpass)$' \
    2>/dev/null || true)"
  [ -z "${unsafe}" ] || refuse "${git_dir} carries unsafe configuration: ${unsafe//$'\n'/ }"
  store="$(hgit config core.worktree)" || refuse "no store is recorded in ${git_dir}"
  [ -d "${store}" ] || refuse "the store recorded in ${git_dir} is missing: ${store}"
}

case "${command_name}" in
  init)
    [ -n "${store}" ] && [ -n "${layout}" ] || usage
    case "${layout}" in claude | codex) ;; *) usage ;; esac
    [ -d "${store}" ] || refuse "store is not a directory: ${store}"
    store="$(cd "${store}" && pwd -P)"
    [ ! -e "${store}/.git" ] || refuse "${store} already holds a .git entry; keep git metadata outside the store"
    # Compare physical paths, so a symlinked prefix cannot hide a git directory inside the store.
    parent="$(dirname "${git_dir}")"
    while [ ! -d "${parent}" ]; do parent="$(dirname "${parent}")"; done
    physical="$(cd "${parent}" && pwd -P)${git_dir#"${parent}"}"
    case "${physical}/" in
      "${store}/"*) refuse "the git directory must live outside the store" ;;
    esac
    git_dir="${physical}"
    if [ -e "${git_dir}" ]; then
      wanted="${store}"
      require_repo
      [ "${store}" = "${wanted}" ] || refuse "${git_dir} already tracks another store"
      echo "memory-history: already initialised: ${git_dir}"
      exit 0
    fi
    mkdir -p "$(dirname "${git_dir}")"
    git_store="${store}"
    store=''
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git init -q --bare "${git_dir}" ||
      die "git init failed for ${git_dir}"
    store="${git_store}"
    hgit config core.bare false
    hgit config core.worktree "${store}"
    hgit config user.name 'agent memory history'
    hgit config user.email 'agent-memory-history@localhost'
    case "${layout}" in
      claude)
        printf '%s\n' '/.memory-backups/' '/.memory-archive-backup-*/' '/.memory-rewrite-recovery*' \
          '*.bak' '*.bak-*' '*.bak.*' '*.memory-rewrite.*' >"${git_dir}/info/exclude"
        ;;
      codex)
        printf '%s\n' '/*' '!/*/' '/*/*' '!/*/memory.md' >"${git_dir}/info/exclude"
        ;;
    esac
    hgit add -A || die "cannot stage ${store}"
    hgit commit -q --allow-empty -m "memory-history: initial snapshot" || die "initial commit failed"
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
      if hgit diff --cached --quiet; then echo "memory-history: unchanged"; exit 0; fi
    done
    hgit rev-parse HEAD
    ;;
  git)
    require_repo
    [ "$#" -gt 0 ] || usage
    verb="$1"
    case "${verb}" in
      log | diff | show | status | ls-files | blame | grep) ;;
      restore)
        # Only named files: restoring the whole store would overwrite a sibling's live writes.
        # Each name must be a file the source revision tracks: never a directory, a pattern, an
        # absolute path or a pathspec before `--`.
        named=0
        past=0
        source_rev=HEAD
        for arg in "${@:2}"; do
          if [ "${past}" = 1 ]; then
            case "${arg}" in
              '' | /* | *..* | ./* | :* | *'*'* | *'?'* | *'['* | *"\\"*)
                refuse "restore takes named files only, not '${arg}'" ;;
            esac
            [ ! -d "${store}/${arg}" ] || refuse "restore takes named files only, not the directory '${arg}'"
            [ -n "$(hgit ls-tree --name-only "${source_rev}" -- "${arg}" 2>/dev/null)" ] ||
              refuse "'${arg}' is not a file tracked at ${source_rev}"
            named=1
          else
            case "${arg}" in
              --) past=1 ;;
              --source=?*) source_rev="${arg#--source=}" ;;
              --staged | --worktree | -W | -S | --quiet | -q) ;;
              *) refuse "restore takes only --source=REV, --staged, --worktree and --quiet before --, not '${arg}'" ;;
            esac
          fi
        done
        [ "${named}" = 1 ] || refuse "restore needs named files after --"
        ;;
      *) refuse "'${verb}' is not allowed here; use log, diff, show, status, ls-files, blame, grep or restore" ;;
    esac
    # Git accepts any unique abbreviation of a long option and bundles short ones, so refuse by
    # prefix: anything that could write a file, run a program, read outside the store or take
    # pathspecs from a file. In grep, a bundled -O (open in pager) runs a program too.
    for arg in "${@:2}"; do
      [ "${arg}" != -- ] || break
      case "${arg}" in
        --output* | --ext* | --tex* | --exe* | --up* | --rec* | --pathspec-f* | --contents* | --no-ind*)
          refuse "option '${arg}' is not allowed here" ;;
        --o*) [ "${verb}" != grep ] || refuse "option '${arg}' is not allowed here" ;;
        --*) ;;
        -*O*) [ "${verb}" != grep ] || refuse "option '${arg}' is not allowed here" ;;
      esac
    done
    hgit "$@"
    ;;
  *) usage ;;
esac
