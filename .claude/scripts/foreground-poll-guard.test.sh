#!/usr/bin/env bash
# Behaviour and wiring tests for .claude/scripts/foreground-poll-guard.sh (monorepo#5010).
#
# The guard's interesting failures are (a) admitting a foreground poll loop, which is the gap it
# closes, and (b) denying work it must leave alone: a backgrounded watcher, a loop that waits on a
# local process, a short sampling loop, a loop over a list, or a script written through a heredoc.
# Each denial is checked for the guard's own reason, not merely a non-zero exit. The wiring half
# asserts settings.json attaches the guard: a guard no hook calls protects nothing.

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly root_dir
readonly guard="${root_dir}/.claude/scripts/foreground-poll-guard.sh"
readonly settings="${root_dir}/.claude/settings.json"

fail=0
fail_case() {
  echo "::error::$1"
  fail=1
}

tmp="$(mktemp -d)"
test_run_completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "${tmp}"
  if [ "${test_run_completed}" != 1 ]; then
    echo "foreground-poll-guard.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
  fi
  exit "${status}"
}
trap on_exit EXIT

if [ ! -f "${guard}" ] || [ ! -x "${guard}" ] || [ -L "${guard}" ]; then
  fail_case "foreground-poll-guard.sh is not a regular executable"
  test_run_completed=1
  exit 1
fi

# run <name> <command> [background] [monitor]: sets rc and err for the call.
run() {
  local name=$1 cmd=$2 bg=${3:-false} mon=${4:-} payload
  payload=$(jq -cn --arg c "${cmd}" --argjson b "${bg}" --arg m "${mon}" \
    '{tool_name: "Bash", tool_input: ({command: $c}
      + (if $b then {run_in_background: true} else {} end)
      + (if $m != "" then {description: "watch", timeout_ms: 600000} else {} end))}')
  set +e
  printf '%s' "${payload}" | "${guard}" >"${tmp}/${name}.out" 2>"${tmp}/${name}.err"
  rc=$?
  set -e
  err=$(cat "${tmp}/${name}.err")
}

expect_deny() {
  run "$1" "$2"
  if [ "${rc}" -ne 2 ]; then
    fail_case "$1: expected a denial (exit 2), got exit ${rc}"
  elif ! grep -q 'deny: foreground remote poll loop' <<<"${err}"; then
    fail_case "$1: exit 2 without the guard's own reason: ${err}"
  fi
}

expect_allow() {
  run "$1" "$2" "${3:-false}" "${4:-}"
  [ "${rc}" -eq 0 ] || fail_case "$1: expected admission (exit 0), got exit ${rc}: ${err}"
}

# --- Denied: the measured shapes -------------------------------------------------------------
# shellcheck disable=SC2016 # The commands are data for the guard, never expanded here.
{
  expect_deny until-checks 'until [ "$(gh pr checks 7932 --repo devantler-tech/ksail --json bucket -q length)" = 0 ]; do sleep 30; done; echo done'
  expect_deny until-assign 'until c=$(gh run view 1 --repo devantler-tech/go-template --json status -q .status) && [ "$c" != queued ]; do sleep 20; done'
  expect_deny for-seq 'for i in $(seq 1 18); do r=$(gh api repos/devantler-tech/platform/pulls/1/reviews --jq length); [ "$r" -gt 0 ] && break; sleep 30; done'
  expect_deny for-brace 'for i in {1..10}; do kubectl get pods -n x | grep -q Running && break; sleep 10; done'
  expect_deny while-counter 'i=0; while [ $i -lt 100 ]; do s=$(gh pr view 5 --json state -q .state); [ "$s" = MERGED ] && break; sleep 10; i=$((i+10)); done'
  expect_deny multiline 'until git ls-remote origin refs/heads/x | grep -q .
do
  sleep 15
done'
  expect_deny git-dash-c 'while ! git -C /x fetch -q origin main; do sleep 5; done'
  # A here-string is not a heredoc: the poll loop on the next line must still be judged.
  expect_deny here-string 'read -r state <<<pending
until gh pr checks 1; do sleep 30; done'
  # A remote read in an `if` (or `elif`) condition inside the body is still a poll.
  expect_deny if-in-body 'for i in $(seq 1 20); do if gh pr view 1 --json state -q .state | grep -q MERGED; then break; fi; sleep 30; done'
  expect_deny elif-in-body 'while true; do if false; then :; elif kubectl get ns x; then break; fi; sleep 10; done'
}

# --- Admitted: what the guard must leave alone -----------------------------------------------
# shellcheck disable=SC2016
{
  expect_allow backgrounded 'until [ "$(gh pr checks 1 --json bucket -q length)" = 0 ]; do sleep 30; done' true
  # The runtime runs Bash hooks for Monitor too, as a Bash call with Monitor's own input (#5016).
  expect_allow monitor 'until [ "$(gh pr checks 1 --json bucket -q length)" = 0 ]; do sleep 30; done' false monitor
  expect_allow local-process 'while kill -0 123 2>/dev/null; do sleep 2; done; gh pr view 1'
  expect_allow sampling 'for i in $(seq 1 12); do curl -s -o /dev/null https://example.invalid/; sleep 2; done'
  expect_allow list-loop 'for r in ksail platform; do gh api repos/devantler-tech/$r --jq .name; sleep 5; done'
  expect_allow settle 'gh pr merge 1 --squash; sleep 5; gh pr view 1 --json state'
  expect_allow heredoc 'cat > /tmp/w.sh <<'"'"'EOF'"'"'
until gh pr checks 1; do sleep 30; done
EOF
chmod +x /tmp/w.sh'
  expect_allow clock-only 'until [ "$(date -u +%H%M)" -ge 1200 ]; do sleep 10; done; date -u'
  expect_allow no-loop 'gh pr checks 1'
  # A control word inside an argument is not a command position.
  expect_allow quoted-if 'for i in {1..3}; do echo "check if gh is available"; sleep 5; done'
}

printf '%s' '{"tool_name":"Edit","tool_input":{"command":"until gh x; do sleep 30; done"}}' | "${guard}" >/dev/null 2>&1 ||
  fail_case "a non-Bash tool must be admitted"
printf '' | "${guard}" >/dev/null 2>&1 || fail_case "empty input must be admitted (wall-clock guard fails open)"
printf 'not json' | "${guard}" >/dev/null 2>&1 || fail_case "unparseable input must be admitted (wall-clock guard fails open)"

# --- Wiring: settings.json attaches the guard as a Bash PreToolUse hook ------------------------
# shellcheck disable=SC2016
expected='"$CLAUDE_PROJECT_DIR"/.claude/scripts/foreground-poll-guard.sh'
EXPECTED_GUARD="${expected}" jq -e '
  [.hooks.PreToolUse[]? | select(.matcher == "Bash")
   | .hooks[] | select(.type == "command" and .command == env.EXPECTED_GUARD)] | length == 1
' "${settings}" >/dev/null ||
  fail_case "settings.json does not attach foreground-poll-guard.sh as a Bash PreToolUse command hook"

if [ "${fail}" -ne 0 ]; then
  exit 1
fi
echo "foreground-poll-guard: foreground remote poll loops denied, everything else admitted, wired in settings.json."
test_run_completed=1
