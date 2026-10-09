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
#               other_local=<n>
# and a closing `CHECKED ...` line with the totals. `other_local=` counts the commits the
# entry holds AWAY from HEAD (other local branches, stashes, the reflog). No verdict covers
# them: a `merged` row with other_local above 0 still holds unexamined commits.
#
# Verdicts for an `unpushed` entry (HEAD is the commit that was looked up):
#   merged         a pull request whose head is this commit was merged into this
#                  repository's default branch: the commits reachable from HEAD are there in content
#   merged-other-base  such a pull request was merged, but into another branch or another
#                  repository (a stacked pull request, a fork): not proof the content reached the default branch
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
# Only `merged` with other_local=0 says the entry's commits need no rescue. Every other
# row means: do not treat the entry as disposable on this evidence.
#
# Exit codes: 0 every `unpushed` entry got a verdict; 2 usage error, an inventory that is
# incomplete (no CHECKED line or one that is not last, an UNREADABLE or malformed row, rows
# that disagree with the inventory's own totals, no worktree found), or an UNKNOWN row: a
# lookup failed, a path is not a plain directory under the root, or the entry no longer
# matches its row (HEAD, its commit counts or its working tree changed since the
# inventory). Nothing is claimed about an UNKNOWN entry. A `NOTE` row says how many entries
# the inventory left out with --min-idle-days: those were not checked at all.
set -euo pipefail

export GIT_OPTIONAL_LOCKS=0
# An inherited location variable would point the origin read at the caller's repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_NAMESPACE
# An inherited host or repository override would send the lookup somewhere else.
unset GH_HOST GH_REPO

OWNER='devantler-tech'
# More associated pull requests than this in one answer means the list may be cut short.
PR_PAGE=50

die() { printf 'worktree-inventory-merged-check: %s\n' "$1" >&2; exit 2; }

[ $# -eq 1 ] || die "usage: worktree-inventory-merged-check.sh <worktree-root> < inventory-output"
case "$1" in
  -h|--help) sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) die "unknown option: $1" ;;
esac
[ -d "$1" ] || die "not a directory: $1"
ROOT=$(cd "$1" 2>/dev/null && /bin/pwd -P) || die "cannot resolve the worktree root"
command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

n_merged=0; n_otherbase=0; n_open=0; n_closed=0; n_other=0; n_nopr=0; n_absent=0; n_notchecked=0
unknown=0; other_rows=0; saw_checked=0; bad_input=0
cache=''

row() { # worktree submodule verdict sha repo pr other-local
  printf 'MERGE-CHECK\t%s\t%s\t%s\thead=%s\trepo=%s\tpr=%s\tother_local=%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

unknown_row() { # worktree submodule why
  unknown=$((unknown+1))
  printf 'UNKNOWN\t%s\t%s\t%s\n' "$1" "$2" "$3"
}

# origin_repo <dir> -> prints `<owner>/<name>` for a github.com origin, or nothing when the
# origin is not a GitHub repository. Non-zero when the origin cannot be read at all.
origin_repo() {
  local url rest top real
  # `git -C` on a directory whose own .git is broken answers for the PARENT repository,
  # whose origin is another repository. Require git to name this directory.
  real=$(cd "$1" 2>/dev/null && /bin/pwd -P) || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd "$top" 2>/dev/null && /bin/pwd -P) || return 1
  [ "$top" = "$real" ] || return 1
  url=$(git -C "$1" config --local --get remote.origin.url 2>/dev/null) || return 1
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
  json=$(gh api graphql --hostname github.com -f o="$OWNER" -f r="$name" -f sha="$sha" -F n="$PR_PAGE" -f query='
    query($o:String!,$r:String!,$sha:GitObjectID!,$n:Int!){
      repository(owner:$o,name:$r){
        defaultBranchRef{ name }
        object(oid:$sha){
          __typename
          ... on Commit{ associatedPullRequests(first:$n){ totalCount nodes{ number state headRefOid baseRefName baseRepository{ nameWithOwner } } } }
        }}}' 2>/dev/null) || return 1
  # Every shape is matched positively. A missing repository, an error body or a list cut
  # short yields no verdict, never `no-pr`.
  answer=$(printf '%s' "$json" | jq -r --arg sha "$sha" --arg repo "$OWNER/$name" '
    if (has("errors")) or (.data.repository == null) or (.data.repository | has("object") | not)
       or ((.data.repository.defaultBranchRef.name | type) != "string") then empty
    elif .data.repository.object == null then "not-on-github -"
    elif .data.repository.object.__typename != "Commit" then empty
    else .data.repository.defaultBranchRef.name as $default
      | .data.repository.object.associatedPullRequests as $p
      | if ($p.totalCount | type) != "number" or ($p.nodes | type) != "array"
           or $p.totalCount != ($p.nodes | length) then empty
        elif $p.totalCount == 0 then "no-pr -"
        else ($p.nodes | map(select(.headRefOid == $sha))) as $at
          | ($at | map(select(.state == "MERGED" and .baseRefName == $default
                       and ((.baseRepository.nameWithOwner // "") | ascii_downcase) == ($repo | ascii_downcase)))) as $in
          | if   ($in | length) > 0 then "merged \($in[0].number)"
            elif ($at | map(select(.state == "MERGED")) | length) > 0
              then "merged-other-base \($at | map(select(.state == "MERGED")) | .[0].number)"
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
    'merged '[0-9]*|'merged-other-base '[0-9]*|'open '[0-9]*|'closed '[0-9]*|'other-head '[0-9]*|'no-pr -'|'not-on-github -') ;;
    *) return 1 ;;
  esac
  case "${answer#* }" in *[!0-9-]*) return 1 ;; esac
  printf '%s\n' "$answer"
}

count_verdict() {
  case "$1" in
    merged)        n_merged=$((n_merged+1)) ;;
    merged-other-base) n_otherbase=$((n_otherbase+1)) ;;
    open)          n_open=$((n_open+1)) ;;
    closed)        n_closed=$((n_closed+1)) ;;
    other-head)    n_other=$((n_other+1)) ;;
    no-pr)         n_nopr=$((n_nopr+1)) ;;
    not-on-github) n_absent=$((n_absent+1)) ;;
    not-checked)   n_notchecked=$((n_notchecked+1)) ;;
  esac
}

