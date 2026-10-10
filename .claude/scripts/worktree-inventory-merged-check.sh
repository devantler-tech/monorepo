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
#   merged-ancestor  no pull request has this commit as its head, but one that was merged
#                  into this repository's default branch contains it, and GitHub's own
#                  comparison shows the commit is an ancestor of the head that merged:
#                  the pull request moved on from this commit and then merged with it
#                  in its history, so what the branch kept of it reached the default
#                  branch. A later commit of that branch may have changed or undone it:
#                  that was the branch's own reviewed outcome, not work left behind
#   github-bot     GitHub has the commit, no pull request has it as its head, and GitHub
#                  itself signed it for one of the bots that work here, its only author:
#                  it was made on GitHub, never on this machine, so there is no local
#                  work in it to rescue. This is NOT proof that the change reached the
#                  default branch, and it is never counted as merged. Where the entry
#                  holds more commits below this one, each of them must be `github-bot`,
#                  `merged` or `merged-ancestor` too, or the verdict stays `no-pr` or
#                  `other-head`. The author's name and email are never the evidence:
#                  anyone can set those locally. GitHub's signature cannot be made here
#   no-pr          GitHub has the commit, and no pull request contains it
#   not-on-github  GitHub does not have the commit: it exists only on this machine
#   not-checked    not looked up: the repository is outside devantler-tech, or its origin
#                  is not a GitHub repository
# A `local-only` entry is always `not-checked`: its HEAD is pushed, and the commits it
# holds sit on other local branches, stashes or the reflog. It is listed so that it is
# never mistaken for a checked entry.
#
# When the inventory ran with --tips, it names those commits, and each TIP row of an
# `unpushed` or `local-only` entry gets its own row after the entry's:
#   TIP-CHECK <worktree> <submodule> <verdict> tip=<sha> kind=<kind> ref=<name|-> repo=<owner/name|-> pr=<n|->
#             commits=<n>
# with the verdicts above, read for that tip instead of HEAD, and one more:
#   stash          a stash entry: changes someone set aside. It is never a pull request's
#                  head, so it is not looked up and needs a person to read it
#   pushed-ref     a `kind=ref` tip (a tag, mostly) that GitHub holds under the same name
#                  at the same commit: it was never local-only, only outside every branch
# An entry's commits away from HEAD need no rescue only when EVERY one of its tips is
# `merged`, `merged-ancestor`, `github-bot` or `pushed-ref`. `no-pr` and `other-head` say GitHub has the commit object, not
# that anything there still keeps it. Tips of entries in other classes are counted, not
# looked up.
#
# With --content-reference <checkout>, every row whose verdict leaves the commit unsettled
# (`other-head`, `no-pr`, `not-on-github`, `closed`, `merged-other-base`) is followed by a
# local comparison with the default branch as that checkout's own copy of the repository
# last fetched it. Squash-merge leaves no graph link, and a branch that moved after its
# pull request merged has no pull request at its head, so the lookup above cannot settle
# these; the change itself can. <checkout> is a checkout of the same superproject (the
# shared one, usually): the repository compared against is the one at the entry's own
# submodule path inside it. Nothing is fetched and nothing is written to either repository.
#   CONTENT-CHECK <worktree> <submodule> <verdict> commit=<sha> base=<sha|-> same_as=<sha|->
#   reached        the default branch at `base=` already contains this very commit
#   no-change      the commit's files are identical to those at the point it left the
#                  default branch: it holds no change at all
#   same-change    one commit on the default branch's first-parent line since that point
#                  (`same_as=`) makes exactly the change this commit's line makes since
#                  it: the work was merged as that commit
#   clean-merge    a merge of two parents that git makes again exactly from them, so it
#                  adds no change of its own, and each parent is either contained in
#                  the default branch or is the head, or in the history, of a pull
#                  request that was merged there. A merge someone resolved by hand,
#                  or one with a parent nothing settles, stays `differs`
#   differs        none of the above. Not proof of anything: the default branch may hold
#                  the work in another shape, or not at all
#   no-reference   the checkout holds no copy of this repository at that path
# `reached`, `no-change`, `same-change` and `clean-merge` say the commit's content needs no rescue.
# A reference that was fetched long ago can only turn those into `differs`.
#
# Only `merged`, `merged-ancestor` or `github-bot` with other_local=0 says the entry's commits need no rescue. Every other
# row means: do not treat the entry as disposable on this evidence.
#
# Exit codes: 0 every `unpushed` entry and every looked-up tip got a verdict; 2 usage error, an inventory that is
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
# A `github-bot` commit with more unpushed commits than this below it is not walked.
BOT_RANGE=10

