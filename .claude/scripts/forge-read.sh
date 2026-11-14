#!/usr/bin/env bash
# Launcher for the conditional forge reader (forge-read-go, monorepo#5051).
# It builds a temporary binary, so no platform-specific artifact is checked in.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)"
BINARY="$(mktemp "${TMPDIR:-/tmp}/forge-read.XXXXXX")" || exit 2
# Bash 3.2 reports a `set -u` abort to an EXIT trap as status 0, and the trap's own successful
# cleanup then becomes the script's status. Completion is recorded explicitly, so reaching a
# verdict is the only way a zero status leaves this script; an abort reports UNKNOWN (monorepo#3414).
blocked_label_blocker_line_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
blocked_label_blocker_line_cleanup() {
  local rc=$?
  rm -f -- "$BINARY"
  if [ "$blocked_label_blocker_line_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "forge-read.sh: aborted before finishing; reporting UNKNOWN rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
trap blocked_label_blocker_line_cleanup EXIT
# shellcheck source=go-helper-build.sh
. "$HERE/go-helper-build.sh" || exit 2
if ! go_helper_build "$HERE/forge-read-go" "$BINARY" .; then
  echo "forge-read.sh: could not build Go guard -- UNKNOWN" >&2
  exit 2
fi
rc=0
"$BINARY" "$@" || rc=$?
blocked_label_blocker_line_finished=1
exit "$rc"
