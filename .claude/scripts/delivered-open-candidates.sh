#!/usr/bin/env bash
# delivered-open-candidates.sh — list open issues that a merged pull request may already have
# delivered (monorepo#2967). Older issues are especially likely to have shipped through a PR that said only
# `Part of #N` or a bare mention, which closes nothing. Every lane that descends to such an issue
# rebuilds finished work. The work-selection guide's *Completion check* asks a run to look for
# delivery before starting; this is the repeatable command behind that step.
#
# A TRIAGE SURFACE, NEVER AN AUTO-CLOSER. A merged reference is not delivery: an umbrella issue whose
# children each say `Part of #N` collects dozens of merged references while its residual is real and
# open (platform#2787 had 30). So the script reports the evidence a run needs to judge, and the run
# verifies each candidate's acceptance criteria against the default branch before closing anything.
#
# For each issue it prints one line:
#   <verdict> <owner/repo>#<n> state=<OPEN|CLOSED> merged=<k> open=<j> closing=<c> subissues=<done>/<total>
#   merged    distinct merged PRs that reference the issue (cross-reference or manual link)
#   open      distinct open PRs that reference it; any open PR means work is still in flight
#   closing   how many of those references GitHub marks as closing the issue (a closing keyword
#             or a manual link) — a merged closing reference on a still-open issue is the strongest
#             signal, since it normally closes the issue on merge
#   verdict   CANDIDATE-SINGLE  exactly one merged PR, none open — the platform#2972 shape
#             CANDIDATE-MULTI   several merged PRs, none open — often an umbrella; read closing=
#             NOT-CANDIDATE     no merged PR, or a PR is still open
#
# Usage:
#   delivered-open-candidates.sh --issue <owner/repo>#<n> [--issue ...]
#   delivered-open-candidates.sh --oldest <N> [--type <IssueType>]
#     --oldest reads the N oldest open issues across the devantler-tech organisation (non-archived
#     repositories only), optionally of one Issue Type, i.e. the head of a ladder rung.
#
# Exit codes:
#   0  every issue was read in full and none is a candidate
#   1  every issue was read in full and at least one is a candidate
#   2  UNKNOWN — usage error, a failed or truncated read; no verdict is printed for an issue whose
#      references could not be read completely, because a short read looks exactly like "no PR"
#   3  DEFERRED — the search budget ran out or the forge refused a search for rate reasons.
#      Completed verdicts remain usable; stderr provides a command for the unchecked issues.
#
# Each invocation spends at most one quarter (rounded down) of the search limit AND remaining
# allowance read at startup (monorepo#4100). The oldest-list lookup counts against that budget too.
# Concurrent users can still spend the allowance first; a refusal defers rather than retries.
#
# Read-only. Prints issue and PR numbers only, never titles or bodies (untrusted input).
#
# Test seam: when DELIVERED_OPEN_GH is set, it is run instead of `gh` for every API call, with the
# same arguments.
set -uo pipefail

ORG=devantler-tech
issues=()
oldest=""
type=""
original_args=("$@")
completed=0
listed_issues=0

