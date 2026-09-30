#!/usr/bin/env bash
# delivered-open-candidates.test.sh — RED/GREEN coverage for delivered-open-candidates.sh
# (monorepo#2967).
#
# Hermetic: every API call goes through the DELIVERED_OPEN_GH seam to a stub that serves fixtures
# written here, so gh is never invoked. The fail-closed cases matter most: a short or failed read
# must print no verdict, because "merged=0" from an unread page looks exactly like "never delivered".

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/delivered-open-candidates.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
pass=0
fail=0

# The stub answers a GraphQL read from gql-<n>[-<cursor>].json, a mention search from
# mention-<n>.json and the organisation search from org.json. A missing fixture is a failed call.
cat >"$FIX/gh" <<'EOF'
#!/usr/bin/env bash
fix=$(dirname "$0")
n=""; after=""; q=""
for a in "$@"; do
  case "$a" in
    number=*) n=${a#number=} ;;
    after=*) after=-${a#after=} ;;
    q=*) q=${a#q=} ;;
  esac
done
if [ -n "$n" ]; then file="$fix/gql-$n$after.json"
elif [[ "$q" == *"in:body"* ]]; then n=$(awk '{print $3}' <<<"$q"); file="$fix/mention-$n.json"
else file="$fix/org.json"
fi
[ -f "$file" ] || exit 1
cat "$file"
EOF
chmod +x "$FIX/gh"

# pr <kind> <number> <state> [closing] — one timeline node
pr() {
  case "$1" in
    xref) jq -nc --argjson n "$2" --arg s "$3" --argjson c "${4:-false}" \
      '{__typename: "CrossReferencedEvent", willCloseTarget: $c, source: {__typename: "PullRequest", number: $n, state: $s, repository: {nameWithOwner: "o/r"}}}' ;;
    link) jq -nc --argjson n "$2" --arg s "$3" \
      '{__typename: "ConnectedEvent", subject: {__typename: "PullRequest", number: $n, state: $s, repository: {nameWithOwner: "o/r"}}}' ;;
    issue) jq -nc '{__typename: "CrossReferencedEvent", willCloseTarget: false, source: {__typename: "Issue"}}' ;;
    commit) jq -nc '{__typename: "ReferencedEvent", commit: {associatedPullRequests: {totalCount: 0, nodes: []}}}' ;;
  esac
}

# gql <issue> <total> <next-cursor|""> <file-suffix> <node>... — one GraphQL page
gql() {
  local n=$1 total=$2 next=$3 suffix=$4; shift 4
  printf '%s\n' "$@" | jq -s --argjson total "$total" --arg next "$next" '{data: {repository: {issue: {
      state: "OPEN", subIssuesSummary: {total: 2, completed: 1},
      timelineItems: {totalCount: $total, pageInfo: {hasNextPage: ($next != ""), endCursor: (if $next == "" then null else $next end)}, nodes: .}}}}}' \
    >"$FIX/gql-$n$suffix.json"
}

# mention <issue> [<number>:<state>:<body>]... — a mention-search result; state is merged|open|closed
mention() {
  local n=$1; shift
  printf '%s\n' "$@" | jq -R 'select(length > 0) | split(":") as $p | {
      repository_url: "https://api.github.com/repos/o/r", number: ($p[0] | tonumber),
      state: (if $p[1] == "open" then "open" else "closed" end),
      pull_request: {merged_at: (if $p[1] == "merged" then "2026-01-01T00:00:00Z" else null end)},
      body: ($p[2:] | join(":"))}' | jq -s '{total_count: length, incomplete_results: false, items: .}' >"$FIX/mention-$n.json"
}

run() { DELIVERED_OPEN_GH="$FIX/gh" "${TEST_BASH:-bash}" "$SCRIPT" "$@" 2>&1; }

# check <name> <want-rc> <want-substring|""> <reject-substring|""> args...
check() {
  local name=$1 want_rc=$2 want=$3 reject=$4; shift 4
  local out rc=0
  out=$(run "$@") || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL: $name — exit $rc, want $want_rc: $out"; fail=$((fail + 1)); return
  fi
  if [ -n "$want" ] && ! grep -qF -- "$want" <<<"$out"; then
    echo "FAIL: $name — missing '$want': $out"; fail=$((fail + 1)); return
  fi
  if [ -n "$reject" ] && grep -qF -- "$reject" <<<"$out"; then
    echo "FAIL: $name — must not print '$reject': $out"; fail=$((fail + 1)); return
  fi
  echo "ok: $name"; pass=$((pass + 1))
}

# 1 — one merged PR, the platform#2972 shape
gql 1 2 "" "" "$(pr xref 10 MERGED)" "$(pr issue)"
mention 1
check "a single merged PR is a single candidate" 1 \
  "CANDIDATE-SINGLE o/r#1 state=OPEN merged=1 open=0 closing=0 subissues=1/2" "" --issue o/r#1

