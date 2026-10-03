#!/usr/bin/env bash
# The programs handed to `scan` are literal jq source, so nothing in them is meant to expand.
# shellcheck disable=SC2016
# review-no-gate-guard.sh — may `<provider>:no-gate@<sha>` be recorded for ONE head? (monorepo#3231)
#
# WHY THIS EXISTS
#   A no-gate record says a review lane delivered nothing at a head, and sends the review loop down
#   to the next, more expensive lane. But a lane's refusal answers ONE request, never the head: when
#   two instances request the same head, the lane serves the first request and refuses the second.
#   Measured on platform#3616 (2026-09-06): CodeRabbit submitted a review of the head with two valid
#   findings at 02:31:02Z, answered the duplicate request 41 seconds later with `Action not
#   completed`, and the head was recorded `cr:no-gate`. Weekly-limited Codex and monthly-limited
#   Bugbot were then spent on a head the free lane had already reviewed, and its findings went
#   unread.
#   So this helper never reads the refusal. It looks for the lane's own review of that head, and a
#   review that exists governs whatever a later reply says.
#
#   What counts as a review of the head, per lane (the shapes review-lanes.md accepts):
#     cr      a review object at the head that coderabbit-review-verdict.sh identifies as a review;
#             a reply comment that coderabbit-comment-verdict.sh reads as a verdict for the head, or
#             as findings when it follows an authenticated request for this head; the summary
#             comment when coderabbit-summary-verdict.sh reads it as GREEN for the head
#     codex   a review object at the head; a clean-pass comment whose `Reviewed commit` is a prefix
#             (10+ characters) of the head; a `## Review finding` comment whose blob permalinks name
#             the head, or name no commit at all and follow an authenticated request for this head
#     bugbot  a completed `Cursor Bugbot` check-run of the `cursor` app at the head titled
#             `Bugbot Review` (success or neutral); a neutral `Error` is a run that never happened
#   An authenticated request is a comment by exactly `devantler` that begins with the disclosure
#   line and carries `<!-- review-request-head: <sha> provider=<lane> -->`.
#
# USAGE
#   review-no-gate-guard.sh --repo <owner>/<repo> --pr <n> --head <sha> --provider <cr|codex|bugbot>
#                           [--round-start <UTC time>]
#   review-no-gate-guard.sh --input <file|-> --head <sha> --provider <cr|codex|bugbot>
#                           [--round-start <UTC time>]
#
#   --head         the FULL 40-character lowercase sha the record would name. With --repo it must
#                  be the pull request's current head: a no-gate is only ever recorded there.
#   --input        a recorded read instead of a live one (`-` reads stdin): ONE JSON object with
#                  the REST lists `reviews` and `comments` (cr, codex) or `check_runs` (bugbot). A
#                  list that is missing or null is a surface that was not read, so the answer is
#                  UNKNOWN.
#   --round-start  YYYY-MM-DDTHH:MM:SSZ. Only artifacts at or after this time are considered. Pass
#                  it ONLY when a recorded refutation restarted the review loop at this same head,
#                  and give the time of that resolution record — never the time of a request, or a
#                  duplicate request's refusal would hide the review the first request drew.
#
# OUTPUT (stdout)
#   ADMIT <provider>@<sha> [round-start=<time>]
#       the lane published no review of this head: the no-gate may be recorded
#   REVIEWED <provider>@<sha> <GREEN|FINDINGS|UNJUDGED> <review|comment|summary|check>:<id> <time>
#       one line per review found, oldest first. That review governs: a GREEN satisfies the gate,
#       FINDINGS are fixed or refuted, and UNJUDGED is an identified review to read by hand.
#
# EXIT CODES
#   0  ADMIT
#   1  REVIEWED — never record the no-gate
#   2  UNKNOWN — usage error, a failed or partial read, or a moved head; nothing may be recorded
set -euo pipefail

