#!/usr/bin/env bash
# lane-draft-count.sh — answer the PER-LANE half of the WIP intake cap in AGENTS.md (Cadence &
# focus): "While your own lane holds more than 20 open drafts, open no new ones." Counts every open
# draft PR across the devantler-tech organisation by BRANCH NAMESPACE (the lane), never by author:
# every instance authors as the same login, so an author count cannot tell the lanes apart
# (monorepo#2562).
#
# This checks ONE bound. The per-run limit (at most 5 new drafts per run) is separate and still
# applies: a WITHIN here never means "a draft is allowed" on its own.
#
# Read-only. Emits only counts and registry namespace names — no PR titles, bodies or branch names,
# since those are untrusted input.
#
# FAILS CLOSED. A count is printed only when the read is provably complete; otherwise UNKNOWN:
#   - a failed query, or a page walk that read fewer drafts than the search reported;
#   - a search the REST surface marks `incomplete_results` (search timed out and returned a
#     partial set) — GraphQL search exposes no such flag, so REST is asked as well and the two
#     totals must agree;
#   - a total that changes between pages, or a duplicate PR id (a draft moved under the cursor);
#   - a credential that cannot see every organisation repository, since the search silently
#     counts only what the token can read.
#
# Usage: lane-draft-count.sh --lane <namespace> [--cap N] [--instances FILE]
#
# Exit codes:
#   0  WITHIN  — the lane holds N <= cap open drafts; the per-lane bound does not block a draft
#   1  OVER    — the lane holds more than cap open drafts; open none, finish instead
#   2  UNKNOWN — usage error, unreadable registry, or an incomplete read
#
# Test seams (when LANE_DRAFTS_JSON is set, gh is never invoked; all must then be set):
#   LANE_DRAFTS_JSON      file: JSON array of {id, headRefName, isCrossRepository}
#   LANE_DRAFTS_TOTALS    space-separated issueCount reported by each GraphQL page
#   LANE_REST_TOTAL       REST search total_count for the same query
#   LANE_REST_INCOMPLETE  REST search incomplete_results (true|false)
#   LANE_REPOS_EXPECTED   repositories the organisation reports (public + private)
#   LANE_REPOS_VISIBLE    repositories the credential could list
set -uo pipefail

CAP=20
LANE=""
ORG=devantler-tech
INSTANCES="${AGENT_INSTANCES_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../plugin-consumption/agent-instances.json}"
QUERY="org:$ORG is:pr is:open draft:true archived:false"

unknown() { echo "lane-draft-count: UNKNOWN — $*" >&2; echo "verdict=UNKNOWN"; exit 2; }
need_val() { [ $# -ge 2 ] && [ -n "$2" ] || unknown "$1 needs a value"; }
is_count() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --lane)      need_val "$@"; LANE="$2"; shift 2 ;;
    --cap)       need_val "$@"; CAP="$2"; shift 2 ;;
    --instances) need_val "$@"; INSTANCES="$2"; shift 2 ;;
    -h|--help)   sed -n '2,36p' "$0"; exit 0 ;;
    *)           unknown "unknown argument: $1" ;;
  esac
done

[ -n "$LANE" ] || unknown "--lane is required"
is_count "$CAP" || unknown "--cap must be a non-negative integer"

