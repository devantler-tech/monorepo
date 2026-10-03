#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
memory_hygiene_binary=""
if ! memory_hygiene_binary="$(mktemp "${TMPDIR:-/tmp}/memory-hygiene.XXXXXX")"; then
  echo "memory-hygiene: failed to allocate temporary binary" >&2
  exit 2
fi

# Bash 3.2 reports a `set -u` abort to an EXIT trap as status 0, and the trap's own successful
# cleanup then becomes the script's status. Completion is recorded explicitly, so reaching the end is
# the only way a zero status leaves this script; an abort reports UNKNOWN (monorepo#3414).
memory_hygiene_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local rc=$?
  rm -f -- "$memory_hygiene_binary"
  if [ "$memory_hygiene_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "memory-hygiene: aborted before finishing; reporting UNKNOWN rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT

if ! go -C "$script_dir/memory-hygiene-go" build -o "$memory_hygiene_binary" .; then
  echo "memory-hygiene: failed to build Go guard" >&2
  exit 2
fi

set +e
"$memory_hygiene_binary" "$@"
memory_hygiene_exit_code=$?
set -e

memory_hygiene_finished=1
exit "$memory_hygiene_exit_code"
