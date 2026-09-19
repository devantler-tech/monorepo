#!/usr/bin/env bash
# lane-draft-count.sh — answer the PER-LANE half of the WIP intake cap in AGENTS.md (Cadence &
# focus): "While your own lane holds more than 20 open drafts, open no new ones." Counts every open
# draft PR across the devantler-tech organisation by lane. A draft belongs to a lane only when its
# branch is in the lane's namespace, it comes from the same repository, AND its author is the
# lane's registered identity: every instance authors as the same login, so the namespace is what
# separates the lanes, while the author check keeps a collaborator or bot using the prefix from
# inflating one (monorepo#2562).
#
# This checks ONE bound. The per-run limit (at most 5 new drafts per run) is separate and still
# applies: a WITHIN here never means "a draft is allowed" on its own.
#
# Read-only. Emits only counts and registry namespace names — no PR titles, bodies or branch names,
# since those are untrusted input.
#
# SOURCE: each repository's own open-PR list, never the search API. Search is an index that can lag
# the real PR state and can time out into a partial set, so a count built on it cannot be proven
# complete. The repository list is verified first, then every non-archived repository's open PRs
# are read in full.
#
# FAILS CLOSED. A count is printed only when the read is provably complete; otherwise UNKNOWN:
#   - any failed request;
#   - a credential that cannot list every organisation repository (public + private), since a
#     repository it cannot see contributes nothing. Archived repositories stay in that check on
#     purpose: whether an INVISIBLE repository is archived cannot be known either;
#   - two full reads that disagree on any draft's attribution (id, branch, fork, author), meaning
#     a PR opened, closed, converted or was renamed while it was being read;
#   - a repository inventory that differs across the three reads taken before, between and after
#     the two draft scans (a repository created, transferred in or unarchived mid-read);
#   - a duplicate PR id within one read.
#
# Usage: lane-draft-count.sh --lane <namespace> [--cap N] [--instances FILE]
#
# Exit codes:
#   0  WITHIN  — the lane holds N <= cap open drafts; the per-lane bound does not block a draft
#   1  OVER    — the lane holds more than cap open drafts; open none, finish instead
#   2  UNKNOWN — usage error, unreadable registry, or an incomplete read
#
# Test seams (when LANE_DRAFTS_JSON is set, gh is never invoked; all must then be set):
#   LANE_DRAFTS_JSON      file: JSON array of open drafts, {id, headRefName, isCrossRepository,
#                         author:{login}}
#   LANE_DRAFTS_JSON_2    file: the second full read (defaults to LANE_DRAFTS_JSON)
#   LANE_REPOS_EXPECTED   repositories the organisation reports (public + private)
#   LANE_REPOS_VISIBLE    repositories the credential could list
#   LANE_REPOS_EXPECTED_2 / LANE_REPOS_VISIBLE_2  the second pass's inventory (default: the first)
#   LANE_REPOS_VISIBLE_3  the inventory read after the last scan (default: the second)
set -uo pipefail

CAP=20
LANE=""
ORG=devantler-tech
INSTANCES="${AGENT_INSTANCES_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../plugin-consumption/agent-instances.json}"

unknown() { echo "lane-draft-count: UNKNOWN — $*" >&2; echo "verdict=UNKNOWN"; exit 2; }
need_val() { [ $# -ge 2 ] && [ -n "$2" ] || unknown "$1 needs a value"; }
is_count() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --lane)      need_val "$@"; LANE="$2"; shift 2 ;;
    --cap)       need_val "$@"; CAP="$2"; shift 2 ;;
    --instances) need_val "$@"; INSTANCES="$2"; shift 2 ;;
    -h|--help)   sed -n '2,45p' "$0"; exit 0 ;;
    *)           unknown "unknown argument: $1" ;;
  esac
done

[ -n "$LANE" ] || unknown "--lane is required"
is_count "$CAP" || unknown "--cap must be a non-negative integer"