die() { printf 'worktree-inventory-merged-check: %s\n' "$1" >&2; exit 2; }

USAGE="usage: worktree-inventory-merged-check.sh <worktree-root> [--content-reference <checkout>] < inventory-output"
case "${1:-}" in
  -h|--help) sed -n '2,/^set -euo pipefail$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
  -*) die "unknown option: $1" ;;
esac
REFERENCE=''
case $# in
  1) ;;
  3) [ "$2" = --content-reference ] || die "$USAGE"
     [ -d "$3" ] || die "not a directory: $3"
     REFERENCE=$(cd "$3" 2>/dev/null && /bin/pwd -P) || die "cannot resolve the reference checkout" ;;
  *) die "$USAGE" ;;
esac
[ -d "$1" ] || die "not a directory: $1"
ROOT=$(cd "$1" 2>/dev/null && /bin/pwd -P) || die "cannot resolve the worktree root"
command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
CACHE_FILE=$(mktemp) || die "cannot create a temporary file"
PATCH_DIR=$(mktemp -d) || { rm -f "$CACHE_FILE"; die "cannot create a temporary directory"; }
merged_check_finished=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -f "$CACHE_FILE"
  rm -rf "$PATCH_DIR"
  if [ "$merged_check_finished" != 1 ] && [ "$status" = 0 ]; then status=2; fi
  exit "$status"
}
trap on_exit EXIT

n_merged=0; n_ancestor=0; n_bot=0; n_otherbase=0; n_open=0; n_closed=0; n_other=0; n_nopr=0; n_absent=0; n_notchecked=0
unknown=0; other_rows=0; saw_checked=0; bad_input=0
rows_tip=0; t_merged=0; t_ancestor=0; t_bot=0; t_settled=0; t_unsettled=0; t_skipped=0
# The entry the following TIP rows belong to: its state is one of `none` (no entry yet),
# `skip` (another class: its tips are counted only), `unknown` (the entry got an UNKNOWN
# row, which already covers its tips), `outside` (not a devantler-tech repository) or `ok`.
cur_state=none; cur_label=''; cur_path=''; cur_gdir=''; cur_repo=''; cur_head=''
cur_other=0; cur_tips=0; missing_tips=0

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