prog="review-no-gate-guard"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only a verdict may leave with 0 or 1. An abort (a `set -e` or `set -u` stop, which bash 3.2 can
# even report to an EXIT trap as 0) would otherwise read as ADMIT, or as a REVIEWED that printed no
# review. Completion is recorded explicitly, so anything else reports UNKNOWN (monorepo#3414).
review_no_gate_guard_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
review_no_gate_guard_exit() {
  local rc=$?
  if [ "$review_no_gate_guard_finished" != 1 ] && [ "$rc" -ne 2 ]; then
    echo "${prog}: aborted before finishing; reporting UNKNOWN rather than a verdict" >&2
    rc=2
  fi
  exit "$rc"
}
trap review_no_gate_guard_exit EXIT

usage() {
  [ "$#" -eq 0 ] || echo "${prog}: $*" >&2
  sed -n '/^# USAGE/,/^# OUTPUT/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}
unknown() {
  echo "${prog}: UNKNOWN — $*" >&2
  exit 2
}

repo="" pr="" head="" provider="" round="" input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo | --pr | --head | --provider | --round-start | --input)
      [ "$#" -ge 2 ] || usage "$1 needs a value"
      case "$1" in
        --repo) repo="$2" ;;
        --pr) pr="$2" ;;
        --head) head="$2" ;;
        --provider) provider="$2" ;;
        --round-start) round="$2" ;;
        --input) input="$2" ;;
      esac
      shift 2
      ;;
    *) usage "unknown argument: $1" ;;
  esac
done

[[ "$head" =~ ^[0-9a-f]{40}$ ]] || usage "--head must be a full 40-character lowercase sha"
case "$provider" in
  cr | codex | bugbot) ;;
  *) usage "--provider must be cr, codex or bugbot" ;;
esac
[ -z "$round" ] || [[ "$round" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  usage "--round-start must be a UTC time like 2026-09-06T02:31:02Z"
if [ -n "$input" ]; then
  if [ -n "$repo" ] || [ -n "$pr" ]; then usage "give either --input or --repo with --pr, not both"; fi
else
  if [ -z "$repo" ] || [ -z "$pr" ]; then usage "give either --input or --repo with --pr"; fi
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage "--repo must be <owner>/<repo>"
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] || usage "--pr must be a pull request number"
fi
command -v jq >/dev/null 2>&1 || unknown "jq is required"

# --- Read the surfaces this lane publishes on. Every one must arrive whole. -----------------------
reviews="" comments="" checks=""
# A surface is a JSON array of objects. Anything else is a read that did not happen.
list_of_objects='if type == "array" and all(.[]; type == "object") then . else error("not a list of objects") end'

if [ -n "$input" ]; then
  if [ "$input" = "-" ]; then
    source_name="stdin"
    doc="$(cat)" || unknown "cannot read stdin"
  else
    source_name="$input"
    [ -r "$input" ] || unknown "cannot read $input"
    doc="$(cat -- "$input")" || unknown "cannot read $input"
  fi
  surface() { # surface <key> — that list from the recorded read
    jq -ce --arg k "$1" ".[\$k] | ${list_of_objects}" <<<"$doc" 2>/dev/null
  }
  case "$provider" in
    cr | codex)
      reviews="$(surface reviews)" || unknown "$source_name carries no reviews list: that surface was not read"
      comments="$(surface comments)" || unknown "$source_name carries no comments list: that surface was not read"
      ;;
    bugbot)
      checks="$(surface check_runs)" || unknown "$source_name carries no check_runs list: that surface was not read"
      ;;
  esac
else
  command -v gh >/dev/null 2>&1 || unknown "gh is required"
  pull="$(gh api "repos/$repo/pulls/$pr")" || unknown "cannot read $repo#$pr"
  current="$(jq -r '.head.sha // empty' <<<"$pull" 2>/dev/null)" || unknown "cannot read the head of $repo#$pr"
  [ "$current" = "$head" ] ||
    unknown "$repo#$pr is at ${current:-an unreadable head}, not $head: a no-gate is recorded only at the current head"
  pages() { # pages <path> — every page of a REST list, joined; an empty answer is a failed read
    local raw
    raw="$(gh api --paginate "$1")" || return 1
    jq -ces "if length > 0 and all(.[]; type == \"array\") then add | ${list_of_objects} else error(\"no page\") end" \
      <<<"$raw" 2>/dev/null
  }
  case "$provider" in
    cr | codex)
      reviews="$(pages "repos/$repo/pulls/$pr/reviews?per_page=100")" || unknown "cannot read $repo#$pr reviews"
      comments="$(pages "repos/$repo/issues/$pr/comments?per_page=100")" || unknown "cannot read $repo#$pr comments"
      ;;
    bugbot)
      raw="$(gh api --paginate "repos/$repo/commits/$head/check-runs?check_name=Cursor%20Bugbot&per_page=100")" ||
        unknown "cannot read the check-runs at $head"
      # The first page states how many runs exist, so a short read is visible.
      checks="$(jq -ces 'if length > 0 and all(.[]; type == "object" and (.check_runs | type == "array"))
          then [.[].check_runs[]] as $runs
            | if ($runs | length) == .[0].total_count then $runs else error("short") end
          else error("no page") end' <<<"$raw" 2>/dev/null)" ||
        unknown "the check-runs read at $head is incomplete"
      ;;
  esac
