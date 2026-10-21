#!/usr/bin/env bash
# RED/GREEN coverage for review-lane-health.sh: each verdict from recorded events, the artifact
# classification against a stub gh, and a failed read reported as UNKNOWN.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$root/.claude/scripts/review-lane-health.sh"
tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$tmp"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then
    echo "review-lane-health.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    exit 1
  fi
}
trap on_exit EXIT
fail() { echo "review-lane-health test: $*" >&2; exit 1; }

now=1790000000 # 2026-09-21T14:13:20Z
# Every run names a cache directory inside $tmp and leaves the sweep cache off, so no case reads the
# real per-user cache or another case's sweep; the cache cases below switch it on. The conditional
# cache under it stays on, so later cases also replay 304s; the cases at the end start it empty.
# $at overrides the clock.
run() {
  set +e
  "$checker" --cache-dir "$tmp/cache" --cache-seconds 0 "$@" --now "${at:-$now}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
}
expect() { # <label> <rc> <line fragment>
  [ "$rc" -eq "$2" ] || { cat "$tmp/out" "$tmp/err" >&2; fail "$1: rc=$rc, want $2"; }
  grep -qF -- "$3" "$tmp/out" || { cat "$tmp/out" >&2; fail "$1: missing '$3'"; }
}
events() { printf '%b' "$1" >"$tmp/events"; run --events "$tmp/events"; }

events 'cr\t2026-09-21T10:00:00Z\tfail\trate-limit\ncr\t2026-09-21T11:00:00Z\tok\t-\n'
expect "review after a refusal" 0 "cr=OK last-review 2026-09-21T11:00:00Z"
grep -qF "codex=NO-EVIDENCE" "$tmp/out" || fail "a lane without artifacts must be NO-EVIDENCE"

events 'codex\t2026-09-21T09:00:00Z\tok\t-\ncodex\t2026-09-21T10:00:00Z\tfail\tusage-limit\n'
expect "usage limit" 1 "codex=DOWN usage-limit since 2026-09-21T10:00:00Z last-review 2026-09-21T09:00:00Z — MAINTAINER-ONLY"

events 'cr\t2026-09-21T12:00:00Z\tok\t-\ncr\t2026-09-21T13:00:00Z\tfail\trate-limit\n'
expect "fresh rate limit" 0 "cr=LIMITED rate-limit at 2026-09-21T13:00:00Z"
grep -qF "until=" "$tmp/out" && fail "a refusal that stated no window must print no until="

# A refusal that states its retry window carries the time it ends, so a later run can tell "retry at T"
# from "refused an hour ago" (monorepo#3007); once now passes it the line says so.
events 'cr\t2026-09-21T12:00:00Z\tok\t-\ncr\t2026-09-21T13:00:00Z\tfail\trate-limit\t2026-09-21T15:00:00Z\n'
expect "pending window" 0 "cr=LIMITED rate-limit at 2026-09-21T13:00:00Z last-review 2026-09-21T12:00:00Z until=2026-09-21T15:00:00Z"
grep -qF "elapsed" "$tmp/out" && fail "a window that has not ended must not say elapsed"
events 'cr\t2026-09-21T12:00:00Z\tok\t-\ncr\t2026-09-21T13:00:00Z\tfail\trate-limit\t2026-09-21T13:30:00Z\n'
expect "elapsed window" 0 "until=2026-09-21T13:30:00Z elapsed"
# CodeRabbit posts each refusal twice and only one may state the window: the pair keeps it.
events 'cr\t2026-09-21T12:00:00Z\tok\t-\ncr\t2026-09-21T13:00:00Z\tfail\trate-limit\t2026-09-21T15:00:00Z\ncr\t2026-09-21T13:00:03Z\tfail\trate-limit\t-\n'
expect "window from the paired refusal" 0 "cr=LIMITED rate-limit at 2026-09-21T13:00:03Z last-review 2026-09-21T12:00:00Z until=2026-09-21T15:00:00Z"
# A later refusal's window replaces an earlier one, even when it ends sooner.
events 'cr\t2026-09-21T11:00:00Z\tok\t-\ncr\t2026-09-21T12:00:00Z\tfail\trate-limit\t2026-09-21T16:00:00Z\ncr\t2026-09-21T13:00:00Z\tfail\trate-limit\t2026-09-21T15:00:00Z\n'
expect "latest stated window" 0 "until=2026-09-21T15:00:00Z"
# A window that ended before a later refusal says nothing about the later one.
events 'cr\t2026-09-21T11:00:00Z\tok\t-\ncr\t2026-09-21T12:00:00Z\tfail\trate-limit\t2026-09-21T12:30:00Z\ncr\t2026-09-21T13:00:00Z\tfail\trate-limit\t-\n'
expect "stale window" 0 "cr=LIMITED rate-limit at 2026-09-21T13:00:00Z"
grep -qF "until=" "$tmp/out" && fail "a window that ended before the newest refusal must print no until="

