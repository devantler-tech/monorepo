#!/usr/bin/env bash
# unsigned-commit-report.sh — report unsigned or unverifiable commits on agent-lane branches
# WITHOUT failing the pull request (monorepo#3212).
#
# Compatibility entrypoint for the Go implementation in unsigned-commit-report-go/ (monorepo#3224).
# The CLI, the three modes, the output lines and the exit codes are unchanged; `--help` prints the
# full usage and design note (unsigned-commit-report-go/help.txt). Every GitHub read still goes
# through `gh` on PATH, so unsigned-commit-report.test.sh's stubbed `gh` drives this exactly as it
# drove the Bash implementation.
#
# EXIT CODES
#   0  the report was produced (findings or not -- this is the non-blocking contract)
#   2  UNKNOWN: usage error, unreadable payload, a failed API read, or the Go program could not be
#      built. Never treat as "none found".
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# /tmp, not TMPDIR, as go_helper_run does: TMPDIR can point at a volume that is not mounted.
BINARY="$(mktemp /tmp/unsigned-commit-report.XXXXXX)" || exit 2
# Bash 3.2 reports a `set -u` abort to an EXIT trap as status 0, and the trap's own successful
# cleanup then becomes the script's status. Completion is recorded explicitly, so reaching a
# verdict is the only way a zero status leaves this script; an abort reports UNKNOWN (monorepo#3414).
unsigned_commit_report_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
unsigned_commit_report_cleanup() {
  local rc=$?
  rm -f -- "$BINARY"
  if [ "$unsigned_commit_report_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "unsigned-commit-report.sh: aborted before finishing; reporting UNKNOWN rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
trap unsigned_commit_report_cleanup EXIT
# shellcheck source=go-helper-build.sh
. "$HERE/go-helper-build.sh" || exit 2
if ! go_helper_build "$HERE/unsigned-commit-report-go" "$BINARY" .; then
  echo "unsigned-commit-report.sh: could not build the Go report -- UNKNOWN" >&2
  exit 2
fi
rc=0
UNSIGNED_COMMIT_REPORT_DEFAULT_INSTANCES="$HERE/../plugin-consumption/agent-instances.json" "$BINARY" "$@" || rc=$?
unsigned_commit_report_finished=1
exit "$rc"