fi

# --- Find the lane's reviews of this head ---------------------------------------------------------
requested=""
# scan <jq program> — run it over stdin with the shared arguments and helpers. `in_round` keeps an
# artifact only when it carries a time inside the round.
scan() {
  jq -r --arg head "$head" --arg round "$round" --arg provider "$provider" --arg requested "$requested" \
    'def body: .body // "";
     def in_round: type == "string" and ($round == "" or . >= $round);
     '"$1"
}

# The earliest authenticated request for this head on this lane. An artifact that names no commit
# can be tied to the head only by following that request.
if [ "$provider" != bugbot ]; then
  requested="$(scan '
    [.[]
      | select(.user.login == "devantler" and (body | startswith("> 🤖 Generated by the"))
          and (body | contains("<!-- review-request-head: \($head) provider=\($provider) -->")))
      | .created_at | select(type == "string")] | min // ""' <<<"$comments")" ||
    unknown "cannot read the request markers"
fi

found=""
# record <time> <id> <verdict> <kind> — one review of the head.
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || unknown "an artifact carries no numeric id"
  found="${found}$1"$'\t'"$2"$'\t'"REVIEWED ${provider}@${head} $3 $4:$2 $1"$'\n'
}
# judge <helper> <payload> — print the helper's verdict line. Its exit 2, or a helper that cannot
# run, is a failed judgement: the guard stops rather than skipping the artifact.
judge() {
  local out rc=0
  out="$(bash "${here}/$1" --input - <<<"$2")" || rc=$?
  [ "$rc" -le 1 ] || return 2
  printf '%s\n' "$out"
}