# A rate limit that has outlasted the stale window is an outage, not a pause.
events 'cr\t2026-09-17T09:00:00Z\tok\t-\ncr\t2026-09-21T13:00:00Z\tfail\trate-limit\n'
expect "stale rate limit" 1 "cr=DOWN rate-limit since 2026-09-21T13:00:00Z last-review 2026-09-17T09:00:00Z"

events 'bugbot\t2026-09-21T13:00:00Z\tfail\terror\n'
expect "error with no review ever" 1 "bugbot=DOWN error since 2026-09-21T13:00:00Z last-review never"

# A generic error shortly after a review is a pause, not an outage.
events 'bugbot\t2026-09-21T12:00:00Z\tok\t-\nbugbot\t2026-09-21T13:00:00Z\tfail\terror\n'
expect "fresh error" 0 "bugbot=LIMITED error at 2026-09-21T13:00:00Z"

# A declined request is scoped to its pull request: it never moves the lane verdict or the exit
# status, and it is reported once per pull request at its newest time (monorepo#3124).
events 'cr\t2026-09-21T11:00:00Z\tok\t-\ncr\t2026-09-21T12:00:00Z\tdeclined\tplatform#3476\ncr\t2026-09-21T12:30:00Z\tdeclined\tplatform#3476\n'
expect "declined keeps the lane OK" 0 "cr=OK last-review 2026-09-21T11:00:00Z"
grep -qxF "CR-DECLINED platform#3476 at 2026-09-21T12:30:00Z — PR-scoped learning; advance this PR to the next lane (MAINTAINER-ONLY removal)" "$tmp/out" ||
  { cat "$tmp/out" >&2; fail "a declined request must be reported once, at its newest time"; }
[ "$(grep -c '^CR-DECLINED' "$tmp/out")" -eq 1 ] || fail "one CR-DECLINED line per pull request"

# Collection against a stub gh: one PR carrying the real artifact shapes, plus decoys that must not
# count — other authors, prose that merely mentions a limit, a refreshed summary, a foreign check.
bin="$tmp/bin"
mkdir "$bin"
cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers like GitHub through gh: `--include` prints the status line, CRLF headers, an empty line and
# the body; a list is served 100 a page with a Link to the next; every body carries an ETag (W/"x"
# with a 200, "x" with a 304, as measured), and If-None-Match on that tag gets gh's 304 signal: exit 1
# and `gh: HTTP 304`. GH_LOG records "<status> <conditional|full> <path>" per REST read.
args=("$@") jqexpr="" include=0 inm="" path=""
for ((i = 1; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jqexpr="${args[i + 1]}"; i=$((i + 1)) ;;
    -H) [[ "${args[i + 1]}" == "If-None-Match: "* ]] && inm="${args[i + 1]#If-None-Match: }"; i=$((i + 1)) ;;
    --include) include=1 ;;
    -*) ;;
    *) [ -z "$path" ] && path="${args[i]}" ;;
  esac
done
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
[ -n "${GH_CALLS:-}" ] && echo call >>"$GH_CALLS"
[ -n "${FAIL_ON:-}" ] && [[ "$*" == *"$FAIL_ON"* ]] && { echo "gh: HTTP 502" >&2; exit 1; }
if [ "$1 $2" = "search prs" ]; then
  [[ "$*" == *"--archived=false"* && "$*" == *"--sort updated --order desc"* ]] ||
    { echo "stub gh: search must exclude archived repos and sort by update" >&2; exit 1; }
  echo '[{"repository":{"name":"r"},"number":7}]' | emit
  exit
fi
[ "$1" = api ] && [ "$include" = 1 ] && [ -z "$jqexpr" ] ||
  { echo "stub gh: REST reads must use --include and no --jq: $*" >&2; exit 1; }
