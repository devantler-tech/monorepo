#!/usr/bin/env bash
# lane-draft-count.sh — answer the WIP intake cap in AGENTS.md (Cadence & focus): "While your own
# lane holds more than 20 open drafts, open no new ones." Counts every open draft PR across the
# devantler-tech organisation by BRANCH NAMESPACE (the lane), never by author: every instance
# authors as the same login, so an author count cannot tell the lanes apart (monorepo#2562).
#
# Read-only. Emits only counts and registry namespace names — no PR titles, bodies or branch names,
# since those are untrusted input.
#
# FAILS CLOSED. A count is printed only when every open draft the search reports was actually read:
# a failed query, a truncated page walk, or a result set larger than the search can page through is
# UNKNOWN, never a number. An unknown count means the cap cannot be shown to permit a new draft.
#
# Usage: lane-draft-count.sh --lane <namespace> [--cap N] [--instances FILE]
#
# Exit codes:
#   0  WITHIN  — the lane holds N <= cap open drafts; a new draft is allowed
#   1  OVER    — the lane holds more than cap open drafts; open none, finish instead
#   2  UNKNOWN — usage error, unreadable registry, or an incomplete read
#
# Test seams (when both are set, gh is never invoked):
#   LANE_DRAFTS_JSON   file: JSON array of {headRefName, isCrossRepository}
#   LANE_DRAFTS_TOTAL  the search's reported issueCount for the same query
set -uo pipefail

CAP=20
LANE=""
INSTANCES="${AGENT_INSTANCES_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../plugin-consumption/agent-instances.json}"
QUERY="org:devantler-tech is:pr is:open draft:true archived:false"

unknown() { echo "lane-draft-count: UNKNOWN — $*" >&2; echo "verdict=UNKNOWN"; exit 2; }
need_val() { [ $# -ge 2 ] && [ -n "$2" ] || unknown "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --lane)      need_val "$@"; LANE="$2"; shift 2 ;;
    --cap)       need_val "$@"; CAP="$2"; shift 2 ;;
    --instances) need_val "$@"; INSTANCES="$2"; shift 2 ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    *)           unknown "unknown argument: $1" ;;
  esac
done

[ -n "$LANE" ] || unknown "--lane is required"
case "$CAP" in ''|*[!0-9]*) unknown "--cap must be a non-negative integer" ;; esac

namespaces=$(jq -er '
  .instances | select(type == "object" and length > 0)
  | [.[].namespace] | select(all(type == "string" and test("^[a-z][a-z0-9-]*$")))
  | select(length == (unique | length)) | .[]
' "$INSTANCES" 2>/dev/null) || unknown "instance registry is unreadable or malformed"
printf '%s\n' "$namespaces" | grep -qxF -- "$LANE" || unknown "lane '$LANE' is not a registered namespace"

if [ -n "${LANE_DRAFTS_JSON:-}" ] && [ -n "${LANE_DRAFTS_TOTAL:-}" ]; then
  nodes=$(jq -ec 'select(type == "array")' "$LANE_DRAFTS_JSON" 2>/dev/null) || unknown "fixture is not a JSON array"
  total=$LANE_DRAFTS_TOTAL
else
  nodes="[]"; total=""; cursor=""
  # 10 pages of 100 is the search API's own ceiling, so a larger total is reported as UNKNOWN below.
  for _page in 1 2 3 4 5 6 7 8 9 10; do
    args=(-f q="$QUERY"); [ -n "$cursor" ] && args+=(-f after="$cursor")
    resp=$(gh api graphql -f query='query($q:String!,$after:String){search(query:$q,type:ISSUE,first:100,after:$after){issueCount pageInfo{hasNextPage endCursor} nodes{... on PullRequest{headRefName isCrossRepository}}}}' "${args[@]}" 2>/dev/null) \
      || unknown "search query failed"
    page_total=$(printf '%s' "$resp" | jq -er '.data.search.issueCount | numbers') || unknown "search returned no issueCount"
    total=$page_total
    nodes=$(jq -nc --argjson a "$nodes" --argjson r "$resp" '$a + [$r.data.search.nodes[] | select(has("headRefName"))]') \
      || unknown "search page could not be parsed"
    [ "$(printf '%s' "$resp" | jq -r '.data.search.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(printf '%s' "$resp" | jq -r '.data.search.pageInfo.endCursor')
  done
fi

case "$total" in ''|*[!0-9]*) unknown "reported total is not a number" ;; esac
fetched=$(printf '%s' "$nodes" | jq 'length')
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
