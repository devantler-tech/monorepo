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
#   ok        a completed review (with or without findings)
#   fail      a refusal: rate-limit (states a retry window, clears on its own), usage-limit (only an
#             account admin can lift it), or error (a run that did not happen, e.g. Bugbot neutral+Error)
#   declined  CodeRabbit refused a disclosed request as context rather than an instruction. A learning
#             it stored on ONE pull request causes this (monorepo#3124), so it never moves the lane
#             verdict; its fourth field names that pull request.
#
# Verdict per lane, from its newest events:
#   OK           the newest event is a completed review
#   LIMITED      the newest event is a rate-limit or error refusal and the lane served within --stale-hours;
#                `until=<UTC>` ends the line when that refusal stated its retry window (`elapsed`
#                follows once --now has passed it). Do not request the lane before it (monorepo#3007).
#   DOWN         the newest event is a usage-limit refusal (MAINTAINER-ONLY), or a refusal/error with
#                no completed review within --stale-hours
#   NO-EVIDENCE  no artifact from this lane in the window (not requested; says nothing about health)
#
# Then one CR-DECLINED line per pull request where CodeRabbit declined a disclosed request. The lane is
# serving elsewhere, so this is neither an outage nor a rate limit: record that pull request's no-gate
# and advance it to the next lane. Only the maintainer can remove the learning (CodeRabbit app,
# Learnings). Without this line every run rediscovers the refusal by spending a request there.
#
# DETECTION ONLY. First verify current applicable unavailability, then stop requesting a DOWN lane
# and escalate a maintainer-only limit. Labels are discovery aids, never fallback evidence on their own. Freshly
# verify the underlying authenticated provider evidence, scope and reset/recovery condition. The
# Local review round still requires direct current-PR reads for all verdicts and findings; verified
# applicable unavailability across all three lanes permits immediate fallback without quota waits.
#
# ONE SWEEP IS SHARED. A sweep reads four lists per pull request, at least 240 REST calls for the
# default 60, from the 5,000 an hour every lane and interactive session shares; both lanes ran it
# dozens of times a day and the budget ran out for hours (monorepo#3973). The verdict is org-wide and
# coarse in time, so a completed sweep is kept in a private per-user cache and reused for
# --cache-seconds (default 900). Only a COMPLETE sweep is stored. A cache that is missing, too old,
# from the future, not this user's own regular file, for other arguments, or malformed in any
# line is ignored and a new sweep runs, so a failed read still reports UNKNOWN and a stored sweep is
# never reported past its lifetime. A reused sweep is announced on stderr; --refresh forces a new one.
#
# A NEW SWEEP ASKS ONLY WHAT CHANGED. Most of what a sweep reads is unchanged since the last one, and
# GitHub does not charge a conditional read it answers with 304 Not Modified. So each read is kept
# with its ETag under <cache-dir>/http-v1 and the next read of that URL sends the ETag back. The kept
# body is used only on gh's exact 304 signal for that tag; any other answer is a full read or UNKNOWN.
# An entry carries its URL and a checksum, so a missing, corrupt or foreign one costs one full read.
# The verdicts are the same as with every read in full; stderr counts the reads answered 304.
#
# Usage:
#   review-lane-health.sh [--org ORG] [--since YYYY-MM-DD] [--limit N] [--stale-hours N] [--now EPOCH]
#                         [--cache-seconds N] [--cache-dir DIR] [--refresh] [--jobs 1..4]
#   review-lane-health.sh --events FILE [--stale-hours N] [--now EPOCH]   # classify recorded events
#
# Events are tab-separated: lane (cr|codex|bugbot), ISO-8601 UTC time, ok|fail|declined, cause (- when
# ok; <repo>#<number> when declined), and optionally the ISO-8601 UTC end of a refusal's stated retry
# window (- or absent when it stated none).
#
# Exit 0  no lane is DOWN (a CR-DECLINED line never changes the exit status)
#      1  at least one lane is DOWN
#      2  UNKNOWN — usage error, or a GitHub read failed (a partial sweep is never reported as healthy)
set -euo pipefail

