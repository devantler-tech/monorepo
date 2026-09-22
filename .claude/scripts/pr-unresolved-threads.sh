#!/usr/bin/env bash
# pr-unresolved-threads.sh — count a pull request's unresolved review threads, or say UNKNOWN
# (monorepo#2670).
#
# WHY THIS EXISTS
#   Unresolved threads block a merge on every portfolio repository, yet no `gh pr view --json`
#   field carries them, so each run counted them inline. That count is silent when wrong: on
#   2026-08-04 a survey reported `unresolved=0` for monorepo#2436 while a Major CodeRabbit thread
#   was open, and the PR was promoted and armed for auto-merge on that number. A failed read, a
#   first-page-only read and a genuine zero all printed `0`. This helper makes the count one
#   tested command whose only zero is a complete, successful read.
#
# USAGE
#   pr-unresolved-threads.sh <owner>/<repo> <pr-number>
#
#   Counts every thread whatever its author and whether or not it is outdated: an outdated
#   thread still blocks `required_review_thread_resolution`.
#
# OUTPUT (one line on stdout)
#   unresolved=<n> total=<t>
#   UNKNOWN <reason>           read-failed | truncated fetched=<f> total=<t> | malformed
#
# EXIT CODES
#   0  complete read, zero unresolved threads
#   1  complete read, at least one unresolved thread
#   2  UNKNOWN or usage error — never read this as zero
set -euo pipefail

usage() {
  sed -n '14,27p' "$0" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
repo="$1"
pr="$2"
grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' <<<"${repo}" || usage
grep -Eq '^[1-9][0-9]*$' <<<"${pr}" || usage
owner="${repo%%/*}"
name="${repo#*/}"

# shellcheck disable=SC2016 # GraphQL variables, not shell expansions
query='
query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      reviewThreads(first:100,after:$endCursor){
        totalCount
        nodes{isResolved}
        pageInfo{hasNextPage endCursor}
      }}}}'

# Capture before parsing: piped straight into jq, a failed read yields an empty stream that
# `jq -s` turns into a zero.
if ! pages="$(gh api graphql --paginate -f owner="${owner}" -f name="${name}" -F number="${pr}" -f query="${query}" 2>/dev/null)"; then
  echo "UNKNOWN read-failed"
  exit 2
fi
[ -n "${pages}" ] || {
  echo "UNKNOWN read-failed"
  exit 2
}

if ! counts="$(printf '%s\n' "${pages}" | jq -s -r '
  [.[].data.repository.pullRequest.reviewThreads] as $t
  | if ($t | length) == 0 or any($t[]; . == null) then error("no reviewThreads") else . end
  | "\([$t[].nodes[]] | length) \($t[0].totalCount) \([$t[].nodes[] | select(.isResolved == false)] | length)"
' 2>/dev/null)"; then
  echo "UNKNOWN malformed"
  exit 2
fi

fetched="${counts%% *}"
rest="${counts#* }"
total="${rest%% *}"
unresolved="${rest##* }"

if [ "${fetched}" != "${total}" ]; then
  echo "UNKNOWN truncated fetched=${fetched} total=${total}"
  exit 2
fi

echo "unresolved=${unresolved} total=${total}"
[ "${unresolved}" -eq 0 ]
