#!/usr/bin/env bash
# consumer-census.sh — list every portfolio repository that uses a shared symbol (monorepo#4842).
#
# Why: a change to a shared surface (a `.github` reusable workflow or action, a KSail config key, a
# Kyverno policy name, a template variable, an agent-plugins contract section) reaches every consumer,
# but nothing listed the consumers when the change was made, so breaks surfaced late. The monorepo
# already aggregates every product as a submodule, so the census is local and free.
#
# For each submodule in `.gitmodules` it fetches the default branch's tip (the working tree may be
# stale) and searches that commit for SYMBOL as a fixed string. It never changes a working tree, an
# index or a branch; the only write is the fetched remote-tracking ref.
#
# The portfolio contract keeps archived repositories out of every census, so each submodule's archive
# state is read live first (one `gh api repos/<owner>/<repo>` call each): an archived repository is
# ARCHIVED and not searched, and one whose state cannot be read is UNKNOWN. Nothing else calls the
# GitHub API.
#
# Usage: consumer-census.sh [--root DIR] [--only PATH]... [--no-fetch] SYMBOL
#   --root DIR    the monorepo checkout whose `.gitmodules` lists the submodules (default: this one)
#   --only PATH   search only this submodule path (repeatable)
#   --no-fetch    search the already-fetched default-branch tip instead of fetching it first
#
# Output, one tab-separated line each:
#   HIT      <path> <file>:<line> <text>          a consumer (text cut at 200 characters)
#   NONE     <path> <branch>@<sha> control-passed  searched, no hit, and the control read the tree
#   UNKNOWN  <path> <reason>                       not populated, no remote, fetch or search failed
#   ARCHIVED <path> <owner>/<repo>                 archived on GitHub, so not part of the census
#   SUMMARY  hits=<n> repos-with-hits=<n> none=<n> archived=<n> unknown=<n>
# A zero count is only ever printed as NONE, after a control query (any text line in the same commit)
# proves the search actually read that tree; a repository that could not be searched is UNKNOWN.
#
# Exit codes: 0 every listed repository was searched · 2 at least one is UNKNOWN, or a usage error
set -euo pipefail

usage() { sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//' >&2; }

root=""
fetch=1
symbol=""
only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { usage; exit 2; }; root="$2"; shift 2 ;;
    --only) [ $# -ge 2 ] || { usage; exit 2; }; only+=("$2"); shift 2 ;;
    --no-fetch) fetch=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; [ $# -eq 1 ] || { usage; exit 2; }; symbol="$1"; shift ;;
    -*) echo "consumer-census: unknown option: $1" >&2; usage; exit 2 ;;
    *) [ -z "$symbol" ] || { echo "consumer-census: one SYMBOL only" >&2; exit 2; }; symbol="$1"; shift ;;
  esac
done
if [ -z "$symbol" ]; then
  echo "consumer-census: SYMBOL is required" >&2
  usage
  exit 2
fi
if [ -z "$root" ]; then
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
fi
root=$(cd "$root" 2>/dev/null && pwd -P) || { echo "consumer-census: cannot enter --root" >&2; exit 2; }
if [ ! -f "$root/.gitmodules" ]; then
  echo "consumer-census: no .gitmodules under $root" >&2
  exit 2
fi

if ! pathlines=$(git config -f "$root/.gitmodules" --get-regexp '^submodule\..*\.path$'); then
  echo "consumer-census: .gitmodules lists no submodule path" >&2
  exit 2
fi
paths=$(printf '%s\n' "$pathlines" | awk '{ print $2 }')
if [ "${#only[@]}" -gt 0 ]; then
  for want in "${only[@]}"; do
    if ! grep -qxF -- "$want" <<<"$paths"; then
      echo "consumer-census: --only $want is not a submodule path in .gitmodules" >&2
      exit 2
    fi
  done
  paths=$(printf '%s\n' "${only[@]}")
fi

hits=0
repos_with_hits=0
none=0
unknown=0
archived=0
unknown_line() { printf 'UNKNOWN\t%s\t%s\n' "$1" "$2"; unknown=$((unknown + 1)); }