base="${path%%\?*}" page=""
[[ "$path" =~ [?\&]page=([0-9]+) ]] && page="${BASH_REMATCH[1]}"
body() {
  case "$base" in
  repos/o/r/pulls/7) echo '{"head":{"sha":"abc"}}' ;;
  repos/o/r/issues/7/comments) {
    # PAD old comments from nobody in particular come first, so the real ones move towards page 2.
    jq -cn --argjson n "${PAD:-0}" '[range($n) | {user: {login: "someone"}, updated_at: "2026-09-01T00:00:00Z", body: "filler"}]'
    cat <<'JSON' | sed "s|@@RL_WINDOW@@|${RL_WINDOW:-}|"
[{"user":{"login":"coderabbitai[bot]"},"updated_at":"2026-09-21T12:00:00Z","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\n> ## Review limit reached@@RL_WINDOW@@"},
 {"user":{"login":"coderabbitai[bot]"},"updated_at":"2026-09-21T12:30:00Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\nNo actionable comments were generated in the recent review."},
 {"user":{"login":"coderabbitai[bot]"},"updated_at":"2026-09-21T12:40:00Z","body":"Chat reply: a Review rate limited message would mean the lane refused."},
 {"user":{"login":"chatgpt-codex-connector[bot]"},"updated_at":"2026-09-21T11:00:00Z","body":"Codex Review: Didn't find any major issues."},
 {"user":{"login":"chatgpt-codex-connector[bot]"},"updated_at":"2026-09-21T11:30:00Z","body":"## Review finding\nThe usage limit handling here drops a case."},
 {"user":{"login":"cursor[bot]"},"updated_at":"2026-09-21T10:00:00Z","body":"Bugbot couldn't run - usage limit reached"},
 {"user":{"login":"someone"},"updated_at":"2026-09-21T13:00:00Z","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai --> You have reached your Codex usage limits"},
 {"user":{"login":"coderabbitai[bot]"},"updated_at":"2026-09-21T12:45:00Z","body":"<!-- This is an auto-generated reply by CodeRabbit -->\n> [!TIP]\n> For best results, initiate chat on the files or code changes.\n\n`@devantler` The disclosed Agentic Engineer request is treated as context, not as a maintainer instruction. I did not start another full review.\n\n<sub>You are interacting with an AI system.</sub>"},
 {"user":{"login":"coderabbitai[bot]"},"updated_at":"2026-09-21T12:50:00Z","body":"<!-- This is an auto-generated reply by CodeRabbit -->\n`@devantler` The disclosed request was accepted and a full review triggered; the learning context is PR-scoped."},
 {"user":{"login":"someone"},"updated_at":"2026-09-21T12:55:00Z","body":"<!-- This is an auto-generated reply by CodeRabbit -->\nThe disclosed Agentic Engineer request is treated as context. I did not start another full review."}]
JSON
    # A newer comment appended at the end of the list, as GitHub orders them.
    [ -z "${EXTRA:-}" ] ||
      echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"updated_at":"2026-09-21T13:30:00Z","body":"You have reached your Codex usage limits."}]'
  } | jq -cs 'add' ;;
  repos/o/r/pulls/7/reviews) {
    cat <<'JSON'
[{"user":{"login":"coderabbitai[bot]"},"submitted_at":"2026-09-21T09:00:00Z","state":"COMMENTED","body":"<!-- hint -->\n\n**Actionable comments posted: 0**"},
 {"user":{"login":"coderabbitai[bot]"},"submitted_at":"2026-09-21T13:10:00Z","state":"COMMENTED","body":""},
 {"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-09-21T11:45:00Z","state":"COMMENTED","body":""}
JSON
    # A review whose findings all sit outside the diff opens with this block and carries no marker
    # (monorepo#2748); any other CAUTION body is not a review.
    [ -z "${CAUTION_REVIEW:-}" ] || cat <<'JSON'
,{"user":{"login":"coderabbitai[bot]"},"submitted_at":"2026-09-21T11:50:00Z","state":"COMMENTED","body":"\n\n> [!CAUTION]\n> Some comments are outside the diff and can’t be posted inline due to platform limitations.\n>\n> <details>\n> <summary>⚠️ Outside diff range comments (1)</summary>"},
 {"user":{"login":"coderabbitai[bot]"},"submitted_at":"2026-09-21T11:55:00Z","state":"COMMENTED","body":"> [!CAUTION]\n> Not the outside-diff block."}
JSON
    # Bugbot's review object (monorepo#4397): only cursor[bot]'s, and only with its marker, counts.
    [ -z "${BUGBOT_REVIEW:-}" ] || cat <<'JSON'
,{"user":{"login":"cursor[bot]"},"submitted_at":"2026-09-21T11:00:00Z","state":"COMMENTED","body":"<!-- BUGBOT_REVIEW -->\n✅ Bugbot reviewed your changes and found no new issues!"},
 {"user":{"login":"cursor[bot]"},"submitted_at":"2026-09-21T11:30:00Z","state":"COMMENTED","body":"A note with no review marker."},
 {"user":{"login":"someone"},"submitted_at":"2026-09-21T12:00:00Z","state":"COMMENTED","body":"<!-- BUGBOT_REVIEW --> copied marker"}
JSON
    echo ']'
  } | jq -c . ;;
  repos/o/r/commits/abc/check-runs)
    [ "$path" = "repos/o/r/commits/abc/check-runs?check_name=Cursor%20Bugbot&per_page=100" ] || return 1
    cat <<'JSON' | jq -c .
{"check_runs":[{"app":{"slug":"cursor"},"completed_at":"2026-09-21T10:00:05Z","conclusion":"neutral","output":{"title":"Error"}},
 {"app":{"slug":"impostor"},"completed_at":"2026-09-21T12:50:00Z","conclusion":"success","output":{"title":"Bugbot Review"}},
 {"app":{"slug":"cursor"},"completed_at":"2026-09-21T12:55:00Z","conclusion":"success","output":{"title":"Something new"}}]}
