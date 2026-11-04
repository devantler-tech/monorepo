#!/usr/bin/env bash
# board-add.sh — ensure an issue is on the 🌊 Project Board with a Status.
#
# Compatibility entrypoint for the Go implementation in board-add-go/ (monorepo#2510). Callers,
# the contract and the skills keep this path; the Go program owns URL and scope validation, the
# visibility gate, the add, the Status write, the read-back verification and the rate-limit
# diagnosis. Every GitHub call still goes through `gh` on PATH, so board-add.test.sh's stubbed
# `gh` drives this exactly as it drove the Bash implementation.
#
# USAGE
#   .claude/scripts/board-add.sh <issue-url> [status-name]
#   .claude/scripts/board-add.sh https://github.com/devantler-tech/ksail/issues/42
#   .claude/scripts/board-add.sh <issue-url> "🫴 Ready"
#
#   With no status argument, preserve an existing Status and use "📥 Backlog"
#   only for a card with no Status. An explicit status deliberately updates it.
#
# EXIT CODES
#   0  item has a Status; an explicit change is verified by read-back
#   1  usage error
#   2  add or set failed, the read-back did not show the requested Status, or the Go program
#      could not be built (UNKNOWN: nothing was attempted)
#
# NOTES
#   - Idempotent: an issue already on the board is not duplicated. A membership
#     sweep leaves its Status untouched; explicit status changes are verified.
#   - PRIVATE REPOS: project 5 is PUBLIC. Adding an item from a private repo is a
#     maintainer decision, never an agent default — this command refuses one.
#   - Serialized on purpose: GitHub's secondary limits allow ~80 content-generating
#     requests/minute. Never fan this out concurrently.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# /tmp, not TMPDIR, as go_helper_run does: TMPDIR can point at a volume that is not mounted.
BINARY="$(mktemp /tmp/board-add.XXXXXX)" || exit 2
# Bash 3.2 reports a `set -u` abort to an EXIT trap as status 0, and the trap's own successful
# cleanup then becomes the script's status. Completion is recorded explicitly, so reaching a
# verdict is the only way a zero status leaves this script; an abort reports UNKNOWN (monorepo#3414).
board_add_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
board_add_cleanup() {
  local rc=$?
  rm -f -- "$BINARY"
  if [ "$board_add_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "board-add: aborted before finishing; reporting UNKNOWN rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
trap board_add_cleanup EXIT
# shellcheck source=go-helper-build.sh
. "$HERE/go-helper-build.sh" || exit 2
if ! go_helper_build "$HERE/board-add-go" "$BINARY" .; then
  echo "board-add: could not build the Go helper -- UNKNOWN; nothing was written" >&2
  exit 2
fi
rc=0
"$BINARY" "$@" || rc=$?
board_add_finished=1
exit "$rc"