# locate <label> <path> -> sets DIR to the submodule directory, or returns 1 with WHY set.
# The rows are data: every component must be a real directory below the root, because a
# symbolic link could lead to a repository outside it.
locate() {
  local cur=$ROOT rest="$1/$2" comp
  DIR=''; WHY=''
  case "$1" in ''|*/*|.|..) WHY="not a worktree name"; return 1 ;; esac
  case "$2" in ''|/*) WHY="the path does not stay inside the worktree"; return 1 ;; esac
  while [ -n "$rest" ]; do
    comp=${rest%%/*}
    case "$rest" in */*) rest=${rest#*/} ;; *) rest='' ;; esac
    case "$comp" in
      '') continue ;;
      .|..) WHY="the path does not stay inside the worktree"; return 1 ;;
    esac
    cur="$cur/$comp"
    if [ -L "$cur" ]; then WHY="a path component is a symbolic link"; return 1; fi
    if [ ! -d "$cur" ]; then WHY="no repository at that path under this root"; return 1; fi
  done
  if [ -L "$cur/.git" ]; then WHY="a path component is a symbolic link"; return 1; fi
  if [ ! -e "$cur/.git" ]; then WHY="no repository at that path under this root"; return 1; fi
  DIR=$cur
}

# checked_field <CHECKED-line> <key> -> prints the key's value; non-zero unless it is a number.
checked_field() {
  local v
  v=$(printf '%s\n' "$1" | tr '\t' '\n' | awk -F= -v k="$2" '$1 == k { print $2 }')
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$v"
}

rows_entry=0; rows_unpushed=0; rows_local=0; checked_line=''
# `|| [ -n "$line" ]`: a last row with no trailing newline is still a row.
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  # Nothing may follow the inventory's closing line: rows after it were never counted by it.
  if [ "$saw_checked" != 0 ]; then bad_input=1; continue; fi
  # Split on single tabs. `read` alone would drop a leading tab and shift every field.
  case "$line" in $'\t'*|*$'\t\t'*) bad_input=1; continue ;; esac
  IFS=$'\t' read -r kind label path class _idle headf unpf locf _rest <<EOF_ROW