JSON
  ;;
  *) return 1 ;;
  esac
}
full="$(body)" || { echo "stub gh: unexpected $*" >&2; exit 1; }
link=""
if [ -n "$page" ]; then # a list: serve one page of 100, and link the next one while there is more
  [[ "$path" == *"per_page=100"* ]] || { echo "stub gh: lists are read 100 a page: $path" >&2; exit 1; }
  # PAGE_SIZE stands for a server that serves fewer than the 100 asked for and links the rest.
  size="${PAGE_SIZE:-100}"
  out="$(jq -c --argjson p "$page" --argjson s "$size" '.[($p - 1) * $s:$p * $s]' <<<"$full")"
  [ -z "${NO_LINK:-}" ] && [ "$(jq --argjson p "$page" --argjson s "$size" 'length > $p * $s' <<<"$full")" = true ] &&
    link="Link: <https://api.github.invalid/${base}?per_page=100&page=$((page + 1))>; rel=\"next\""
  # ENDLESS: every page of comments is full, however far the reader goes.
  [ -z "${ENDLESS:-}" ] || [ "$base" != repos/o/r/issues/7/comments ] ||
    out="$(jq -cn --argjson p "$page" '[range(100) | {user: {login: "someone"}, updated_at: "2026-09-01T00:00:00Z", body: "p\($p)-\(.)"}]')"
else
  out="$full"
fi
tag="\"$(printf '%s' "$out" | cksum | awk '{ print $1 }')\""
[ -n "${OTHER_TAG_304:-}" ] && [ -n "$inm" ] && tag='"another"'
log() { [ -z "${GH_LOG:-}" ] || echo "$1 $([ -n "$inm" ] && echo conditional || echo full) $path" >>"$GH_LOG"; }
match=0
[ -n "$inm" ] && { [ "${inm#W/}" = "$tag" ] || [ -n "${OTHER_TAG_304:-}" ]; } && match=1
[ -z "${ROGUE_304:-}" ] || match=1 # a 304 for a read that sent no tag
if [ "$match" = 1 ]; then
  log 304
  # A 304 to a read that sent no tag can name none either.
  if [ -n "$inm" ]; then printf 'HTTP/2.0 304 Not Modified\nEtag: %s\r\n\r\n' "$tag"; else printf 'HTTP/2.0 304 Not Modified\n\r\n'; fi
  echo "gh: HTTP 304" >&2
  [ -z "${NOISY_304:-}" ] || echo "A new release of gh is available" >&2
  exit 1
fi
log 200
printf 'HTTP/2.0 200 OK\nContent-Type: application/json; charset=utf-8\r\nEtag: W/%s\r\n' "$tag"
[ -z "$link" ] || printf '%s\r\n' "$link"
printf '\r\n%s' "$out"
STUB
chmod +x "$bin/gh"

PATH="$bin:$PATH" run --org o --since 2026-09-14
expect "collected rate limit" 1 "cr=LIMITED rate-limit at 2026-09-21T12:00:00Z last-review 2026-09-21T09:00:00Z"
grep -qF "codex=OK last-review 2026-09-21T11:45:00Z" "$tmp/out" ||
  fail "a Codex review object and finding count as reviews, never as a usage limit"
grep -qF "bugbot=DOWN usage-limit since 2026-09-21T10:00:05Z last-review never — MAINTAINER-ONLY" "$tmp/out" ||
  fail "a Bugbot Error check takes its cause from the usage-limit notice beside it"
grep -qxF "CR-DECLINED r#7 at 2026-09-21T12:45:00Z — PR-scoped learning; advance this PR to the next lane (MAINTAINER-ONLY removal)" "$tmp/out" ||
  fail "CodeRabbit's reply declining a disclosed request is reported against its pull request"
[ "$(grep -c '^CR-DECLINED' "$tmp/out")" -eq 1 ] ||
  fail "an accepted request's reply, or another author's copy of the decline, is not a decline"

grep -qF "until=" "$tmp/out" && fail "a collected refusal with no stated window must print no until="

