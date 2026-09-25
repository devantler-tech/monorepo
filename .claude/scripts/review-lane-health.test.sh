#!/usr/bin/env bash
# RED/GREEN coverage for review-lane-health.sh: each verdict from recorded events, the artifact
# classification against a stub gh, and a failed read reported as UNKNOWN.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$root/.claude/scripts/review-lane-health.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "review-lane-health test: $*" >&2; exit 1; }

now=1790000000 # 2026-09-21T13:33:20Z
run() { set +e; "$checker" "$@" --now "$now" >"$tmp/out" 2>"$tmp/err"; rc=$?; set -e; }
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
[ -n "${FAIL_ON:-}" ] && [[ "$*" == *"$FAIL_ON"* ]] && { echo "gh: HTTP 502" >&2; exit 1; }
case "$1 $2" in
  "search prs")
    [[ "$*" == *"--archived=false"* && "$*" == *"--sort updated --order desc"* ]] ||
      { echo "stub gh: search must exclude archived repos and sort by update" >&2; exit 1; }
    echo '[{"repository":{"name":"r"},"number":7}]' | emit ;;
  "api repos/o/r/pulls/7") echo '{"head":{"sha":"abc"}}' | emit ;;
  "api repos/o/r/issues/7/comments") cat <<'JSON' | emit
[{"user":{"login":"coderabbitai[bot]"},"updated_at":"2026-09-21T12:00:00Z","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\n> ## Review limit reached"},
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

CAUTION_REVIEW=1 PATH="$bin:$PATH" run --org o --since 2026-09-14
expect "outside-diff review" 1 "cr=LIMITED rate-limit at 2026-09-21T12:00:00Z last-review 2026-09-21T11:50:00Z"

# Any failed read is UNKNOWN, never a healthy partial sweep.
FAIL_ON=reviews PATH="$bin:$PATH" run --org o --since 2026-09-14
[ "$rc" -eq 2 ] || fail "a failed read must exit 2, got $rc"
grep -qF "UNKNOWN" "$tmp/err" || fail "a failed read must say UNKNOWN"

echo "review-lane-health: OK"