namespaces=$(jq -er '
  .instances | select(type == "object" and length > 0)
  | [.[].namespace] | select(all(type == "string" and test("^[a-z][a-z0-9-]*$")))
  | select(length == (unique | length)) | .[]
' "$INSTANCES" 2>/dev/null) || unknown "instance registry is unreadable or malformed"
printf '%s\n' "$namespaces" | grep -qxF -- "$LANE" || unknown "lane '$LANE' is not a registered namespace"

if [ -n "${LANE_DRAFTS_JSON:-}" ]; then
  nodes=$(jq -ec 'select(type == "array")' "$LANE_DRAFTS_JSON" 2>/dev/null) || unknown "fixture is not a JSON array"
  page_totals=${LANE_DRAFTS_TOTALS:-}
  rest_total=${LANE_REST_TOTAL:-}
  rest_incomplete=${LANE_REST_INCOMPLETE:-}
  repos_expected=${LANE_REPOS_EXPECTED:-}
  repos_visible=${LANE_REPOS_VISIBLE:-}
else
  # Coverage: the search counts only repositories this credential can read. total_private_repos is
  # null for a credential without org-owner visibility, which is_count rejects below.
  repos_expected=$(gh api "orgs/$ORG" --jq '(.public_repos // "x" | tostring) + " " + (.total_private_repos // "x" | tostring)' 2>/dev/null) \
    || unknown "organisation repository totals are unreadable"
  pub=${repos_expected%% *}; priv=${repos_expected##* }
  is_count "$pub" && is_count "$priv" || unknown "the credential cannot see the organisation's private repository total"
  repos_expected=$((pub + priv))
  repos_visible=$(set -o pipefail; gh api --paginate --slurp "orgs/$ORG/repos?type=all&per_page=100" 2>/dev/null | jq '[.[][]] | length') \
    || unknown "organisation repository listing failed"

  rest=$(gh api -X GET search/issues -f q="$QUERY" -f per_page=1 2>/dev/null) || unknown "REST search failed"
  rest_total=$(printf '%s' "$rest" | jq -r '.total_count')
  rest_incomplete=$(printf '%s' "$rest" | jq -r '.incomplete_results')

  nodes="[]"; page_totals=""; cursor=""
  # 10 pages of 100 is the search API's own ceiling, so a larger total fails the completeness check.
  for _page in 1 2 3 4 5 6 7 8 9 10; do
    args=(-f q="$QUERY"); [ -n "$cursor" ] && args+=(-f after="$cursor")
    resp=$(gh api graphql -f query='query($q:String!,$after:String){search(query:$q,type:ISSUE,first:100,after:$after){issueCount pageInfo{hasNextPage endCursor} nodes{... on PullRequest{id headRefName isCrossRepository}}}}' "${args[@]}" 2>/dev/null) \
      || unknown "GraphQL search failed"
    page_totals="$page_totals $(printf '%s' "$resp" | jq -r '.data.search.issueCount')"
    nodes=$(jq -nc --argjson a "$nodes" --argjson r "$resp" '$a + [$r.data.search.nodes[] | select(has("headRefName"))]') \
      || unknown "search page could not be parsed"
    [ "$(printf '%s' "$resp" | jq -r '.data.search.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(printf '%s' "$resp" | jq -r '.data.search.pageInfo.endCursor')
  done
fi

is_count "$repos_expected" && is_count "$repos_visible" || unknown "repository coverage is not a number"
[ "$repos_visible" -eq "$repos_expected" ] || unknown "the credential sees $repos_visible of $repos_expected organisation repositories"
[ "$rest_incomplete" = "false" ] || unknown "the search reported incomplete results"
is_count "$rest_total" || unknown "REST total is not a number"

set -- $page_totals
[ $# -gt 0 ] || unknown "no search page was read"
total=$1
for t in "$@"; do
  is_count "$t" || unknown "a page total is not a number"
  [ "$t" -eq "$total" ] || unknown "the total changed between pages ($total then $t)"
done
[ "$rest_total" -eq "$total" ] || unknown "REST and GraphQL disagree on the total ($rest_total vs $total)"

fetched=$(printf '%s' "$nodes" | jq 'length')
unique=$(printf '%s' "$nodes" | jq '[.[].id] | unique | length')
[ "$unique" -eq "$fetched" ] || unknown "a draft was read twice — the result set moved under the cursor"
[ "$fetched" -eq "$total" ] || unknown "read $fetched of $total open drafts — the count would be a floor, not a count"

counts=""
for ns in $namespaces; do
  n=$(printf '%s' "$nodes" | jq --arg p "$ns/" '[.[] | select(.isCrossRepository != true and (.headRefName | startswith($p)))] | length')
  counts="$counts $ns=$n"
  [ "$ns" = "$LANE" ] && mine=$n
done
other=$(printf '%s' "$nodes" | jq --argjson ns "$(printf '%s\n' "$namespaces" | jq -R . | jq -sc .)" \
  '[.[] | select(.isCrossRepository == true or (.headRefName as $h | all($ns[]; . as $n | ($h | startswith($n + "/")) | not)))] | length')

echo "open_drafts:${counts} other=${other} total=${total}"
if [ "$mine" -gt "$CAP" ]; then
  echo "lane=$LANE drafts=$mine cap=$CAP verdict=OVER"
  exit 1
fi
echo "lane=$LANE drafts=$mine cap=$CAP verdict=WITHIN"