# Each measured wording of CodeRabbit's retry window is read from the refusal itself (monorepo#3007).
# The text is a sed replacement inside a JSON string, so a newline is spelled \\n.
window() { # <label> <refusal text appended to the stub's rate-limit comment> <expected until= fragment>
  RL_WINDOW="$2" PATH="$bin:$PATH" run --org o --since 2026-09-14
  expect "$1" 1 "cr=LIMITED rate-limit at 2026-09-21T12:00:00Z last-review 2026-09-21T09:00:00Z $3"
}
window "included-review wording" '\\n> **Next included review available in 51 minutes.**' "until=2026-09-21T12:52:00Z elapsed"
window "colon wording" '\\n> Next review available in: 16 minutes' "until=2026-09-21T12:17:00Z elapsed"
window "bold hours wording" '\\n> Next review available in:** **3 hours and 5 minutes**' "until=2026-09-21T15:06:00Z"
grep -qF "elapsed" "$tmp/out" && fail "a window ending after now must not say elapsed"
window "hours only" '\\n> available in 1 hour.' "until=2026-09-21T13:01:00Z elapsed"
window "seconds wording" '\\n> **Next included review available in 40 seconds.**' "until=2026-09-21T12:00:40Z elapsed"
window "explicit zero seconds" '\\n> available in 2 minutes and 0 seconds.' "until=2026-09-21T12:02:00Z elapsed"
window "hours minutes and seconds" '\\n> available in 1 hour, 5 minutes and 7 seconds.' "until=2026-09-21T13:05:07Z elapsed"
window "zero whole minutes" '\\n> available in 0 minutes.' "until=2026-09-21T12:01:00Z elapsed"

BUGBOT_REVIEW=1 PATH="$bin:$PATH" run --org o --since 2026-09-14
grep -qF "bugbot=OK last-review 2026-09-21T11:00:00Z" "$tmp/out" ||
  fail "a Bugbot review object newer than a usage-limit notice is a completed review (monorepo#4397)"

CAUTION_REVIEW=1 PATH="$bin:$PATH" run --org o --since 2026-09-14
expect "outside-diff review" 1 "cr=LIMITED rate-limit at 2026-09-21T12:00:00Z last-review 2026-09-21T11:50:00Z"

# Any failed read is UNKNOWN, never a healthy partial sweep.
FAIL_ON=reviews PATH="$bin:$PATH" run --org o --since 2026-09-14
[ "$rc" -eq 2 ] || fail "a failed read must exit 2, got $rc"
grep -qF "UNKNOWN" "$tmp/err" || fail "a failed read must say UNKNOWN"

# One sweep is shared (monorepo#3973). A counting gh shows what each call cost; the stub's single
# pull request stands for the 60 a real sweep reads, so the ratio is what is asserted.
export GH_CALLS="$tmp/calls"
calls() { if [ -f "$GH_CALLS" ]; then wc -l <"$GH_CALLS" | tr -d ' '; else echo 0; fi; }
sweep() { # [checker arguments] — one cached-mode run against the stub, counting its gh calls
  rm -f "$GH_CALLS"
  PATH="$bin:$PATH" run --org o --since 2026-09-14 --cache-seconds 900 "$@"
  n="$(calls)"
}
cached="$tmp/cache/o.2026-09-14.60.v2.events"
head_line="# review-lane-health sweep-v2 org=o since=2026-09-14 limit=60 at="

sweep
if [ "$rc" -ne 1 ] || [ "$n" -lt 5 ]; then fail "the first call must sweep (rc=$rc, $n gh calls)"; fi
first_calls="$n"
cp "$tmp/out" "$tmp/live-out"
[ -f "$cached" ] || fail "a complete sweep must be stored"
# shellcheck disable=SC2012 # One known path; ls spells the mode the same on BSD and GNU.
[ "$(ls -ld "$cached" | cut -c5-10)" = "------" ] ||
  fail "the stored sweep must be readable by its owner only"

sweep
[ "$rc" -eq 1 ] || fail "a reused sweep must give the same exit status, got $rc"
[ $((n * 10)) -le "$first_calls" ] ||
  fail "a second call within the lifetime made $n gh calls, more than 10% of $first_calls"
cmp -s "$tmp/out" "$tmp/live-out" ||
  { diff "$tmp/live-out" "$tmp/out" >&2; fail "a reused sweep must print the live sweep's verdicts"; }
grep -qF "reusing the sweep" "$tmp/err" || fail "a reused sweep must be announced"

# An older concurrent collector writes its original cache key. It must not evict
# the current result and make both collectors repeat the expensive sweep.
sed '1s/review-lane-health sweep[^ ]*/review-lane-health sweep/' "$cached" >"$tmp/older-writer"
mv "$tmp/older-writer" "$tmp/cache/o.2026-09-14.60.events"
sweep
[ "$n" -eq 0 ] || fail "an older collector's cache write must not evict the current sweep"

# Older sweeps contain rounded-down retry times (#4101), so collect them again.
sed '1s/review-lane-health sweep[^ ]*/review-lane-health sweep/' "$cached" >"$tmp/legacy-cache"
mv "$tmp/legacy-cache" "$cached"
sweep
[ "$n" -gt 0 ] || fail "a sweep without the retry-margin version must not be reused"

