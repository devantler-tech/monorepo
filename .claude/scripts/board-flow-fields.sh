#!/usr/bin/env bash
# board-flow-fields.sh — report 🏃🏻‍♂️ In Progress cards on the 🌊 Project Board (org project 5)
# whose flow dates are missing or stale (monorepo#4992).
#
# WHY THIS EXISTS
#   The board guide (.claude/guides/issues-and-board.md, "Flow fields and WIP capacity") says First
#   started records actual first work and Blocked since records the first blocked observation. On
#   2026-11-12, 37 of 46 In Progress cards had no First started and 10 of the 11 cards with an open
#   blocker had no Blocked since, so no run could tell how long started work had been running or
#   waiting. Nothing reported the gap, so it grew silently. This check makes it visible.
#
# WHAT IT CHECKS (In Progress issue cards only; no titles or bodies are printed)
#   missing-first-started   the card has no First started value
#   missing-blocked-since   the issue is blocked and has no Blocked since value
#   stale-blocked-since     the issue is not blocked but Blocked since is still set
#   An issue is blocked when it has an open native blocking dependency OR the `blocked` label, which
#   the board guide reserves for upstream, outcome and authority blockers a dependency cannot express.
#
# EXIT CODES
#   0  every In Progress card has the fields it needs
#   1  at least one finding (one line each: `<kind> <repo>#<number>`)
#   2  UNKNOWN: usage error, failed or malformed read, or the board cannot be shown to be read. The
#      exact Status option must exist (a misspelt status filter returns zero items silently), and
#      the unfiltered board must be non-empty. Never read exit 2 as "all filled".
#
# USAGE
#   board-flow-fields.sh [--summary]
#     --summary  print only the counts line, not each finding
#
# TEST SEAM
#   BOARD_FLOW_FIXTURE  file: {"total": N, "options": ["<Status>", ...], "items": [<item node>, ...]}
#                       where an item node has the GraphQL shape this script queries
#                       ({isArchived, fs:{date}|null, bs:{date}|null, content:{number, repository:{name},
#                       issueDependenciesSummary:{blockedBy}, labels:{totalCount, nodes:[{name}]}}}).
#                       When set, gh is never invoked.
set -euo pipefail

STATUS='🏃🏻‍♂️ In Progress'
SUMMARY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --summary) SUMMARY=1; shift ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "board-flow-fields: unknown argument (value not echoed)" >&2; exit 2 ;;
  esac
done

unknown() {
  echo "board-flow-fields: UNKNOWN — $1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || unknown "jq is not installed"

if [ -n "${BOARD_FLOW_FIXTURE:-}" ]; then
  data=$(cat "$BOARD_FLOW_FIXTURE" 2>/dev/null) || unknown "fixture unreadable"
else
  command -v gh >/dev/null 2>&1 || unknown "gh is not installed"
  # Controls: the unfiltered item count and the Status options, read in one call.
  meta=$(gh api graphql -f query='query{organization(login:"devantler-tech"){projectV2(number:5){
      items{totalCount}
      status:field(name:"Status"){... on ProjectV2SingleSelectField{options{name}}}}}}' \
    --jq '.data.organization.projectV2 | {total: .items.totalCount, options: [.status.options[]?.name]}') ||
    unknown "board control read failed"
  # `--paginate` advances only with a variable named exactly `$endCursor`; the GraphQL variables are
  # meant literally, so the single quotes are intended.
  # shellcheck disable=SC2016
  pages=$(gh api graphql --paginate -f q="status:\"${STATUS}\" is:open is:issue" -f query='
    query($q:String!, $endCursor:String){organization(login:"devantler-tech"){projectV2(number:5){
      items(first:100, after:$endCursor, query:$q){
        pageInfo{hasNextPage endCursor}
        nodes{
          isArchived
          fs:fieldValueByName(name:"First started"){... on ProjectV2ItemFieldDateValue{date}}
          bs:fieldValueByName(name:"Blocked since"){... on ProjectV2ItemFieldDateValue{date}}
          content{... on Issue{number repository{name} issueDependenciesSummary{blockedBy}
            labels(first:100){totalCount nodes{name}}}}}}}}}' \
    --jq '.data.organization.projectV2.items.nodes') || unknown "In Progress item read failed"
  # Every page must be an array, and there must be at least one: an empty or null page is a read
  # that returned nothing, not an empty column. A valid empty column is one `[]` page.
  items=$(printf '%s\n' "$pages" | jq -s '
    if length == 0 or any(.[]; type != "array") then error("a page is missing or not an array")
    else add end') || unknown "In Progress pages are missing, null or did not parse"
  data=$(jq -n --argjson m "$meta" --argjson i "$items" '$m + {items: $i}') ||
    unknown "could not assemble the board read"
fi

printf '%s' "$data" | jq -e '
  (.total | type == "number") and (.options | type == "array") and (.items | type == "array")' \
  >/dev/null 2>&1 || unknown "board read is not the expected shape"
printf '%s' "$data" | jq -e '.total > 0' >/dev/null || unknown "the unfiltered board returned no items"
printf '%s' "$data" | jq -e --arg s "$STATUS" '.options | index($s) != null' >/dev/null ||
  unknown "Status option '${STATUS}' does not exist, so the filter cannot be trusted"

# Every node must be an issue with a repository, a number and a dependency summary: a node missing
# them was not read, and skipping it would under-count.
printf '%s' "$data" | jq -e '
  all(.items[]; (.content.number | type == "number")
                and (.content.repository.name | type == "string")
                and (.content.issueDependenciesSummary.blockedBy | type == "number")
                and (.content.labels.nodes | type == "array")
                and (.content.labels.totalCount == (.content.labels.nodes | length)))' \
  >/dev/null || unknown "an In Progress card lacks its issue number, repository, dependency summary or full label list"

# An archived card is off the board, so it is neither counted nor reported.
data=$(printf '%s' "$data" | jq -c '.items |= map(select(.isArchived != true))') ||
  unknown "could not drop archived cards"

findings=$(printf '%s' "$data" | jq -r '
  .items[]
  | (.content.repository.name + "#" + (.content.number | tostring)) as $id
  | (.fs.date // null) as $fs | (.bs.date // null) as $bs
  | ((.content.issueDependenciesSummary.blockedBy > 0)
     or any(.content.labels.nodes[]; .name == "blocked")) as $blocked
  | (if $fs == null then "missing-first-started \($id)" else empty end),
    (if $blocked and $bs == null then "missing-blocked-since \($id)" else empty end),
    (if ($blocked | not) and $bs != null then "stale-blocked-since \($id)" else empty end)' |
  LC_ALL=C sort) || unknown "could not evaluate the cards"

total=$(printf '%s' "$data" | jq '.items | length')
count() { printf '%s\n' "$findings" | grep -c "^$1 " || true; }
echo "board-flow-fields: in_progress=${total} missing-first-started=$(count missing-first-started)" \
  "missing-blocked-since=$(count missing-blocked-since) stale-blocked-since=$(count stale-blocked-since)"

if [ -n "$findings" ]; then
  [ "$SUMMARY" -eq 1 ] || printf '%s\n' "$findings"
  exit 1
fi
exit 0
