#!/usr/bin/env bash
# python-ban-guard: allow-file — inert fixtures test command surfaces through the real guard.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$tmp"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then
    echo "python-ban-guard-command-surfaces.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    exit 1
  fi
}
trap on_exit EXIT
mkdir -p "$tmp/tools"
: >"$tmp/tools/check.sh"
git -C "$tmp" init -q
git -C "$tmp" add -- tools/check.sh
fail=0

# Run only the scanner entrypoint; fixture contents never become shell commands.
check() {
  local name="$1" command="$2" expected="$3" out rc=0
  printf '%s\n' "$command" >"$tmp/tools/check.sh"
  out="$(bash "$here/python-ban-guard.sh" "$tmp" 2>&1)" || rc=$?
  if [[ "$rc" == "$expected" ]] && { [[ "$rc" == 0 ]] || [[ "$out" == *'Python invocation'* ]]; }; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s: rc=%s expected=%s %s\n' "$name" "$rc" "$expected" "$out"
    fail=1
  fi
}
check 'bash rcfile command' 'bash --rcfile python3 -c '\''python3 --version'\''' 1
check 'bash init-file command' 'bash --init-file python3 -c '\''python3 --version'\''' 1
check 'bash rcfile data' 'bash --rcfile python3 -c '\''echo safe'\''' 0
check 'unset env expansion' 'env -u EMPTY -S '\''${EMPTY} python3 --version'\''' 1
check 'optional env word data' 'env -u EMPTY -S '\''${EMPTY} echo python3'\''' 0
check 'quoted env expansion stays operand' 'env -S '\''"${EMPTY}" python3'\''' 0
check 'find exec command' 'find . -exec python3 --version '\'';'\''' 1
check 'find execdir command' 'find . -execdir python3 '\''{}'\'' +' 1
check 'find ok command' 'find . -ok python3 --version '\'';'\''' 1
check 'find okdir command' 'find . -okdir python3 --version '\'';'\''' 1
check 'find predicate data' 'find . -name python3 -printf '\''python3 --version'\''' 0
check 'find command argument data' 'find . -exec echo -exec python3 '\'';'\''' 0
completed=1
exit "$fail"
