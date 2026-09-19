#!/usr/bin/env bash
# review-lane-health.sh — is each review lane serving ANYWHERE in the portfolio?
#
# The survey reports review state per pull request, so a lane that is down everywhere looks like many
# pull requests that each simply have no review yet. Cursor Bugbot hit its usage limit on 2026-07-21
# and nothing reported it for weeks while drafts parked on it (monorepo#2561). This check computes one
# verdict per lane from the newest artifacts across recently updated pull requests.
#
# It reads only what the lanes publish on GitHub: CodeRabbit and Codex comments and reviews, the
# Cursor Bugbot check-run at each head, and cursor[bot] comments. Each artifact becomes one event:
#   ok    a completed review (with or without findings)
#   fail  a refusal: rate-limit (states a retry window, clears on its own), usage-limit (only an
#         account admin can lift it), or error (a run that did not happen, e.g. Bugbot neutral+Error)
#
# Verdict per lane, from its newest events:
#   OK           the newest event is a completed review
#   LIMITED      the newest event is a rate-limit refusal and the lane served within --stale-hours
#   DOWN         the newest event is a usage-limit refusal (MAINTAINER-ONLY), or a refusal/error with
#                no completed review within --stale-hours
#   NO-EVIDENCE  no artifact from this lane in the window (not requested; says nothing about health)
#
# DETECTION ONLY. A DOWN line is the cue to escalate a maintainer-only limit and to stop spending
# requests on that lane. It is NOT admissible evidence for the Local review round fallback, which
# AGENTS.md requires to rest on a direct per-PR check of all three lanes at the current head.
#
# Usage:
#   review-lane-health.sh [--org ORG] [--since YYYY-MM-DD] [--limit N] [--stale-hours N] [--now EPOCH]
#   review-lane-health.sh --events FILE [--stale-hours N] [--now EPOCH]   # classify recorded events
#
# Events are tab-separated: lane (cr|codex|bugbot), ISO-8601 UTC time, ok|fail, cause (- when ok).
#
# Exit 0  no lane is DOWN
#      1  at least one lane is DOWN
#      2  UNKNOWN — usage error, or a GitHub read failed (a partial sweep is never reported as healthy)
set -euo pipefail

org="devantler-tech" since="" limit=60 stale_hours=72 now="" events_file=""
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --org) org="${2:-}"; shift 2 || usage ;;
    --since) since="${2:-}"; shift 2 || usage ;;
    --limit) limit="${2:-}"; shift 2 || usage ;;
    --stale-hours) stale_hours="${2:-}"; shift 2 || usage ;;
    --now) now="${2:-}"; shift 2 || usage ;;
    --events) events_file="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done
