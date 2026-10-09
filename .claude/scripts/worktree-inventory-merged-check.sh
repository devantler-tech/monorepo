#!/usr/bin/env bash
# worktree-inventory-merged-check.sh — for each `unpushed` entry of the per-submodule
# inventory, ask GitHub whether a pull request whose head is that commit was merged
# (monorepo#3072).
#
# WHY: every repository here squash-merges, so a branch whose pull request merged still
# reads as "unpushed commits" forever: no graph test can tell it from unfinished work. The
# only evidence is the pull request itself. worktree-submodule-inventory.sh prints the
# commit for exactly this lookup; this reads its rows and makes the lookup.
#
# It never writes: one read of each submodule's `remote.origin.url`, and one GraphQL read
# per distinct repository and commit. Nothing is fetched, removed or changed.
#
# Usage:
#   worktree-submodule-inventory.sh <worktree-root> | \
#     worktree-inventory-merged-check.sh <worktree-root>
#
#   <worktree-root>   the SAME root the inventory read; the rows name paths below it
#   stdin             the inventory's complete output, including its closing CHECKED line
#
# Output, tab-separated, one row per `unpushed` or `local-only` inventory entry:
#   MERGE-CHECK <worktree> <submodule> <verdict> head=<sha> repo=<owner/name|-> pr=<n|->
# and a closing `CHECKED ...` line with the totals.
#
# Verdicts for an `unpushed` entry (HEAD is the commit that was looked up):
#   merged         a pull request whose head is this commit was merged: the commits are in
#                  the default branch in content
#   open           a pull request whose head is this commit is open: work in flight
#   closed         a pull request whose head is this commit was closed without merging
#   other-head     GitHub has the commit and pull requests contain it, but none has it as
#                  its head (the pull request moved on, or was rebuilt). Not proof of
#                  anything: `pr=` names one to read
#   no-pr          GitHub has the commit, and no pull request contains it
#   not-on-github  GitHub does not have the commit: it exists only on this machine
#   not-checked    not looked up: the repository is outside devantler-tech, or its origin
#                  is not a GitHub repository
# A `local-only` entry is always `not-checked`: its HEAD is pushed, and the commits it
# holds sit on other local branches, stashes or the reflog, which the inventory does not
# name. It is listed so that it is never mistaken for a checked entry.
#
# Only `merged` says the commits need no rescue, and only for the commits reachable from
# that head. Every other verdict means: do not treat the entry as disposable on this
# evidence.
#
# Exit codes: 0 every `unpushed` entry got a verdict; 2 usage error, an inventory that is
# incomplete (no CHECKED line, an UNREADABLE row, a malformed row), or any lookup that
# failed (an UNKNOWN row: nothing is claimed about that entry).
set -euo pipefail

export GIT_OPTIONAL_LOCKS=0
# An inherited location variable would point the origin read at the caller's repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_NAMESPACE

OWNER='devantler-tech'
# More associated pull requests than this in one answer means the list may be cut short.
PR_PAGE=50

die() { printf 'worktree-inventory-merged-check: %s\n' "$1" >&2; exit 2; }

[ $# -eq 1 ] || die "usage: worktree-inventory-merged-check.sh <worktree-root> < inventory-output"
case "$1" in
  -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) die "unknown option: $1" ;;
esac
[ -d "$1" ] || die "not a directory: $1"
ROOT=$(cd "$1" 2>/dev/null && /bin/pwd -P) || die "cannot resolve the worktree root"
command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

n_merged=0; n_open=0; n_closed=0; n_other=0; n_nopr=0; n_absent=0; n_notchecked=0
unknown=0; other_rows=0; saw_checked=0; bad_input=0
cache=''

