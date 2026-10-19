#!/usr/bin/env bash
# Apply the agreed retention to the Codex desktop app's task worktrees.
#
# Why this exists: the Codex app gives every task a directory <CODEX_HOME>/worktrees/<id>/ and
# nothing ever removes one. They grew from 9.5 GB (390 directories) on 2026-10-12 to 21 GB (706)
# on 2026-10-19 and kept the agent host below its low-space threshold (monorepo#4136). The
# maintainer chose, on 2026-10-19, to let the clean-up helper delete Codex worktrees nobody has
# touched for more than 7 days, never one a process is using or one on an open pull request's
# branch (option A of monorepo#4329).
#
# Usage:
#   codex-worktree-retention.sh [dry-run|apply] [min_age_days]
#
# Defaults: dry-run, 7 days. Values below 7 are refused.
#
# Exit: 0 every task directory was judged; 2 a usage error, or a root, the open-file list, a
# checkout or the pull-request lookup that could not be read (logged as UNKNOWN -- what could not
# be judged is kept, and the summary is then partial, never clean).
#
# Environment (all optional):
#   CODEX_WORKTREE_RETENTION_HOME   the Codex home; default ${CODEX_HOME:-$HOME/.codex}
#   CODEX_WORKTREE_RETENTION_LSOF   the open-file lister; default lsof from PATH, then
#                                   /usr/sbin, /usr/bin, /bin
#   CODEX_WORKTREE_RETENTION_GH     the GitHub CLI used for the open pull-request check;
#                                   default gh from PATH
#
# SAFETY -- this deletes, so every rule below fails closed. A task directory <id> directly below
# <home>/worktrees is removed only when ALL of these hold; anything that cannot be read is KEPT:
#   * It is a plain directory owned by this user, holds nothing owned by anyone else, and its name
#     has no line break. The worktrees root itself must not be a symbolic link.
#   * Nothing inside it (file, directory or link) was written within min_age_days.
#   * No process holds a file open, or has its working directory, at or below it. The open-file
#     list counts only when lsof exits 0 with a non-empty list.
#   * Every git checkout inside it (any `.git` within five levels, so populated submodules too)
#     has no uncommitted change (Codex's own `.codex/` and `.agents/` tool folders aside), no
#     commit that no remote-tracking branch contains, and is not on a branch that is the head of
#     an open pull request.
#   * Immediately before removal its age, ownership and open files are read again.
# After a removal, each git repository a removed checkout belonged to is pruned, so its worktree
# list stops naming the deleted folder. Nothing outside <home>/worktrees is touched.
set -uo pipefail

MODE=${1:-dry-run}
MIN_AGE_DAYS=${2:-7}
MIN_ALLOWED_DAYS=7

log() { printf 'codex-worktree-retention: %s\n' "$*"; }

case "$MODE" in
  dry-run | apply) ;;
  *)
    log "mode must be dry-run or apply, got ${MODE}" >&2
    exit 2
    ;;
esac
case "$MIN_AGE_DAYS" in
  '' | *[!0-9]*)
    log 'min_age_days must be a whole number of days' >&2
    exit 2
    ;;
esac
if [ "${#MIN_AGE_DAYS}" -gt 5 ]; then
  log "min_age_days is out of range: ${MIN_AGE_DAYS}" >&2
  exit 2
