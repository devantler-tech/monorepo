#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
memory_hygiene_binary="$(mktemp "${TMPDIR:-/tmp}/memory-hygiene.XXXXXX")"

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  rm -f -- "$memory_hygiene_binary"
}
trap cleanup EXIT

go -C "$script_dir/memory-hygiene-go" build -o "$memory_hygiene_binary" .

set +e
"$memory_hygiene_binary" "$@"
memory_hygiene_exit_code=$?
set -e

exit "$memory_hygiene_exit_code"
