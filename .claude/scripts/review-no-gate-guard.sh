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
#     cr      a review object at the head that coderabbit-review-verdict.sh identifies as a review,
#             or that CodeRabbit submitted as APPROVED or CHANGES_REQUESTED; a reply comment that
#             coderabbit-comment-verdict.sh reads as a verdict for the head, or as findings when it
#             follows an authenticated request for this head; the summary comment when
#             coderabbit-summary-verdict.sh reads it as GREEN for the head
#     codex   a review object at the head; a clean-pass comment whose `Reviewed commit` is a prefix
#             (10+ characters) of the head; a `## Review finding` comment whose blob permalinks name
#             the head, or name no commit at all and follow an authenticated request for this head
#     bugbot  a completed `Cursor Bugbot` check-run of the `cursor` app at the head. Only a neutral
#             run titled `Error` is a run that never happened; a success is GREEN, a neutral
#             `Bugbot Review` is FINDINGS, and every other completed run (a failure, a timeout, an
#             unknown title) is UNJUDGED, because nobody has measured what it delivered. A run that
#             has not completed, with no completed review beside it, is UNKNOWN.
#   An authenticated request is a comment by exactly `devantler` that begins with the disclosure
#   line and carries `<!-- review-request-head: <sha> provider=<lane> -->` on a line of its own:
#   a comment that only quotes the marker requested nothing (monorepo#3821).
#   Times are compared as text, which is sound only for `YYYY-MM-DDTHH:MM:SSZ`, the form GitHub
#   answers in. An artifact stamped any other way is UNKNOWN.
#
#   LIMIT: it judges what is published when it runs. A review still being written for another
#   request is invisible to it, so a refusal that arrives first is admitted. The review-request lock
#   is what keeps two requests from being in flight at one head, and a review that lands after a
#   no-gate was recorded supersedes that record.
#
# USAGE
#   review-no-gate-guard.sh --repo <owner>/<repo> --pr <n> --head <sha> --provider <cr|codex|bugbot>
#                           [--round-start <UTC time>]
#   review-no-gate-guard.sh --input <file|-> --head <sha> --provider <cr|codex|bugbot>
#                           [--round-start <UTC time>]
#
#   --head         the FULL 40-character lowercase sha the record would name. With --repo it must
#                  be the pull request's current head: a no-gate is only ever recorded there.
#   --input        a recorded read instead of a live one (`-` reads stdin): exactly ONE JSON object
#                  (a second document, or anything that is not an object, is UNKNOWN) with
#                  the REST lists `reviews` and `comments` (cr, codex) or `check_runs` (bugbot, plus
#                  `comments` when --round-start is given). A list that is missing or null is a
#                  surface that was not read, so the answer is UNKNOWN.
#   --round-start  YYYY-MM-DDTHH:MM:SSZ. Only artifacts at or after this time are considered. Pass
#                  it ONLY when a recorded refutation restarted the review loop at this same head,
#                  and give the time of that resolution record — never the time of a request, or a
#                  duplicate request's refusal would hide the review the first request drew. It is
#                  refused unless an authenticated request for this head on this lane follows it:
#                  the request that restarted the loop.
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
# CodeRabbit and Codex publish reviews and comments, Bugbot check-runs. The request markers live in
# the comments, so a round start needs them on every lane.
need_reviews=0 need_comments=0 need_checks=0
case "$provider" in
  cr | codex) need_reviews=1 need_comments=1 ;;
  bugbot) need_checks=1 ;;
esac
[ -z "$round" ] || need_comments=1
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
  # ONE object: a second document would otherwise be read past, and jq would answer once per
  # document.
  doc="$(jq -ces 'if length == 1 and (.[0] | type == "object") then .[0] else error("not one object") end' <<<"$doc" 2>/dev/null)" ||
    unknown "$source_name must hold exactly one JSON object"
  surface() { # surface <key> — that list from the recorded read
    jq -ce --arg k "$1" ".[\$k] | ${list_of_objects}" <<<"$doc" 2>/dev/null
  }
  if [ "$need_reviews" = 1 ]; then
    reviews="$(surface reviews)" || unknown "$source_name carries no reviews list: that surface was not read"
  fi
  if [ "$need_comments" = 1 ]; then
    comments="$(surface comments)" || unknown "$source_name carries no comments list: that surface was not read"
  fi
  if [ "$need_checks" = 1 ]; then
    checks="$(surface check_runs)" || unknown "$source_name carries no check_runs list: that surface was not read"
  fi
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
  if [ "$need_reviews" = 1 ]; then
    reviews="$(pages "repos/$repo/pulls/$pr/reviews?per_page=100")" || unknown "cannot read $repo#$pr reviews"
  fi
  if [ "$need_comments" = 1 ]; then
    comments="$(pages "repos/$repo/issues/$pr/comments?per_page=100")" || unknown "cannot read $repo#$pr comments"
  fi
  if [ "$need_checks" = 1 ]; then
    # filter=all: the default returns only the newest run of the check, and a failed re-run would
    # then hide the review an earlier run delivered.
    raw="$(gh api --paginate "repos/$repo/commits/$head/check-runs?check_name=Cursor%20Bugbot&filter=all&per_page=100")" ||
      unknown "cannot read the check-runs at $head"
    # The first page states how many runs exist, so a short read is visible.
    checks="$(jq -ces 'if length > 0 and all(.[]; type == "object" and (.check_runs | type == "array"))
        then [.[].check_runs[]] as $runs
          | if ($runs | length) == .[0].total_count then $runs else error("short") end
        else error("no page") end' <<<"$raw" 2>/dev/null)" ||
      unknown "the check-runs read at $head is incomplete"
  fi
