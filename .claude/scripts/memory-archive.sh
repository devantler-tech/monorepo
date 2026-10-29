#!/usr/bin/env bash
# Archive one Markdown section through the existing guarded helpers (#2990).
# The temporary binary preserves the command's exit status without checked-in artifacts.
set -Eeuo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
memory_archive_binary=""
if ! memory_archive_binary="$(mktemp "${TMPDIR:-/tmp}/memory-archive.XXXXXX")"; then
  echo 'memory-archive: failed to allocate temporary binary' >&2
  exit 2
fi
memory_archive_finished=0
# Bash 3.2 may mask an abort in EXIT; only a completed command can leave zero.
# shellcheck disable=SC2329 # Invoked indirectly by EXIT.
cleanup() {
  local rc=$?
  rm -f -- "$memory_archive_binary"
  if [[ "$memory_archive_finished" != 1 && "$rc" == 0 ]]; then
    echo 'memory-archive: aborted before completion; reporting UNKNOWN' >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT
if ! go -C "$script_dir/memory-backup-go" build -o "$memory_archive_binary" ./cmd/memory-archive; then
  echo 'memory-archive: failed to build Go helper' >&2
  exit 2
fi
set +e
MEMORY_ARCHIVE_HELPER_DIR="$script_dir" "$memory_archive_binary" "$@"
memory_archive_exit=$?
set -e
memory_archive_finished=1
exit "$memory_archive_exit"
