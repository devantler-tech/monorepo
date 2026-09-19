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

# Collection against a stub gh: one PR carrying one artifact of each kind.
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
  "search prs") echo '[{"repository":{"name":"r"},"number":7}]' | emit ;;
  "api repos/o/r/pulls/7") echo '{"head":{"sha":"abc"}}' | emit ;;
  "api repos/o/r/issues/7/comments") cat <<'JSON' | emit
[{"user":{"login":"coderabbitai[bot]"},"updated_at":"2026-09-21T12:00:00Z","body":"<!-- x -->\n> ## Review limit reached\nReview rate limited."},
 {"user":{"login":"chatgpt-codex-connector[bot]"},"updated_at":"2026-09-21T11:00:00Z","body":"Codex Review: Didn't find any major issues."},
 {"user":{"login":"cursor[bot]"},"updated_at":"2026-09-21T10:00:00Z","body":"Bugbot couldn't run - usage limit reached"},
 {"user":{"login":"someone"},"updated_at":"2026-09-21T13:00:00Z","body":"Review rate limited. usage limit"}]
JSON
  ;;
  "api repos/o/r/pulls/7/reviews") cat <<'JSON' | emit
[{"user":{"login":"coderabbitai[bot]"},"submitted_at":"2026-09-21T09:00:00Z","body":"<!-- hint -->\n\n**Actionable comments posted: 0**"},
 {"user":{"login":"coderabbitai[bot]"},"submitted_at":"2026-09-21T13:10:00Z","body":""}]
JSON
  ;;
  "api repos/o/r/commits/abc/check-runs?check_name=Cursor%20Bugbot&per_page=100")
    echo '{"check_runs":[{"completed_at":"2026-09-21T10:00:05Z","conclusion":"neutral","output":{"title":"Error"}}]}' | emit ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$bin/gh"

PATH="$bin:$PATH" run --org o --since 2026-09-14
expect "collected rate limit" 1 "cr=LIMITED rate-limit at 2026-09-21T12:00:00Z last-review 2026-09-21T09:00:00Z"
grep -qF "codex=OK last-review 2026-09-21T11:00:00Z" "$tmp/out" || fail "a Codex clean pass must read OK"
grep -qF "bugbot=DOWN error since 2026-09-21T10:00:05Z" "$tmp/out" ||
  fail "Bugbot neutral+Error must be a failure, newer than its usage-limit comment"

# Any failed read is UNKNOWN, never a healthy partial sweep.
FAIL_ON=reviews PATH="$bin:$PATH" run --org o --since 2026-09-14
[ "$rc" -eq 2 ] || fail "a failed read must exit 2, got $rc"
grep -qF "UNKNOWN" "$tmp/err" || fail "a failed read must say UNKNOWN"

echo "review-lane-health: OK"