row() { # worktree submodule verdict sha repo pr
  printf 'MERGE-CHECK\t%s\t%s\t%s\thead=%s\trepo=%s\tpr=%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

unknown_row() { # worktree submodule why
  unknown=$((unknown+1))
  printf 'UNKNOWN\t%s\t%s\t%s\n' "$1" "$2" "$3"
}

# origin_repo <dir> -> prints `<owner>/<name>` for a github.com origin, or nothing when the
# origin is not a GitHub repository. Non-zero when the origin cannot be read at all.
origin_repo() {
  local url rest
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
  case "$url" in
    git@github.com:*)       rest=${url#git@github.com:} ;;
    ssh://git@github.com/*) rest=${url#ssh://git@github.com/} ;;
    https://github.com/*)   rest=${url#https://github.com/} ;;
    *) return 0 ;;
  esac
  rest=${rest%/}; rest=${rest%.git}
  case "$rest" in
    */*/*|/*|*/|'') return 0 ;;
    */*) ;;
    *) return 0 ;;
  esac
  case "$rest" in *[!A-Za-z0-9._/-]*) return 0 ;; esac
  printf '%s\n' "$rest"
}

# lookup <name> <sha> -> prints `<verdict> <pr|->`. Non-zero when the read failed or its
# answer cannot be trusted; nothing is printed then.
lookup() {
  local name=$1 sha=$2 json answer
  # shellcheck disable=SC2016 # $o, $r, $sha and $n are GraphQL variables.
  json=$(gh api graphql -f o="$OWNER" -f r="$name" -f sha="$sha" -F n="$PR_PAGE" -f query='
    query($o:String!,$r:String!,$sha:GitObjectID!,$n:Int!){
      repository(owner:$o,name:$r){
        object(oid:$sha){
          __typename
          ... on Commit{ associatedPullRequests(first:$n){ totalCount nodes{ number state headRefOid } } }
        }}}' 2>/dev/null) || return 1
  # Every shape is matched positively. A missing repository, an error body or a list cut
  # short yields no verdict, never `no-pr`.
  answer=$(printf '%s' "$json" | jq -r --arg sha "$sha" '
    if (has("errors")) or (.data.repository == null) then empty
    elif .data.repository.object == null then "not-on-github -"
    elif .data.repository.object.__typename != "Commit" then empty
    else .data.repository.object.associatedPullRequests as $p
      | if ($p.totalCount | type) != "number" or ($p.nodes | type) != "array"
           or $p.totalCount != ($p.nodes | length) then empty
        elif $p.totalCount == 0 then "no-pr -"
        else ($p.nodes | map(select(.headRefOid == $sha))) as $at
          | if   ($at | map(select(.state == "MERGED")) | length) > 0
              then "merged \($at | map(select(.state == "MERGED")) | .[0].number)"
            elif ($at | map(select(.state == "OPEN")) | length) > 0
              then "open \($at | map(select(.state == "OPEN")) | .[0].number)"
            elif ($at | map(select(.state == "CLOSED")) | length) > 0
              then "closed \($at | map(select(.state == "CLOSED")) | .[0].number)"
            elif ($at | length) > 0 then empty
            else "other-head \($p.nodes[0].number)"
            end
        end
    end' 2>/dev/null) || return 1
  case "$answer" in
    'merged '[0-9]*|'open '[0-9]*|'closed '[0-9]*|'other-head '[0-9]*|'no-pr -'|'not-on-github -') ;;
    *) return 1 ;;
  esac
  case "${answer#* }" in *[!0-9-]*) return 1 ;; esac
  printf '%s\n' "$answer"
}

count_verdict() {
  case "$1" in
    merged)        n_merged=$((n_merged+1)) ;;
    open)          n_open=$((n_open+1)) ;;
    closed)        n_closed=$((n_closed+1)) ;;
    other-head)    n_other=$((n_other+1)) ;;
    no-pr)         n_nopr=$((n_nopr+1)) ;;
    not-on-github) n_absent=$((n_absent+1)) ;;
    not-checked)   n_notchecked=$((n_notchecked+1)) ;;
  esac
}

while IFS=$'\t' read -r kind label path class _idle headf _rest; do
  case "$kind" in
    '') continue ;;
    CHECKED) saw_checked=1; continue ;;
    SKIP) continue ;;
    UNREADABLE) bad_input=1; continue ;;
    ENTRY) ;;
    *) bad_input=1; continue ;;
  esac
  case "$class" in
    unpushed|local-only) ;;
    modified|nested|untracked|ignored|clean) other_rows=$((other_rows+1)); continue ;;
    *) bad_input=1; continue ;;
  esac
  sha=${headf#head=}
  if [ "$sha" = "$headf" ] || [ ${#sha} -ne 40 ]; then unknown_row "$label" "$path" "the row carries no full head commit"; continue; fi
  case "$sha" in *[!0-9a-f]*) unknown_row "$label" "$path" "the row carries no full head commit"; continue ;; esac
  if [ "$class" = local-only ]; then
    count_verdict not-checked; row "$label" "$path" not-checked "$sha" - -; continue
  fi
  # The rows are data: refuse a name that would read a directory outside the root.
  case "$label" in ''|*/*|.|..) unknown_row "$label" "$path" "not a worktree name"; continue ;; esac
  case "/$path/" in *'/../'*|*'/./'*|'//'*) unknown_row "$label" "$path" "the path does not stay inside the worktree"; continue ;; esac
  dir="$ROOT/$label/$path"
  [ -d "$dir" ] && [ -e "$dir/.git" ] \
    || { unknown_row "$label" "$path" "no repository at that path under this root"; continue; }
  repo=$(origin_repo "$dir") || { unknown_row "$label" "$path" "cannot read its origin"; continue; }
  case "$repo" in
    "$OWNER"/*) name=${repo#*/} ;;
    *) count_verdict not-checked; row "$label" "$path" not-checked "$sha" - -; continue ;;
  esac
  key="$repo@$sha"
  hit=$(printf '%s' "$cache" | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }')
  if [ -z "$hit" ]; then
    hit=$(lookup "$name" "$sha") || { unknown_row "$label" "$path" "the pull request lookup failed"; continue; }
    cache="$cache$key"$'\t'"$hit"$'\n'
  fi
  verdict=${hit% *}; pr=${hit#* }
  count_verdict "$verdict"
  row "$label" "$path" "$verdict" "$sha" "$repo" "$pr"
done

printf 'CHECKED\tmerged=%s\topen=%s\tclosed=%s\tother_head=%s\tno_pr=%s\tnot_on_github=%s\tnot_checked=%s\tother_classes=%s\tunknown=%s\n' \
  "$n_merged" "$n_open" "$n_closed" "$n_other" "$n_nopr" "$n_absent" "$n_notchecked" "$other_rows" "$unknown"
[ "$saw_checked" = 1 ] || die "the inventory has no closing CHECKED line: it is incomplete"
[ "$bad_input" = 0 ] || die "the inventory holds an UNREADABLE or malformed row: it is incomplete"
[ "$unknown" -eq 0 ] || exit 2
exit 0
