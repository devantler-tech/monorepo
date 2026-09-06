#!/usr/bin/env bash
# python-ban-guard: allow-file — inert fixtures test command surfaces through the real guard.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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
exit "$fail"