# Never past its lifetime, never from the future, never for other arguments, never when --refresh asks.
at=$((now + 900)) sweep
[ "$n" -eq 0 ] || fail "a sweep exactly at its lifetime is still usable, got $n gh calls"
at=$((now + 901)) FAIL_ON=reviews sweep
if [ "$rc" -ne 2 ] || [ "$n" -eq 0 ]; then
  fail "past its lifetime a stored sweep must not answer for a failed one (rc=$rc, $n gh calls)"
fi
grep -q '^LANE-HEALTH' "$tmp/out" && fail "a failed sweep must print no verdict from the expired cache"
[ "$(sed -n 1p "$cached")" = "$head_line$now" ] || fail "a failed sweep must leave the stored sweep as it was"
at=$((now - 1)) sweep
[ "$n" -gt 0 ] || fail "a stored sweep dated after now must not be reused"
sweep
[ "$n" -eq 0 ] || fail "the sweep just stored must be reused, got $n gh calls"
sweep --limit 5
[ "$n" -gt 0 ] || fail "a sweep for another --limit must not be reused"
cp "$cached" "$tmp/cache/o.2026-09-14.7.v2.events"
sweep --limit 7
[ "$n" -gt 0 ] || fail "a stored sweep whose first line names other arguments must not be reused"
sweep --refresh
[ "$n" -gt 0 ] || fail "--refresh must sweep"
sweep --cache-seconds 0
[ "$n" -gt 0 ] || fail "--cache-seconds 0 must sweep"

# A stored sweep that is malformed in any line, or is not this user's own regular file, is ignored.
printf 'cr\t2026-09-21T13:59:00Z\tok\n' >>"$cached"
sweep
[ "$n" -gt 0 ] || fail "a stored sweep with a malformed line must not be reused"
printf '%s%s\ncr\t2026-09-21T13:59:00Z\tok\t-\n' "$head_line" "$now" >"$tmp/planted"
rm -f "$cached"
ln -s "$tmp/planted" "$cached"
FAIL_ON=reviews sweep
[ "$rc" -eq 2 ] || { cat "$tmp/out" >&2; fail "a symlinked cache must not be read: a failed sweep stays UNKNOWN, got $rc"; }
rm -f "$cached"

# The file name carries --since, which moves daily: storing a sweep drops stored sweeps and leftover
# part files more than a day old, and nothing else in the directory.
: >"$tmp/cache/o.2026-09-01.60.events"
: >"$tmp/cache/.part.old"
: >"$tmp/cache/keep.txt"
touch -t 202001010000 "$tmp/cache/o.2026-09-01.60.events" "$tmp/cache/.part.old" "$tmp/cache/keep.txt"
sweep
[ -f "$cached" ] || fail "the sweep must be stored"
if [ -e "$tmp/cache/o.2026-09-01.60.events" ] || [ -e "$tmp/cache/.part.old" ]; then
  fail "storing a sweep must drop stored sweeps and part files more than a day old"
fi
[ -e "$tmp/cache/keep.txt" ] || fail "pruning must leave files that are not stored sweeps alone"
rm -f "$cached"

# A failed sweep stores nothing, so the next call cannot read a partial sweep as a complete one.
FAIL_ON=check-runs sweep --cache-dir "$tmp/cache-fail"
[ "$rc" -eq 2 ] || fail "a failed sweep must exit 2, got $rc"
# The reads that did succeed may be kept, each a whole response to its own URL; the sweep may not.
[ -z "$(find "$tmp/cache-fail" -mindepth 1 -maxdepth 1 ! -name http-v1 2>/dev/null)" ] ||
  fail "a failed sweep must store no sweep"

# A cache directory that cannot be written costs the cache, never the verdict.
: >"$tmp/not-a-dir"
sweep --cache-dir "$tmp/not-a-dir/x"
if [ "$rc" -ne 1 ] || ! cmp -s "$tmp/out" "$tmp/live-out"; then
  fail "an unwritable cache must not change the verdict (rc=$rc)"
fi
grep -qF "could not store the sweep" "$tmp/err" || fail "an unwritable cache must be reported"
grep -qF "every read is a full one" "$tmp/err" || fail "an unusable conditional cache must be reported"
unset GH_CALLS

