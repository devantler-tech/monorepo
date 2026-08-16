#!/usr/bin/env bash
# Thin portable launcher for the Go implementation. The helper is invoked only
# before a destructive memory rewrite, so building an isolated temporary binary
# keeps the repository free of checked-in platform-specific artifacts.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
memory_backup_binary=""
if ! memory_backup_binary="$(mktemp "${TMPDIR:-/tmp}/memory-backup.XXXXXX")"; then
  echo "memory-backup: failed to allocate temporary binary" >&2
  exit 2
fi

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  rm -f -- "$memory_backup_binary"
}
trap cleanup EXIT

if ! go -C "$script_dir/memory-backup-go" build -o "$memory_backup_binary" .; then
  echo "memory-backup: failed to build Go helper" >&2
  exit 2
fi

set +e
"$memory_backup_binary" "$@"
memory_backup_exit_code=$?
set -e

exit "$memory_backup_exit_code"
