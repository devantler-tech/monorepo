#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # check() evals single-quoted conditions; CONSTITUTION is read there.
# gh-json-read.test.sh — RED/GREEN coverage for gh-json-read.sh (monorepo#2692).
#
# The cases that matter most are the fail-closed ones: a rejected or failed read must never print
# anything a caller could count, because an empty result reads exactly like "nothing matched".
#
# Fixtures are hermetic: a fake `gh` on PATH replays a scripted exit status, stdout and stderr,
# so the real CLI is never invoked.

set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/gh-json-read.sh"
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
CONSTITUTION="${AGENTS_FILE:-$REPO_ROOT/AGENTS.md}"
[ -f "$SCRIPT" ] || {
  echo "FAIL: script not found at $SCRIPT" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "FAIL: jq is required" >&2
  exit 1
}

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bin"
pass=0
fail=0

# The fake gh records its arguments and replays FAKE_RC / FAKE_OUT / FAKE_ERR.
cat >"$FIX/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_ARGS"
[ -n "${FAKE_OUT-}" ] && printf '%s' "$FAKE_OUT"
[ -n "${FAKE_ERR-}" ] && printf '%s\n' "$FAKE_ERR" >&2
exit "${FAKE_RC:-0}"
EOF
chmod +x "$FIX/bin/gh"

# run <rc> <stdout> <stderr> <args…> — sets RC, OUT, ERR for the helper's result.
run() {
  local rc=$1 out=$2 err=$3
  shift 3
  RC=0
  PATH="$FIX/bin:$PATH" FAKE_RC="$rc" FAKE_OUT="$out" FAKE_ERR="$err" FAKE_ARGS="$FIX/args" \
    "$SCRIPT" "$@" >"$FIX/out" 2>"$FIX/err" || RC=$?
  OUT=$(cat "$FIX/out")
  ERR=$(cat "$FIX/err")
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

# 1. The measured incident: an unknown field makes gh exit 1 with nothing on stdout.
run 1 "" 'Unknown JSON field: "headRefName"' search prs --json number,headRefName
check "rejected field is UNKNOWN" '[ "$RC" -eq 2 ]'
check "rejected field prints nothing to count" '[ -z "$OUT" ]'
check "rejected field names the exit status" 'grep -Fq "UNKNOWN gh-exit=1" <<<"$ERR"'
check "rejected field surfaces gh's reason" 'grep -Fq "Unknown JSON field" <<<"$ERR"'

# 2. A genuine empty result stays a result.
run 0 "[]" "" search prs --json number
check "genuine empty is success" '[ "$RC" -eq 0 ]'
check "genuine empty passes []" '[ "$OUT" = "[]" ]'

# 3. Results pass through unchanged, and the arguments reach gh unchanged.
run 0 '[{"number":1},{"number":2}]' "" search prs --owner devantler-tech --json number
check "results pass through" '[ "$(jq length <<<"$OUT")" -eq 2 ]'
check "arguments reach gh" '[ "$(tr "\n" " " <"$FIX/args")" = "search prs --owner devantler-tech --json number " ]'

# 4. A failure that still prints JSON (gh api on a 404) is not a result.
run 1 '{"message":"Not Found","status":"404"}' "gh: Not Found (HTTP 404)" api repos/x/y/pulls
check "error body is UNKNOWN" '[ "$RC" -eq 2 ]'
check "error body is not passed on" '[ -z "$OUT" ]'

# 5. Exit 0 with nothing printed is not "zero results".
run 0 "" "" api repos/x/y/pulls
check "silent success is UNKNOWN" '[ "$RC" -eq 2 ] && grep -Fq "empty-output" <<<"$ERR"'

# 6. Exit 0 with a truncated payload is not JSON.
run 0 '[{"number":1},{"numb' "" api repos/x/y/pulls
check "truncated payload is UNKNOWN" '[ "$RC" -eq 2 ] && grep -Fq "not-json" <<<"$ERR" && [ -z "$OUT" ]'

# 7. --paginate concatenates one document per page; that is still JSON.
run 0 '[{"n":1}][{"n":2}]' "" api repos/x/y/pulls --paginate
check "paginated pages are success" '[ "$RC" -eq 0 ] && [ "$(jq -s "add | length" <<<"$OUT")" -eq 2 ]'

# 8. Filters produce text the helper cannot check, so they are refused before gh runs.
for flag in --jq --jq=.x -q --template --template=x -t; do
  rm -f "$FIX/args"
  run 0 "[]" "" pr list --json number "$flag"
  check "refuses $flag" '[ "$RC" -eq 2 ] && [ ! -e "$FIX/args" ]'
done

# 9. No arguments is a usage error, never a silent success.
run 0 "[]" ""
check "no arguments is a usage error" '[ "$RC" -eq 2 ] && [ -z "$OUT" ]'

# 10. The contract names this helper where the vocabulary rule lives, so the rule has a tool.
check "AGENTS.md names the helper" 'grep -Fq ".claude/scripts/gh-json-read.sh" "$CONSTITUTION"'

echo "gh-json-read: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