$line
EOF_ROW
  case "$kind" in
    CHECKED) saw_checked=1; checked_line=$line; continue ;;
    SKIP) continue ;;
    UNREADABLE) bad_input=1; continue ;;
    ENTRY) ;;
    *) bad_input=1; continue ;;
  esac
  rows_entry=$((rows_entry+1))
  case "$class" in
    unpushed)   rows_unpushed=$((rows_unpushed+1)) ;;
    local-only) rows_local=$((rows_local+1)) ;;
    modified|nested|untracked|ignored|clean) other_rows=$((other_rows+1)); continue ;;
    *) bad_input=1; continue ;;
  esac
  sha=${headf#head=}
  if [ "$sha" = "$headf" ] || [ ${#sha} -ne 40 ]; then unknown_row "$label" "$path" "the row carries no full head commit"; continue; fi
  case "$sha" in *[!0-9a-f]*) unknown_row "$label" "$path" "the row carries no full head commit"; continue ;; esac
  unp=${unpf#unpushed=}; loc=${locf#local_only=}
  case "$unpf$locf" in "unpushed=${unp}local_only=${loc}") ;; *) unknown_row "$label" "$path" "the row carries no commit counts"; continue ;; esac
  # A leading zero would be read as octal by the arithmetic below.
  case "$unp" in 0?*) unp=x ;; esac; case "$loc" in 0?*) loc=x ;; esac
  case "$unp$loc" in ''|*[!0-9]*) unknown_row "$label" "$path" "the row carries no commit counts"; continue ;; esac
  [ -n "$unp" ] && [ -n "$loc" ] && [ "$loc" -ge "$unp" ] \
    || { unknown_row "$label" "$path" "the row carries no commit counts"; continue; }
  # Commits held away from HEAD (other branches, stashes, the reflog): no verdict covers them.
  other=$((loc - unp))
  if [ "$class" = local-only ]; then
    count_verdict not-checked; row "$label" "$path" not-checked "$sha" - - "$other"; continue
  fi
  locate "$label" "$path" || { unknown_row "$label" "$path" "$WHY"; continue; }
  repo=$(origin_repo "$DIR") || { unknown_row "$label" "$path" "cannot read its origin"; continue; }
  # A saved or stale inventory names a commit the repository has since moved away from.
  now=$(git -C "$DIR" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) \
    || { unknown_row "$label" "$path" "cannot read its HEAD"; continue; }
  [ "$now" = "$sha" ] || { unknown_row "$label" "$path" "its HEAD moved since the inventory"; continue; }
  # HEAD can stand still while the entry changes: a new local branch, a stash, an edit.
  # Re-read what the row claims; any difference means the row no longer describes it.
  g_dir=$(git -C "$DIR" rev-parse --absolute-git-dir 2>/dev/null) \
    || { unknown_row "$label" "$path" "cannot find its git directory"; continue; }
  unp_now=$(git --git-dir="$g_dir" rev-list --count "$sha" --not --remotes 2>/dev/null) \
    || { unknown_row "$label" "$path" "cannot recount its commits"; continue; }
  loc_now=$(git --git-dir="$g_dir" rev-list --count --all --reflog --not --remotes 2>/dev/null) \
    || { unknown_row "$label" "$path" "cannot recount its commits"; continue; }
  dirty=$(git -C "$DIR" -c core.fsmonitor=false status --porcelain --untracked-files=all 2>&1) \
    || { unknown_row "$label" "$path" "cannot read its status"; continue; }
  [ "$unp_now" = "$unp" ] && [ "$loc_now" = "$loc" ] && [ -z "$dirty" ] \
    || { unknown_row "$label" "$path" "it changed since the inventory"; continue; }
  case "$repo" in
    "$OWNER"/*) name=${repo#*/} ;;
    *) count_verdict not-checked; row "$label" "$path" not-checked "$sha" - - "$other"; continue ;;
  esac
  key="$repo@$sha"
  hit=$(printf '%s' "$cache" | awk -F'\t' -v k="$key" '$1 == k && !done { print $2; done = 1 }')
  if [ -z "$hit" ]; then
    hit=$(lookup "$name" "$sha") || { unknown_row "$label" "$path" "the pull request lookup failed"; continue; }
    cache="$cache$key"$'\t'"$hit"$'\n'
  fi
  verdict=${hit% *}; pr=${hit#* }
  count_verdict "$verdict"
  row "$label" "$path" "$verdict" "$sha" "$repo" "$pr" "$other"
done

printf 'CHECKED\tmerged=%s\tmerged_other_base=%s\topen=%s\tclosed=%s\tother_head=%s\tno_pr=%s\tnot_on_github=%s\tnot_checked=%s\tother_classes=%s\tunknown=%s\n' \
  "$n_merged" "$n_otherbase" "$n_open" "$n_closed" "$n_other" "$n_nopr" "$n_absent" "$n_notchecked" "$other_rows" "$unknown"
[ "$saw_checked" = 1 ] || die "the inventory has no closing CHECKED line: it is incomplete"
[ "$bad_input" = 0 ] || die "the inventory holds an UNREADABLE, malformed or trailing row: it is incomplete"
# The closing line is the inventory's own account of what it printed. Rows lost on the way
# here, or an inventory that itself stopped short, show up as a disagreement with it.
no_totals() { die "the inventory's closing line carries no totals: it is incomplete"; }
c_wt=$(checked_field "$checked_line" worktrees) || no_totals
c_entries=$(checked_field "$checked_line" entries) || no_totals
c_unp=$(checked_field "$checked_line" unpushed) || no_totals
c_loc=$(checked_field "$checked_line" local_only) || no_totals
c_bad=$(checked_field "$checked_line" unreadable) || no_totals
c_young=$(checked_field "$checked_line" below_min_idle) || no_totals
[ "$c_wt" -gt 0 ] || die "the inventory found no worktree: wrong root, not an empty result"
[ "$c_bad" -eq 0 ] || die "the inventory reports unreadable entries: it is incomplete"
[ "$c_entries" -eq "$rows_entry" ] && [ "$c_unp" -eq "$rows_unpushed" ] && [ "$c_loc" -eq "$rows_local" ] \
  || die "the rows read do not match the inventory's own totals: it is incomplete"
# Entries the inventory left out for being too recently used were never checked here.
[ "$c_young" -eq 0 ] || printf 'NOTE\tthe inventory left out %s entries below its --min-idle-days\n' "$c_young"
[ "$unknown" -eq 0 ] || exit 2
exit 0