org="devantler-tech" since="" limit=60 stale_hours=72 now="" events_file=""
cache_seconds=900 cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/review-lane-health" refresh=0 jobs=4
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --org) org="${2:-}"; shift 2 || usage ;;
    --since) since="${2:-}"; shift 2 || usage ;;
    --limit) limit="${2:-}"; shift 2 || usage ;;
    --stale-hours) stale_hours="${2:-}"; shift 2 || usage ;;
    --now) now="${2:-}"; shift 2 || usage ;;
    --events) events_file="${2:-}"; shift 2 || usage ;;
    --cache-seconds) cache_seconds="${2:-}"; shift 2 || usage ;;
    --cache-dir) cache_dir="${2:-}"; shift 2 || usage ;;
    --refresh) refresh=1; shift ;;
    --jobs) jobs="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done
[[ "$limit" =~ ^[0-9]+$ && "$stale_hours" =~ ^[0-9]+$ && "$cache_seconds" =~ ^[0-9]+$ ]] || usage
[[ "$jobs" =~ ^[1-4]$ ]] || usage
[ -n "$cache_dir" ] || usage
[ -z "$now" ] && now="$(date -u +%s)"
[[ "$now" =~ ^[0-9]+$ ]] || usage
command -v jq >/dev/null || { echo "review-lane-health: jq is required — UNKNOWN" >&2; exit 2; }