progress() {
  if [ "$listed_issues" = 1 ]; then
    printf 'completed=%s remaining=%s\n' "$completed" "$((${#issues[@]} - completed))" >&2
  fi
}
unknown() { echo "delivered-open-candidates: UNKNOWN — $*" >&2; progress; exit 2; }
defer() {
  echo "delivered-open-candidates: DEFERRED — $*; retry after the search allowance recovers" >&2
  progress
  printf 'resume:' >&2
  printf ' %q' "$0" >&2
  if [ "$listed_issues" = 1 ]; then
    local i
    for ((i=completed; i<${#issues[@]}; i++)); do printf ' --issue %q' "${issues[$i]}" >&2; done
  else
    printf ' %q' "${original_args[@]}" >&2
  fi
  printf '\n' >&2
  exit 3
}
usage() { unknown "usage: --issue <owner/repo>#<n> ... | --oldest <N> [--type <IssueType>]"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      [ $# -ge 2 ] || usage
      [[ "$2" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$ ]] || unknown "--issue must be <owner/repo>#<n>, got '$2'"
      issues+=("$2"); shift 2 ;;
    --oldest)
      [ $# -ge 2 ] || usage
      [[ "$2" =~ ^[1-9][0-9]*$ ]] && [ "$2" -le 100 ] || unknown "--oldest must be 1..100, got '$2'"
      oldest="$2"; shift 2 ;;
    --type)
      [ $# -ge 2 ] || usage
      [[ "$2" =~ ^[A-Za-z]+$ ]] || unknown "--type must be an Issue Type name, got '$2'"
      type="$2"; shift 2 ;;
    *) usage ;;
  esac
done
if [ -n "$oldest" ]; then
  [ "${#issues[@]}" -eq 0 ] || unknown "--oldest and --issue are exclusive"
else
  [ "${#issues[@]}" -gt 0 ] || usage
  [ -z "$type" ] || unknown "--type needs --oldest"
  listed_issues=1
fi

gh_() { if [ -n "${DELIVERED_OPEN_GH:-}" ]; then "$DELIVERED_OPEN_GH" "$@"; else gh "$@"; fi; }

allowance=$(gh_ api rate_limit) || unknown "search allowance read failed"
budget=$(jq -ers 'select(length == 1) | .[0].resources.search | select(
  (.limit | type) == "number" and (.remaining | type) == "number" and
  .limit > 0 and .limit == (.limit | floor) and
  .remaining >= 0 and .remaining <= .limit and .remaining == (.remaining | floor))
  | [(.limit / 4 | floor), (.remaining / 4 | floor)] | min' <<<"$allowance") ||
  unknown "invalid search allowance"

# Run in the caller, not a command substitution: the budget must survive each search.
search_read() {
  [ "$budget" -gt 0 ] || defer "invocation search budget reached"
  budget=$((budget - 1))
  if ! search_result=$(gh_ api -X GET search/issues "$@" 2>&1); then
    case "$search_result" in
      *"rate limit"*|*"rate-limit"*|*"HTTP 429"*) defer "forge refused a search for rate reasons" ;;
      *) unknown "${ref:-issue list}: search read failed" ;;
    esac
  fi
}

if [ -n "$oldest" ]; then
  q="org:${ORG} is:issue is:open archived:false"
  [ -z "$type" ] || q="$q type:${type}"
  search_read -f q="$q" -f sort=created -f order=asc -f per_page="$oldest"
  search=$search_result
  listed=$(jq -r '.items[] | "\(.repository_url | split("/") | .[-2:] | join("/"))#\(.number)"' <<<"$search") ||
    unknown "issue search returned an unparseable payload"
  total=$(jq -r '.total_count' <<<"$search")
  incomplete=$(jq -r '.incomplete_results' <<<"$search")
  [ "$incomplete" = "false" ] || unknown "issue search reported incomplete results"
  want=$(( total < oldest ? total : oldest ))
  got=$(grep -c . <<<"$listed" || true)
  [ "$got" -eq "$want" ] || unknown "issue search returned $got of $want issues"
  while IFS= read -r ref; do [ -n "$ref" ] && issues+=("$ref"); done <<<"$listed"
  listed_issues=1
fi

# shellcheck disable=SC2016  # GraphQL variables, not shell expansions.
query='query($owner:String!,$name:String!,$number:Int!,$after:String){
  repository(owner:$owner,name:$name){
    issue(number:$number){
      state
      subIssuesSummary{total completed}
      timelineItems(itemTypes:[CROSS_REFERENCED_EVENT,CONNECTED_EVENT,REFERENCED_EVENT],first:100,after:$after){
        totalCount
        pageInfo{hasNextPage endCursor}
        nodes{
          __typename
          ... on CrossReferencedEvent{willCloseTarget source{__typename ... on PullRequest{number state repository{nameWithOwner}}}}
          ... on ConnectedEvent{subject{__typename ... on PullRequest{number state repository{nameWithOwner}}}}
          ... on ReferencedEvent{commit{associatedPullRequests(first:5){totalCount nodes{number state repository{nameWithOwner}}}}}
        }
      }
    }
  }
}'

found=0
for ref in "${issues[@]}"; do
  # Avoid reading an issue's timeline when its mandatory mention search cannot be served.
  [ "$budget" -gt 0 ] || defer "invocation search budget reached"
  owner=${ref%%/*}; rest=${ref#*/}; name=${rest%%#*}; number=${ref##*#}
  after=""; nodes="[]"; seen=0; total=""; state=""; subs=""
  while :; do
    args=(api graphql -f query="$query" -f owner="$owner" -f name="$name" -F number="$number")
    [ -z "$after" ] || args+=(-f after="$after")
    page=$(gh_ "${args[@]}") || unknown "$ref: reference read failed"
    jq -e '.data.repository.issue' >/dev/null 2>&1 <<<"$page" || unknown "$ref: no such issue, or an unparseable payload"
    ! jq -e '.errors' >/dev/null 2>&1 <<<"$page" || unknown "$ref: the read returned errors"
    state=$(jq -r '.data.repository.issue.state' <<<"$page")
    subs=$(jq -r '.data.repository.issue.subIssuesSummary | "\(.completed)/\(.total)"' <<<"$page")
    total=$(jq -r '.data.repository.issue.timelineItems.totalCount' <<<"$page")
    nodes=$(jq -c --argjson acc "$nodes" '$acc + .data.repository.issue.timelineItems.nodes' <<<"$page")
    seen=$(jq -r 'length' <<<"$nodes")
    [ "$(jq -r '.data.repository.issue.timelineItems.pageInfo.hasNextPage' <<<"$page")" = "true" ] || break
    after=$(jq -r '.data.repository.issue.timelineItems.pageInfo.endCursor' <<<"$page")
    [ -n "$after" ] && [ "$after" != "null" ] || unknown "$ref: a next page was promised without a cursor"
  done
  [ "$seen" = "$total" ] || unknown "$ref: read $seen of $total references"
  # A commit can belong to more PRs than one page of its connection holds; a short list could hide an
  # open PR, so refuse it rather than judge on part of it.
  short=$(jq -r '[ .[] | select(.__typename == "ReferencedEvent") | .commit.associatedPullRequests // empty
    | select((.nodes | length) != .totalCount) ] | length' <<<"$nodes") || unknown "$ref: unparseable commit references"
  [ "$short" = "0" ] || unknown "$ref: a referencing commit belongs to more PRs than were read"

  # A PR whose body names the issue does not always leave a timeline event: platform#2973 delivered
  # platform#2972 and says so in its body, yet #2972 records no cross-reference. So also search the
  # repository's PRs for the number and keep only bodies that name it as `#<n>` (not `owner/repo#<n>`,
  # and not a longer number). Bodies are matched locally and never printed.
  mentions_q="repo:${owner}/${name} is:pr ${number} in:body"
  search_read -f q="$mentions_q" -f per_page=100
  search=$search_result
  [ "$(jq -r '.incomplete_results' <<<"$search")" = "false" ] || unknown "$ref: mention search reported incomplete results"
  [ "$(jq -r '.total_count' <<<"$search")" -le 100 ] 2>/dev/null || unknown "$ref: more than 100 PRs match its number"
  jq -e '(.items | type) == "array" and (.items | length) == .total_count' >/dev/null 2>&1 <<<"$search" ||
    unknown "$ref: mention search returned fewer items than it counted"
  mentions=$(jq -c --arg n "$number" '[ .items[]
    | select((.body // "") | test("(^|[^A-Za-z0-9_./#-])#" + $n + "([^0-9]|$)"))
    | {k: "\(.repository_url | split("/") | .[-2:] | join("/"))#\(.number)",
       s: (if .pull_request.merged_at then "MERGED" elif .state == "open" then "OPEN" else "CLOSED" end),
       c: false} ]' <<<"$search") || unknown "$ref: unparseable mention search"

  # One row per distinct PR: a PR can be cross-referenced several times and also linked manually.
  # It counts as closing when ANY of its references does.
  counts=$(jq -r --argjson mentions "$mentions" '
    [ .[]
      | if .__typename == "CrossReferencedEvent" then
          (.willCloseTarget // false) as $c
          | .source | select(.__typename == "PullRequest")
          | {k: "\(.repository.nameWithOwner)#\(.number)", s: .state, c: $c}
        elif .__typename == "ConnectedEvent" then
          .subject | select(.__typename == "PullRequest")
          | {k: "\(.repository.nameWithOwner)#\(.number)", s: .state, c: true}
        elif .__typename == "ReferencedEvent" then
          (.commit.associatedPullRequests.nodes // [])[]
          | {k: "\(.repository.nameWithOwner)#\(.number)", s: .state, c: false}
        else empty end ] + $mentions
    | group_by(.k)
    | map({s: .[0].s, c: (map(.c) | any)})
    | "\(map(select(.s == "MERGED")) | length) \(map(select(.s == "OPEN")) | length) \(map(select(.c)) | length)"
  ' <<<"$nodes") || unknown "$ref: could not classify its references"
  read -r merged open closing <<<"$counts"

  if [ "$open" -gt 0 ] || [ "$merged" -eq 0 ]; then verdict=NOT-CANDIDATE
  elif [ "$merged" -eq 1 ]; then verdict=CANDIDATE-SINGLE; found=1
  else verdict=CANDIDATE-MULTI; found=1
  fi
  echo "$verdict $ref state=$state merged=$merged open=$open closing=$closing subissues=$subs"
  completed=$((completed + 1))
done

exit "$found"
