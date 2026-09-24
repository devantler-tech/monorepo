#!/usr/bin/env bash
# coderabbit-review-verdict.sh — decide whether ONE CodeRabbit review OBJECT is a finding-free
# review of ONE exact head (monorepo#2768).
#
# WHY THIS EXISTS
#   AGENTS.md accepts a current-head CodeRabbit review object as a green-review artifact only when
#   it is POSITIVELY identified as a review. Until this helper, that rule lived only in prose, and a
#   prose pin cannot tell a correct rule from a wrong one. The measured traps it encodes:
#     - an EMPTY object is a reply container, never a review, whatever its `commit_id`
#       (16 of 19 CodeRabbit objects at merged heads, 2026-08-07);
#     - a real review body starts with an agent-hint HTML comment, so the marker must be matched
#       after stripping LEADING comments and whitespace — but only leading ones, anchored
#       (2026-08-13: four real reviews, none began with the marker);
#     - a review whose findings all sit outside the diff opens with the outside-diff CAUTION block
#       and carries no marker at all, and always carries a finding (monorepo#2748);
#     - a finding in a collapsed section counts, except `🔇 Additional comments` (informational);
#     - a did-not-run marker blocks the green but never discards a finding (monorepo#2764).
#
# USAGE
#   coderabbit-review-verdict.sh --input -
#   stdin: ONE JSON object with exactly the string keys `head`, `author`, `commit_id` and `body`,
#          e.g. from `gh api repos/<o>/<r>/pulls/<n>/reviews/<id> --jq '{head:"<headRefOid>",
#          author:.user.login, commit_id:.commit_id, body:(.body // "")}'`.
#   `head` and `commit_id` must be full 40-character lowercase shas.
#   The caller still owns the freshness bind (submitted after the authenticated request for this
#   head) and every other pentad surface (threads, CI, conflicts); this judges one object only.
#
# OUTPUT (one line on stdout)
#   GREEN            an identified CodeRabbit review of --head with zero actionable findings
#   FINDINGS <n>     an identified review carrying <n> findings (actionable + finding sections)
#   NONE <reason>    not a review result for this head; <reason> is one of not-coderabbit,
#                    other-head, empty-container, not-a-review, did-not-run
#
# EXIT CODES
#   0  GREEN
#   1  FINDINGS or NONE
#   2  usage error or malformed input — nothing was judged
set -euo pipefail

usage() {
  sed -n '19,37p' "$0" >&2
  exit 2
}

[ "$#" -eq 2 ] && [ "$1" = "--input" ] && [ "$2" = "-" ] || usage
command -v jq >/dev/null 2>&1 || {
  echo "coderabbit-review-verdict: jq is required" >&2
  exit 2
}

payload="$(cat)" || exit 2
jq -se 'length == 1 and (.[0] | type == "object"
    and (keys == ["author", "body", "commit_id", "head"])
    and ([.head, .commit_id] | all(type == "string" and length == 40 and (test("[^0-9a-f]") | not)))
    and (.author | type == "string") and (.body | type == "string"))' \
  <<<"$payload" >/dev/null 2>&1 || {
  echo "coderabbit-review-verdict: stdin must be one JSON object with exactly the string keys author, body, commit_id and head (full lowercase shas)" >&2
  exit 2
}

# One jq program decides; bash only maps the line to an exit status.
result="$(jq -r '
  # Strip LEADING HTML comments and whitespace only. An unterminated comment stops the strip
  # rather than consuming the body, so the anchored test below then fails closed.
  def strip:
    sub("^\\s+"; "")
    | if startswith("<!--") then
        (index("-->")) as $i
        | if $i == null then . else (.[$i + 3:] | strip) end
      else . end;

  .body as $body
  | ($body | strip) as $lead
  | ($lead | test("^\\*\\*Actionable comments posted: [0-9]+\\*\\*")) as $marker
  | ($lead | test("^> \\[!CAUTION\\][ \\t]*\\r?\\n> Some comments are outside the diff")) as $outside
  # The count is read from the anchored marker only; a marker whose count cannot be parsed fails
  # the $marker test above, so an unknown count can never read as zero.
  | ([$lead | scan("^\\*\\*Actionable comments posted: ([0-9]+)\\*\\*") | .[0] | tonumber] | first // 0) as $actionable
  | ([$body | scan("<summary>([^<]*comments \\(([0-9]+)\\))</summary>")
      | select(.[0] | test("^🔇 Additional comments \\(") | not) | .[1] | tonumber] | add // 0) as $sections
  | ($actionable + $sections) as $n
  # Only did-not-run markers owned by CodeRabbit count: its structural comment, or a service-shell
  # heading at the start of a line. Prose anywhere in a review can quote those phrases.
  | ($body | test("rate limited by coderabbit\\.ai -->|(\\A|\\n)(> )?#+ (Review limit reached|Review failed|Review skipped)")) as $notrun
  | if .author != "coderabbitai[bot]" then "NONE not-coderabbit"
    elif .commit_id != .head then "NONE other-head"
    elif ($lead | length) == 0 then "NONE empty-container"
    elif ($marker or $outside | not) then "NONE not-a-review"
    elif $n > 0 then "FINDINGS \($n)"
    # The outside-diff shape always carries a finding; a zero count there is a parse miss, not a green.
    elif $outside then "FINDINGS 1"
    elif $notrun then "NONE did-not-run"
    else "GREEN" end
' <<<"$payload")" || exit 2

printf '%s\n' "$result"
[ "$result" = GREEN ]