# [{ns, author}] for every registered instance; namespaces unique, authors non-empty. The REST
# identity is used because the drafts are read from the REST pulls endpoint.
lanes=$(jq -ec '
  .instances | select(type == "object" and length > 0)
  | [.[] | {ns: .namespace, author: .authors.rest}]
  | select(all(.ns | type == "string" and test("^[a-z][a-z0-9-]*$")))
  | select(all(.author | type == "string" and length > 0))
  | select(([.[].ns] | length) == ([.[].ns] | unique | length))
' "$INSTANCES" 2>/dev/null) || unknown "instance registry is unreadable or malformed"
printf '%s' "$lanes" | jq -e --arg l "$LANE" 'any(.[]; .ns == $l)' >/dev/null || unknown "lane '$LANE' is not a registered namespace"

# read_drafts <repo-names> — every open draft across those repositories, sorted by id.
read_drafts() {
  local repo page out="[]"
  for repo in $1; do
    page=$(set -o pipefail; gh api --paginate --slurp "repos/$ORG/$repo/pulls?state=open&per_page=100" 2>/dev/null | jq -c '
      [.[][] | select(.draft == true) | {
        id: .node_id,
        headRefName: .head.ref,
        isCrossRepository: ((.head.repo.full_name // "") != .base.repo.full_name),
        author: {login: .user.login}}]') || unknown "open pull requests of $repo are unreadable"
    out=$(jq -nc --argjson a "$out" --argjson b "$page" '$a + $b') || unknown "pull request page could not be merged"
  done
  printf '%s' "$out" | jq -c 'sort_by(.id)'
}

# read_inventory — {expected, visible, repos:[{name, archived}]} for the organisation right now.
read_inventory() {
  local totals pub priv repos
  # total_private_repos is null for a credential without org-owner visibility; is_count rejects it.
  totals=$(gh api "orgs/$ORG" --jq '(.public_repos // "x" | tostring) + " " + (.total_private_repos // "x" | tostring)' 2>/dev/null) \
    || unknown "organisation repository totals are unreadable"
  pub=${totals%% *}; priv=${totals##* }
  is_count "$pub" && is_count "$priv" || unknown "the credential cannot see the organisation's private repository total"
  repos=$(set -o pipefail; gh api --paginate --slurp "orgs/$ORG/repos?type=all&per_page=100" 2>/dev/null \
    | jq -c '[.[][] | {name, archived: (.archived == true)}] | sort_by(.name)') \
    || unknown "organisation repository listing failed"
  jq -nc --argjson e "$((pub + priv))" --argjson r "$repos" '{expected: $e, visible: ($r | length), repos: $r}'
}

# Each pass reads its own repository inventory and then the drafts of that inventory's active
# repositories, so a repository created or transferred in during the read changes the second
# inventory and fails the comparison below instead of being silently omitted from both passes.
if [ -n "${LANE_DRAFTS_JSON:-}" ]; then
  nodes=$(jq -ec 'select(type == "array") | sort_by(.id)' "$LANE_DRAFTS_JSON" 2>/dev/null) || unknown "fixture is not a JSON array"
  nodes2=$(jq -ec 'select(type == "array") | sort_by(.id)' "${LANE_DRAFTS_JSON_2:-$LANE_DRAFTS_JSON}" 2>/dev/null) || unknown "second fixture is not a JSON array"
  inv=$(jq -nc --arg e "${LANE_REPOS_EXPECTED:-}" --arg v "${LANE_REPOS_VISIBLE:-}" '{expected: $e, visible: $v}')
  inv2=$(jq -nc --arg e "${LANE_REPOS_EXPECTED_2:-${LANE_REPOS_EXPECTED:-}}" --arg v "${LANE_REPOS_VISIBLE_2:-${LANE_REPOS_VISIBLE:-}}" '{expected: $e, visible: $v}')
  inv3=$(jq -nc --arg e "${LANE_REPOS_EXPECTED_2:-${LANE_REPOS_EXPECTED:-}}" --arg v "${LANE_REPOS_VISIBLE_3:-${LANE_REPOS_VISIBLE_2:-${LANE_REPOS_VISIBLE:-}}}" '{expected: $e, visible: $v}')
else
  inv=$(read_inventory) || { echo "verdict=UNKNOWN"; exit 2; }
  nodes=$(read_drafts "$(printf '%s' "$inv" | jq -r '.repos[] | select(.archived | not) | .name')") || { echo "verdict=UNKNOWN"; exit 2; }
  inv2=$(read_inventory) || { echo "verdict=UNKNOWN"; exit 2; }
  nodes2=$(read_drafts "$(printf '%s' "$inv2" | jq -r '.repos[] | select(.archived | not) | .name')") || { echo "verdict=UNKNOWN"; exit 2; }
  # A third inventory AFTER the last scan closes the remaining window: a repository created,
  # transferred in or unarchived during that scan would otherwise be missing from both draft
  # reads while both inventories still described the old set.
  inv3=$(read_inventory) || { echo "verdict=UNKNOWN"; exit 2; }
fi

jq -en --argjson a "$inv" --argjson b "$inv2" --argjson c "${inv3:-$inv2}" '$a == $b and $b == $c' >/dev/null \
  || unknown "the organisation's repositories changed while the drafts were being read"
repos_expected=$(printf '%s' "$inv" | jq -r '.expected')
repos_visible=$(printf '%s' "$inv" | jq -r '.visible')
is_count "$repos_expected" && is_count "$repos_visible" || unknown "repository coverage is not a number"
[ "$repos_visible" -eq "$repos_expected" ] || unknown "the credential sees $repos_visible of $repos_expected organisation repositories"

total=$(printf '%s' "$nodes" | jq 'length')
[ "$(printf '%s' "$nodes" | jq '[.[].id] | unique | length')" -eq "$total" ] || unknown "a draft appears twice in one read"
jq -en --argjson a "$nodes" --argjson b "$nodes2" '$a == $b' >/dev/null \
  || unknown "two full reads disagree on the open drafts — one opened, closed, converted or was renamed while being read"

counted=$(jq -nc --argjson n "$nodes" --argjson l "$lanes" '
  [$l[] as $lane | {ns: $lane.ns, n: ([$n[] | select(.isCrossRepository != true
     and ((.headRefName // "") | startswith($lane.ns + "/"))
     and (.author.login? // "") == $lane.author)] | length)}]')
counts=$(printf '%s' "$counted" | jq -r 'map(" \(.ns)=\(.n)") | join("")')
mine=$(printf '%s' "$counted" | jq --arg l "$LANE" '.[] | select(.ns == $l) | .n')
other=$((total - $(printf '%s' "$counted" | jq '[.[].n] | add')))

echo "open_drafts:${counts} other=${other} total=${total}"
if [ "$mine" -gt "$CAP" ]; then
  echo "lane=$LANE drafts=$mine cap=$CAP verdict=OVER"
  exit 1
fi
echo "lane=$LANE drafts=$mine cap=$CAP verdict=WITHIN"
