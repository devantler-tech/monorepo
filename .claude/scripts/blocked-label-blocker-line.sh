#!/usr/bin/env bash
# Compatibility entrypoint for the Go blocker guard. Bodies remain local data;
# the Go implementation owns validation, Markdown parsing and bounded forge reads.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)"
BINARY="$(mktemp "${TMPDIR:-/tmp}/blocked-label-blocker-line.XXXXXX")" || exit 2
trap 'rm -f -- "$BINARY"' EXIT
if ! go -C "$HERE/blocked-label-blocker-line-go" build -o "$BINARY" .; then
  echo "blocked-label-blocker-line.sh: could not build Go guard -- UNKNOWN" >&2
  exit 2
fi
if "$BINARY" "$@"; then
  exit 0
else
  exit "$?"
fi