# 2 — an umbrella: several merged PRs, each counted once
gql 2 4 "" "" "$(pr xref 20 MERGED)" "$(pr xref 21 MERGED)" "$(pr xref 22 MERGED)" "$(pr xref 22 MERGED)"
mention 2
check "several merged PRs are a multi candidate, deduplicated" 1 "CANDIDATE-MULTI o/r#2 state=OPEN merged=3 " "" --issue o/r#2

# 3 — an open PR means work is in flight
gql 3 2 "" "" "$(pr xref 30 MERGED)" "$(pr xref 31 OPEN)"
mention 3
check "an open PR is never a candidate" 0 "NOT-CANDIDATE o/r#3 state=OPEN merged=1 open=1" "" --issue o/r#3

# 4 — no reference at all
gql 4 1 "" "" "$(pr commit)"
mention 4
check "a commit-only reference with no PR is not a candidate" 0 "NOT-CANDIDATE o/r#4 state=OPEN merged=0 open=0" "" --issue o/r#4

# 5 — a closing reference and a manual link on the same PR count as one closing PR
gql 5 2 "" "" "$(pr xref 50 MERGED true)" "$(pr link 50 MERGED)"
mention 5
check "a PR referenced twice counts once, closing when any reference closes" 1 "merged=1 open=0 closing=1" "" --issue o/r#5

# 6 — a body mention with no timeline event (platform#2973 -> #2972); foreign and longer numbers ignored
gql 6 0 "" ""
mention 6 "60:merged:Delivers #6 end to end." "61:merged:See other/repo#6 for context." "62:merged:Tracks #66 and #600." "63:closed:Abandoned attempt at #6."
check "a body-only mention counts; owner/repo#n and longer numbers do not" 1 \
  "CANDIDATE-SINGLE o/r#6 state=OPEN merged=1 open=0" "" --issue o/r#6

# 7 — two pages accumulate
gql 7 2 "c2" "" "$(pr xref 70 MERGED)"
gql 7 2 "" "-c2" "$(pr xref 71 MERGED)"
mention 7
check "references on a second page are read" 1 "CANDIDATE-MULTI o/r#7 state=OPEN merged=2" "" --issue o/r#7

# 8 — a short read prints no verdict
gql 8 3 "" "" "$(pr xref 80 MERGED)"
mention 8
check "a read shorter than totalCount is UNKNOWN and prints no verdict" 2 "read 1 of 3 references" "o/r#8 state=" --issue o/r#8

# 9 — a failed read prints no verdict, and stops before later issues
check "a failed reference read is UNKNOWN" 2 "o/r#9: reference read failed" "CANDIDATE" --issue o/r#9 --issue o/r#1

# 10 — an incomplete mention search is UNKNOWN
gql 10 1 "" "" "$(pr xref 100 MERGED)"
jq -n '{total_count: 1, incomplete_results: true, items: []}' >"$FIX/mention-10.json"
check "an incomplete mention search is UNKNOWN" 2 "mention search reported incomplete results" "o/r#10 state=" --issue o/r#10

# 11 — a GraphQL payload carrying errors is UNKNOWN
jq '. + {errors: [{message: "boom"}]}' "$FIX/gql-1.json" >"$FIX/gql-11.json"
mention 11
check "a GraphQL error is UNKNOWN" 2 "the read returned errors" "o/r#11 state=" --issue o/r#11

# 12 — portfolio mode reads the organisation search, and a short search is UNKNOWN
jq -n '{total_count: 2, incomplete_results: false, items: [
  {repository_url: "https://api.github.com/repos/o/r", number: 1},
  {repository_url: "https://api.github.com/repos/o/r", number: 3}]}' >"$FIX/org.json"
check "--oldest reads each listed issue" 1 "NOT-CANDIDATE o/r#3" "" --oldest 2 --type Security
jq -n '{total_count: 5, incomplete_results: false, items: [{repository_url: "https://api.github.com/repos/o/r", number: 1}]}' >"$FIX/org.json"
check "--oldest with fewer issues than promised is UNKNOWN" 2 "returned 1 of 2 issues" "CANDIDATE" --oldest 2

# 13 — usage errors
check "no arguments is UNKNOWN" 2 "usage" ""
check "a malformed --issue is UNKNOWN" 2 "must be <owner/repo>#<n>" "" --issue o/r-1
check "--type without --oldest is UNKNOWN" 2 "--type needs --oldest" "" --issue o/r#1 --type Bug
check "--oldest above the page size is UNKNOWN" 2 "--oldest must be 1..100" "" --oldest 101

echo "delivered-open-candidates: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
