#!/usr/bin/env bash
# worktree-submodule-inventory.sh — read-only inventory of what each populated submodule
# inside a session worktree still holds, one row per submodule entry (monorepo#3072).
#
# WHY: the worktree sweep keeps any worktree whose submodule holds something a removal
# would destroy, and reports one reason per WORKTREE. Measured 2026-10-09, 31 of the 39
# worktrees older than the salvage age were kept only because the session had populated a
# submodule, and the single top-level reason hid which case applied: unfinished authored
# work, tool output, a nested worktree, or commits that were squash-merged long ago. Those
# need different handling, so this lists them per submodule entry.
#
# It never writes: no fetch, no network, no ref or index update (GIT_OPTIONAL_LOCKS=0 stops
# `git status` from refreshing another session's index), so it is safe while sessions run.
#
# Usage:
#   worktree-submodule-inventory.sh <worktree-root> [--min-idle-days N]
#
#   <worktree-root>      a directory whose immediate children are worktrees
#                        (for example <checkout>/.claude/worktrees)
#   --min-idle-days N    list only entries idle for at least N days (default 0)
#
# Output, tab-separated, one row per populated submodule of each worktree:
#   ENTRY <worktree> <submodule> <class> idle_days=<n> head=<sha> unpushed=<n>
#         local_only=<n> modified=<n> untracked=<n> nested=<n> ignored=<n>
# and a closing `CHECKED ...` line with the totals. Other rows:
#   SKIP <name> <reason>                     a child that is not a worktree
#   UNREADABLE <worktree> <submodule> <why>  a read failed; nothing is claimed about it
#
# Each entry gets exactly ONE class, the first that applies:
#   modified     tracked files changed (staged or not): looks like unfinished authored work
#   nested       an untracked or ignored directory that is, or holds, a repository or
#                worktree; it cannot be judged until that inner repository is classified
#   untracked    untracked files only
#   unpushed     clean, but HEAD holds commits no remote-tracking ref reaches. Under
#                squash-merge these are often merged in content already: check the pull
#                request whose head is `head=`, never `git branch --merged`
#   local-only   clean and HEAD is pushed, but a local branch, stash or HEAD reflog entry
#                holds commits no remote-tracking ref reaches
#   ignored      nothing but files the repository's own ignore rules cover (build output,
#                dependency directories): rarely authored, but a removal deletes them
#   clean        nothing a removal would destroy
#
# `local_only=` counts every such commit, so it includes the ones `unpushed=` counts.
# The counts are local facts at the time of the read. "Reaches" is judged against the
# remote-tracking refs already in the repository; a stale fetch can only over-report.
# Submodules nested inside a submodule are not listed separately.
# A submodule is one the worktree's .gitmodules names or its index records as a gitlink.
# Git still reads each inspected repository's own configuration (filters, attributes);
# these are the agent's own worktrees, not untrusted checkouts.
#
# Exit codes: 0 every entry was read; 2 usage error, unreadable root, a root holding no
# worktree at all, or any UNREADABLE row
# (the inventory is then incomplete: never read it as a full list).
set -euo pipefail

export GIT_OPTIONAL_LOCKS=0
# An inherited location variable would point every read below at the caller's repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_NAMESPACE
# Tracing writes to stderr, which the status read below treats as a warning.
unset GIT_TRACE GIT_TRACE_SETUP GIT_TRACE_PERFORMANCE GIT_TRACE2 GIT_TRACE_PACKET GIT_TRACE_REFS

# rgit — git with the repository-configured helpers that `git status` would otherwise run or
# start (a filesystem monitor writes into the git directory) switched off. The commit graph
# is an optional speed-up; a stale one only makes git warn, and a warning fails the read.
rgit() { git -c core.fsmonitor=false -c core.untrackedCache=false -c core.commitGraph=false "$@"; }

die() { printf 'worktree-submodule-inventory: %s\n' "$1" >&2; exit 2; }

# physical_path <dir> — canonical path from the kernel, so two spellings of one directory
# compare equal on a case-insensitive filesystem (same reason as worktree-cleanup.sh).
physical_path() { (cd "$1" 2>/dev/null && /bin/pwd -P); }

file_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) m=$(stat -f %m "$1" 2>/dev/null || true) ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

ROOT=''
MIN_IDLE_DAYS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --min-idle-days)
      [ $# -ge 2 ] || die "--min-idle-days needs a value"
      MIN_IDLE_DAYS=$2; shift 2 ;;
    -h|--help) sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$ROOT" ] || die "exactly one <worktree-root> is expected"
       ROOT=$1; shift ;;
  esac