tmp="$(mktemp -d)"
# Bash 3.2 reports a `set -u` abort to an EXIT trap as status 0, and the trap's own successful
# cleanup then becomes the script's status. Completion is recorded explicitly, so reaching the end is
# the only way a zero status leaves this script; an abort reports UNKNOWN (monorepo#3414).
review_lane_health_finished=0
review_cleanup_scope=$BASH_SUBSHELL
sweep_pids=''
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
review_lane_health_cleanup() {
  local rc=$? pid
  # Errexit can unwind a worker's locals before EXIT on Bash 3.2. Its inherited
  # parent bindings must never authorize cleanup in a different subshell.
  if [ "$BASH_SUBSHELL" -eq "$review_cleanup_scope" ]; then
    for pid in $sweep_pids; do wait "$pid" || true; done
    rm -rf "$tmp"
  fi
  if [ "$review_lane_health_finished" != 1 ] && [ "$rc" -ne 2 ]; then
    echo "review-lane-health: aborted before finishing; reporting UNKNOWN rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
install_cleanup() {
  trap review_lane_health_cleanup EXIT
  trap 'exit 2' HUP INT TERM
}
install_cleanup

unknown() { echo "review-lane-health: UNKNOWN — $*" >&2; exit 2; }

# Conditional reads (monorepo#3973). An entry is one file named by a checksum of its URL: a version
# line, `url`, `etag`, `next` (whether its response linked a next page), `sum` (cksum of the body),
# then the body. Only ETag is used: Last-Modified has one-second resolution, so a second change within
# the same second would replay a stale body, and the list reads do not send it.
http_dir="$cache_dir/http-v1" http_magic="# review-lane-health http-v1" http_usable=0
http_reads=0 http_replays=0 http_unstored=0 http_unconfirmed=0
etag_re='^(W/)?"[[:alnum:]._:+/=-]+"$'
checksum() { cksum | awk '{ print $1 "-" $2 }'; }
# opaque <entity tag> — If-None-Match compares tags weakly, and GitHub sends W/"x" with a 200 but "x"
# with the 304 that matches it.
opaque() { printf '%s' "${1#W/}"; }
# http_header <name> — the first value of that header in the last response.
http_header() {
  awk -v n="$1" 'BEGIN { n = tolower(n) ":" }
    tolower(substr($0, 1, length(n))) == n {
      v = substr($0, length(n) + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v; exit }' \
    "$tmp/http-head"
}

# http_entry <file> <path> — copy the stored read of <path> to $tmp/http-stored and set http_tag and
# http_stored_next; false for anything but an intact, private entry for exactly that path.
http_entry() {
  local f="$1" path="$2" magic url tag next sum
  http_tag="" http_stored_next=0
  rm -f "$tmp/http-stored" # never leave the previous read's body where this one's is looked for
  [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] && [ -r "$f" ] || return 1
  cp "$f" "$tmp/http-entry" 2>/dev/null || return 1
  { IFS= read -r magic && IFS= read -r url && IFS= read -r tag && IFS= read -r next && IFS= read -r sum; } \
    <"$tmp/http-entry" || return 1
  [ "$magic" = "$http_magic" ] && [ "$url" = "url $path" ] || return 1
  [[ "$tag" == "etag "* && "$next" == "next "* && "$sum" == "sum "* ]] || return 1
  tag="${tag#etag }" next="${next#next }" sum="${sum#sum }"
  [[ "$tag" =~ $etag_re && "$next" =~ ^[01]$ ]] || return 1
  tail -n +6 "$tmp/http-entry" >"$tmp/http-stored" 2>/dev/null || return 1
  [ "$(checksum <"$tmp/http-stored")" = "$sum" ] || return 1
  jq -e 'type == "array" or type == "object"' "$tmp/http-stored" >/dev/null 2>&1 || return 1
  http_tag="$tag" http_stored_next="$next"
}

# http_request <path> [entity tag] — one GET, conditional when a tag is given. Leaves the status code
# in http_status, the headers in $tmp/http-head, the body in $tmp/http-body, gh's stderr in
# $tmp/http-err, and returns gh's exit status.
http_request() {
  local rc=0
  http_reads=$((http_reads + 1)) http_status=""
  if [ -n "${2:-}" ]; then
    GH_NO_UPDATE_NOTIFIER=1 gh api --include -H "If-None-Match: $2" "$1" </dev/null \
      >"$tmp/http-raw" 2>"$tmp/http-err" || rc=$?
  else
    GH_NO_UPDATE_NOTIFIER=1 gh api --include "$1" </dev/null >"$tmp/http-raw" 2>"$tmp/http-err" || rc=$?
  fi
  : >"$tmp/http-head"
  : >"$tmp/http-body"
  # gh prints the status line, the headers ending in CRLF, an empty line, then the body.
  awk -v h="$tmp/http-head" -v b="$tmp/http-body" 'NR == 1 { next }
    body { print > b; next } { sub(/\r$/, "") } $0 == "" { body = 1; next } { print > h }' \
    "$tmp/http-raw" || return 99
  http_status="$(awk 'NR == 1 && $1 ~ /^HTTP\/[0-9.]+$/ && $2 ~ /^[0-9][0-9][0-9]$/ { print $2 }' \
    "$tmp/http-raw")" || return 99
  return "$rc"
}

# http_take <path> <body file> <entry> — accept a 200 just read: hand its body on and store it.
http_take() {
  local tag
  cp "$tmp/http-body" "$2" || return 1
  grep -qiE '^link:.*rel="next"' "$tmp/http-head" && http_next=1
  tag="$(http_header etag)"
  [ -n "$3" ] && [[ "$tag" =~ $etag_re ]] || return 0
  # Storing is best-effort, as for the sweep: a read that cannot be kept is simply read in full later.
  (
    umask 077
    part="$(mktemp "$http_dir/.part.XXXXXX")" || exit 1
    # rm first: mv onto a symlink to a directory would move the body into the link's target.
    { printf '%s\nurl %s\netag %s\nnext %s\nsum %s\n' "$http_magic" "$1" "$tag" "$http_next" \
      "$(checksum <"$2")" && cat "$2"; } >"$part" && rm -f "$3" && mv -f "$part" "$3" ||
      { rm -f "$part"; exit 1; }
  ) 2>/dev/null || http_unstored=$((http_unstored + 1))
}

# http_get <path> <body file> — read <path>, revalidating its stored read when one is usable. Sets
# http_next=1 when the response linked a next page. False on any read that is neither a 200 nor gh's
# exact 304 signal for the tag that was sent, so a failed read never falls back to a stored body.
http_get() {
  local path="$1" out="$2" entry="" tag="" rc=0
  http_next=0
  if [ "$http_usable" = 1 ]; then
    entry="$http_dir/$(printf '%s' "$path" | checksum)"
    http_entry "$entry" "$path" && tag="$http_tag"
  fi
  http_request "$path" "$tag" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$http_status" = 200 ]; then
    http_take "$path" "$out" "$entry"
    return
  fi
  [ "$http_status" = 304 ] || return 1
  if [ -n "$tag" ] && [ "$rc" -eq 1 ] && [ "$(cat "$tmp/http-err")" = "gh: HTTP 304" ] &&
    [ "$(opaque "$(http_header etag)")" = "$(opaque "$tag")" ]; then
    cp "$tmp/http-stored" "$out" || return 1
    http_next="$http_stored_next" http_replays=$((http_replays + 1))
    touch "$entry" 2>/dev/null || true # pruning goes by last use
    return 0
  fi
  # Any other 304 — another tag, no tag sent, or not gh's exact signal (GH_DEBUG output, a new gh
  # notice) — confirms nothing about the stored body: read it in full, so it never becomes either a
  # replay or an UNKNOWN that every later sweep repeats.
  http_unconfirmed=$((http_unconfirmed + 1)) rc=0
  http_request "$path" || rc=$?
  [ "$rc" -eq 0 ] && [ "$http_status" = 200 ] || return 1
  http_take "$path" "$out" "$entry"
}

# http_list <path> <jq filter> <out> — every page of a list, 100 items a page, through http_get, each
# item through <filter>. Pages are walked by number and a full page always reads the next one: a 304
# for a full page replays its old links, so it cannot say whether a next page has appeared since.
# This relies on GitHub serving the 100 asked for, its documented maximum for both list reads.
http_list() {
  local path="$1" filter="$2" out="$3" page=1 n
  : >"$out"
  while :; do
    http_get "$path?per_page=100&page=$page" "$tmp/http-page" || return 1
    n="$(jq 'if type == "array" then length else error("not a list") end' "$tmp/http-page" 2>/dev/null)" ||
      return 1
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    jq -c "$filter" "$tmp/http-page" >>"$out" || return 1
    [ "$n" -gt 0 ] && { [ "$n" -ge 100 ] || [ "$http_next" = 1 ]; } || return 0
    page=$((page + 1))
    [ "$page" -le 100 ] || return 1 # 10,000 items: something is wrong, and a cut-off list is no pass
  done
}

# collect_pr <repo> <number> — append this pull request's lane events to $tmp/events.
collect_pr() {
  local repo="$1" n="$2" head
  http_get "repos/$org/$repo/pulls/$n" "$tmp/pull" || unknown "cannot read $repo#$n"
  head="$(jq -r '.head.sha' "$tmp/pull")" || unknown "cannot read $repo#$n"
  http_list "repos/$org/$repo/issues/$n/comments" \
    '.[] | {kind: "comment", login: .user.login, at: .updated_at, body: .body}' \
    "$tmp/comments" || unknown "cannot read $repo#$n comments"
  http_list "repos/$org/$repo/pulls/$n/reviews" \
    '.[] | {kind: "review", login: .user.login, at: .submitted_at, state: .state, body: .body}' \
    "$tmp/reviews" || unknown "cannot read $repo#$n reviews"
  http_get "repos/$org/$repo/commits/$head/check-runs?check_name=Cursor%20Bugbot&per_page=100" \
    "$tmp/check-runs" || unknown "cannot read $repo#$n check-runs"
  jq -c '.check_runs[] | {app: .app.slug, at: .completed_at, conclusion: .conclusion, title: .output.title}' \
    "$tmp/check-runs" >"$tmp/checks" || unknown "cannot read $repo#$n check-runs"
  jq -r --arg pr "$repo#$n" -f "$tmp/classify-comments.jq" "$tmp/comments" "$tmp/reviews" >>"$tmp/events"
  # Only the Cursor app's run, and only the three documented conclusion/title pairs, count.
  jq -r 'select(.at != null and .app == "cursor") |
    if (.conclusion == "success" or .conclusion == "neutral") and .title == "Bugbot Review" then
      "bugbot\t\(.at)\tok\t-"
    elif .conclusion == "neutral" and .title == "Error" then "bugbot\t\(.at)\tfail\terror"
    else empty end' "$tmp/checks" >>"$tmp/events"
}

# Independent PR reads overlap, but each collector owns its complete scratch directory.
# Join the whole bounded batch, then merge results in search order. A failed worker never
# contributes a verdict or a completed sweep; successful per-URL HTTP entries stay valid.
# --jobs 1 retains the original serial control (monorepo#4491).
collect_prs() {
  local parent_tmp=$tmp pr count=0 ids='' id pid failed=0 a b c d extra
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    if [ "$jobs" = 1 ]; then
      collect_pr "${pr%% *}" "${pr##* }"
      continue
    fi
    count=$((count + 1))
    mkdir "$parent_tmp/worker-$count" "$parent_tmp/result-$count" || unknown 'cannot allocate collector scratch'
    collect_worker "$parent_tmp" "$count" "${pr%% *}" "${pr##* }" \
      2>"$parent_tmp/result-$count/err" &
    sweep_pids="$sweep_pids $!"
    ids="$ids $count"
    if [ $((count % jobs)) -ne 0 ]; then continue; fi
    finish_collectors
  done <"$parent_tmp/prs"
  [ -z "$sweep_pids" ] || finish_collectors
}

# Called only as a background job: local scratch/counters stay private, and explicit
# exit keeps them bound through cleanup. It exports only complete result files.
collect_worker() {
  local tmp="$1/worker-$2" result_dir="$1/result-$2" sweep_pids=''
  local http_reads=0 http_replays=0 http_unstored=0 http_unconfirmed=0
  local review_lane_health_finished=0
  local review_cleanup_scope=$BASH_SUBSHELL
  install_cleanup
  # A trapped signal waits for the foreground gh child before exiting, so an
  # interrupted collector cannot leave that child writing into removed scratch.
  cp "$1/classify-comments.jq" "$tmp/classify-comments.jq"
  : >"$tmp/events"
  collect_pr "$3" "$4"
  cp "$tmp/events" "$result_dir/events"
  printf '%s %s %s %s\n' "$http_reads" "$http_replays" "$http_unstored" "$http_unconfirmed" \
    >"$result_dir/stats"
  review_lane_health_finished=1
  # Exit while the worker's local scratch still binds the inherited EXIT handler.
  exit 0
}

# Uses collect_prs' dynamically scoped batch locals; no caller may remove worker scratch
# until every wait has completed, even when the first worker failed.
finish_collectors() {
  for pid in $sweep_pids; do wait "$pid" || failed=1; done
  sweep_pids=''
  if [ "$failed" != 0 ]; then
    for id in $ids; do cat "$parent_tmp/result-$id/err" >&2; done
    unknown 'pull-request collector failed'
  fi
  for id in $ids; do
    read -r a b c d extra <"$parent_tmp/result-$id/stats" || unknown 'collector counters missing'
    [[ "$a $b $c $d" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ && -z "$extra" ]] || unknown 'invalid collector counters'
    cat "$parent_tmp/result-$id/events" >>"$parent_tmp/events" || unknown 'collector events unreadable'
    http_reads=$((http_reads + a)) http_replays=$((http_replays + b))
    http_unstored=$((http_unstored + c)) http_unconfirmed=$((http_unconfirmed + d))
  done
  ids=''
}

# One jq program classifies comments and review objects. Each lane counts only its own bot and only
# exact artifact shapes, so a review that merely discusses a rate or usage limit is never a refusal.
# CodeRabbit's auto-generated summary is not evidence: a refusal refreshes it.
cat >"$tmp/classify-comments.jq" <<'JQ'
def body: .body // "";
def text: body | gsub("^(\\s*<!--[\\s\\S]*?-->)*\\s*"; "");
def invocation: body | contains("<!-- CodeRabbit review command invocation");
# A review whose findings all sit outside the diff opens with this block instead of the marker.
def review_body: text | startswith("**Actionable comments posted:")
  or startswith("> [!CAUTION]\n> Some comments are outside the diff");
# The refusal's own retry window ("Next included review available in 51 minutes", "available in:
# 16 minutes", "available in **1 hour and 5 minutes**", "available in 40 seconds") as the UTC time
# it ends; - when it states none. Whole-minute waits are rounded down by the provider,
# so reserve one more minute unless seconds were stated explicitly (monorepo#4101).
def retry_until:
  ([body | capture("available in:?[*\\s]*(?:(?<h>[0-9]+)\\s*hours?[,\\s]*(?:and\\s*)?)?(?:(?<m>[0-9]+)\\s*minutes?[,\\s]*(?:and\\s*)?)?(?:(?<s>[0-9]+)\\s*seconds?)?"; "i")]
    | map(select(.h != null or .m != null or .s != null)) | first) as $w
  | if $w == null then "-"
    else (.at | fromdateiso8601) + (($w.h // "0" | tonumber) * 3600) + (($w.m // "0" | tonumber) * 60)
      + ($w.s // "0" | tonumber)
      + (if $w.s == null then 60 else 0 end)
      | todateiso8601 end;
select(.at != null) |
if .login == "coderabbitai[bot]" then
  if (body | contains("<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->"))
    or (invocation and (body | contains("Review rate limited")))
  then "cr\t\(.at)\tfail\trate-limit\t\(retry_until)"
  # A chat reply (never a review or command reply) that calls a disclosed request context and says it
  # started nothing. The wording varies per reply, so both halves are matched loosely but required.
  elif .kind == "comment" and (invocation | not)
    and (body | contains("<!-- This is an auto-generated reply by CodeRabbit -->"))
    and (body | test("disclosed[^\n]*\\bcontext\\b"; "i"))
    and (body | test("did not (start|trigger)|does not authorize|not a maintainer instruction|maintainer-authenticated"; "i"))
  then "cr\t\(.at)\tdeclined\t\($pr)"
  elif (.kind == "review" and review_body)
    or (invocation and (body | test("Full review is complete for [0-9a-f]{7,40}|Reviewed pull request .* at `?[0-9a-f]{7,40}")))
  then "cr\t\(.at)\tok\t-"
  else empty end
elif .login == "chatgpt-codex-connector[bot]" then
  if .kind == "review" then "codex\t\(.at)\tok\t-"
  elif body | test("## Review finding|Didn't find any major issues") then "codex\t\(.at)\tok\t-"
  elif body | contains("You have reached your Codex usage limits") then "codex\t\(.at)\tfail\tusage-limit"
  else empty end
elif .login == "cursor[bot]" then
  # Bugbot's review object outlives the check-run, which is read only at the current head: without
  # it, one push after a completed review hides it and an old usage-limit notice stays the newest
  # event, so a working lane reads DOWN (monorepo#4397).
  if .kind == "review" and (body | contains("<!-- BUGBOT_REVIEW -->")) then "bugbot\t\(.at)\tok\t-"
  elif body | contains("usage limit reached") then "bugbot\t\(.at)\tfail\tusage-limit" else empty end
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
  # The stored sweep is named and headed by the arguments that decide what a sweep reads, so a sweep
  # for other arguments is never reused. Arguments that cannot be a safe file name are not cached.
  # Version the file name too: a still-running older collector must not overwrite this format.
  cache_file="" cache_head="# review-lane-health sweep-v2 org=$org since=$since limit=$limit at="
  if [ "$cache_seconds" -gt 0 ] && [[ "$org" =~ ^[A-Za-z0-9._-]+$ && "$since" =~ ^[0-9-]+$ ]]; then
    cache_file="$cache_dir/$org.$since.$limit.v2.events"
  fi
  # cache_usable — true only for a private regular file of this user whose first line names these
  # arguments and a sweep time within the lifetime, and whose every other line is a well-formed event.
  cache_usable() {
    local first at
    [ -n "$cache_file" ] && [ "$refresh" = 0 ] || return 1
    [ -f "$cache_file" ] && [ ! -L "$cache_file" ] && [ -O "$cache_file" ] && [ -r "$cache_file" ] || return 1
    IFS= read -r first <"$cache_file" || return 1
    [ "${first#"$cache_head"}" != "$first" ] || return 1
    at="${first#"$cache_head"}"
    [[ "$at" =~ ^[0-9]+$ ]] && [ "$at" -le "$now" ] && [ $((now - at)) -le "$cache_seconds" ] || return 1
    awk -F'\t' 'NR == 1 { next }
      !((NF == 4 || NF == 5) && $1 ~ /^(cr|codex|bugbot)$/ && $3 ~ /^(ok|fail|declined)$/ &&
        $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) { bad = 1 }
      END { exit bad }' "$cache_file" || return 1
    cache_at="$at"
  }
  if cache_usable; then
    sed 1d "$cache_file" >"$tmp/events" || unknown "cannot read $cache_file"
    echo "review-lane-health: reusing the sweep taken at epoch $cache_at ($((now - cache_at))s old); --refresh forces a new one" >&2
  else
    if (umask 077 && mkdir -p "$http_dir") 2>/dev/null && [ -d "$http_dir" ] && [ ! -L "$http_dir" ] &&
      [ -O "$http_dir" ] && [ -w "$http_dir" ]; then
      http_usable=1
    else
      echo "review-lane-health: no conditional cache in $http_dir; every read is a full one" >&2
    fi
    gh search prs --owner "$org" --updated ">=$since" --archived=false --sort updated --order desc \
      --limit "$limit" --json repository,number \
      --jq '.[] | "\(.repository.name) \(.number)"' >"$tmp/prs" || unknown "cannot search $org pull requests"
    collect_prs
    echo "review-lane-health: $http_reads REST reads, $http_replays answered 304 Not Modified (not charged)" >&2
    if [ "$http_usable" = 1 ]; then
      [ "$http_unstored" -eq 0 ] ||
        echo "review-lane-health: $http_unstored reads could not be kept; they are read in full next time" >&2
      [ "$http_unconfirmed" -eq 0 ] ||
        echo "review-lane-health: $http_unconfirmed answers of 304 were not gh's exact signal for the tag sent; read in full" >&2
      # Entries are touched on every use: drop those no sweep has used for more than two days.
      find "$http_dir" -maxdepth 1 -type f -mtime +2 -exec rm -f {} + 2>/dev/null || true
    fi
    # Every read above succeeded, or the script has already exited UNKNOWN: only a complete sweep is
    # stored. It is dated at this run's start, so it expires no later than its oldest read allows.
    # Storing is best-effort: the verdict below stands on the sweep, not on the cache.
    if [ -n "$cache_file" ]; then
      if (
        umask 077
        mkdir -p "$cache_dir" && part="$(mktemp "$cache_dir/.part.XXXXXX")" || exit 1
        { printf '%s%s\n' "$cache_head" "$now" && cat "$tmp/events"; } >"$part" &&
          mv -f "$part" "$cache_file" || { rm -f "$part"; exit 1; }
        # The name carries --since, which moves every day: drop what yesterday left behind.
        find "$cache_dir" -maxdepth 1 -type f \( -name '*.events' -o -name '.part.*' \) -mtime +1 \
          -exec rm -f {} + || true
      ) 2>/dev/null; then :
      else
        echo "review-lane-health: could not store the sweep in $cache_dir; the next call sweeps again" >&2
      fi
    fi
  fi
fi

# to_epoch <ISO-8601 UTC> — BSD and GNU date spell the parse differently.
to_epoch() { date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }

# Classify: per lane, the newest ok, the newest fail (with its cause), the newest usage-limit, and the
# latest stated retry window. CodeRabbit posts each refusal twice (summary and command reply) and only
# one may state the window, so the window comes from the latest refusal that states one, unless it
# ended before the newest refusal.
down=0
for lane in cr codex bugbot; do
  line="$(awk -F'\t' -v l="$lane" '
    $1 == l && $3 == "ok"   && $2 > ok   { ok = $2 }
    $1 == l && $3 == "fail" && $2 > fail { fail = $2; cause = $4 }
    $1 == l && $3 == "fail" && $5 != "" && $5 != "-" && ($2 > win_at || ($2 == win_at && $5 > win)) { win_at = $2; win = $5 }
    $1 == l && $4 == "usage-limit" && $2 > ul { ul = $2 }
    END { if (win < fail) win = ""; printf "%s|%s|%s|%s|%s", ok, fail, cause, ul, win }' "$tmp/events")"
  IFS="|" read -r ok fail cause ul win <<<"$line" || true
  if [ -z "$ok" ] && [ -z "$fail" ]; then
    echo "LANE-HEALTH $lane=NO-EVIDENCE"
    continue
  fi
  if [ -n "$ok" ] && [[ "$ok" > "$fail" || -z "$fail" ]]; then
    echo "LANE-HEALTH $lane=OK last-review $ok"
    continue
  fi
  # Bugbot posts its usage-limit comment moments before the failed check completes, so the check's
  # generic error takes its cause from a usage-limit notice within 15 minutes of it.
  if [ "$cause" = error ] && [ -n "$ul" ]; then
    fail_epoch="$(to_epoch "$fail")" || unknown "unparseable time $fail"
    ul_epoch="$(to_epoch "$ul")" || unknown "unparseable time $ul"
    gap=$((fail_epoch - ul_epoch)); [ "$gap" -lt 0 ] && gap=$((-gap))
    [ "$gap" -le 900 ] && cause=usage-limit
  fi
  fresh=0
  if [ -n "$ok" ]; then
    ok_epoch="$(to_epoch "$ok")" || unknown "unparseable time $ok"
    [ $((now - ok_epoch)) -le $((stale_hours * 3600)) ] && fresh=1
  fi
  last="${ok:-never}"
  if [ "$cause" = usage-limit ]; then
    echo "LANE-HEALTH $lane=DOWN usage-limit since $fail last-review $last — MAINTAINER-ONLY"
    down=1
  elif [ "$fresh" = 1 ]; then
    # The window the refusal stated, so a later run can tell "retry at T" from "refused an hour ago".
    window=""
    if [ -n "$win" ]; then
      win_epoch="$(to_epoch "$win")" || unknown "unparseable time $win"
      window=" until=$win"
      [ "$now" -ge "$win_epoch" ] && window="$window elapsed"
    fi
    echo "LANE-HEALTH $lane=LIMITED $cause at $fail last-review $last$window"
  else
    echo "LANE-HEALTH $lane=DOWN $cause since $fail last-review $last"
    down=1
  fi
done

# Pull-request-scoped refusals, newest per pull request, after the lane verdicts they do not affect.
awk -F'\t' '$1 == "cr" && $3 == "declined" && $2 > at[$4] { at[$4] = $2 }
  END { for (pr in at) print pr "\t" at[pr] }' "$tmp/events" | sort |
  while IFS=$'\t' read -r pr at; do
    echo "CR-DECLINED $pr at $at — PR-scoped learning; advance this PR to the next lane (MAINTAINER-ONLY removal)"
  done
review_lane_health_finished=1
exit "$down"