fi

# --- Find the lane's reviews of this head ---------------------------------------------------------
requested=""
# scan <jq program> — run it over stdin with the shared arguments and helpers. `at` reads an
# artifact's time and fails when it carries none: that is a read that lost a field, never a reason
# to skip the artifact. `in_round` keeps a time inside the round.
scan() {
  jq -r --arg head "$head" --arg round "$round" --arg provider "$provider" --arg requested "$requested" \
    'def body: .body // "";
     def at: if type == "string" then . else error("an artifact carries no time") end
       | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then . else error("an artifact carries \(.), which is not a UTC time to the second") end;
     def lines: body | gsub("\r"; "") | split("\n") | map(gsub("^[ \t]+|[ \t]+$"; ""));
     def in_round: $round == "" or . >= $round;
     '"$1"
}

# The authenticated requests for this head on this lane: the earliest and the latest. An artifact
# that names no commit can be tied to the head only by following the earliest one.
latest_request=""
if [ "$need_comments" = 1 ]; then
  markers="$(scan '
    [.[]
      | select(.user.login == "devantler" and (body | startswith("> 🤖 Generated by the"))
          and (lines | index("<!-- review-request-head: \($head) provider=\($provider) -->") != null))
      | .created_at | at]
    | [(min // ""), (max // "")] | join(" ")' <<<"$comments")" || unknown "cannot read the request markers"
  requested="${markers%% *}"
  latest_request="${markers##* }"
fi
# A round start is the resolution record that a restarting request followed. With no request after
# it there is no restarted round, only a time chosen to hide a review.
if [ -n "$round" ] && { [ -z "$latest_request" ] || [[ ! "$latest_request" > "$round" ]]; }; then
  unknown "--round-start $round is not followed by an authenticated ${provider} request for $head, so no round was restarted there"
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
    # Candidates carry their position in the list, so the object judged is the object selected.
    candidates="$(scan '
      to_entries[] | .key as $i | .value
      | select(.user.login == "coderabbitai[bot]" and .commit_id == $head)
      | (.submitted_at | at) as $t | select($t | in_round)
      | ["review", $i, .id, $t, "bound", (.state // "-")] | @tsv' <<<"$reviews")" ||
      unknown "cannot scan the reviews"
    # A reply is a candidate when it names this head, or follows the authenticated request for it.
    # The two comment shapes are tested independently: one comment can quote the other marker.
    more="$(scan '
      to_entries[] | .key as $i | .value | select(.user.login == "coderabbitai[bot]")
      | (if body | contains("<!-- This is an auto-generated reply by CodeRabbit -->") then
           (.created_at | at) as $t | select($t | in_round)
           | (if $requested != "" and $t >= $requested then "bound" else "unbound" end) as $bind
           | select($bind == "bound" or (body | contains($head[0:7])))
           | ["comment", $i, .id, $t, $bind, "-"]
         else empty end),
        (if body | contains("<!-- This is an auto-generated comment: summarize by coderabbit.ai -->") then
           (.updated_at | at) as $t | select($t | in_round)
           | ["summary", $i, .id, $t, "bound", "-"]
         else empty end)
      | @tsv' <<<"$comments")" || unknown "cannot scan the comments"
    while IFS=$'\t' read -r kind index id at bind state; do
      [ -n "$kind" ] || continue
      if ! [[ "$index" =~ ^[0-9]+$ && "$id" =~ ^[0-9]+$ ]]; then unknown "an artifact carries no numeric id"; fi
      case "$kind" in
        review)
          payload="$(jq -c --arg head "$head" --argjson i "$index" \
            '.[$i] | {head: $head, author: .user.login, commit_id, body: (.body // "")}' <<<"$reviews")" ||
            unknown "cannot read review $id"
          verdict="$(judge coderabbit-review-verdict.sh "$payload")" || unknown "cannot judge review $id"
          case "$verdict" in
            GREEN) record "$at" "$id" GREEN review ;;
            FINDINGS\ *) record "$at" "$id" FINDINGS review ;;
            # An identified review whose finding count cannot be trusted is still a review.
            "NONE unbalanced-sections" | "NONE hidden-finding-sections") record "$at" "$id" UNJUDGED review ;;
            # An approval or a change request CodeRabbit submitted at this head is its verdict,
            # whatever the body holds.
            *) case "$state" in APPROVED | CHANGES_REQUESTED) record "$at" "$id" UNJUDGED review ;; esac ;;
          esac
          ;;
        comment)
          payload="$(jq -c --arg head "$head" --argjson i "$index" \
            '.[$i] | {head: $head, author: .user.login, body: (.body // "")}' <<<"$comments")" ||
            unknown "cannot read comment $id"
          verdict="$(judge coderabbit-comment-verdict.sh "$payload")" || unknown "cannot judge comment $id"
          case "$verdict" in
            # A verdict reply names its commit, so the helper has already bound it to the head.
            GREEN) record "$at" "$id" GREEN comment ;;
            # A finding reply names no commit: only the request for this head can tie it here.
            FINDINGS\ *) [ "$bind" != bound ] || record "$at" "$id" FINDINGS comment ;;
          esac
          ;;
        summary)
          payload="$(jq -c --arg head "$head" --argjson i "$index" \
            '.[$i] | {head: $head, body: (.body // "")}' <<<"$comments")" || unknown "cannot read comment $id"
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
      .[] | select(.user.login == "chatgpt-codex-connector[bot]" and .commit_id == $head)
      | (.submitted_at | at) as $t | select($t | in_round)
      | [$t, .id, "FINDINGS", "review"] | @tsv' <<<"$reviews")" || unknown "cannot scan the reviews"
    # Both comment shapes are tested on every comment, and a finding outranks a clean pass: a
    # finding can quote the clean-pass sentence.
    more="$(scan '
      .[] | select(.user.login == "chatgpt-codex-connector[bot]")
      | (.created_at | at) as $t | select($t | in_round)
      # A finding names its commit only in its blob permalinks. One that names no commit fails
      # closed onto this head, but only once this head has an authenticated request.
      | [body | scan("/blob/([0-9a-f]{40})/") | .[0]] as $shas
      | ((body | test("(^|\\n)## Review finding"))
          and (any($shas[]; . == $head)
            or (($shas | length) == 0 and $requested != "" and $t >= $requested))) as $finding
      # The clean pass names the commit it reviewed, abbreviated and in backticks.
      | ([body | capture("\\*\\*Reviewed commit:\\*\\*\\s*`?(?<sha>[0-9a-f]{10,40})") | .sha] | first // "") as $sha
      | ((body | test("Didn.t find any major issues")) and $sha != "" and ($head | startswith($sha))) as $clean
      | if $finding then [$t, .id, "FINDINGS", "comment"] | @tsv
        elif $clean then [$t, .id, "GREEN", "comment"] | @tsv
        else empty end' <<<"$comments")" || unknown "cannot scan the comments"
    while IFS=$'\t' read -r at id verdict kind; do
      [ -n "$at" ] || continue
      record "$at" "$id" "$verdict" "$kind"
    done <<<"${lines}"$'\n'"${more}"
    ;;
  bugbot)
    lines="$(scan '
      .[] | select(.app.slug == "cursor" and ((.name // "") | test("bugbot"; "i"))
          and (.head_sha // $head) == $head)
      # A run that has not completed is an accepted request with no answer yet. It has no time, and
      # an empty first field would be swallowed by the tab-separated read below.
      | if .status != "completed" then ["-", .id, "RUNNING", "check"] | @tsv
        else
          (.completed_at | at) as $t | select($t | in_round)
          | if .conclusion == "success" and .output.title == "Bugbot Review" then [$t, .id, "GREEN", "check"] | @tsv
            # A successful run under a title this helper does not know is still a delivered run.
            elif .conclusion == "success" then [$t, .id, "UNJUDGED", "check"] | @tsv
            elif .conclusion == "neutral" and .output.title == "Bugbot Review" then [$t, .id, "FINDINGS", "check"] | @tsv
            # The one measured shape of a run that never happened. It admits.
            elif .conclusion == "neutral" and .output.title == "Error" then empty
            # Every other completed run is a shape nobody has measured: read it by hand.
            else [$t, .id, "UNJUDGED", "check"] | @tsv end
        end' <<<"$checks")" || unknown "cannot scan the check-runs"
    running=""
    while IFS=$'\t' read -r at id verdict kind; do
      [ -n "$id" ] || continue
      if [ "$verdict" = RUNNING ]; then running="$id"; continue; fi
      record "$at" "$id" "$verdict" "$kind"
    done <<<"$lines"
    # A delivered review governs whatever a later run is doing. With none, a run still going
    # may yet deliver one, so nothing is shown either way.
    if [ -z "$found" ] && [ -n "$running" ]; then
      unknown "Bugbot check-run $running at $head has not completed: read again once it has"
    fi
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
