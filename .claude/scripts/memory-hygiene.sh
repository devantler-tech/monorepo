#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
memory_hygiene_binary="$(mktemp "${TMPDIR:-/tmp}/memory-hygiene.XXXXXX")"

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  rm -f -- "$memory_hygiene_binary"
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

exit "$memory_hygiene_exit_code"
