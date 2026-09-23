#!/usr/bin/env bash
# coderabbit-summary-verdict.sh — decide whether ONE CodeRabbit auto-generated summary comment
# carries a finding-free review verdict for ONE exact head (monorepo#2653).
#
# WHY THIS EXISTS
#   AGENTS.md accepts CodeRabbit's auto-generated summary comment as an alternative green-review
#   artifact. That comment is edited in place over the PR's life and is mostly a walkthrough, so
#   "it was updated after the request and names the head" is not evidence that a review ran:
#     - doggy-countdown#1 was promoted on a summary with no verdict line and no sha at all;
#     - a rate-limit shell REFRESHES the summary and carries a range header naming the FULL
#       current head (platform#4041, 2026-09-22) while stating that no review ran.
#   Only the `recent_review` block's verdict line plus its range header ending at the head is a
#   review result. This helper applies exactly that test so no lane re-derives it by eye.
#
# USAGE
#   coderabbit-summary-verdict.sh --head <40-hex-sha> [--input <file>|-]
#
#   --head   the FULL 40-character headRefOid (abbreviations are refused: the range header
#            always carries full shas, and a prefix match would accept a different commit).
#   --input  the comment BODY (default: stdin). The caller still owns the author bind
#            (`user.login == "coderabbitai[bot]"`) and the freshness bind (updated after the
#            authenticated request); this helper judges the body only.
#
# OUTPUT (one line on stdout)
#   GREEN                      verdict `No actionable comments were generated in the recent
#                              review`, range header ends at --head, no did-not-run marker
#   FINDINGS <n>               the recent review posted <n> actionable comments, even beside a did-not-run marker
#   NONE <reason>              not a review result for this head; <reason> is one of
#                              not-a-summary, did-not-run, no-recent-review, no-verdict,
#                              no-range, range-other-head
#
# EXIT CODES
#   0  GREEN
#   1  FINDINGS or NONE — the summary does not satisfy the green-review gate
#   2  usage error or unreadable input — nothing was judged
set -euo pipefail

usage() {
  sed -n '15,34p' "$0" >&2
  exit 2
}

head=""
input="-"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --head)
      [ "$#" -ge 2 ] || usage
      head="$2"
      shift 2
      ;;
    --input)
      [ "$#" -ge 2 ] || usage
      input="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

grep -Eq '^[0-9a-f]{40}$' <<<"$head" || {
  echo "coderabbit-summary-verdict: --head must be a full 40-character lowercase sha" >&2
  exit 2
}

if [ "$input" = "-" ]; then
  body="$(cat)" || exit 2
else
  [ -r "$input" ] || {
    echo "coderabbit-summary-verdict: cannot read $input" >&2
    exit 2
  }
  body="$(cat -- "$input")" || exit 2
fi

verdict() {
  printf '%s\n' "$1"
  case "$1" in GREEN) exit 0 ;; *) exit 1 ;; esac
}

grep -Fq '<!-- This is an auto-generated comment: summarize by coderabbit.ai -->' <<<"$body" ||
  verdict "NONE not-a-summary"

# Every test below reads a here-string, never `printf | grep -q`: under pipefail an early-exiting
# grep makes printf die of SIGPIPE on a large body, so a match reads as a miss.
# Judge only the recent_review block: the walkthrough and pre-merge tables are not a verdict.
recent="$(printf '%s\n' "$body" | awk '
  /<!-- recent_review_start -->/ { inside = 1; next }
  /<!-- recent_review_end -->/   { inside = 0 }
  inside { print }
')"

# Findings are read BEFORE the did-not-run marker: a finding is positive evidence and survives an
# incomplete run, so a body carrying both reports its findings (monorepo#2764).
findings="$(sed -nE '/Actionable comments posted: [0-9]+/{s/.*Actionable comments posted: ([0-9]+).*/\1/p;q;}' <<<"$recent")"
if [ -n "$findings" ] && [ "$findings" -gt 0 ]; then
  verdict "FINDINGS $findings"
fi

# A body saying the review did not run can never be GREEN, even with a range header naming the head
# (the rate-limit shell carries one). The structural marker counts anywhere; the prose markers count
# only outside the blocks that summarise the PR itself, because a PR ABOUT review limits has a
# walkthrough that quotes them.
own_text="$(printf '%s\n' "$body" | awk '
  /<!-- (walkthrough|pre_merge_checks_walkthrough|change_assessment|tips)_start -->/ { skip = 1 }
  !skip { print }
  /<!-- (walkthrough|pre_merge_checks_walkthrough|change_assessment|tips)_end -->/   { skip = 0 }
')"
if grep -Fq 'rate limited by coderabbit.ai -->' <<<"$body" ||
  grep -Eiq 'Review limit reached|review limit|couldn.t start this review|Review skipped|Review failed' <<<"$own_text"; then
  verdict "NONE did-not-run"
fi

[ -n "$recent" ] || verdict "NONE no-recent-review"
grep -Fq 'No actionable comments were generated in the recent review' <<<"$recent" ||
  { [ "$findings" = "0" ] || verdict "NONE no-verdict"; }

# The END sha of the range is the commit that was reviewed. Any sha elsewhere in the comment is
# not: the walkthrough can list every commit on the PR, including ones pushed after it was written.
range_end="$(printf '%s\n' "$recent" | sed -nE 's/.*Reviewing files that changed .* between [0-9a-f]{40} and ([0-9a-f]{40})\..*/\1/p' | tail -n 1)"
[ -n "$range_end" ] || verdict "NONE no-range"
[ "$range_end" = "$head" ] || verdict "NONE range-other-head"

verdict GREEN