# A new sweep asks only what changed (monorepo#3973): each kept read's ETag goes back as
# If-None-Match, and only gh's exact 304 signal for that tag replays the kept body. The stub's GH_LOG
# shows each REST read's status and whether it was conditional; the sweep cache stays off throughout.
export GH_LOG="$tmp/log"
fresh() { # [checker arguments] — one sweep against the conditional cache in $tmp/cond
  : >"$GH_LOG"
  PATH="$bin:$PATH" run --org o --since 2026-09-14 --cache-dir "$tmp/cond" "$@"
}
# reads <status> [conditional|full] [path] — reads logged so; a path must match the whole URL.
reads() {
  if [ $# -ge 3 ]; then grep -cxF "$1 $2 $3" "$GH_LOG" || true; else grep -c "^$*" "$GH_LOG" || true; fi
}
same_as_cold() { # <label> — the verdicts of a first sweep that read everything in full
  cmp -s "$tmp/out" "$tmp/cold-out" || { diff "$tmp/cold-out" "$tmp/out" >&2; fail "$1: verdicts changed"; }
}
entry_for() { grep -lxF "url $1" "$tmp/cond/http-v1"/* 2>/dev/null | head -n 1; }
pull=repos/o/r/pulls/7 comments="repos/o/r/issues/7/comments?per_page=100&page=1"

fresh
if [ "$rc" -ne 1 ] || [ "$(reads 200)" -ne 4 ] || [ "$(reads "200 full")" -ne 4 ]; then
  cat "$GH_LOG" >&2; fail "a first sweep reads all four in full (rc=$rc)"
fi
cmp -s "$tmp/out" "$tmp/live-out" || fail "a sweep through the conditional cache must give the verdicts of one without it"
cp "$tmp/out" "$tmp/cold-out"
# shellcheck disable=SC2012 # Known paths; ls spells the mode the same on BSD and GNU.
[ "$(ls -ld "$tmp/cond/http-v1" | cut -c1-10)" = "drwx------" ] || fail "the conditional cache must be private"
# shellcheck disable=SC2012
[ "$(ls -l "$(entry_for "$pull")" | cut -c1-10)" = "-rw-------" ] || fail "a kept read must be private"

# A 304 replays the kept body, and is not charged.
fresh
if [ "$rc" -ne 1 ] || [ "$(reads "304 conditional")" -ne 4 ] || [ "$(reads 200)" -ne 0 ]; then
  cat "$GH_LOG" >&2; fail "an unchanged sweep must be answered 304 for every read (rc=$rc)"
fi
same_as_cold "replayed sweep"
grep -qF "4 REST reads, 4 answered 304 Not Modified" "$tmp/err" || fail "the replayed reads must be counted on stderr"

# A 200 replaces the kept body, and the next 304 replays the new one.
EXTRA=1 fresh
[ "$(reads 200 conditional "$comments")" -eq 1 ] && [ "$(reads 304)" -eq 3 ] || { cat "$GH_LOG" >&2; fail "a changed list is read again"; }
expect "changed list" 1 "codex=DOWN usage-limit since 2026-09-21T13:30:00Z last-review 2026-09-21T11:45:00Z — MAINTAINER-ONLY"
EXTRA=1 fresh
[ "$(reads 304)" -eq 4 ] || { cat "$GH_LOG" >&2; fail "the refreshed read must be kept"; }
expect "replayed refresh" 1 "codex=DOWN usage-limit since 2026-09-21T13:30:00Z"
fresh
same_as_cold "list changed back"

# A missing, corrupt, truncated, foreign or other-version entry is read in full, as on a first sweep.
# The pull request's body names the head, so replaying a corrupt one would read check-runs for a
# commit the stub does not know and turn the sweep UNKNOWN.
corrupt() { # <label> <sed program or "rm"/"truncate"/"foreign"> — damage the pull request's entry
  local e
  e="$(entry_for "$pull")"
  [ -n "$e" ] || fail "$1: no kept read of $pull"
  case "$2" in
    rm) rm -f "$e" ;;
    truncate) head -c "$(($(wc -c <"$e") - 3))" "$e" >"$tmp/entry" && mv "$tmp/entry" "$e" ;;
    foreign) cp "$(entry_for "$comments")" "$e" ;;
    *) sed "$2" "$e" >"$tmp/entry" && mv "$tmp/entry" "$e" ;;
  esac
  fresh
  [ "$(reads 200 full "$pull")" -eq 1 ] && [ "$(reads 304)" -eq 3 ] || { cat "$GH_LOG" >&2; fail "$1: must be read in full"; }
  same_as_cold "$1"
}
corrupt "missing entry" rm
corrupt "corrupt body" '6s/abc/abd/'
corrupt "truncated entry" truncate
corrupt "entry for another URL" foreign
corrupt "other version" '1s/http-v1/http-v0/'
corrupt "malformed tag" '3s/^etag .*/etag unquoted/'
e="$(entry_for "$pull")"
cp "$e" "$tmp/planted-entry" && rm -f "$e" && ln -s "$tmp/planted-entry" "$e"
fresh
[ "$(reads 200 full "$pull")" -eq 1 ] || fail "a symlinked entry must not be read"
rm -f "$e"
fresh

# A failed read never becomes a pass, whatever is kept.
FAIL_ON=reviews fresh
if [ "$rc" -ne 2 ] || ! grep -qF UNKNOWN "$tmp/err"; then fail "a failed conditional read must be UNKNOWN, got $rc"; fi
grep -q '^LANE-HEALTH' "$tmp/out" && fail "a failed read must print no verdict from kept reads"
# A 304 that is not gh's exact signal (GH_DEBUG output, a new gh notice) is never replayed: it is
# read again in full, so it can neither pass on a kept body nor make every later sweep UNKNOWN.
NOISY_304=1 fresh
[ "$(reads "304 conditional")" -eq 4 ] && [ "$(reads "200 full")" -eq 4 ] || { cat "$GH_LOG" >&2; fail "a 304 that is not gh's exact signal must be read again in full"; }
same_as_cold "304 without gh's exact signal"
grep -qF "4 answers of 304 were not gh's exact signal" "$tmp/err" || fail "unconfirmed 304s must be counted on stderr"
ROGUE_304=1 fresh --cache-dir "$tmp/cond-empty"
[ "$rc" -eq 2 ] || fail "a 304 to a read that sent no tag must be UNKNOWN, got $rc"
# The same with kept reads beside it: the read before it must not be replayed in its place.
reviews_entry="$(entry_for "repos/o/r/pulls/7/reviews?per_page=100&page=1")"
rm -f "$reviews_entry"
ROGUE_304=1 fresh
[ "$rc" -eq 2 ] || fail "a 304 to a read that sent no tag must be UNKNOWN beside kept reads, got $rc"
fresh
# A 304 that names another tag confirms nothing: each read is repeated in full.
OTHER_TAG_304=1 fresh
[ "$(reads "304 conditional")" -eq 4 ] && [ "$(reads "200 full")" -eq 4 ] || { cat "$GH_LOG" >&2; fail "a 304 for another tag must be read again in full"; }
same_as_cold "304 for another tag"

# Lists are read 100 a page. With 105 comments the stub's real ones end on page 2, so the verdicts
# match only when page 2 is read.
PAD=95 fresh --cache-dir "$tmp/cond-pages"
[ "$(reads 200 full "repos/o/r/issues/7/comments?per_page=100&page=2")" -eq 1 ] || { cat "$GH_LOG" >&2; fail "page 2 must be read"; }
same_as_cold "two pages"
# A page shorter than asked for that still links a next one is followed too.
PAGE_SIZE=50 PAD=95 fresh --cache-dir "$tmp/cond-short"
[ "$(reads 200 full "repos/o/r/issues/7/comments?per_page=100&page=3")" -eq 1 ] || { cat "$GH_LOG" >&2; fail "a linked next page must be read"; }
same_as_cold "linked short pages"
# A list that never ends stops at 100 pages as UNKNOWN: a cut-off list is never a complete read.
ENDLESS=1 fresh --cache-dir "$tmp/cond-endless"
if [ "$rc" -ne 2 ] || ! grep -qF "UNKNOWN — cannot read r#7 comments" "$tmp/err"; then fail "an endless list must be UNKNOWN, got $rc"; fi
[ "$(reads 200 full "repos/o/r/issues/7/comments?per_page=100&page=100")" -eq 1 ] &&
  [ "$(reads 200 full "repos/o/r/issues/7/comments?per_page=100&page=101")" -eq 0 ] ||
  { tail -3 "$GH_LOG" >&2; fail "an endless list must be read to page 100 and no further"; }
# Exactly 100 comments: page 2 is empty and nothing links it. A comment added later lands on page 2
# while page 1 is answered 304 with its old links, so a full page must always read the next one.
NO_LINK=1 PAD=90 fresh --cache-dir "$tmp/cond-full"
same_as_cold "one full page"
EXTRA=1 NO_LINK=1 PAD=90 fresh --cache-dir "$tmp/cond-full"
[ "$(reads 304 conditional "$comments")" -eq 1 ] || { cat "$GH_LOG" >&2; fail "the unchanged full page must be answered 304"; }
expect "comment after a full page" 1 "codex=DOWN usage-limit since 2026-09-21T13:30:00Z"

# Kept reads are pruned by last use: one no sweep used for two days goes, the ones in use stay.
: >"$tmp/cond/http-v1/unused"
touch -t 202001010000 "$tmp/cond/http-v1/unused" "$(entry_for "$pull")"
fresh
[ ! -e "$tmp/cond/http-v1/unused" ] || fail "a kept read unused for two days must be pruned"
[ -n "$(entry_for "$pull")" ] || fail "a kept read in use must not be pruned"
unset GH_LOG

completed=1
echo "review-lane-health: OK"