done
[ -n "$ROOT" ] || die "usage: worktree-submodule-inventory.sh <worktree-root> [--min-idle-days N]"
case "$MIN_IDLE_DAYS" in ''|*[!0-9]*) die "--min-idle-days must be a non-negative integer" ;; esac
[ -d "$ROOT" ] || die "not a directory: $ROOT"
ROOT=$(physical_path "$ROOT") || die "cannot resolve the worktree root"
NOW=$(date +%s)

worktrees=0; entries=0; unreadable=0; skipped=0; below_age=0
n_modified=0; n_nested=0; n_untracked=0; n_unpushed=0; n_local_only=0; n_ignored=0; n_clean=0

unreadable_row() { # worktree submodule why
  unreadable=$((unreadable+1))
  printf 'UNREADABLE\t%s\t%s\t%s\n' "$1" "$2" "$3"
}

# idle_days <git-dir> -> whole days since the repository's HEAD or index was last written.
idle_days() {
  local g=$1 newest=0 m f
  for f in "$g/HEAD" "$g/index"; do
    [ -e "$f" ] || continue
    m=$(file_mtime "$f") || return 1
    [ "$m" -gt "$newest" ] && newest=$m
  done
  [ "$newest" -gt 0 ] || return 1
  [ "$newest" -le "$NOW" ] || newest=$NOW
  printf '%s\n' $(( (NOW - newest) / 86400 ))
}

# classify_entry <worktree-label> <submodule-path> <submodule-dir>
classify_entry() {
  local label=$1 path=$2 dir=$3
  local top real g head status line code rest
  local modified=0 untracked=0 nested=0 ignored=0 inner hidden unpushed local_only idle class

  # `git -C` on a directory whose own .git is broken answers for the PARENT repository, so
  # a broken submodule would read as the parent's state. Require git to name this directory.
  real=$(physical_path "$dir") || { unreadable_row "$label" "$path" "cannot resolve the directory"; return 0; }
  top=$(rgit -C "$dir" rev-parse --show-toplevel 2>/dev/null) \
    || { unreadable_row "$label" "$path" "not a readable repository"; return 0; }
  top=$(physical_path "$top") || { unreadable_row "$label" "$path" "cannot resolve its top level"; return 0; }
  [ "$top" = "$real" ] \
    || { unreadable_row "$label" "$path" "git resolves it to another working tree"; return 0; }
  g=$(rgit -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) \
    || { unreadable_row "$label" "$path" "cannot find its git directory"; return 0; }
  head=$(rgit -C "$dir" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) \
    || { unreadable_row "$label" "$path" "HEAD is not a commit"; return 0; }

  # -z never quotes a path; NUL becomes the record separator and a real newline \001, so a
  # path holding a newline is detected instead of being split into two records.
  # `git status` hides a tracked file marked assume-unchanged or skip-worktree, edited or
  # not, so such a mark means the status below cannot vouch for the working tree.
  hidden=$(rgit -C "$dir" ls-files -v 2>/dev/null | awk '/^[a-zS] / { n++ } END { print n + 0 }') \
    || { unreadable_row "$label" "$path" "cannot list its tracked files"; return 0; }
  [ "$hidden" = 0 ] \
    || { unreadable_row "$label" "$path" "tracked files are hidden from git status"; return 0; }

  # stderr joins the stream on purpose: git only WARNS about a directory it may not open and
  # still exits 0, and a warning line carries a newline, so the guard below rejects it.
  # --ignored=matching: an ignored file dies with the worktree too, and an ignored directory
  # can hold a whole repository.
  status=$(rgit -C "$dir" status --porcelain -z --untracked-files=all --ignored=matching \
             --ignore-submodules=none 2>&1 \
           | tr '\0\n' '\n\001') \
    || { unreadable_row "$label" "$path" "cannot read its status"; return 0; }
  case "$status" in
    *$'\001'*) unreadable_row "$label" "$path" "git warned about the read, or a path holds a newline"; return 0 ;;
  esac
  # Drop the rename/copy SOURCE that -z emits as its own field.
  status=$(printf '%s\n' "$status" | awk 'skip { skip = 0; next } { print } /^([RC].|.[RC]) / { skip = 1 }')
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    code=${line:0:2}; rest=${line:3}
    case "$code" in
      '??')
        # git lists an untracked repository as one directory entry and does not descend.
        case "$rest" in
          */) if [ -e "$dir/${rest%/}/.git" ]; then nested=$((nested+1)); else untracked=$((untracked+1)); fi ;;
          *)  untracked=$((untracked+1)) ;;
        esac ;;
      '!!')
        # An ignored directory is listed whole, so a repository can sit anywhere below it.
        case "$rest" in
          */) inner=$(find "$dir/${rest%/}" -name .git -print -quit 2>/dev/null) \
                || { unreadable_row "$label" "$path" "cannot search an ignored directory"; return 0; }
              if [ -n "$inner" ]; then nested=$((nested+1)); else ignored=$((ignored+1)); fi ;;
          *)  ignored=$((ignored+1)) ;;
        esac ;;
      *) modified=$((modified+1)) ;;
    esac
  done <<< "$status"

  unpushed=$(rgit --git-dir="$g" rev-list --count "$head" --not --remotes 2>/dev/null) \
    || { unreadable_row "$label" "$path" "cannot count unpushed commits"; return 0; }
  local_only=$(rgit --git-dir="$g" rev-list --count --all --reflog --not --remotes 2>/dev/null) \
    || { unreadable_row "$label" "$path" "cannot count local-only commits"; return 0; }
  case "$unpushed$local_only" in ''|*[!0-9]*)
    unreadable_row "$label" "$path" "a commit count is not a number"; return 0 ;;
  esac
  idle=$(idle_days "$g") || { unreadable_row "$label" "$path" "cannot read its last-write time"; return 0; }

  if   [ "$modified"   -gt 0 ]; then class=modified
  elif [ "$nested"     -gt 0 ]; then class=nested
  elif [ "$untracked"  -gt 0 ]; then class=untracked
  elif [ "$unpushed"   -gt 0 ]; then class=unpushed
  elif [ "$local_only" -gt 0 ]; then class=local-only
  elif [ "$ignored"    -gt 0 ]; then class=ignored
  else class=clean
  fi

  if [ "$idle" -lt "$MIN_IDLE_DAYS" ]; then below_age=$((below_age+1)); return 0; fi
  entries=$((entries+1))
  case "$class" in
    modified)   n_modified=$((n_modified+1)) ;;
    nested)     n_nested=$((n_nested+1)) ;;
    untracked)  n_untracked=$((n_untracked+1)) ;;
    unpushed)   n_unpushed=$((n_unpushed+1)) ;;
    local-only) n_local_only=$((n_local_only+1)) ;;
    ignored)    n_ignored=$((n_ignored+1)) ;;
    clean)      n_clean=$((n_clean+1)) ;;
  esac
  printf 'ENTRY\t%s\t%s\t%s\tidle_days=%s\thead=%s\tunpushed=%s\tlocal_only=%s\tmodified=%s\tuntracked=%s\tnested=%s\tignored=%s\n' \
    "$label" "$path" "$class" "$idle" "$head" "$unpushed" "$local_only" "$modified" "$untracked" "$nested" "$ignored"
}