# slug_for <path>: owner/repo from the submodule's .gitmodules URL, or nothing for a non-GitHub URL.
slug_for() {
  local key name url
  key=$(printf '%s\n' "$pathlines" | awk -v p="$1" '$2 == p && !found { print $1; found = 1 }')
  name=${key#submodule.}
  name=${name%.path}
  url=$(git config -f "$root/.gitmodules" --get "submodule.${name}.url" 2>/dev/null) || return 0
  url=${url%.git}
  case "$url" in
    git@github.com:*/*) printf '%s\n' "${url#git@github.com:}" ;;
    https://github.com/*/*) printf '%s\n' "${url#https://github.com/}" ;;
  esac
}

while IFS= read -r path; do
  [ -n "$path" ] || continue
  dir="$root/$path"
  # Archived repositories are outside every census (root AGENTS.md); an unreadable state is UNKNOWN.
  slug=$(slug_for "$path")
  if [ -z "$slug" ]; then
    unknown_line "$path" "archive state unknown: not a GitHub submodule URL"
    continue
  fi
  state=$(gh api "repos/${slug}" --jq .archived 2>/dev/null) || state=""
  case "$state" in
    true) printf 'ARCHIVED\t%s\t%s\n' "$path" "$slug"; archived=$((archived + 1)); continue ;;
    false) ;;
    *) unknown_line "$path" "archive state of ${slug} could not be read"; continue ;;
  esac
  # Populated = the directory is the top of its own work tree. An empty submodule directory
  # resolves to the monorepo itself, which would search the wrong repository.
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$(cd "$dir" && pwd -P)" ]; then
    unknown_line "$path" "not populated"
    continue
  fi
  if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    unknown_line "$path" "no origin remote"
    continue
  fi
  if [ "$fetch" -eq 1 ]; then
    if ! head_ref=$(git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null | awk '$1 == "ref:" && $3 == "HEAD" && !found { print $2; found = 1 }'); then
      head_ref=""
    fi
    branch=${head_ref#refs/heads/}
    if [ -z "$head_ref" ] || [ "$branch" = "$head_ref" ]; then
      unknown_line "$path" "cannot read the default branch from origin"
      continue
    fi
    if ! git -C "$dir" fetch --quiet --no-tags origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>/dev/null; then
      unknown_line "$path" "fetch of origin/${branch} failed"
      continue
    fi
  else
    head_ref=$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || head_ref="refs/remotes/origin/main"
    branch=${head_ref#refs/remotes/origin/}
  fi
  if ! rev=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/${branch}^{commit}"); then
    unknown_line "$path" "no fetched origin/${branch}"
    continue
  fi

  rc=0
  out=$(git -C "$dir" grep -n -I -F -e "$symbol" "$rev" -- 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ]; then
    n=0
    while IFS= read -r line; do
      line=${line#"$rev":}
      file=${line%%:*}
      rest=${line#*:}
      lineno=${rest%%:*}
      text=${rest#*:}
      printf 'HIT\t%s\t%s:%s\t%s\n' "$path" "$file" "$lineno" "${text:0:200}"
      n=$((n + 1))
    done <<EOF
$out
EOF
    hits=$((hits + n))
    repos_with_hits=$((repos_with_hits + 1))
  elif [ "$rc" -eq 1 ]; then
    # Control: the same search over the same commit with a pattern any text line matches. Without
    # it, a tree git could not read would look exactly like a tree with no consumers.
    if git -C "$dir" grep -q -I -e . "$rev" -- 2>/dev/null; then
      printf 'NONE\t%s\t%s@%s\tcontrol-passed\n' "$path" "$branch" "${rev:0:12}"
      none=$((none + 1))
    else
      unknown_line "$path" "control query found no text in ${branch}@${rev:0:12}"
    fi
  else
    unknown_line "$path" "search failed (git grep exit $rc)"
  fi
done <<EOF
$paths
EOF

printf 'SUMMARY\thits=%s\trepos-with-hits=%s\tnone=%s\tarchived=%s\tunknown=%s\n' "$hits" "$repos_with_hits" "$none" "$archived" "$unknown"
if [ "$unknown" -gt 0 ]; then
  exit 2
fi
exit 0