[[ "$limit" =~ ^[0-9]+$ && "$stale_hours" =~ ^[0-9]+$ ]] || usage
[ -z "$now" ] && now="$(date -u +%s)"
[[ "$now" =~ ^[0-9]+$ ]] || usage
command -v jq >/dev/null || { echo "review-lane-health: jq is required — UNKNOWN" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

unknown() { echo "review-lane-health: UNKNOWN — $*" >&2; exit 2; }

# collect_pr <repo> <number> — append this pull request's lane events to $tmp/events.
collect_pr() {
  local repo="$1" n="$2" head
  head="$(gh api "repos/$org/$repo/pulls/$n" --jq '.head.sha')" || unknown "cannot read $repo#$n"
  gh api "repos/$org/$repo/issues/$n/comments" --paginate --jq '.[] | {login: .user.login, at: .updated_at, body: .body}' \
    >"$tmp/comments" || unknown "cannot read $repo#$n comments"
  gh api "repos/$org/$repo/pulls/$n/reviews" --paginate --jq '.[] | {login: .user.login, at: .submitted_at, body: .body}' \
    >"$tmp/reviews" || unknown "cannot read $repo#$n reviews"
  gh api "repos/$org/$repo/commits/$head/check-runs?check_name=Cursor%20Bugbot&per_page=100" \
    --jq '.check_runs[] | {at: .completed_at, conclusion: .conclusion, title: .output.title}' \
    >"$tmp/checks" || unknown "cannot read $repo#$n check-runs"
  jq -r -f "$tmp/classify-comments.jq" "$tmp/comments" "$tmp/reviews" >>"$tmp/events"
  jq -r 'select(.at != null) |
    if .conclusion == "success" or (.conclusion == "neutral" and .title == "Bugbot Review") then
      "bugbot\t\(.at)\tok\t-"
    elif .conclusion == "neutral" then "bugbot\t\(.at)\tfail\terror"
    else empty end' "$tmp/checks" >>"$tmp/events"
}

# One jq program classifies both comments and review objects. A body counts only when its author is
# the lane's own bot; leading HTML comments are stripped before reading CodeRabbit's review marker.
cat >"$tmp/classify-comments.jq" <<'JQ'
def text: (.body // "") | gsub("^(\\s*<!--[\\s\\S]*?-->)*\\s*"; "");
select(.at != null) |
if .login == "coderabbitai[bot]" then
  if (.body // "") | test("Review rate limited|Review limit reached") then "cr\t\(.at)\tfail\trate-limit"
  elif (text | startswith("**Actionable comments posted:"))
    or ((.body // "") | test("No actionable comments were generated|Full review is complete for|Reviewed pull request"))
  then "cr\t\(.at)\tok\t-"
  else empty end
elif .login == "chatgpt-codex-connector[bot]" then
  if (.body // "") | test("reached your Codex usage limits|usage limit"; "i") then "codex\t\(.at)\tfail\tusage-limit"
  elif (.body // "") | test("Didn't find any major issues|## Review finding|\\*\\*Reviewed commit:\\*\\*") then "codex\t\(.at)\tok\t-"
  else empty end
elif .login == "cursor[bot]" then
  if (.body // "") | test("usage limit"; "i") then "bugbot\t\(.at)\tfail\tusage-limit" else empty end
else empty end
JQ

: >"$tmp/events"
if [ -n "$events_file" ]; then
  [ -r "$events_file" ] || unknown "cannot read $events_file"
  cp "$events_file" "$tmp/events"
else
  command -v gh >/dev/null || unknown "gh is required"
  if [ -z "$since" ]; then
    since="$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)"
  fi
  gh search prs --owner "$org" --updated ">=$since" --limit "$limit" --json repository,number \
    --jq '.[] | "\(.repository.name) \(.number)"' >"$tmp/prs" || unknown "cannot search $org pull requests"
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    collect_pr "${pr%% *}" "${pr##* }"
  done <"$tmp/prs"
fi

# Classify: per lane, the newest ok and the newest fail (with its cause).
down=0
for lane in cr codex bugbot; do
  line="$(awk -F'\t' -v l="$lane" '
    $1 == l && $3 == "ok"   && $2 > ok   { ok = $2 }
    $1 == l && $3 == "fail" && $2 > fail { fail = $2; cause = $4 }
    END { printf "%s\t%s\t%s", ok, fail, cause }' "$tmp/events")"
  ok="${line%%$'\t'*}"; rest="${line#*$'\t'}"; fail="${rest%%$'\t'*}"; cause="${rest#*$'\t'}"
  if [ -z "$ok" ] && [ -z "$fail" ]; then
    echo "LANE-HEALTH $lane=NO-EVIDENCE"
    continue
  fi
  if [ -n "$ok" ] && [[ "$ok" > "$fail" || -z "$fail" ]]; then
    echo "LANE-HEALTH $lane=OK last-review $ok"
    continue
  fi
  fresh=0
  if [ -n "$ok" ]; then
    ok_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ok" +%s 2>/dev/null || date -u -d "$ok" +%s)" ||
      unknown "unparseable time $ok"
    [ $((now - ok_epoch)) -le $((stale_hours * 3600)) ] && fresh=1
  fi
  last="${ok:-never}"
  if [ "$cause" = usage-limit ]; then
    echo "LANE-HEALTH $lane=DOWN usage-limit since $fail last-review $last — MAINTAINER-ONLY"
    down=1
  elif [ "$cause" = rate-limit ] && [ "$fresh" = 1 ]; then
    echo "LANE-HEALTH $lane=LIMITED rate-limit at $fail last-review $last"
  else
    echo "LANE-HEALTH $lane=DOWN $cause since $fail last-review $last"
    down=1
  fi
done
exit "$down"