fi
MIN_AGE_DAYS=$((10#$MIN_AGE_DAYS))
if [ "$MIN_AGE_DAYS" -lt "$MIN_ALLOWED_DAYS" ]; then
  log "min_age_days must be at least ${MIN_ALLOWED_DAYS}, got ${MIN_AGE_DAYS}" >&2
  exit 2
fi
MIN_AGE_MINUTES=$((MIN_AGE_DAYS * 1440))

work=$(mktemp -d) || { log 'UNKNOWN: cannot create a work directory' >&2; exit 2; }
retention_finished=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf -- "$work"
  if [ "$retention_finished" != 1 ] && [ "$status" != 2 ]; then
    log "UNKNOWN: aborted before finishing (status ${status})" >&2
    exit 2
  fi
}
trap on_exit EXIT

if [ -n "${CODEX_WORKTREE_RETENTION_HOME:-}" ]; then
  CODEX_HOME_DIR=$CODEX_WORKTREE_RETENTION_HOME
elif [ -n "${CODEX_HOME:-}" ]; then
  CODEX_HOME_DIR=$CODEX_HOME
elif [ -n "${HOME:-}" ]; then
  CODEX_HOME_DIR=$HOME/.codex
else
  log 'UNKNOWN: no Codex home is set (CODEX_WORKTREE_RETENTION_HOME, CODEX_HOME or HOME)'
  exit 2
fi
ME=$(id -u) || { log 'UNKNOWN: cannot read the current user id' >&2; exit 2; }
ROOT=$CODEX_HOME_DIR/worktrees

# "Absent" is believed only when the parent directory can be searched.
if [ ! -e "$ROOT" ] && [ ! -L "$ROOT" ]; then
  root_parent=$(dirname -- "$ROOT")
  if [ -d "$root_parent" ] && [ -x "$root_parent" ]; then
    log "no Codex worktrees at ${ROOT}; nothing to do"
    retention_finished=1
    exit 0
  fi
  log "UNKNOWN: ${ROOT} cannot be examined (its parent cannot be searched)"
  exit 2
fi
if [ -L "$ROOT" ] || [ ! -d "$ROOT" ]; then
  log "UNKNOWN: ${ROOT} is not a plain directory; refusing"
  exit 2
fi
# lsof names paths physically (on macOS /tmp is /private/tmp), so compare physical paths.
ROOT=$(cd -P -- "$ROOT" && pwd -P) || { log 'UNKNOWN: cannot resolve the worktrees root'; exit 2; }

resolve_lsof() {
  local candidate
  if [ -n "${CODEX_WORKTREE_RETENTION_LSOF:-}" ]; then
    [ -x "$CODEX_WORKTREE_RETENTION_LSOF" ] && { printf '%s' "$CODEX_WORKTREE_RETENTION_LSOF"; return 0; }
    return 1
  fi
  candidate=$(command -v lsof 2>/dev/null) && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  for candidate in /usr/sbin/lsof /usr/bin/lsof /bin/lsof; do
    [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# open_snapshot <out> writes every path a process holds open (working directories included),
# lower-cased so a case-insensitive volume's other spelling still matches. Only a zero exit with
# a non-empty list counts: a partial enumeration can print paths and still fail.
open_snapshot() {
  [ -n "$LSOF" ] || return 1
  "$LSOF" -n -F n > "$1.raw" 2>/dev/null || return 1
  [ -s "$1.raw" ] || return 1
  sed -n 's/^n//p' "$1.raw" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u > "$1" || return 1
  [ -s "$1" ]
}

# held <dir> <open> succeeds when the open-file list names <dir> or anything below it.
held() {
  LC_ALL=C awk -v d="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')" '
    $0 == d || index($0, d "/") == 1 { found = 1; exit }
    END { exit found ? 0 : 1 }' "$2"
}

# fresh <dir> succeeds when anything at or below <dir> was written within the age line, and
# fails with status 2 when the tree could not be read completely (kept, never judged old).
fresh() {
  # A failed find (an unreadable subfolder) is not proof that nothing is recent.
  find "$1" -mmin -"$MIN_AGE_MINUTES" -print > "$work/fresh" 2>/dev/null || return 2
  [ -s "$work/fresh" ]
}

# foreign <dir> succeeds when anything at or below <dir> is owned by another user, or fails with
# status 2 when that cannot be read.
foreign() {
  find "$1" ! -user "$ME" -print > "$work/foreign" 2>/dev/null || return 2
  [ -s "$work/foreign" ]
}

# repo_slug <checkout> prints owner/repo of the checkout's origin when it is on github.com.
repo_slug() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  url=${url%.git}
  case "$url" in
    https://github.com/*/*) url=${url#https://github.com/} ;;
    git@github.com:*/*) url=${url#git@github.com:} ;;
    ssh://git@github.com/*/*) url=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  case "$url" in */*/* | *[!A-Za-z0-9._/-]*) return 1 ;; esac
  printf '%s' "$url"
}

# judge_checkout <checkout> prints why the checkout must be kept (empty = removable), or fails
# when it cannot be read.
judge_checkout() {
  local c=$1 st branch ahead slug prs
  # --no-optional-locks: a plain status may rewrite the index, which would itself read as a recent
  # write and keep the worktree another min_age_days.
  st=$(git --no-optional-locks -C "$c" status --porcelain --ignore-submodules=all 2>/dev/null) || return 1
  st=$(printf '%s\n' "$st" | grep -v -E '^\?\? \.(codex|agents)/' | sed '/^$/d')
  if [ -n "$st" ]; then printf 'uncommitted changes'; return 0; fi
  ahead=$(git -C "$c" rev-list --count HEAD --not --remotes 2>/dev/null) || return 1
  case "$ahead" in '' | *[!0-9]*) return 1 ;; esac
  if [ "$ahead" -gt 0 ]; then printf 'unpushed commits'; return 0; fi
  branch=$(git -C "$c" symbolic-ref -q --short HEAD 2>/dev/null) || return 0 # detached: no branch
  slug=$(repo_slug "$c") || { printf 'branch %s of a repository not on GitHub' "$branch"; return 0; }
  [ -n "$GH" ] || return 1
  prs=$("$GH" pr list --repo "$slug" --head "$branch" --state open --json number --jq 'length' < /dev/null 2>/dev/null) || return 1
  case "$prs" in '' | *[!0-9]*) return 1 ;; esac
  if [ "$prs" -gt 0 ]; then printf 'open pull request on %s' "$branch"; fi
  return 0
}

dir_kb() {
  local k
  k=$(du -sk -- "$1" 2>/dev/null | awk 'NR==1{print $1}') || return 1
  case "$k" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$k"
}

LSOF=$(resolve_lsof) || LSOF=''
GH=${CODEX_WORKTREE_RETENTION_GH:-$(command -v gh 2>/dev/null || true)}
[ -z "$GH" ] || [ -x "$GH" ] || GH=''

if ! open_snapshot "$work/open"; then
  log "UNKNOWN: the open-file list could not be read; nothing under ${ROOT} is removed"
  retention_finished=1
  exit 2
fi

if ! find "$ROOT" -mindepth 1 -maxdepth 1 -print0 > "$work/children.nul" 2>/dev/null; then
  log "UNKNOWN: ${ROOT} could not be listed; nothing removed"
  retention_finished=1
  exit 2
fi

unknown=0
examined=0
removed=0
kept_young=0
kept_open=0
kept_work=0
failed=0
kb_total=0
: > "$work/repos"

while IFS= read -r -d '' d; do
  examined=$((examined + 1))
  case "$d" in *$'\n'*)
    log 'UNKNOWN: a task directory name holds a line break; kept'
    unknown=$((unknown + 1))
    continue
    ;;
  esac
  if [ -L "$d" ] || [ ! -d "$d" ]; then
    log "kept ${d}: not a plain directory"
    kept_work=$((kept_work + 1))
    continue
  fi
  fresh "$d"
  rc=$?
  if [ "$rc" -eq 0 ]; then kept_young=$((kept_young + 1)); continue; fi
  if [ "$rc" -eq 2 ]; then
    log "UNKNOWN: ${d} could not be read completely; kept"
    unknown=$((unknown + 1))
    continue
  fi
  foreign "$d"
  rc=$?
  if [ "$rc" -ne 1 ]; then
    if [ "$rc" -eq 0 ]; then
      log "kept ${d}: holds files owned by another user"
      kept_work=$((kept_work + 1))
    else
      log "UNKNOWN: ownership under ${d} could not be read; kept"
      unknown=$((unknown + 1))
    fi
    continue
  fi
  if held "$d" "$work/open"; then
    log "kept ${d}: a process is using it"
    kept_open=$((kept_open + 1))
    continue
  fi
  # Every checkout inside, at most five levels down, so populated submodules are judged too.
  if ! find "$d" -maxdepth 5 -name .git -prune -print0 > "$work/git.nul" 2>/dev/null; then
    log "UNKNOWN: checkouts under ${d} could not be listed; kept"
    unknown=$((unknown + 1))
    continue
  fi
  reason=''
  bad=0
  : > "$work/these-repos"
  while IFS= read -r -d '' g; do
    c=${g%/.git}
    if ! why=$(judge_checkout "$c"); then bad=1; break; fi
    if [ -n "$why" ]; then reason=$why; break; fi
    common=$(git -C "$c" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { bad=1; break; }
    printf '%s\n' "$common" >> "$work/these-repos"
  done < "$work/git.nul"
  if [ "$bad" -eq 1 ]; then
    log "UNKNOWN: a checkout under ${d} could not be judged; kept"
    unknown=$((unknown + 1))
    continue
  fi
  if [ -n "$reason" ]; then
    log "kept ${d}: ${reason}"
    kept_work=$((kept_work + 1))
    continue
  fi
  kb=$(dir_kb "$d") || {
    log "UNKNOWN: the size of ${d} could not be read; kept"
    unknown=$((unknown + 1))
    continue
  }

  if [ "$MODE" != apply ]; then
    log "would remove ${d} (~$((kb / 1024)) MB)"
    removed=$((removed + 1))
    kb_total=$((kb_total + kb))
    continue
  fi

  # Read age, ownership and open files again immediately before the removal.
  if ! open_snapshot "$work/open.now"; then
    log "UNKNOWN: the open-file list could not be read again; ${d} and the rest are kept"
    unknown=$((unknown + 1))
    break
  fi
  fresh "$d"
  fresh_rc=$?
  foreign "$d"
  foreign_rc=$?
  if [ -L "$d" ] || held "$d" "$work/open.now" || [ "$fresh_rc" -ne 1 ] || [ "$foreign_rc" -ne 1 ]; then
    log "kept ${d}: changed since it was scanned"
    kept_work=$((kept_work + 1))
    continue
  fi
  rm -rf -- "$d" 2>/dev/null
  if [ ! -e "$d" ] && [ ! -L "$d" ]; then
    log "removed ${d} (~$((kb / 1024)) MB)"
    removed=$((removed + 1))
    kb_total=$((kb_total + kb))
    cat "$work/these-repos" >> "$work/repos"
  else
    log "removal of ${d} failed"
    failed=$((failed + 1))
  fi
done < "$work/children.nul"

# Prune each repository a removed checkout belonged to, so `git worktree list` stops naming it.
if [ -s "$work/repos" ]; then
  while IFS= read -r repo; do
    # A clone's repository lived inside the folder just removed; only a surviving one is pruned.
    [ -n "$repo" ] && [ -d "$repo" ] || continue
    git --git-dir="$repo" worktree prune 2>/dev/null ||
      log "note: could not prune the worktree list of ${repo}"
  done < <(LC_ALL=C sort -u "$work/repos")
fi

mb=$((kb_total / 1024))
kept=$((kept_young + kept_open + kept_work))
if [ "$MODE" = apply ]; then
  log "summary: age>${MIN_AGE_DAYS}d examined=${examined} removed=${removed} kept=${kept} (young=${kept_young} in_use=${kept_open} work=${kept_work}) failed=${failed} reclaimed=~${mb} MB"
else
  log "summary: age>${MIN_AGE_DAYS}d examined=${examined} would remove=${removed} kept=${kept} (young=${kept_young} in_use=${kept_open} work=${kept_work}) would reclaim=~${mb} MB (dry-run: nothing deleted)"
fi
if [ "$failed" -gt 0 ]; then
  log "UNKNOWN: ${failed} removal(s) failed"
  unknown=$((unknown + 1))
fi
retention_finished=1
[ "$unknown" -eq 0 ] || exit 2
exit 0