# is_ancestor <name> <sha> <head> -> 0 when GitHub's comparison shows <sha> is an ancestor of
# <head>, 1 when it shows it is not, 2 when the read failed or its answer
# cannot be trusted. The merge base of the two IS <sha> exactly when <sha> is an ancestor.
# `identical` is never accepted: it would mean <head> is <sha>, and then a pull request has
# <sha> as its head, which the caller has already ruled out.
is_ancestor() {
  local name=$1 sha=$2 head=$3 json answer
  case "$name" in ''|.|..|*/*) return 2 ;; esac
  json=$(gh api --hostname github.com "repos/$OWNER/$name/compare/$sha...$head" 2>/dev/null) || return 2
  answer=$(printf '%s' "$json" | jq -r --arg sha "$sha" '
    if (type != "object") or ((.merge_base_commit.sha | type) != "string")
       or ((.status | type) != "string") or ((.behind_by | type) != "number")
       or ((.ahead_by | type) != "number") then "unknown"
    elif .merge_base_commit.sha == $sha and .behind_by == 0 and .ahead_by > 0
         and .status == "ahead" then "yes"
    elif .merge_base_commit.sha != $sha and .behind_by > 0
         and (.status == "diverged" or .status == "behind") then "no"
    else "unknown"
    end' 2>/dev/null) || return 2
  case "$answer" in yes) return 0 ;; no) return 1 ;; *) return 2 ;; esac
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
          ... on Commit{
            author{ user{ login } } authors(first:2){ totalCount } signature{ isValid wasSignedByGitHub }
            associatedPullRequests(first:$n){ totalCount nodes{ number state headRefOid baseRefName baseRepository{ nameWithOwner } } } }
        }}}' 2>/dev/null) || return 1
  # Every shape is matched positively. A missing repository, an error body or a list cut
  # short yields no verdict, never `no-pr`.
  answer=$(printf '%s' "$json" | jq -r --arg sha "$sha" --arg repo "$OWNER/$name" '
    if (has("errors")) or (.data.repository == null) or (.data.repository | has("object") | not)
       or ((.data.repository.defaultBranchRef.name | type) != "string") then empty
    elif .data.repository.object == null then "not-on-github -"
    elif .data.repository.object.__typename != "Commit" then empty
    else .data.repository.defaultBranchRef.name as $default
      # Made on GitHub by a bot: GitHub signed it and the bot is its only author. A field
      # that is missing or has another shape reads as "not shown", never as a bot commit.
      | (.data.repository.object as $c
         | ($c.signature.isValid == true) and ($c.signature.wasSignedByGitHub == true)
           and ($c.authors.totalCount == 1)
           and (($c.author.user.login // "") as $l
                | ["dependabot[bot]", "github-actions[bot]", "ksail-bot[bot]", "renovate[bot]"] | index($l) != null)) as $bot
      | .data.repository.object.associatedPullRequests as $p
      | if ($p.totalCount | type) != "number" or ($p.nodes | type) != "array"
           or $p.totalCount != ($p.nodes | length) then empty
        elif $p.totalCount == 0 then (if $bot then "github-bot -" else "no-pr -" end)
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
            else ($p.nodes | map(select(.state == "MERGED" and .baseRefName == $default
                         and ((.baseRepository.nameWithOwner // "") | ascii_downcase) == ($repo | ascii_downcase)))) as $anc
              | if ($anc | length) > 0
                then "ancestor\(if $bot then "-bot" else "" end)? \($p.nodes[0].number) \($anc | map("\(.number):\(.headRefOid)") | join(","))"
                else "\(if $bot then "github-bot" else "other-head" end) \($p.nodes[0].number)"
                end
            end
        end
    end' 2>/dev/null) || return 1
  # A pull request merged into the default branch contains the commit, at another head.
  # Whether the commit is in the history that merged is a second read; until one of them
  # proves it, the verdict stays `other-head`.
  case "$answer" in 'ancestor? '[0-9]*' '[0-9]*|'ancestor-bot? '[0-9]*' '[0-9]*)
    local first=${answer#*\? } list pair n h is unsure=0 fallback=other-head
    # What a bot made on GitHub is known whatever the comparisons below say.
    case "$answer" in ancestor-bot*) fallback=github-bot ;; esac
    list=${first#* }; first=${first%% *}
    case "$first" in ''|*[!0-9]*) return 1 ;; esac
    answer="$fallback $first"
    while [ -n "$list" ]; do
      pair=${list%%,*}
      case "$list" in *,*) list=${list#*,} ;; *) list='' ;; esac
      n=${pair%%:*}; h=${pair#*:}
      case "$n" in ''|*[!0-9]*) return 1 ;; esac
      [ ${#h} -eq 40 ] || return 1
      case "$h" in *[!0-9a-f]*) return 1 ;; esac
      is=0; is_ancestor "$name" "$sha" "$h" || is=$?
      case "$is" in
        0) answer="merged-ancestor $n"; break ;;
        1) ;;
        # An unreadable comparison settles nothing, and a later pull request may still prove it.
        *) unsure=1 ;;
      esac
    done
    # Nothing proved it, and one comparison could not be read: `other-head` would be a guess.
    case "$answer" in other-head\ *) [ "$unsure" = 0 ] || return 1 ;; esac ;;
  esac
  case "$answer" in
    'merged-ancestor '[0-9]*) ;;
    'merged '[0-9]*|'merged-other-base '[0-9]*|'open '[0-9]*|'closed '[0-9]*|'other-head '[0-9]*|'no-pr -'|'not-on-github -') ;;
    'github-bot '[0-9]*|'github-bot -') ;;
    *) return 1 ;;
  esac
  case "${answer#* }" in *[!0-9-]*) return 1 ;; esac
  printf '%s\n' "$answer"
}

# ref_held <name> <refname> <sha> -> 0 when GitHub holds that ref at that commit (an
# annotated tag counts by the commit it names), 1 when it does not, 2 when the read failed
# or its answer cannot be trusted.
ref_held() {
  local name=$1 ref=$2 sha=$3 json answer
  case "$ref" in refs/*) ;; *) return 1 ;; esac
  # shellcheck disable=SC2016 # $o, $r and $q are GraphQL variables.
  json=$(gh api graphql --hostname github.com -f o="$OWNER" -f r="$name" -f q="$ref" -f query='
    query($o:String!,$r:String!,$q:String!){
      repository(owner:$o,name:$r){
        ref(qualifiedName:$q){ target{ oid ... on Tag{ target{ oid } } } }
      }}' 2>/dev/null) || return 2
  answer=$(printf '%s' "$json" | jq -r --arg sha "$sha" '
    if (has("errors")) or (.data.repository == null) or (.data.repository | has("ref") | not) then "unknown"
    elif .data.repository.ref == null then "absent"
    elif ((.data.repository.ref.target.oid // "") == $sha)
         or ((.data.repository.ref.target.target.oid // "") == $sha) then "held"
    else "absent"
    end' 2>/dev/null) || return 2
  case "$answer" in held) return 0 ;; absent) return 1 ;; *) return 2 ;; esac
}

count_verdict() {
  case "$1" in
    merged)        n_merged=$((n_merged+1)) ;;
    merged-ancestor) n_ancestor=$((n_ancestor+1)) ;;
    github-bot)    n_bot=$((n_bot+1)) ;;
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
  DIR=''; WHY=''
  case "$1" in ''|*/*|.|..) WHY="not a worktree name"; return 1 ;; esac
  case "$2" in ''|/*) WHY="the path does not stay inside the worktree"; return 1 ;; esac
  walk "$ROOT" "$1/$2"
}

# walk <root> <relative-path> -> the same walk below any root: sets DIR, or returns 1 with
# WHY set.
walk() {
  local cur=$1 rest=$2 comp
  DIR=''; WHY=''
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

# --- content comparison (--content-reference) ---------------------------------------------
# Both sides of a comparison are printed with the same options, so the two patch ids are
# comparable, and no program the repository configures (an external diff, a text conversion,
# a signature check) is run. `--binary --full-index` makes a binary file's content part of
# the id, and `patch-id --verbatim` keeps whitespace in it: two changes that differ only in
# indentation are different changes.
DIFF_OPTS=(--no-ext-diff --no-textconv --no-renames --no-color --binary --full-index)
c_reached=0; c_same=0; c_empty=0; c_clean=0; c_differs=0; c_noref=0
# The current entry's reference: `unset` until first needed, then `none` (the checkout has
# no copy of this repository there), `fail` (it has one that cannot be read) or `ok`.
cur_refstate='unset'; cur_base=''; cur_alt=''

# gitc — git on the entry's repository, also reading the reference's objects. The
# reference's default branch is usually newer than anything the entry has fetched.
gitc() { GIT_ALTERNATE_OBJECT_DIRECTORIES="$cur_alt" git --git-dir="$cur_gdir" "$@"; }

resolve_reference() {
  local rdir rrepo head objs
  cur_refstate=none; cur_base=''; cur_alt=''
  walk "$REFERENCE" "$cur_path" || return 0
  rdir=$DIR
  rrepo=$(origin_repo "$rdir") || { cur_refstate=fail; return 0; }
  [ "$rrepo" = "$cur_repo" ] || return 0
  cur_refstate=fail
  head=$(git -C "$rdir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || return 0
  case "$head" in refs/remotes/origin/?*) ;; *) return 0 ;; esac
  cur_base=$(git -C "$rdir" rev-parse --verify --quiet "$head^{commit}" 2>/dev/null) || return 0
  objs=$(git -C "$rdir" rev-parse --path-format=absolute --git-path objects 2>/dev/null) || return 0
  # The object directories are passed as a colon-separated list.
  case "$objs" in /*) ;; *) return 0 ;; esac
  case "$objs" in *:*|*'"'*) return 0 ;; esac
  [ -d "$objs" ] || return 0
  cur_alt=$objs; cur_refstate=ok
}

# default_branch_ids <fork-point> -> prints the file holding `<patch-id> <commit>` for every
# first-parent commit of the default branch after the fork point (a merge commit counts by
# what it brought in). Read once per fork point and base.
default_branch_ids() {
  local f="$PATCH_DIR/$1-$cur_base"
  if [ ! -f "$f" ]; then
    gitc log --no-show-signature --first-parent --diff-merges=first-parent -p "${DIFF_OPTS[@]}" --format='commit %H' "$1..$cur_base" 2>/dev/null \
      | git patch-id --verbatim > "$f.tmp" 2>/dev/null || { rm -f "$f.tmp"; return 1; }
    mv "$f.tmp" "$f" || return 1
  fi
  printf '%s\n' "$f"
}

content_row() { # worktree submodule verdict sha base same-as
  case "$3" in
    reached)      c_reached=$((c_reached+1)) ;;
    same-change)  c_same=$((c_same+1)) ;;
    no-change)    c_empty=$((c_empty+1)) ;;
    clean-merge)  c_clean=$((c_clean+1)) ;;
    differs)      c_differs=$((c_differs+1)) ;;
    no-reference) c_noref=$((c_noref+1)) ;;
  esac
  printf 'CONTENT-CHECK\t%s\t%s\t%s\tcommit=%s\tbase=%s\tsame_as=%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

# clean_merge <sha> — 0 when the commit is a merge of two parents that git reproduces
# exactly from them, so it adds no change of its own, and neither parent needs a rescue:
# the default branch contains it, or a pull request that has it as its head or in its
# history was merged there. 1 when not; 2 when a read failed.
# The merge is made again in a scratch object directory, so nothing is written to the
# entry's repository. A merge driver is a program the repository configures: where one
# is configured, no merge is made and the commit stays `differs`.
clean_merge() {
  local line p1 p2 rest tree objs scratch auto rc p hit
  line=$(gitc rev-list --no-walk --parents "$1" 2>/dev/null) || return 2
  p1=''; p2=''; rest=''
  read -r _ p1 p2 rest <<<"$line" || return 2
  [ -n "$p2" ] && [ -z "$rest" ] || return 1
  tree=$(gitc rev-parse --verify --quiet "$1^{tree}" 2>/dev/null) || return 2
  rc=0; gitc config --get-regexp '^merge\..*\.driver$' >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) return 1 ;; 1) ;; *) return 2 ;; esac
  rc=0; gitc merge-base "$p1" "$p2" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  objs=$(git --git-dir="$cur_gdir" rev-parse --path-format=absolute --git-path objects 2>/dev/null) || return 2
  case "$objs" in /*) ;; *) return 2 ;; esac
  case "$objs" in *:*|*'"'*) return 2 ;; esac
  scratch="$PATCH_DIR/merge-objects"
  mkdir -p "$scratch" || return 2
  rc=0
  auto=$(GIT_OBJECT_DIRECTORY="$scratch" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objs${cur_alt:+:$cur_alt}" \
    git --git-dir="$cur_gdir" -c merge.renormalize=false merge-tree --write-tree --no-messages "$p1" "$p2" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    # The two parents conflict: whoever made the merge resolved it by hand.
    1) return 1 ;;
    *) return 2 ;;
  esac
  [ "$auto" = "$tree" ] || return 1
  for p in "$p1" "$p2"; do
    rc=0; gitc merge-base --is-ancestor "$p" "$cur_base" 2>/dev/null || rc=$?
    case "$rc" in 0) continue ;; 1) ;; *) return 2 ;; esac
    hit=$(cached_lookup "$cur_repo" "$p") || return 2
    case "${hit% *}" in merged|merged-ancestor) ;; *) return 1 ;; esac
  done
  return 0
}

# differs_or_clean_merge <sha> — the row for a commit no comparison settled.
differs_or_clean_merge() {
  local rc=0
  clean_merge "$1" || rc=$?
  case "$rc" in
    0) content_row "$cur_label" "$cur_path" clean-merge "$1" "$cur_base" - ;;
    1) content_row "$cur_label" "$cur_path" differs "$1" "$cur_base" - ;;
    *) unknown_row "$cur_label" "$cur_path" "cannot read a merge commit's parents" ;;
  esac
}

# content_check <verdict> <sha> — compare one unsettled commit of the current entry.
content_check() {
  local sha=$2 rc fork tree_a tree_b pid ids same
  [ -n "$REFERENCE" ] || return 0
  case "$1" in other-head|no-pr|not-on-github|closed|merged-other-base) ;; *) return 0 ;; esac
  [ "$cur_refstate" != unset ] || resolve_reference
  case "$cur_refstate" in
    none) content_row "$cur_label" "$cur_path" no-reference "$sha" - -; return 0 ;;
    ok) ;;
    *) unknown_row "$cur_label" "$cur_path" "cannot read the default branch in the reference checkout"; return 0 ;;
  esac
  rc=0; gitc merge-base --is-ancestor "$sha" "$cur_base" 2>/dev/null || rc=$?
  case "$rc" in
    0) content_row "$cur_label" "$cur_path" reached "$sha" "$cur_base" -; return 0 ;;
    1) ;;
    *) unknown_row "$cur_label" "$cur_path" "cannot compare a commit with the default branch"; return 0 ;;
  esac
  rc=0; fork=$(gitc merge-base "$cur_base" "$sha" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    # No shared history with the default branch at all.
    1) content_row "$cur_label" "$cur_path" differs "$sha" "$cur_base" -; return 0 ;;
    *) unknown_row "$cur_label" "$cur_path" "cannot compare a commit with the default branch"; return 0 ;;
  esac
  tree_a=$(gitc rev-parse --verify --quiet "$fork^{tree}" 2>/dev/null) \
    || { unknown_row "$cur_label" "$cur_path" "cannot compare a commit with the default branch"; return 0; }
  tree_b=$(gitc rev-parse --verify --quiet "$sha^{tree}" 2>/dev/null) \
    || { unknown_row "$cur_label" "$cur_path" "cannot compare a commit with the default branch"; return 0; }
  if [ "$tree_a" = "$tree_b" ]; then content_row "$cur_label" "$cur_path" no-change "$sha" "$cur_base" -; return 0; fi
  pid=$(gitc diff "${DIFF_OPTS[@]}" "$fork" "$sha" 2>/dev/null | git patch-id --verbatim 2>/dev/null) \
    || { unknown_row "$cur_label" "$cur_path" "cannot compare a commit with the default branch"; return 0; }
  pid=${pid%% *}
  # The files differ, so an empty or malformed id is a failed read, never "no change".
  [ ${#pid} -eq 40 ] || { unknown_row "$cur_label" "$cur_path" "cannot compare a commit with the default branch"; return 0; }
  case "$pid" in *[!0-9a-f]*) unknown_row "$cur_label" "$cur_path" "cannot compare a commit with the default branch"; return 0 ;; esac
  ids=$(default_branch_ids "$fork") \
    || { unknown_row "$cur_label" "$cur_path" "cannot read the default branch's commits in the reference checkout"; return 0; }
  same=$(awk -v p="$pid" '$1 == p && !done { print $2; done = 1 }' "$ids") \
    || { unknown_row "$cur_label" "$cur_path" "cannot compare a commit with the default branch"; return 0; }
  if [ -z "$same" ]; then differs_or_clean_merge "$sha"; return 0; fi
  [ ${#same} -eq 40 ] || { unknown_row "$cur_label" "$cur_path" "cannot compare a commit with the default branch"; return 0; }
  content_row "$cur_label" "$cur_path" same-change "$sha" "$cur_base" "$same"
}

# close_entry — an entry that holds commits away from HEAD must have named at least one tip
# when the inventory was asked for them; none means its TIP rows were lost on the way here.
close_entry() {
  case "$cur_state" in ok|outside|unknown|skip)
    if [ "$cur_other" -gt 0 ] && [ "$cur_tips" -eq 0 ]; then missing_tips=$((missing_tips+1)); fi ;;
  esac
}

# tip_row <label> <path> <verdict> <sha> <kind> <ref> <repo> <pr> <commits>
tip_row() {
  case "$3" in
    merged)     t_merged=$((t_merged+1)) ;;
    merged-ancestor) t_ancestor=$((t_ancestor+1)) ;;
    github-bot) t_bot=$((t_bot+1)) ;;
    pushed-ref) t_settled=$((t_settled+1)) ;;
    *)          t_unsettled=$((t_unsettled+1)) ;;
  esac
  printf 'TIP-CHECK\t%s\t%s\t%s\ttip=%s\tkind=%s\tref=%s\trepo=%s\tpr=%s\tcommits=%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

# check_tip <tip-line> — one TIP row of the current entry.
check_tip() {
  local t_label t_path tipf kindf reff comf t_rest sha kind ref n now hit held
  IFS=$'\t' read -r _ t_label t_path tipf kindf reff comf t_rest <<EOF_TIP
$1
EOF_TIP
  rows_tip=$((rows_tip+1))
  # A TIP row belongs to the ENTRY row right before it; anywhere else it describes nothing.
  if [ "$cur_state" = none ] || [ "$t_label" != "$cur_label" ] || [ "$t_path" != "$cur_path" ] \
     || [ -n "$t_rest" ] || [ "$cur_other" -eq 0 ]; then bad_input=1; return 0; fi
  cur_tips=$((cur_tips+1))
  sha=${tipf#tip=}; kind=${kindf#kind=}; ref=${reff#ref=}; n=${comf#commits=}
  case "$tipf$kindf$reff$comf" in "tip=${sha}kind=${kind}ref=${ref}commits=${n}") ;; *) bad_input=1; return 0 ;; esac
  [ ${#sha} -eq 40 ] || { bad_input=1; return 0; }
  case "$sha" in *[!0-9a-f]*) bad_input=1; return 0 ;; esac
  case "$kind" in branch|stash|ref|reflog) ;; *) bad_input=1; return 0 ;; esac
  case "$n" in ''|0*|*[!0-9]*) bad_input=1; return 0 ;; esac
  [ -n "$ref" ] || { bad_input=1; return 0; }
  case "$cur_state" in
    skip)    t_skipped=$((t_skipped+1)); return 0 ;;
    unknown) return 0 ;;
  esac
  # The entry's counts were re-read above; this ties the row to the commit it names.
  now=$(git --git-dir="$cur_gdir" rev-list --count "$sha" --not --remotes "$cur_head" 2>/dev/null) \
    || { unknown_row "$cur_label" "$cur_path" "cannot re-read a commit it holds away from HEAD"; return 0; }
  [ "$now" = "$n" ] || { unknown_row "$cur_label" "$cur_path" "a commit it holds away from HEAD changed since the inventory"; return 0; }
  if [ "$kind" = stash ]; then tip_row "$cur_label" "$cur_path" stash "$sha" "$kind" "$ref" - - "$n"; return 0; fi
  if [ "$cur_state" = outside ]; then tip_row "$cur_label" "$cur_path" not-checked "$sha" "$kind" "$ref" - - "$n"; return 0; fi
  if [ "$kind" = ref ]; then
    held=0; ref_held "${cur_repo#*/}" "$ref" "$sha" || held=$?
    case "$held" in
      0) tip_row "$cur_label" "$cur_path" pushed-ref "$sha" "$kind" "$ref" "$cur_repo" - "$n"; return 0 ;;
      1) ;;
      *) unknown_row "$cur_label" "$cur_path" "the ref lookup failed for a commit held away from HEAD"; return 0 ;;
    esac
  fi
  hit=$(cached_lookup "$cur_repo" "$sha") \
    || { unknown_row "$cur_label" "$cur_path" "the pull request lookup failed for a commit held away from HEAD"; return 0; }
  hit=$(bot_range "$cur_repo" "$sha" "$hit" "$n" "$cur_head") \
    || { unknown_row "$cur_label" "$cur_path" "the pull request lookup failed for a commit held away from HEAD"; return 0; }
  tip_row "$cur_label" "$cur_path" "${hit% *}" "$sha" "$kind" "$ref" "$cur_repo" "${hit#* }" "$n"
  content_check "${hit% *}" "$sha"
}