# submodule_paths <worktree> -> prints each path .gitmodules names or the index records as a
# gitlink, one per line, deduplicated. Either source alone misses a case: a deleted
# .gitmodules, or a submodule added but not yet staged. Non-zero on any failed read and on
# a path holding a newline.
submodule_paths() {
  local wt=$1 named='' links rc=0
  if [ -e "$wt/.gitmodules" ]; then
    [ -f "$wt/.gitmodules" ] && [ -r "$wt/.gitmodules" ] || return 1
    # -z prints `key<newline>value<NUL>`, so a submodule NAME holding a space cannot shift
    # the value. Exit 1 means no key matched.
    named=$(git config -z -f "$wt/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null \
            | tr '\0\n' '\n\001') || rc=$?
    [ "$rc" -le 1 ] || return 1
    named=$(printf '%s\n' "$named" | awk -F'\001' 'NF == 0 { next } NF != 2 { bad = 1 } { print $2 } END { exit bad }') \
      || return 1
  fi
  links=$(rgit -C "$wt" ls-files -s -z 2>/dev/null | tr '\0\n' '\n\001') || return 1
  case "$links" in *$'\001'*) return 1 ;; esac
  links=$(printf '%s\n' "$links" | awk '$1 == "160000" { sub(/^[^\t]*\t/, ""); print }')
  printf '%s\n%s\n' "$named" "$links" | awk 'length($0) && !seen[$0]++'
}

