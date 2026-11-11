#!/usr/bin/env bash
# claude-dispatch-rate.sh — how many of a Claude task's scheduled slots actually dispatched?
#
# Compatibility entrypoint for the Go implementation in claude-lane-go/ (monorepo#3592). The flags,
# the output lines and the exit codes are unchanged; `--help` prints the full usage, the counting
# rule and what the store cannot show (claude-lane-go/dispatch-rate-help.txt).
#
# READ-ONLY: from each session transcript it reads only the first line's task marker and timestamp.
#
# Exit 0  measured; prints `DISPATCH-RATE task=<id> scheduled=<n> dispatched=<d> dropped=<n-d> ...`
#      2  UNKNOWN -- bad arguments, absent/ambiguous store, unsupported cron, an unreadable
#         transcript, no settled slot in the window, or a Go program that could not be built.
#         Never a rate computed from a partial read.
#
# The bounded build and the private executable belong to go_helper_run, which reports an
# incomplete run as UNKNOWN; this entrypoint itself keeps no temporary file and installs no trap.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)" || exit 2
# shellcheck source=go-helper-build.sh
. "$HERE/go-helper-build.sh" || exit 2
go_helper_run "$HERE/claude-lane-go" . dispatch-rate "$@"
