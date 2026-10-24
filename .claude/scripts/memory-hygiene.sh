#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
memory_hygiene_binary=""
memory_hygiene_go_cache=""
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
  if [ -n "$memory_hygiene_go_cache" ]; then
    if ! rm -rf -- "$memory_hygiene_go_cache"; then
      echo "memory-hygiene: failed to clean private Go cache" >&2
      rc=2
    fi
  fi
  if [ "$memory_hygiene_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "memory-hygiene: aborted before finishing; reporting UNKNOWN rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT

if ! memory_hygiene_build_output=$(go -C "$script_dir/memory-hygiene-go" build -o "$memory_hygiene_binary" . 2>&1); then
  # Scheduled runs repeatedly encounter an inaccessible default Go cache (#4479).
  # Retry that setup failure once, without changing the guard or a caller's
  # explicit GOCACHE. An unrelated build failure remains UNKNOWN.
  memory_hygiene_default_cache=""
  if [ -z "${GOCACHE:-}" ] \
     && memory_hygiene_default_cache=$(go env GOCACHE 2>/dev/null) \
     && [[ "$memory_hygiene_default_cache" == /* && "$memory_hygiene_default_cache" != *$'\n'* ]] \
     && printf '%s\n' "$memory_hygiene_build_output" \
        | MEMORY_HYGIENE_CACHE_ROOT="$memory_hygiene_default_cache" awk '
            (index($0, ENVIRON["MEMORY_HYGIENE_CACHE_ROOT"] "/") ||
             index($0, ENVIRON["MEMORY_HYGIENE_CACHE_ROOT"] ":")) &&
            /operation not permitted|permission denied/ { found = 1 }
            END { exit !found }'; then
    if ! memory_hygiene_go_cache=$(mktemp -d "${TMPDIR:-/tmp}/memory-hygiene-gocache.XXXXXX"); then
      echo "memory-hygiene: failed to allocate private Go cache" >&2
      exit 2
    fi
    echo "memory-hygiene: default Go cache inaccessible; retrying once with a private cache" >&2
    if ! GOCACHE="$memory_hygiene_go_cache" go -C "$script_dir/memory-hygiene-go" build -o "$memory_hygiene_binary" .; then
      echo "memory-hygiene: failed to build Go guard with private cache" >&2
      exit 2
    fi
  else
    printf '%s\n' "$memory_hygiene_build_output" >&2
    echo "memory-hygiene: failed to build Go guard" >&2
    exit 2
  fi
fi

set +e
"$memory_hygiene_binary" "$@"
memory_hygiene_exit_code=$?
set -e

memory_hygiene_finished=1
exit "$memory_hygiene_exit_code"
