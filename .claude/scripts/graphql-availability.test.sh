#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # check() evals single-quoted conditions that read these variables.
# graphql-availability.test.sh — coverage for graphql-availability.sh and the merge-policy rule
# that names the GraphQL-unavailable state (monorepo#3429).
#
# The cases that matter most: a refusal must never read as serving, a failed or malformed call
# must never read as a refusal that clears by itself, and the probe must exercise GraphQL rather
# than read the rate-limit report, which was measured reporting an untouched bucket during a
# 35-minute refusal.
#
# Fixtures are hermetic: a fake `gh` on PATH replays a scripted exit status, stdout and stderr.
# There is deliberately no EXIT trap here, so an abort cannot be reported as a pass on bash 3.2;
# the fixture directory is removed on the normal path only.

set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/graphql-availability.sh"
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
GUIDE="${MERGE_POLICY_FILE:-$REPO_ROOT/.claude/guides/merge-policy.md}"
[ -f "$SCRIPT" ] || {
  echo "FAIL: script not found at $SCRIPT" >&2
  exit 1
}
[ -f "$GUIDE" ] || {
  echo "FAIL: merge-policy guide not found at $GUIDE" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "FAIL: jq is required" >&2
  exit 1
}

FIX=$(mktemp -d) || exit 1
mkdir -p "$FIX/bin"
pass=0
fail=0

cat >"$FIX/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_ARGS"
[ -n "${FAKE_OUT-}" ] && printf '%s' "$FAKE_OUT"
[ -n "${FAKE_ERR-}" ] && printf '%s\n' "$FAKE_ERR" >&2
exit "${FAKE_RC:-0}"
EOF
chmod +x "$FIX/bin/gh"

# run <rc> <stdout> <stderr> [args…] — sets RC, OUT, ERR, ARGS and CALLS for the helper's result.
# The fake appends one line per invocation, so ARGS holds EVERY call and CALLS counts them: a
# helper that read the rate-limit report first and then queried GraphQL would show two lines.
run() {
  local rc=$1 out=$2 err=$3
  shift 3
  RC=0
  : >"$FIX/args"
  PATH="$FIX/bin:$PATH" FAKE_RC="$rc" FAKE_OUT="$out" FAKE_ERR="$err" FAKE_ARGS="$FIX/args" \
    bash "$SCRIPT" "$@" >"$FIX/out" 2>"$FIX/err" || RC=$?
  OUT=$(cat "$FIX/out")
  ERR=$(cat "$FIX/err")
  ARGS=$(cat "$FIX/args")
  CALLS=$(grep -c '' "$FIX/args" || true)
}

check() {
  local name=$1 cond=$2
  if eval "$cond"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $name (rc=$RC out=[$OUT] err=[$ERR])" >&2
  fi
}

SERVING='{"data":{"viewer":{"login":"someone"}}}'
REFUSAL='{"errors":[{"type":"RATE_LIMIT","code":"graphql_rate_limit","message":"API rate limit already exceeded for user ID 12345678."}]}'

# --- serving ---------------------------------------------------------------------------------
run 0 "$SERVING" ''
check 'a viewer login reads as serving' '[ "$RC" -eq 0 ] && [ "$OUT" = "GRAPHQL=SERVING" ]'
check 'the probe makes exactly one call' '[ "$CALLS" -eq 1 ]'
check 'the probe exercises GraphQL on github.com' \
  'case "$ARGS" in "api graphql --hostname github.com "*) true ;; *) false ;; esac'
check 'the probe never reads the rate-limit report' \
  'case "$ARGS" in *rate_limit*) false ;; *) true ;; esac'

# --- refusing --------------------------------------------------------------------------------
run 1 "$REFUSAL" 'gh: API rate limit already exceeded for user ID 12345678.'
check 'a rate-limit refusal reads as refusing' \
  '[ "$RC" -eq 1 ] && [ "$OUT" = "GRAPHQL=REFUSING reason=rate-limit" ]'
check 'the refusal never prints the account id' \
  'case "$OUT$ERR" in *12345678*) false ;; *) true ;; esac'

run 1 '' 'gh: API rate limit already exceeded for user ID 12345678.'
check 'a refusal seen on stderr only still reads as refusing' '[ "$RC" -eq 1 ]'

run 1 "$REFUSAL" ''
check 'a refusal seen on stdout only still reads as refusing' '[ "$RC" -eq 1 ]'

