#!/usr/bin/env bash
# claude-lane-liveness.sh — did the Claude lane's dispatched runs actually RUN?
#
# Compatibility entrypoint for the Go implementation in claude-lane-go/ (monorepo#3592). The flags,
# the output lines and the exit codes are unchanged; `--help` prints the full usage and design note
# (claude-lane-go/liveness-help.txt).
#
# READ-ONLY, and deliberately NARROW: from each session transcript it reads only the first line's
# task marker, timestamps, record types, and on assistant records the runtime-error class and
# whether the last turn is an unanswered tool call. It never reads message text.
#
# Exit 0  every enabled task checked is dispatching and produced work on its most recent settled run
#      1  NOT PRODUCING -- a dispatch produced no work, stalled on a tool call, or never happened
#      2  UNKNOWN -- could not determine, including a Go program that could not be built
# Only 0 and 1 are verdicts; a caller must not read anything else as "alive".
#
# The bounded build and the private executable belong to go_helper_run, which reports an
# incomplete run as UNKNOWN; this entrypoint itself keeps no temporary file and installs no trap.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)" || exit 2
# shellcheck source=go-helper-build.sh
. "$HERE/go-helper-build.sh" || exit 2
go_helper_run "$HERE/claude-lane-go" . liveness "$@"