case "$provider" in
  cr)
    candidates="$(scan '
      .[] | select(.user.login == "coderabbitai[bot]" and .commit_id == $head and (.submitted_at | in_round)) | ["review", .id, .submitted_at, "bound"] | @tsv' \
      <<<"$reviews")" || unknown "cannot scan the reviews"
    # A reply is a candidate when it names this head, or follows the authenticated request for it.
    more="$(scan '
      .[] | select(.user.login == "coderabbitai[bot]")
      | if (body | contains("<!-- This is an auto-generated reply by CodeRabbit -->")) and (.created_at | in_round) then
          (if $requested != "" and .created_at >= $requested then "bound" else "unbound" end) as $bind
          | select($bind == "bound" or (body | contains($head[0:7])))
          | ["comment", .id, .created_at, $bind] | @tsv
        elif (body | contains("<!-- This is an auto-generated comment: summarize by coderabbit.ai -->"))
            and (.updated_at | in_round) then
          ["summary", .id, .updated_at, "bound"] | @tsv
        else empty end' <<<"$comments")" || unknown "cannot scan the comments"
    while IFS=$'\t' read -r kind id at bind; do
      [ -n "$kind" ] || continue
      [[ "$id" =~ ^[0-9]+$ ]] || unknown "an artifact carries no numeric id"
      case "$kind" in
        review)
          payload="$(jq -c --arg head "$head" --argjson id "$id" \
            'first(.[] | select(.id == $id)) | {head: $head, author: .user.login, commit_id, body: (.body // "")}' \
            <<<"$reviews")" || unknown "cannot read review $id"
          verdict="$(judge coderabbit-review-verdict.sh "$payload")" || unknown "cannot judge review $id"
          case "$verdict" in
            GREEN) record "$at" "$id" GREEN review ;;
            FINDINGS\ *) record "$at" "$id" FINDINGS review ;;
            # An identified review whose finding count cannot be trusted is still a review.
            "NONE unbalanced-sections" | "NONE hidden-finding-sections") record "$at" "$id" UNJUDGED review ;;
          esac
          ;;
        comment)
          payload="$(jq -c --arg head "$head" --argjson id "$id" \
            'first(.[] | select(.id == $id)) | {head: $head, author: .user.login, body: (.body // "")}' \
            <<<"$comments")" || unknown "cannot read comment $id"
          verdict="$(judge coderabbit-comment-verdict.sh "$payload")" || unknown "cannot judge comment $id"
          case "$verdict" in
            # A verdict reply names its commit, so the helper has already bound it to the head.
            GREEN) record "$at" "$id" GREEN comment ;;
            # A finding reply names no commit: only the request for this head can tie it here.
            FINDINGS\ *) [ "$bind" != bound ] || record "$at" "$id" FINDINGS comment ;;
          esac
          ;;
        summary)
          payload="$(jq -c --arg head "$head" --argjson id "$id" \
            'first(.[] | select(.id == $id)) | {head: $head, body: (.body // "")}' <<<"$comments")" ||
            unknown "cannot read comment $id"
          verdict="$(judge coderabbit-summary-verdict.sh "$payload")" || unknown "cannot judge summary $id"
          # Only GREEN is bound to the head (its range ends there). The findings a summary counts
          # belong to the review object, which is read above.
          [ "$verdict" != GREEN ] || record "$at" "$id" GREEN summary
          ;;
      esac
    done <<<"${candidates}"$'\n'"${more}"
    ;;
  codex)
    lines="$(scan '
      .[] | select(.user.login == "chatgpt-codex-connector[bot]" and .commit_id == $head and (.submitted_at | in_round)) | [.submitted_at, .id, "FINDINGS", "review"] | @tsv' \
      <<<"$reviews")" || unknown "cannot scan the reviews"
    more="$(scan '
      .[] | select(.user.login == "chatgpt-codex-connector[bot]" and (.created_at | in_round))
      | if body | test("Didn.t find any major issues") then
          # The clean pass names the commit it reviewed, abbreviated and in backticks.
          ([body | capture("\\*\\*Reviewed commit:\\*\\*\\s*`?(?<sha>[0-9a-f]{10,40})") | .sha] | first // "") as $sha
          | select($sha != "" and ($head | startswith($sha)))
          | [.created_at, .id, "GREEN", "comment"] | @tsv
        elif body | test("(^|\\n)## Review finding") then
          # A finding names its commit only in its blob permalinks. One that names no commit fails
          # closed onto this head, but only once this head has an authenticated request.
          [body | scan("/blob/([0-9a-f]{40})/") | .[0]] as $shas
          | select(($shas | index($head)) != null
              or (($shas | length) == 0 and $requested != "" and .created_at >= $requested))
          | [.created_at, .id, "FINDINGS", "comment"] | @tsv
        else empty end' <<<"$comments")" || unknown "cannot scan the comments"
    while IFS=$'\t' read -r at id verdict kind; do
      [ -n "$at" ] || continue
      record "$at" "$id" "$verdict" "$kind"
    done <<<"${lines}"$'\n'"${more}"
    ;;
  bugbot)
    lines="$(scan '
      .[] | select(.app.slug == "cursor" and ((.name // "") | test("bugbot"; "i"))
          and (.head_sha // $head) == $head and .status == "completed" and (.completed_at | in_round)
          and .output.title == "Bugbot Review")
      | if .conclusion == "success" then [.completed_at, .id, "GREEN", "check"] | @tsv
        elif .conclusion == "neutral" then [.completed_at, .id, "FINDINGS", "check"] | @tsv
        else empty end' <<<"$checks")" || unknown "cannot scan the check-runs"
    while IFS=$'\t' read -r at id verdict kind; do
      [ -n "$at" ] || continue
      record "$at" "$id" "$verdict" "$kind"
    done <<<"$lines"
    ;;
esac

if [ -n "$found" ]; then
  printf '%s' "$found" | LC_ALL=C sort -t $'\t' -k1,1 -k2,2n | cut -f3-
  review_no_gate_guard_finished=1
  exit 1
fi
if [ -n "$round" ]; then
  echo "ADMIT ${provider}@${head} round-start=${round}"
else
  echo "ADMIT ${provider}@${head}"
fi
review_no_gate_guard_finished=1