# cached_lookup <owner/name> <sha> -> lookup's answer, read once per repository and commit.
# The cache lives in a file because this runs in a command substitution.
cached_lookup() {
  local key="$1@$2" hit
  hit=$(awk -F'\t' -v k="$key" '$1 == k && !done { print $2; done = 1 }' "$CACHE_FILE") || return 1
  if [ -z "$hit" ]; then
    hit=$(lookup "${1#*/}" "$2") || return 1
    printf '%s\t%s\n' "$key" "$hit" >> "$CACHE_FILE" || return 1
  fi
  printf '%s\n' "$hit"
}

# bot_range <owner/name> <sha> <answer> <n> [<also-excluded>] -> prints the answer to use
# for the current entry. A `github-bot` answer speaks for one commit, and the entry holds
# <n> unpushed commits ending at it: the others may be anyone's. Each must be `github-bot`,
# `merged` or `merged-ancestor` itself, or the answer falls back to what it would have been
# without the rule. Non-zero when one of them cannot be read.
bot_range() {
  local repo=$1 sha=$2 hit=$3 n=$4 demoted list c other
  case "$hit" in 'github-bot '*) ;; *) printf '%s\n' "$hit"; return 0 ;; esac
  [ "$n" -gt 1 ] || { printf '%s\n' "$hit"; return 0; }
  case "${hit#* }" in -) demoted='no-pr -' ;; *) demoted="other-head ${hit#* }" ;; esac
  [ "$n" -le "$BOT_RANGE" ] || { printf '%s\n' "$demoted"; return 0; }
  list=$(git --git-dir="$cur_gdir" rev-list "$sha" --not --remotes ${5:+"$5"} 2>/dev/null) || return 1
  # The walk must be the very commits the row counted.
  [ "$(printf '%s\n' "$list" | grep -c .)" = "$n" ] || return 1
  for c in $list; do
    [ "$c" != "$sha" ] || continue
    [ ${#c} -eq 40 ] || return 1
    other=$(cached_lookup "$repo" "$c") || return 1
    case "${other% *}" in
      github-bot|merged|merged-ancestor) ;;
      *) printf '%s\n' "$demoted"; return 0 ;;
    esac
  done
  printf '%s\n' "$hit"
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
    CHECKED) close_entry; cur_state=none; saw_checked=1; checked_line=$line; continue ;;
    TIP) check_tip "$line"; continue ;;
    SKIP) continue ;;
    UNREADABLE) bad_input=1; continue ;;
    ENTRY) ;;
    *) bad_input=1; continue ;;
  esac
  rows_entry=$((rows_entry+1))
  close_entry
  cur_state=skip; cur_label=$label; cur_path=$path; cur_gdir=''; cur_repo=''; cur_head=''
  cur_other=0; cur_tips=0
  cur_refstate='unset'; cur_base=''; cur_alt=''
  # Every class can hold commits away from HEAD, so every row's counts place its TIP rows.
  e_unp=${unpf#unpushed=}; e_loc=${locf#local_only=}
  case "$e_unp" in 0?*) e_unp=x ;; esac; case "$e_loc" in 0?*) e_loc=x ;; esac
  case "$e_unp$e_loc" in ''|*[!0-9]*) ;; *) [ -z "$e_unp" ] || [ -z "$e_loc" ] || [ "$e_loc" -lt "$e_unp" ] || cur_other=$((e_loc - e_unp)) ;; esac
  case "$class" in
    unpushed)   rows_unpushed=$((rows_unpushed+1)) ;;
    local-only) rows_local=$((rows_local+1)) ;;
    modified|nested|untracked|ignored|clean) other_rows=$((other_rows+1)); continue ;;
    *) bad_input=1; continue ;;
  esac
  cur_state=unknown
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
  cur_gdir=$g_dir; cur_repo=$repo; cur_head=$sha
  case "$repo" in
    "$OWNER"/*) ;;
    *) cur_state=outside; count_verdict not-checked; row "$label" "$path" not-checked "$sha" - - "$other"; continue ;;
  esac
  cur_state=ok
  # HEAD is pushed: there is nothing to look up for it, only for the tips that follow.
  if [ "$class" = local-only ]; then
    count_verdict not-checked; row "$label" "$path" not-checked "$sha" - - "$other"; continue
  fi
  hit=$(cached_lookup "$repo" "$sha") || { cur_state=unknown; unknown_row "$label" "$path" "the pull request lookup failed"; continue; }
  hit=$(bot_range "$repo" "$sha" "$hit" "$unp") || { cur_state=unknown; unknown_row "$label" "$path" "the pull request lookup failed"; continue; }
  verdict=${hit% *}; pr=${hit#* }
  count_verdict "$verdict"
  row "$label" "$path" "$verdict" "$sha" "$repo" "$pr" "$other"
  content_check "$verdict" "$sha"
done

close_entry
# The tip totals are printed only when the inventory was asked for tips.
tip_totals=''
case "$checked_line" in *$'\t'tips=*)
  tip_totals=$'\t'"tips=$rows_tip"$'\t'"tips_merged=$t_merged"$'\t'"tips_merged_ancestor=$t_ancestor"$'\t'"tips_github_bot=$t_bot"$'\t'"tips_pushed_ref=$t_settled"$'\t'"tips_unsettled=$t_unsettled"$'\t'"tips_other_classes=$t_skipped" ;;
esac
# The content totals are printed only when a reference checkout was given.
[ -z "$REFERENCE" ] || tip_totals="$tip_totals"$'\t'"content_reached=$c_reached"$'\t'"content_same_change=$c_same"$'\t'"content_no_change=$c_empty"$'\t'"content_clean_merge=$c_clean"$'\t'"content_differs=$c_differs"$'\t'"content_no_reference=$c_noref"
printf 'CHECKED\tmerged=%s\tmerged_ancestor=%s\tgithub_bot=%s\tmerged_other_base=%s\topen=%s\tclosed=%s\tother_head=%s\tno_pr=%s\tnot_on_github=%s\tnot_checked=%s\tother_classes=%s\tunknown=%s%s\n' \
  "$n_merged" "$n_ancestor" "$n_bot" "$n_otherbase" "$n_open" "$n_closed" "$n_other" "$n_nopr" "$n_absent" "$n_notchecked" "$other_rows" "$unknown" "$tip_totals"
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
# With --tips the inventory counts its TIP rows; without it, none may appear at all.
case "$checked_line" in
  *$'\t'tips=*)
    c_tips=$(checked_field "$checked_line" tips) || no_totals
    [ "$c_tips" -eq "$rows_tip" ] || die "the TIP rows read do not match the inventory's own total: it is incomplete"
    [ "$missing_tips" -eq 0 ] || die "an entry holds commits away from HEAD but names none of them: the inventory is incomplete" ;;
  *) [ "$rows_tip" -eq 0 ] || die "TIP rows without the inventory's tips total: it is incomplete" ;;
esac
[ "$c_young" -eq 0 ] || printf 'NOTE\tthe inventory left out %s entries below its --min-idle-days\n' "$c_young"
merged_check_finished=1
[ "$unknown" -eq 0 ] || exit 2
exit 0