# locate_submodule <worktree-realpath> <path> -> sets SUB_DIR to the submodule's directory.
# Returns 0 when it is there to read, 1 when it is provably absent (unpopulated), and 2 with
# SUB_WHY set when that cannot be established. Every component must be a real directory this
# process may read and search: `-e` is false both for an absent entry and for one behind a
# directory it may not search, and a symbolic link can lead out of the worktree.
locate_submodule() {
  local cur=$1 rest=$2 comp
  SUB_DIR=''; SUB_WHY=''
  case "$rest" in
    /*)      SUB_WHY="the path is absolute"; return 2 ;;
    *$'\t'*) SUB_WHY="the path holds a tab"; return 2 ;;
  esac
  while [ -n "$rest" ]; do
    comp=${rest%%/*}
    case "$rest" in */*) rest=${rest#*/} ;; *) rest='' ;; esac
    case "$comp" in
      '') continue ;;
      .|..) SUB_WHY="the path does not stay inside the worktree"; return 2 ;;
    esac
    if [ ! -r "$cur" ] || [ ! -x "$cur" ]; then SUB_WHY="no permission to read ${cur##*/}"; return 2; fi
    cur="$cur/$comp"
    if [ -L "$cur" ]; then SUB_WHY="a path component is a symbolic link"; return 2; fi
    [ -e "$cur" ] || return 1
    [ -d "$cur" ] || return 1
  done
  if [ ! -r "$cur" ] || [ ! -x "$cur" ]; then SUB_WHY="no permission to read the directory"; return 2; fi
  SUB_DIR=$cur
  return 0
}

for wt in "$ROOT"/*/; do
  [ -d "$wt" ] || continue
  wt=${wt%/}
  label=${wt##*/}
  # A link to a worktree would list it twice, once under each name.
  if [ -L "$wt" ]; then
    skipped=$((skipped+1)); printf 'SKIP\t%s\t%s\n' "$label" "a symbolic link"; continue
  fi
  # `-e` cannot tell an absent .git from one it may not look at.
  if [ ! -r "$wt" ] || [ ! -x "$wt" ]; then
    unreadable_row "$label" "-" "no permission to read the directory"; continue
  fi
  if [ ! -e "$wt/.git" ]; then
    skipped=$((skipped+1)); printf 'SKIP\t%s\t%s\n' "$label" "not a git worktree"; continue
  fi
  wt_real=$(physical_path "$wt") || { unreadable_row "$label" "-" "cannot resolve the worktree"; continue; }
  wt_top=$(rgit -C "$wt" rev-parse --show-toplevel 2>/dev/null) \
    || { unreadable_row "$label" "-" "not a readable worktree"; continue; }
  wt_top=$(physical_path "$wt_top") || { unreadable_row "$label" "-" "cannot resolve its top level"; continue; }
  [ "$wt_top" = "$wt_real" ] \
    || { unreadable_row "$label" "-" "git resolves it to another working tree"; continue; }
  worktrees=$((worktrees+1))
  paths=$(submodule_paths "$wt") || { unreadable_row "$label" "-" "cannot list its submodules"; continue; }
  seen_dirs=''
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rc=0; locate_submodule "$wt_real" "$path" || rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *) unreadable_row "$label" "$path" "$SUB_WHY"; continue ;;
    esac
    # A populated submodule has its own .git entry; an unpopulated one holds nothing.
    # A directory with content but no usable .git is a broken checkout, not an empty one.
    if [ ! -e "$SUB_DIR/.git" ]; then
      content=$(ls -A "$SUB_DIR" 2>/dev/null) \
        || { unreadable_row "$label" "$path" "cannot list the directory"; continue; }
      [ -z "$content" ] || unreadable_row "$label" "$path" "holds files but no git directory"
      continue
    fi
    # Two spellings of one directory (`sub` and `sub/`, or another letter case) are one entry.
    sub_real=$(physical_path "$SUB_DIR") \
      || { unreadable_row "$label" "$path" "cannot resolve the directory"; continue; }
    case "$seen_dirs" in *$'\n'"$sub_real"$'\n'*) continue ;; esac
    seen_dirs="$seen_dirs"$'\n'"$sub_real"$'\n'
    classify_entry "$label" "$path" "$SUB_DIR"
  done <<< "$paths"
done

printf 'CHECKED\tworktrees=%s\tentries=%s\tmodified=%s\tnested=%s\tuntracked=%s\tunpushed=%s\tlocal_only=%s\tignored=%s\tclean=%s\tbelow_min_idle=%s\tskipped=%s\tunreadable=%s\n' \
  "$worktrees" "$entries" "$n_modified" "$n_nested" "$n_untracked" "$n_unpushed" "$n_local_only" \
  "$n_ignored" "$n_clean" "$below_age" "$skipped" "$unreadable"
[ "$unreadable" -eq 0 ] || exit 2
# A root holding no worktree is far more likely the wrong directory than an empty lane.
[ "$worktrees" -gt 0 ] || die "no worktree found under $ROOT"
exit 0