run 1 '{"errors":[{"type":"RATE_LIMITED","message":"slow down"}]}' ''
check 'the RATE_LIMITED error type with no rate-limit wording is refusing' \
  '[ "$RC" -eq 1 ] && [ "$OUT" = "GRAPHQL=REFUSING reason=rate-limit" ]'

# The dangerous shape: gh exits 0 while the body is a refusal. Exit status alone would say serving.
run 0 "$REFUSAL" ''
check 'a refusal with a zero exit status is still refusing, never serving' \
  '[ "$RC" -eq 1 ] && [ "$OUT" = "GRAPHQL=REFUSING reason=rate-limit" ]'

# --- unknown ---------------------------------------------------------------------------------
run 1 '' 'gh: HTTP 502'
check 'a 5xx is unknown, not a refusal' \
  '[ "$RC" -eq 2 ] && [ "$OUT" = "GRAPHQL=UNKNOWN reason=server-error" ]'

run 1 '' 'gh: Bad credentials (HTTP 401)'
check 'an auth failure is unknown' '[ "$RC" -eq 2 ] && [ "$OUT" = "GRAPHQL=UNKNOWN reason=auth" ]'

run 1 '' 'dial tcp: lookup api.github.com: no such host'
check 'a network failure is unknown' \
  '[ "$RC" -eq 2 ] && [ "$OUT" = "GRAPHQL=UNKNOWN reason=failed-call" ]'

run 0 '' ''
check 'an empty successful reply is unknown, never serving' \
  '[ "$RC" -eq 2 ] && [ "$OUT" = "GRAPHQL=UNKNOWN reason=malformed-reply" ]'

run 0 '<html>bad gateway</html>' ''
check 'a non-JSON successful reply is unknown, never serving' '[ "$RC" -eq 2 ]'

run 0 '{"data":{"viewer":null}}' ''
check 'a reply with no viewer is unknown, never serving' '[ "$RC" -eq 2 ]'

run 0 '{"data":{"viewer":{"login":123}}}' ''
check 'a non-string login is unknown, never serving' \
  '[ "$RC" -eq 2 ] && [ "$OUT" = "GRAPHQL=UNKNOWN reason=malformed-reply" ]'

run 0 '{"data":{"viewer":{"login":["x"]}}}' ''
check 'an array login is unknown, never serving' '[ "$RC" -eq 2 ]'

run 0 '{"data":{"viewer":{"login":""}}}' ''
check 'an empty login is unknown, never serving' '[ "$RC" -eq 2 ]'

run 0 '{"data":{"viewer":{"login":"someone"}},"errors":[{"type":"OTHER","message":"partial"}]}' ''
check 'a reply carrying errors beside a login is unknown, never serving' '[ "$RC" -eq 2 ]'

run 0 "$SERVING" '' --verbose
check 'an argument is a usage error and makes no call' \
  '[ "$RC" -eq 2 ] && [ "$OUT" = "GRAPHQL=UNKNOWN reason=usage" ] && [ -z "$ARGS" ]'

# --- the contract: the merge policy names the state and what a run does in it -----------------
RC=0
OUT=''
ERR=''
# Scope the assertions to the paragraph that names the state. An empty extraction passes every
# substring check, so a missing paragraph is its own failure.
section=$(awk '/Name the state: `GraphQL-unavailable`/ {on = 1} on && /^$/ {exit} on' "$GUIDE")
check 'the merge policy has a paragraph naming GraphQL-unavailable' '[ -n "$section" ]'
check 'it names the probe' 'case "$section" in *graphql-availability.sh*) true ;; *) false ;; esac'
check 'it says the thread count is UNKNOWN' \
  'case "$section" in *UNKNOWN*) true ;; *) false ;; esac'
check 'it says no merge goes ahead' \
  'case "$section" in *"decline every merge"*) true ;; *) false ;; esac'
check 'it says non-merge work continues' \
  'case "$section" in *"continue all non-merge work"*) true ;; *) false ;; esac'
check 'it rules out the rate-limit report as evidence' \
  'case "$section" in *rate_limit*) true ;; *) false ;; esac'
check 'it forbids parking the pull request behind the maintainer' \
  'case "$section" in *"never a maintainer gate"*) true ;; *) false ;; esac'
check 'it sends an UNKNOWN verdict to diagnosis instead of waiting it out' \
  'case "$section" in *"diagnose it by its reason"*) true ;; *) false ;; esac'

rm -rf "$FIX"
echo "graphql-availability.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
