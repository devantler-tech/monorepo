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
# Every run names a cache directory inside $tmp and leaves the cache off, so no case reads the real
# per-user cache or another case's sweep; the cache cases below switch it on. $at overrides the clock.
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
# Honour --jq by running it through jq, as gh does.
args=("$@"); jqexpr=""
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[i]}" = --jq ] && jqexpr="${args[i + 1]}"; done
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
[ -n "${GH_CALLS:-}" ] && echo call >>"$GH_CALLS"
[ -n "${FAIL_ON:-}" ] && [[ "$*" == *"$FAIL_ON"* ]] && { echo "gh: HTTP 502" >&2; exit 1; }
case "$1 $2" in
  "search prs")
    [[ "$*" == *"--archived=false"* && "$*" == *"--sort updated --order desc"* ]] ||
      { echo "stub gh: search must exclude archived repos and sort by update" >&2; exit 1; }
    echo '[{"repository":{"name":"r"},"number":7}]' | emit ;;
  "api repos/o/r/pulls/7") echo '{"head":{"sha":"abc"}}' | emit ;;
  "api repos/o/r/issues/7/comments") cat <<'JSON' | sed "s|@@RL_WINDOW@@|${RL_WINDOW:-}|" | emit
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
  ;;
  "api repos/o/r/pulls/7/reviews") {
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
    echo ']'
  } | emit
  ;;
  "api repos/o/r/commits/abc/check-runs?check_name=Cursor%20Bugbot&per_page=100") cat <<'JSON' | emit
{"check_runs":[{"app":{"slug":"cursor"},"completed_at":"2026-09-21T10:00:05Z","conclusion":"neutral","output":{"title":"Error"}},
 {"app":{"slug":"impostor"},"completed_at":"2026-09-21T12:50:00Z","conclusion":"success","output":{"title":"Bugbot Review"}},
 {"app":{"slug":"cursor"},"completed_at":"2026-09-21T12:55:00Z","conclusion":"success","output":{"title":"Something new"}}]}
JSON
  ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
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
window "included-review wording" '\\n> **Next included review available in 51 minutes.**' "until=2026-09-21T12:51:00Z elapsed"
window "colon wording" '\\n> Next review available in: 16 minutes' "until=2026-09-21T12:16:00Z elapsed"
window "bold hours wording" '\\n> Next review available in:** **3 hours and 5 minutes**' "until=2026-09-21T15:05:00Z"
grep -qF "elapsed" "$tmp/out" && fail "a window ending after now must not say elapsed"
window "hours only" '\\n> available in 1 hour.' "until=2026-09-21T13:00:00Z elapsed"
window "seconds wording" '\\n> **Next included review available in 40 seconds.**' "until=2026-09-21T12:00:40Z elapsed"

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
cached="$tmp/cache/o.2026-09-14.60.events"
head_line="# review-lane-health sweep org=o since=2026-09-14 limit=60 at="

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
cp "$cached" "$tmp/cache/o.2026-09-14.7.events"
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

# A failed sweep stores nothing, so the next call cannot read a partial sweep as a complete one.
FAIL_ON=check-runs sweep --cache-dir "$tmp/cache-fail"
[ "$rc" -eq 2 ] || fail "a failed sweep must exit 2, got $rc"
[ -z "$(ls -A "$tmp/cache-fail" 2>/dev/null)" ] || fail "a failed sweep must store nothing"

# A cache directory that cannot be written costs the cache, never the verdict.
: >"$tmp/not-a-dir"
sweep --cache-dir "$tmp/not-a-dir/x"
if [ "$rc" -ne 1 ] || ! cmp -s "$tmp/out" "$tmp/live-out"; then
  fail "an unwritable cache must not change the verdict (rc=$rc)"
fi
grep -qF "could not store the sweep" "$tmp/err" || fail "an unwritable cache must be reported"
unset GH_CALLS

completed=1
echo "review-lane-health: OK"
